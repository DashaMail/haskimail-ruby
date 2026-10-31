# frozen_string_literal: true

# Example Rails controller for Haskimail webhooks.
#
# config/routes.rb:
#   post "/webhooks/haskimail", to: "haskimail_webhooks#create"
#   post "/webhooks/haskimail/inbound", to: "haskimail_webhooks#inbound"
class HaskimailWebhooksController < ActionController::API
  # ActionController::API leaves HTTP authentication out; bring it back.
  include ActionController::HttpAuthentication::Basic::ControllerMethods

  # Inbound webhooks are not signed: protect them with HTTP basic auth
  # (configure the URL as https://user:password@your-app.example/webhooks/haskimail/inbound).
  http_basic_authenticate_with name: ENV.fetch("HASKIMAIL_INBOUND_USER"),
                               password: ENV.fetch("HASKIMAIL_INBOUND_PASSWORD"),
                               only: :inbound

  # Events: delivery, bounce, open, click, spam complaint, subscription change.
  # Haskimail waits up to 10 seconds, retries 5xx and does not retry 4xx.
  def create
    event = Haskimail::Webhook.construct_event(request.raw_post,
                                               signing_key: ENV.fetch("HASKIMAIL_WEBHOOK_KEY"))
    # Haskimail may deliver an event twice: dedupe on event.idempotency_key.
    # Answer fast and process asynchronously.
    HaskimailEventJob.perform_later(event.to_h)
    head :ok
  rescue Haskimail::SignatureVerificationError, Haskimail::ValidationError
    head :forbidden
  end

  # Inbound email: Haskimail waits up to 60 seconds; any answer except 2xx
  # and 403 is retried (10 times over ~10.5 hours); 403 stops retries for
  # good and the message becomes Failed.
  def inbound
    message = Haskimail::Webhook.parse_inbound(request.raw_post)
    SupportTicket.reply!(hash: message.mailbox_hash, text: message.stripped_text_reply)
    head :ok
  rescue Haskimail::WebhookPayloadTooLargeError
    head 413 # keep the message retriable; raise max_size: if needed
  rescue Haskimail::ValidationError
    head :forbidden # not a Haskimail payload: stop retries
  end
end
