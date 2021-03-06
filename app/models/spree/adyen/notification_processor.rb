module Spree
  module Adyen
    # Class responsible for taking in a notification from Adyen and applying
    # some form of modification to the associated payment.
    #
    # I would in the future like to refactor this by breaking this into
    # separate classes that are only aware of how to process specific kinds of
    # notifications (auth, capture, refund, etc.).
    class NotificationProcessor
      attr_accessor :notification, :payment, :order

      def initialize(notification, payment = nil)
        self.notification = notification
        self.order = notification.order
        self.payment = payment ? payment : notification.payment
      end

      # for the given payment, process all notifications that are currently
      # unprocessed in the order that they were dispatched.
      def self.process_outstanding!(payment)
        payment.
          source.
          notifications(true). # bypass caching
          unprocessed.
          as_dispatched.
          map do |notification|
            new(notification, payment).process!
          end
      end

      # only process the notification if there is a matching payment there's a
      # number of reasons why there may not be a matching payment such as test
      # notifications, reports etc, we just log them and then accept
      def process!
        Rails.logger.debug "Spree::Adyen::process!"
        return notification if order.nil?
        Rails.logger.debug "Spree::Adyen::step 1"
        order.with_lock do
          Rails.logger.debug "Spree::Adyen::step 2: #{should_create_payment?}"
          if should_create_payment?
            self.payment = create_missing_payment
          end

          Rails.logger.debug "Spree::Adyen::step 3"

          if !notification.success?
            Rails.logger.debug "Spree::Adyen::step 10"
            handle_failure

          elsif notification.modification_event?
            Rails.logger.debug "Spree::Adyen::step 11"
            handle_modification_event

          elsif notification.normal_event?
            Rails.logger.debug "Spree::Adyen::step 12"
            handle_normal_event

          end
        end

        return notification
      end

      private

      def handle_failure
        notification.processed!
        # ignore failures if the payment was already completed, or if it doesn't
        # exist
        return if payment.nil? || payment.completed?
        # might have to do something else on modification events,
        # namely refunds
        payment.failure!
      end

      def handle_modification_event
        if notification.capture?
          notification.processed!
          complete_payment!

        elsif notification.cancel_or_refund?
          notification.processed!
          payment.void

        elsif notification.refund?
          payment.refunds.create!(
            amount: notification.value / 100.0, # cents to dollars
            transaction_id: notification.psp_reference,
            refund_reason_id: ::Spree::RefundReason.first.id # FIXME
          )
          # payment was processing, move back to completed
          payment.complete! unless payment.completed?
          notification.processed!
        end
      end

      # normal event is defined as just AUTHORISATION
      def handle_normal_event
        Rails.logger.debug "Spree::Adyen::handle_normal_event"
        # Payment may not have psp_reference. Add this from notification if it
        # doesn't have one.
        unless self.payment.response_code
          payment.response_code = notification.psp_reference
          payment.save
        end

        if notification.auto_captured?

          Rails.logger.debug "Spree::Adyen::notification.auto_captured?: true"
          complete_payment!

        # elsif payment.hpp_payment?
        #   payment.capture!

        end
        notification.processed!
      end

      def complete_payment!
        Rails.logger.debug "Spree::Adyen::complete_payment!"
        money = ::Money.new(notification.value, notification.currency)

        # this is copied from Spree::Payment::Processing#capture
        payment.capture_events.create!(amount: money.to_f)
        payment.update!(amount: payment.captured_amount)
        payment.complete!
      end

      # At this point the auth was received before the redirect, we create
      # the payment here with the information we have available so that if
      # the user is not redirected to back for some reason we still have a
      # record of the payment.
      def create_missing_payment
        order = notification.order

        source = Spree::Adyen::HppSource.new(
          auth_result: "unknown",
          order: order,
          payment_method: notification.payment_method,
          psp_reference: notification.psp_reference
        )

        payment = order.payments.create!(
          amount: notification.money.dollars,
          # We have no idea what payment method they used, this will be
          # updated when/if they get redirected
          payment_method: Spree::Gateway::AdyenHPP.last,
          response_code: notification.psp_reference,
          source: source,
          order: order
        )

        order.contents.advance
        order.complete
        payment
      end

      def should_create_payment?
        notification.authorisation? &&
        notification.success? &&
        notification.order.present? &&
        payment.nil?
      end
    end
  end
end
