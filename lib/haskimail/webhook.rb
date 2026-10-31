# frozen_string_literal: true

require "digest"
require "json"
require "openssl"
require "strscan"

require_relative "errors"
require_relative "util"
require_relative "api_object"

module Haskimail
  # Parsing and verification of incoming webhooks.
  # https://haskimail.ru/developer/webhooks/webhooks-overview
  #
  # Rails example:
  #
  #   def haskimail
  #     event = Haskimail::Webhook.construct_event(
  #       request.raw_post, signing_key: ENV.fetch("HASKIMAIL_WEBHOOK_KEY")
  #     )
  #     ProcessHaskimailEventJob.perform_later(event.to_h) # answer fast, work later
  #     head :ok
  #   rescue Haskimail::SignatureVerificationError, Haskimail::ValidationError
  #     head :forbidden # event webhooks are not retried after a 4xx
  #   end
  #
  # Inbound email is different: Haskimail waits up to 60 seconds, retries any
  # answer except 2xx and 403, and a 403 stops retries for good
  # (see examples/rails_webhook_controller.rb).
  module Webhook
    # Default size limits (override with `max_size:`). 1 MB is far above any
    # event payload. Inbound emails carry Base64 attachments and, when enabled,
    # the raw source, and the documentation sets no limit, so the default is generous.
    MAX_EVENT_SIZE = 1024 * 1024
    # Default limit for inbound emails.
    MAX_INBOUND_SIZE = 64 * 1024 * 1024

    # Shapes of the two signed fields. They are concatenated without a
    # delimiter before hashing, so constraining them limits how an attacker
    # could shift the boundary between them.
    RECIPIENT_FORMAT = /\A[^@\s]+@[^@\s]+\z/
    # MessageID: letters, digits, "-" and "_" (empty for events without an email).
    MESSAGE_ID_FORMAT = /\A[0-9A-Za-z_-]*\z/

    # Fields whose look-alikes (e.g. "Recipient") are refused, because the SDK
    # reads them and only some of them are signed.
    GUARDED_FIELDS = %w[recipient messageid secret event email].freeze

    # Parsing a JSON integer with millions of digits takes tens of seconds
    # on some Ruby/json versions, so numbers this long are refused. Digits
    # inside strings (an inbound email body, say) are fine.
    HUGE_NUMBER = /(?<![0-9])[0-9]{10000}/
    # A complete JSON string; possessive, so scanning stays linear.
    JSON_STRING = /"(?:[^"\\]++|\\.)*+"/
    # A webhook body must be a JSON object.
    JSON_OBJECT_START = /\A[ \t\r\n]*+\{/

    module_function

    # Parses an event body and verifies its signature.
    #
    # The signature covers only `recipient` and `message_id` (a limitation of
    # the Haskimail protocol): other fields such as `event` are not signed.
    # Keep the webhook URL secret, use HTTPS and, ideally, HTTP basic auth too.
    #
    # @param payload [String] raw request body (do not re-serialize parsed params)
    # @param signing_key [String] webhook signing key from the Haskimail UI
    # @return [Event]
    # @raise [SignatureVerificationError] signature missing or wrong
    # @raise [ValidationError] body is not a well-formed event
    def construct_event(payload, signing_key:, max_size: MAX_EVENT_SIZE)
      event = parse_event(payload, max_size: max_size)
      unless valid_signature?(event.to_h, signing_key: signing_key)
        raise SignatureVerificationError, "Webhook signature verification failed"
      end

      event
    end

    # Parses an event body WITHOUT verifying it. Use only behind another
    # authentication layer (HTTP basic auth, IP allow-list).
    # @return [Event]
    def parse_event(payload, max_size: MAX_EVENT_SIZE)
      data = parse_object(payload, max_size)
      # Field access is case-insensitive, so "Recipient" next to "recipient"
      # could make the application read a different value than was signed.
      guarded = data.keys.map { |key| ApiObject.normalize(key) }.select { |key| GUARDED_FIELDS.include?(key) }
      raise ValidationError, "Webhook payload has ambiguous duplicate fields" if guarded.uniq.size != guarded.size

      Event.new(data)
    end

    # `secret == md5(recipient + message_id + signing_key)`, compared in
    # constant time. Both signed fields must be present with exact names.
    #
    # @param event [Hash, Event] parsed payload
    # @param signing_key [String]
    # @raise [ConfigurationError] when signing_key is blank
    def valid_signature?(event, signing_key:)
      raise ConfigurationError, "signing_key must not be blank" if Util.blank?(signing_key)

      key = signing_key.to_s
      return false unless event.respond_to?(:to_h)

      data = event.to_h
      recipient = data["recipient"]
      # Events not tied to an email carry "" (a missing/null value is signed as "").
      message_id = data["message_id"].nil? ? "" : data["message_id"]
      secret = data["secret"]
      return false unless recipient.is_a?(String) && RECIPIENT_FORMAT.match?(recipient)
      return false unless message_id.is_a?(String) && MESSAGE_ID_FORMAT.match?(message_id)
      return false unless secret.is_a?(String) && !secret.empty?

      expected = Digest::MD5.hexdigest("#{recipient}#{message_id}#{key}")
      OpenSSL.secure_compare(expected, secret.downcase)
    end

    # Parses the inbound-email webhook (Postmark-compatible format, no signature:
    # protect the URL with HTTP basic auth — `https://user:pass@host/path`).
    # @return [InboundMessage]
    def parse_inbound(payload, max_size: MAX_INBOUND_SIZE)
      InboundMessage.new(parse_object(payload, max_size))
    end

    # @api private
    # @return [Hash]
    def parse_object(payload, limit)
      # Rack's raw_post is binary; the body itself must be UTF-8 JSON.
      text = payload.to_s.dup.force_encoding(Encoding::UTF_8)
      raise WebhookPayloadTooLargeError, "Webhook payload is larger than #{limit} bytes" if text.bytesize > limit
      raise ValidationError, "Webhook payload is not valid UTF-8" unless text.valid_encoding?
      raise ValidationError, "Webhook payload must be a JSON object" unless JSON_OBJECT_START.match?(text)
      raise ValidationError, "Webhook payload contains an oversized number" if huge_number?(text)

      # Starts with "{", so a successful parse is always a Hash.
      Util.parse_json(text)
    rescue JSON::ParserError => e
      raise ValidationError, "Webhook payload is not valid JSON: #{e.message}"
    end
    private_class_method :parse_object

    # @api private
    # True when a run of 10 000+ digits appears outside JSON strings.
    # A single regex pass rules out almost every body; only bodies that do
    # contain such a run are walked token by token (linear; an unterminated
    # string ends the walk, the JSON parser rejects such a body anyway).
    def huge_number?(text)
      return false unless HUGE_NUMBER.match?(text)

      scanner = StringScanner.new(text)
      until scanner.eos?
        scanner.skip(/[^"0-9]++/)
        next if scanner.skip(JSON_STRING)
        return false if scanner.check(/"/)
        return true if scanner.match?(HUGE_NUMBER)

        scanner.skip(/[0-9]++/)
      end
      false
    end
    private_class_method :huge_number?

    # A delivery/bounce/open/click/spam-complaint/subscription-change event.
    # All raw fields remain available (`event.recipient`, `event["code"]`...).
    class Event < ApiObject
      # Lower-case `event` value => #type.
      TYPES = {
        "sent" => :sent, # sandbox servers only
        "delivered" => :delivered,
        "bounced" => :bounced,
        "complained" => :complained,
        "opened" => :opened,
        "clicked" => :clicked,
        "subscriptionchange" => :subscription_change
      }.freeze

      # bounce_category value => Symbol.
      BOUNCE_CATEGORIES = {
        "hrd" => :hard_bounce,
        "sft" => :soft_bounce,
        "blk" => :blocked,
        "spm" => :spam_block
      }.freeze

      # Normalized event type. The docs use both cases ("complained" and
      # "COMPLAINED"), so comparison is case-insensitive.
      # @return [Symbol] one of TYPES values, or :unknown
      def type
        TYPES.fetch(self["event"].to_s.downcase, :unknown)
      end

      TYPES.each_value do |name|
        define_method(:"#{name}?") do
          # @type self: Event
          type == name
        end
      end

      # The signed recipient field (exact key, never a look-alike).
      # @return [String, nil]
      def recipient
        exact("recipient")
      end

      # MessageID of the email (signed field); "" for events not tied to an email.
      def message_id
        exact("message_id").to_s
      end

      # Raw `email` field (an unsigned copy of `recipient`).
      def email
        exact("email")
      end

      # Tag of the email (sent as `campaign_id`).
      def tag
        self["campaign_id"].to_s
      end

      # Metadata of the email. The API sends it as a JSON string (or, in some
      # examples, as an object); both are returned as a Hash.
      # @return [Hash]
      def metadata
        raw = to_h["custom_vars"]
        case raw
        when Hash then raw
        when String
          parsed = raw.strip.empty? ? {} : Util.parse_json(raw)
          parsed.is_a?(Hash) ? parsed : {}
        else {}
        end
      rescue JSON::ParserError
        {}
      end

      # @return [Integer, nil]
      def server_id
        value = self["server_id"]
        value.nil? ? nil : Integer(value.to_s, 10)
      rescue ArgumentError
        nil
      end

      # @return [String, nil]
      def stream_id
        value = self["stream_id"]
        value&.to_s
      end

      # Event time as Time (UTC field preferred, Moscow time as fallback).
      # @return [Time, nil]
      def occurred_at
        utc = self["event_time_utc"].to_s
        return Util.parse_time(self["event_time"]) unless utc.match?(/\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\z/)

        Time.strptime("#{utc} +00:00", "%Y-%m-%d %H:%M:%S %z").utc
      rescue ArgumentError
        Util.parse_time(self["event_time"])
      end

      # Bounce category: :hard_bounce, :soft_bounce, :blocked, :spam_block.
      # @return [Symbol, nil]
      def bounce_category
        BOUNCE_CATEGORIES[self["bounce_category"].to_s]
      end

      # Subscription change: true when the address was added to the suppression list.
      def suppressed?
        %w[true 1].include?(self["SuppressSending"].to_s.strip.downcase)
      end

      # Key for de-duplication: Haskimail may deliver the same event twice.
      # Clicks include the link, so clicks on two links in the same second
      # stay distinct.
      # @return [String]
      def idempotency_key
        [type, message_id, recipient, exact("event_time"), exact("url_original")].join("|")
      end
    end

    # Inbound email as delivered to the inbound webhook.
    class InboundMessage < ApiObject
      # @return [Array<InboundAttachment>] decoded attachments
      def attachments
        items = to_h["Attachments"]
        return [] unless items.is_a?(Array)

        items.filter_map do |item|
          next unless item.is_a?(Hash)

          InboundAttachment.new(
            name: item["Name"].to_s,
            content_type: item["ContentType"].to_s,
            content_id: item["ContentID"].to_s,
            content: item["Content"].to_s.unpack1("m")
          )
        end
      end

      # @return [String, nil] value of a header by case-insensitive name
      def header(name)
        wanted = name.to_s.downcase
        headers = to_h["Headers"]
        return nil unless headers.is_a?(Array)

        headers.each do |header|
          return header["Value"] if header.is_a?(Hash) && header["Name"].to_s.downcase == wanted
        end
        nil
      end

      # @return [Float, nil] value of the X-Spam-Score header
      def spam_score
        value = header("X-Spam-Score")
        value.nil? ? nil : Float(value)
      rescue ArgumentError, TypeError # not a number, or not even a String
        nil
      end

      # Short form: bodies, headers and Base64 attachments (up to 64 MB) are
      # left out. Use #to_h for everything.
      def inspect
        summary = %w[MessageID From To Subject].filter_map do |key|
          value = exact(key)
          "#{key}=#{value.inspect}" unless value.nil?
        end
        attachments = exact("Attachments")
        summary << "attachments=#{attachments.size}" if attachments.is_a?(Array)
        "#<#{self.class.name} #{summary.join(' ')}>"
      end
      alias to_s inspect

      # `pp` and IRB print the same short form.
      def pretty_print(printer)
        printer.text(inspect)
      end
    end

    # Decoded attachment of an inbound email. The name comes from the sender:
    # never use it as a file path without sanitizing.
    class InboundAttachment
      attr_reader :name, :content_type, :content_id, :content

      # @param name [String] file name chosen by the sender
      # @param content_type [String]
      # @param content_id [String] "" for regular attachments
      # @param content [String] decoded bytes
      def initialize(name:, content_type:, content_id:, content:)
        @name = name
        @content_type = content_type
        @content_id = content_id
        @content = content
        freeze
      end

      # True for inline attachments (with a content ID).
      def inline?
        !content_id.empty?
      end

      # Decoded size in bytes.
      def size
        content.bytesize
      end

      # @return [Hash{Symbol => String}]
      def to_h
        { name: name, content_type: content_type, content_id: content_id, content: content }
      end

      # Same class and same fields.
      def ==(other)
        other.instance_of?(self.class) && other.to_h == to_h
      end
      alias eql? ==

      # Consistent with #eql?.
      def hash
        [self.class, to_h].hash
      end

      # Name, type and size; never the content.
      def inspect
        "#<#{self.class.name} name=#{name.inspect} content_type=#{content_type.inspect} size=#{size}>"
      end
      alias to_s inspect

      # `pp` and IRB print the same short form, never the content.
      def pretty_print(printer)
        printer.text(inspect)
      end
    end
  end
end
