# frozen_string_literal: true

require_relative "base"
require_relative "../attachment"

module Haskimail
  module Resources
    # Sending email: https://haskimail.ru/developer/api/email-api
    #
    # Fields may be given as snake_case keywords (`html_body:`) or with exact
    # API names as String keys (`"HtmlBody"`). Documented limits are checked
    # before anything is sent.
    class Emails < Base
      # Emails per batch request.
      MAX_BATCH_SIZE = 500
      # Size of a batch request.
      MAX_BATCH_BYTES = 50 * 1024 * 1024

      # Documented limits (https://haskimail.ru/developer/user-guide/send-email-with-api).
      # Lengths are counted in UTF-16 code units, as Haskimail counts them.
      MAX_RECIPIENTS = 50
      # Length of From, in UTF-16 units.
      MAX_FROM_LENGTH = 255
      # Length of Subject, in UTF-16 units.
      MAX_SUBJECT_LENGTH = 2000
      # Length of Tag, in UTF-16 units.
      MAX_TAG_LENGTH = 1000
      # Size of HtmlBody and of TextBody, each.
      MAX_BODY_BYTES = 5 * 1024 * 1024
      # The whole message, attachments included (counted after Base64).
      MAX_MESSAGE_BYTES = Attachment::MAX_MESSAGE_SIZE
      # Field => maximum length.
      LENGTH_LIMITS = { "From" => MAX_FROM_LENGTH, "Subject" => MAX_SUBJECT_LENGTH, "Tag" => MAX_TAG_LENGTH }.freeze

      # Fields that become email headers: line breaks or other control
      # characters there could inject extra headers (e.g. a hidden Bcc).
      HEADER_FIELDS = %w[From To Cc Bcc ReplyTo Subject Tag].freeze
      # Fields holding address lists (Arrays are joined with ", ").
      ADDRESS_FIELDS = %w[To Cc Bcc ReplyTo].freeze
      # Fields counted against MAX_RECIPIENTS.
      RECIPIENT_FIELDS = %w[To Cc Bcc].freeze
      # Email bodies.
      BODY_FIELDS = %w[HtmlBody TextBody].freeze
      # Exactly one of these selects the template.
      TEMPLATE_FIELDS = %w[TemplateId TemplateAlias].freeze
      # Every documented field of /email and /email/withTemplate. Other
      # spellings ("subject", :replyTo, "reply_to") are mapped to these names,
      # so no check can be bypassed by writing a field name differently.
      EMAIL_FIELDS = (HEADER_FIELDS + BODY_FIELDS + TEMPLATE_FIELDS + %w[
        TemplateModel InlineCss Headers Attachments Metadata MessageStream TrackOpens TrackLinks
      ]).freeze
      # Keys of one custom header.
      HEADER_ITEM_FIELDS = %w[Name Value].freeze
      # Keys of one attachment.
      ATTACHMENT_FIELDS = %w[Name Content ContentType ContentID].freeze
      # Control characters (except TAB) plus Unicode line separators.
      UNSAFE_HEADER_CHARS = Util::UNSAFE_HEADER_CHARS
      # RFC 5322 field-name: printable ASCII except ":".
      HEADER_NAME = /\A[\x21-\x39\x3B-\x7E]+\z/n
      # Quoted display name in an address list.
      QUOTED = /"(?:\\.|[^"\\])*"/
      # <address> part of an address.
      ANGLE_ADDR = /<[^>]*>/
      # (comment) in an address.
      COMMENT = /\([^)]*\)/

      # Number of addresses in `a@b.example, "Фамилия, Имя" <c@d.example>`: commas inside
      # quoted names, comments or angle brackets do not separate addresses.
      # @api private
      def self.count_addresses(list)
        list.to_s.gsub(QUOTED, '""').gsub(COMMENT, "").gsub(ANGLE_ADDR, "<>")
            .split(",").count { |part| !part.strip.empty? }
      end

      # POST /email — sends one email.
      #
      #   client.emails.deliver(
      #     from: "Магазин <shop@example.com>",
      #     to: "ivan@example.com",
      #     subject: "Заказ №1042 оформлен",
      #     html_body: "<p>Здравствуйте!</p>",
      #     text_body: "Здравствуйте!",
      #     tag: "orders",
      #     metadata: { order_id: "1042" },
      #     headers: { "X-Order-Id" => "1042" },
      #     attachments: [Haskimail::Attachment.from_file("invoice.pdf")],
      #     message_stream: "2081"
      #   )
      #
      # @return [SendResult]
      # @raise [UnprocessableEntityError] when the email is rejected
      def deliver(message = nil, **fields)
        send_result(api_post("/email", prepare_plain(merge_params(message, fields))))
      end

      # POST /email/batch — up to 500 emails (plain or template-based) in one
      # request. Never raises for individual rejected emails: inspect the
      # returned {BatchResult}.
      #
      # @param messages [Array<Hash>]
      # @return [BatchResult]
      def deliver_batch(messages)
        payload = prepare_batch(messages) { |message| prepare_batch_item(message) }
        batch_result(api_post("/email/batch", check_batch_size!(payload)), payload.size)
      end

      # POST /email/withTemplate — sends one email based on a stored template.
      #
      #   client.emails.deliver_with_template(
      #     template_alias: "order-created",
      #     template_model: { "{{name}}" => "Иван", "{{order}}" => "1042" },
      #     from: "shop@example.com", to: "ivan@example.com"
      #   )
      #
      # Note: TemplateModel keys are replaced literally, so they include the
      # delimiters (`"{{name}}"`), exactly as in the documentation.
      #
      # @return [SendResult]
      def deliver_with_template(message = nil, **fields)
        send_result(api_post("/email/withTemplate", prepare_template(merge_params(message, fields))))
      end

      # POST /email/batchWithTemplates — up to 500 template emails.
      # @return [BatchResult]
      def deliver_batch_with_templates(messages)
        payload = { "Messages" => prepare_batch(messages) { |message| prepare_template(message) } }
        batch_result(api_post("/email/batchWithTemplates", check_batch_size!(payload)), payload["Messages"].size)
      end

      private

      def prepare(message)
        payload = api_fields(message)
        # Stream IDs are strings in the API ("2081"); an Integer is accepted too.
        payload["MessageStream"] = payload["MessageStream"].to_s if payload["MessageStream"].is_a?(Integer)
        join_addresses!(payload)
        %w[From To].each do |field|
          raise ValidationError, "#{field} is required" if Util.blank?(payload[field])
        end
        check_header_fields!(payload)
        check_limits!(payload)
        normalize_headers!(payload)
        check_size!(payload)
        payload
      end

      def prepare_plain(message)
        payload = prepare(message)
        return payload if BODY_FIELDS.any? { |field| !payload[field].to_s.empty? }

        raise ValidationError, "Either html_body or text_body is required"
      end

      def prepare_template(message)
        payload = prepare(message)
        given = TEMPLATE_FIELDS.count { |field| payload.key?(field) }
        raise ValidationError, "template_id or template_alias is required" if given.zero?
        raise ValidationError, "Pass either template_id or template_alias, not both" if given > 1

        payload
      end

      # /email/batch accepts plain and template-based emails alike.
      def prepare_batch_item(message)
        fields = api_fields(message)
        template = TEMPLATE_FIELDS.any? { |field| fields.key?(field) }
        template ? prepare_template(message) : prepare_plain(message)
      end

      # Converts keys to API names and maps any other spelling of a
      # documented field to its canonical name.
      # Top-level keys are mapped first, so that Metadata and TemplateModel
      # are recognised as user data (and left untouched) under any spelling.
      def api_fields(message)
        Util.to_api(canonicalize(expand_headers(message), EMAIL_FIELDS, "Field"))
      end

      # Renames keys that differ from a known field only in case, punctuation
      # or Unicode compatibility form ("reply_to", "REPLYTO", "ſubject");
      # unknown keys are kept as given.
      def canonicalize(hash, fields, label)
        index = fields.to_h { |field| [field_key(field), field] }
        hash.each_with_object({}) do |(key, value), result|
          name = index.fetch(field_key(key), key)
          raise ValidationError, "#{label} #{name} is given more than once" if result.key?(name)

          result[name] = value
        end
      end

      def prepare_batch(messages)
        raise ValidationError, "Batch must be an Array of Hashes" unless messages.is_a?(Array) && messages.all?(Hash)
        unless messages.size.between?(1, MAX_BATCH_SIZE)
          raise ValidationError, "Batch must contain 1..#{MAX_BATCH_SIZE} emails, got #{messages.size}"
        end

        messages.each_with_index.map do |message, index|
          yield(message)
        rescue ValidationError => e
          raise ValidationError, "Email ##{index}: #{e.message}"
        end
      end

      def check_batch_size!(payload)
        size = Util.generate_json(payload).bytesize
        return payload if size <= MAX_BATCH_BYTES

        raise ValidationError, "Batch request is #{size} bytes; the limit is 50 MB"
      end

      # Accepts `headers: { "X-Id" => "1" }` as a shortcut for
      # `[{ "Name" => "X-Id", "Value" => "1" }]`. Header names are kept
      # verbatim (never camel-cased).
      def expand_headers(message)
        message.to_h do |key, value|
          if headers_key?(key) && value.is_a?(Hash)
            value = value.map { |name, item| { "Name" => name.to_s, "Value" => item.to_s } }
          end
          [key, value]
        end
      end

      def headers_key?(key)
        field_key(key) == "headers"
      end

      # Comparison form of a field name: NFKC (so "ſ" and fullwidth letters
      # become ASCII), case-folded, letters and digits only.
      def field_key(key)
        return nil unless key.is_a?(String) || key.is_a?(Symbol)

        Util.utf8(key.to_s).unicode_normalize(:nfkc).downcase(:fold).gsub(/[^[:alnum:]]/, "")
      end

      # `to: ["a@example.com", "b@example.com"]` becomes the comma-separated
      # string the API expects.
      def join_addresses!(payload)
        ADDRESS_FIELDS.each do |field|
          value = payload[field]
          next unless value.is_a?(Array)

          raise ValidationError, "#{field} must contain only Strings" unless value.all?(String)

          payload[field] = value.join(", ")
        end
      end

      def check_header_fields!(payload)
        HEADER_FIELDS.each do |field|
          value = payload[field]
          next if value.nil?

          value = payload[field] = value.to_s if value.is_a?(Symbol) || value.is_a?(Numeric)
          raise ValidationError, "#{field} must be a String" unless value.is_a?(String)
          raise ValidationError, "#{field} must not contain line breaks or control characters" if unsafe?(value)
        end
      end

      def check_limits!(payload)
        LENGTH_LIMITS.each do |field, limit|
          length = utf16_length(payload[field])
          raise ValidationError, "#{field} is longer than #{limit} characters (#{length})" if length > limit
        end
        BODY_FIELDS.each do |field|
          size = payload[field].to_s.bytesize
          raise ValidationError, "#{field} exceeds 5 MB (#{size} bytes)" if size > MAX_BODY_BYTES
        end
        recipients = RECIPIENT_FIELDS.sum { |field| self.class.count_addresses(payload[field]) }
        return if recipients <= MAX_RECIPIENTS

        raise ValidationError, "#{recipients} recipients in To, Cc and Bcc; at most #{MAX_RECIPIENTS} are allowed"
      end

      # @param value [String, nil] valid UTF-8 (Util.to_api converts every string)
      def utf16_length(value)
        value.nil? ? 0 : value.encode(Encoding::UTF_16LE).bytesize / 2
      end

      # @param value [String] valid UTF-8 (Util.to_api converts every string)
      def unsafe?(value)
        UNSAFE_HEADER_CHARS.match?(value)
      end

      def normalize_headers!(payload)
        headers = payload["Headers"]
        return if headers.nil?

        unless headers.is_a?(Array) && headers.all?(Hash)
          raise ValidationError, "headers must be a Hash or an Array of { name:, value: }"
        end

        payload["Headers"] = headers.map do |item|
          header = canonicalize(item, HEADER_ITEM_FIELDS, "Header field")
          name = header["Name"].to_s
          raise ValidationError, "Invalid header name #{name.b.inspect}" unless HEADER_NAME.match?(name.b)

          value = header["Value"].to_s
          raise ValidationError, "Header #{name} must not contain line breaks or control characters" if unsafe?(value)

          header.merge("Value" => value)
        end
      end

      # Attachments are validated and the whole message (bodies + Base64
      # attachments) must fit into 10 MB.
      def check_size!(payload)
        normalize_attachments!(payload)
        attachments = (payload["Attachments"] || []).sum { |attachment| attachment["Content"].to_s.bytesize }
        total = BODY_FIELDS.sum { |field| payload[field].to_s.bytesize } + attachments
        return if total <= MAX_MESSAGE_BYTES

        raise ValidationError, "The email is #{total} bytes with attachments; the limit is 10 MB"
      end

      # Name, ContentType and ContentID become MIME headers of the part, so
      # they get the same checks as attachments built with Haskimail::Attachment.
      def normalize_attachments!(payload)
        attachments = payload["Attachments"]
        return if attachments.nil?
        raise ValidationError, "attachments must be an Array" unless attachments.is_a?(Array)

        payload["Attachments"] = attachments.map do |item|
          raise ValidationError, "Each attachment must be a Hash or Haskimail::Attachment" unless item.is_a?(Hash)

          attachment = canonicalize(item, ATTACHMENT_FIELDS, "Attachment field")
          Attachment.validate_name!(attachment["Name"])
          Attachment.validate_content_type!(attachment["ContentType"]) unless attachment["ContentType"].nil?
          Attachment.validate_content_id!(attachment["ContentID"]) unless attachment["ContentID"].nil?
          attachment
        end
      end

      # One result per email, in order; anything else means the outcome of
      # some emails is unknown.
      def batch_result(data, expected)
        unless data.is_a?(Array) && data.all?(Hash) && data.size == expected
          shape = data.is_a?(Array) ? "#{data.size} results for #{expected} emails" : data.class.to_s
          raise UnexpectedResponseError.new("Unexpected batch response: #{shape}. Emails MAY have been " \
                                            "accepted — check the message log before re-sending", http_status: 200)
        end

        results = data.map { |item| SendResult.new(item) }
        if results.any? { |result| result.error_code.nil? }
          raise UnexpectedResponseError.new("Batch result without a numeric ErrorCode. Emails MAY have been " \
                                            "accepted — check the message log before re-sending", http_status: 200)
        end

        BatchResult.new(results)
      end
    end
  end
end
