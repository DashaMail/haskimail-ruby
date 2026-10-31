# frozen_string_literal: true

require_relative "base"

module Haskimail
  module Resources
    # Servers (account token): https://haskimail.ru/developer/api/servers-api
    class Servers < Base
      # Documented colours (case-insensitive). The API silently stores
      # "purple" for anything else; the SDK raises instead, so a typo is
      # caught rather than turned into the wrong colour.
      COLORS = %w[purple blue turquoise green red orange yellow grey].freeze
      # Values of TrackLinks besides true/false.
      TRACK_LINKS = %w[None HtmlAndText HtmlOnly TextOnly].freeze
      # Live delivers mail, Sandbox never does (set at creation only).
      DELIVERY_TYPES = %w[Live Sandbox].freeze

      # GET /servers
      # @return [ApiObject] TotalCount, Servers[]
      def list(count: nil, offset: nil)
        check_paging!(count, offset)
        object(api_get("/servers", query({ count: count, offset: offset }, PAGING)))
      end

      # The API returns 50 servers per page by default.
      # @return [Paginator]
      def each(page_size: 50, &block)
        paginator = paginate("Servers", page_size: page_size) do |count, offset|
          api_get("/servers", { "count" => count, "offset" => offset })
        end
        run(paginator, block)
      end

      # GET /servers/{serverid}
      def get(server_id)
        object(api_get(path("/servers/%s", server_id)))
      end

      # POST /servers
      #
      #   account.servers.create(name: "Интернет-магазин", color: "purple",
      #                          track_opens: true, track_links: "HtmlAndText")
      #
      # `delivery_type: "Sandbox"` creates a server that never delivers mail;
      # the type cannot be changed later.
      def create(params = nil, **fields)
        payload = validate!(Util.to_api(merge_params(params, fields)))
        raise ValidationError, "name is required" if Util.blank?(payload["Name"])
        raise ValidationError, "color is required" if Util.blank?(payload["Color"])

        object(api_post("/servers", payload))
      end

      # PUT /servers/{serverid} — pass only the fields to change.
      def update(server_id, params = nil, **fields)
        payload = validate!(Util.to_api(merge_params(params, fields)))
        raise ValidationError, "Nothing to update" if payload.empty?
        if payload.key?("DeliveryType")
          raise ValidationError, "delivery_type cannot be changed after the server is created"
        end

        object(api_put(path("/servers/%s", server_id), payload))
      end

      # DELETE /servers/{serverid} — also deletes its inbound rules.
      def delete(server_id)
        object(api_delete(path("/servers/%s", server_id)))
      end

      private

      def validate!(payload)
        check_value!(payload, "Color", COLORS) { |value| Util.strip_text(value, "color").downcase }
        check_value!(payload, "DeliveryType", DELIVERY_TYPES)
        if payload.key?("TrackLinks") && ![true, false].include?(payload["TrackLinks"])
          check_value!(payload, "TrackLinks", TRACK_LINKS)
        end
        threshold = payload["InboundSpamThreshold"]
        if threshold && !(threshold.is_a?(Integer) && threshold.between?(0, 30) && (threshold % 5).zero?)
          raise ValidationError, "inbound_spam_threshold must be 0..30 in steps of 5"
        end

        payload
      end

      def check_value!(payload, key, allowed)
        return unless payload.key?(key)

        value = block_given? ? yield(payload[key]) : payload[key].to_s
        return if allowed.include?(value)

        raise ValidationError, "#{key} must be one of: #{allowed.join(', ')}"
      end
    end

    # Sending domains (account token): https://haskimail.ru/developer/api/domains-api
    class Domains < Base
      # GET /domains
      # @return [ApiObject] TotalCount, Domains[]
      def list(count: nil, offset: nil)
        check_paging!(count, offset)
        object(api_get("/domains", query({ count: count, offset: offset }, PAGING)))
      end

      # @return [Paginator]
      def each(page_size: 500, &block)
        paginator = paginate("Domains", page_size: page_size) do |count, offset|
          api_get("/domains", { "count" => count, "offset" => offset })
        end
        run(paginator, block)
      end

      # GET /domains/{domainid} — includes the SPF/DKIM records to publish.
      def get(domain_id)
        object(api_get(path("/domains/%s", domain_id)))
      end

      # POST /domains
      # @param name [String] e.g. "example.com"
      def create(name)
        domain = Util.strip_text(name, "Domain name")
        raise ValidationError, "Domain name must not be blank" if domain.empty?

        object(api_post("/domains", { "Name" => domain }))
      end

      # DELETE /domains/{domainid} — also removes confirmed addresses on it.
      def delete(domain_id)
        object(api_delete(path("/domains/%s", domain_id)))
      end

      # PUT /domains/{domainid}/verifyDkim — re-checks DNS.
      def verify_dkim(domain_id)
        object(api_put(path("/domains/%s/verifyDkim", domain_id)))
      end

      # PUT /domains/{domainid}/verifyspf — re-checks DNS.
      def verify_spf(domain_id)
        object(api_put(path("/domains/%s/verifyspf", domain_id)))
      end
    end
  end
end
