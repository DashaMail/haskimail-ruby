# frozen_string_literal: true

require_relative "base"

module Haskimail
  module Resources
    # Bounces: https://haskimail.ru/developer/api/bounce-api
    class Bounces < Base
      # Keyword => query parameter.
      FILTERS = PAGING.merge(
        type: "type", email_filter: "emailFilter", tag: "tag", message_id: "messageID",
        message_stream: "messagestream", from_date: "fromdate", to_date: "todate"
      ).freeze

      # Values accepted by the `type:` filter. The delivery-stats spellings
      # (BulkBounce, SpamBlock) are accepted by the API as well.
      TYPES = %w[HardBounce SoftBounce BlkBounce SpmBounce BulkBounce SpamBlock].freeze

      # GET /deliverystats — bounce counts by type for the last 45 days.
      # @return [ApiObject] Bounces[] (Type, Name, Count)
      def delivery_stats
        object(api_get("/deliverystats"))
      end

      # GET /bounces — newest first.
      # @return [ApiObject] TotalCount, Bounces[]
      def list(**filters)
        object(api_get("/bounces", build_query(filters)))
      end

      # @return [Paginator]
      def each(page_size: 500, **filters, &block)
        reject_paging!(filters)
        base = build_query(filters)
        paginator = paginate("Bounces", page_size: page_size) do |count, offset|
          api_get("/bounces", base.merge("count" => count, "offset" => offset))
        end
        run(paginator, block)
      end

      private

      def build_query(filters)
        check_paging!(filters[:count], filters[:offset])
        type = filters[:type]
        raise ValidationError, "type must be one of: #{TYPES.join(', ')}" if type && !TYPES.include?(type.to_s)

        query(Dates.date_only(filters), FILTERS)
      end
    end

    # Converts date filters for endpoints that accept only dates.
    # @api private
    module Dates
      # Filters converted to YYYY-MM-DD.
      KEYS = %i[from_date to_date].freeze

      # Converts from_date/to_date for endpoints that accept only YYYY-MM-DD.
      def self.date_only(filters)
        filters.to_h { |key, value| KEYS.include?(key) ? [key, Util.format_date(value)] : [key, value] }
      end
    end

    # Message streams: https://haskimail.ru/developer/api/message-streams-api
    class MessageStreams < Base
      # Accepted message_stream_type values.
      TYPES = %w[transactional broadcasts].freeze

      # GET /message-streams (archived streams included)
      # @return [ApiObject] TotalCount, MessageStreams[]
      def list
        object(api_get("/message-streams"))
      end

      # GET /message-streams/{streamid}
      def get(stream_id)
        object(api_get(path("/message-streams/%s", stream_id)))
      end

      # POST /message-streams
      # @param message_stream_type [String, Symbol] "transactional" or "broadcasts"
      # @param server_id [Integer, nil] required with the account token
      def create(name:, message_stream_type:, server_id: nil)
        if server_id.nil? && @client.is_a?(AccountClient)
          raise ValidationError, "server_id is required with the account token"
        end

        unless TYPES.include?(Util.strip_text(message_stream_type, "message_stream_type").downcase)
          raise ValidationError, "message_stream_type must be transactional or broadcasts"
        end

        payload = Util.to_api(name: name, message_stream_type: message_stream_type.to_s, server_id: server_id)
        object(api_post("/message-streams", payload))
      end

      # PATCH /message-streams/{streamid} — only the name can be changed.
      def update(stream_id, name:)
        raise ValidationError, "name must not be blank" if Util.blank?(name)

        object(api_patch(path("/message-streams/%s", stream_id), { "Name" => name }))
      end

      # POST /message-streams/{streamid}/archive — deleted after 45 days unless unarchived.
      def archive(stream_id)
        object(api_post(path("/message-streams/%s/archive", stream_id), idempotent: true))
      end

      # POST /message-streams/{streamid}/unarchive
      def unarchive(stream_id)
        object(api_post(path("/message-streams/%s/unarchive", stream_id), idempotent: true))
      end
    end

    # Suppression lists: https://haskimail.ru/developer/api/suppressions-api
    class Suppressions < Base
      # GET /message-streams/{streamid}/suppressions/dump
      # @return [ApiObject] Suppressions[] (EmailAddress, SuppressionReason, Origin, CreatedAt)
      def list(stream_id)
        object(api_get(path("/message-streams/%s/suppressions/dump", stream_id)))
      end

      # POST /message-streams/{streamid}/suppressions
      # @param emails [Array<String>, String]
      # @return [ApiObject] per-address Status: Suppressed / Failed
      def create(stream_id, emails)
        object(api_post(path("/message-streams/%s/suppressions", stream_id), payload(emails), idempotent: true))
      end

      # POST /message-streams/{streamid}/suppressions/delete
      # @return [ApiObject] per-address Status: Deleted / Failed
      def delete(stream_id, emails)
        object(api_post(path("/message-streams/%s/suppressions/delete", stream_id), payload(emails),
                        idempotent: true))
      end

      private

      def payload(emails)
        list = Array(emails).map { |email| Util.strip_text(email, "Email address") }
        raise ValidationError, "At least one email address is required" if list.empty?
        raise ValidationError, "Email addresses must not be blank" if list.any?(&:empty?)

        { "Suppressions" => list.map { |email| { "EmailAddress" => email } } }
      end
    end

    # Webhooks: https://haskimail.ru/developer/api/webhooks-api
    class Webhooks < Base
      # Keyword => API trigger name.
      TRIGGERS = {
        delivery: "Delivery", bounce: "Bounce", spam_complaint: "SpamComplaint",
        open: "Open", click: "Click", subscription_change: "SubscriptionChange"
      }.freeze

      # GET /webhooks
      # @return [ApiObject] Webhooks[]
      def list
        object(api_get("/webhooks"))
      end

      # GET /webhooks/{webhookid}
      def get(webhook_id)
        object(api_get(path("/webhooks/%s", webhook_id)))
      end

      # POST /webhooks
      #
      #   client.webhooks.create(url: "https://example.com/haski",
      #                          message_stream: "2081",
      #                          triggers: { delivery: true, bounce: true, spam_complaint: true })
      #
      # Triggers not listed are disabled. The long API form
      # (`{ "Bounce" => { "Enabled" => true } }`) is accepted too.
      def create(url:, message_stream: nil, triggers: {})
        payload = { "Url" => check_url!(url), "Triggers" => normalize_triggers(triggers) }
        payload["MessageStream"] = message_stream.to_s unless message_stream.nil?
        object(api_post("/webhooks", payload))
      end

      # PUT /webhooks/{webhookid} — only given triggers change; the stream cannot change.
      def update(webhook_id, url: nil, triggers: nil)
        payload = {}
        payload["Url"] = check_url!(url) unless url.nil?
        payload["Triggers"] = normalize_triggers(triggers) unless triggers.nil? || triggers == {}
        raise ValidationError, "Nothing to update: pass url: and/or triggers:" if payload.empty?

        object(api_put(path("/webhooks/%s", webhook_id), payload))
      end

      # DELETE /webhooks/{webhookid}
      def delete(webhook_id)
        object(api_delete(path("/webhooks/%s", webhook_id)))
      end

      private

      def check_url!(url)
        uri = URI.parse(url.to_s)
        valid = %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?
        raise ValidationError, "Webhook url must be an http(s) URL" unless valid

        url.to_s
      rescue URI::InvalidURIError
        raise ValidationError, "Webhook url is not a valid URL"
      end

      def normalize_triggers(triggers)
        raise ValidationError, "triggers must be a Hash" unless triggers.is_a?(Hash)

        triggers.each_with_object({}) do |(name, value), result|
          api_name = name.is_a?(Symbol) ? TRIGGERS[name] : name.to_s
          if api_name.nil? || !TRIGGERS.value?(api_name)
            raise ValidationError, "Unknown trigger #{name.inspect}. Allowed: #{TRIGGERS.keys.join(', ')}"
          end

          result[api_name] = { "Enabled" => enabled_flag(name, value) }
        end
      end

      def enabled_flag(name, value)
        if value.is_a?(Hash)
          key = ["Enabled", :enabled, :Enabled, "enabled"].find { |candidate| value.key?(candidate) }
          value = key.nil? ? nil : value[key]
        end
        return value if [true, false].include?(value)

        raise ValidationError, "Trigger #{name.inspect} must be true or false"
      end
    end

    # Inbound blocking rules (server token): https://haskimail.ru/developer/api/inbound-rules-triggers-api
    class InboundRules < Base
      # Documented maximum of count.
      MAX_PAGE_SIZE = 500

      # GET /triggers/inboundrules
      # @return [ApiObject] TotalCount, InboundRules[] (ID, Rule)
      def list(count: nil, offset: nil)
        check_paging!(count, offset, max_count: MAX_PAGE_SIZE)
        object(api_get("/triggers/inboundrules", query({ count: count, offset: offset }, PAGING)))
      end

      # @return [Paginator]
      def each(page_size: MAX_PAGE_SIZE, &block)
        check_page_size!(page_size, MAX_PAGE_SIZE)
        paginator = paginate("InboundRules", page_size: page_size) do |count, offset|
          api_get("/triggers/inboundrules", { "count" => count, "offset" => offset })
        end
        run(paginator, block)
      end

      # POST /triggers/inboundrules
      # @param rule [String] email address ("spam@example.com") or whole domain ("example.org")
      def create(rule)
        text = Util.strip_text(rule, "Rule")
        raise ValidationError, "rule must not be blank" if text.empty?

        object(api_post("/triggers/inboundrules", { "Rule" => text }))
      end

      # DELETE /triggers/inboundrules/{triggerid}
      def delete(rule_id)
        object(api_delete(path("/triggers/inboundrules/%s", rule_id)))
      end
    end

    # Outbound statistics: https://haskimail.ru/developer/api/stats-api
    #
    # Every method accepts `from_date:`, `to_date:` (Date, Time or "YYYY-MM-DD")
    # and `message_stream:`.
    class Stats < Base
      # Keyword => query parameter.
      FILTERS = { from_date: "fromdate", to_date: "todate", message_stream: "messagestream" }.freeze

      # Method name => endpoint.
      ENDPOINTS = {
        summary: "/stats",
        sends: "/stats/sends",
        bounces: "/stats/bounces",
        spam_complaints: "/stats/spam",
        opens: "/stats/opens",
        clicks: "/stats/clicks",
        opens_by_platform: "/stats/opens/platforms",
        opens_by_email_client: "/stats/opens/emailclients",
        clicks_by_browser_family: "/stats/clicks/browserfamilies",
        clicks_by_platform: "/stats/clicks/platforms"
      }.freeze

      ENDPOINTS.each do |name, endpoint|
        define_method(name) do |**filters|
          # @type self: Stats
          object(api_get(endpoint, query(Dates.date_only(filters), FILTERS)))
        end
      end
    end
  end
end
