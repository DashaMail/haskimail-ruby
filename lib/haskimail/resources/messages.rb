# frozen_string_literal: true

require_relative "base"

module Haskimail
  module Resources
    # Shared logic for outbound searches limited to count + offset <= 10000.
    # @api private
    class OutboundSearch < Base
      # Documented maximum of count.
      MAX_PAGE_SIZE = 500
      # Documented maximum of count + offset.
      MAX_WINDOW = 10_000

      private

      def search(endpoint, filters, mapping)
        check_paging!(filters[:count], filters[:offset], max_count: MAX_PAGE_SIZE, max_window: MAX_WINDOW)
        api_get(endpoint, query(filters, mapping))
      end

      def iterate(endpoint, items_key, filters, mapping, page_size)
        reject_paging!(filters)
        check_page_size!(page_size, MAX_PAGE_SIZE)
        base = query(filters, mapping)
        paginate(items_key, page_size: page_size, max_window: MAX_WINDOW) do |count, offset|
          api_get(endpoint, base.merge("count" => count, "offset" => offset))
        end
      end
    end

    # Sent messages: https://haskimail.ru/developer/api/messages-api
    class Messages < OutboundSearch
      # Keyword => query parameter.
      FILTERS = PAGING.merge(
        recipient: "recipient", from_email: "fromemail", tag: "tag", subject: "subject",
        message_stream: "messagestream", from_date: "fromdate", to_date: "todate"
      ).freeze

      # GET /messages — newest first, one record per recipient.
      # `from_date`/`to_date` accept Date, Time (converted to Moscow time) or String.
      # @return [ApiObject] TotalCount, Messages[]
      def list(**filters)
        object(search("/messages", filters, FILTERS))
      end

      # Iterates over search results (the API caps the window at 10 000 records).
      # @return [Paginator]
      def each(page_size: MAX_PAGE_SIZE, **filters, &block)
        run(iterate("/messages", "Messages", filters, FILTERS, page_size), block)
      end

      # GET /messages/{messageid}/details
      # @raise [UnprocessableEntityError] ErrorCode 701 when not found
      def details(message_id)
        object(api_get(path("/messages/%s/details", message_id)))
      end
    end

    # Open events: https://haskimail.ru/developer/api/messages-api
    class Opens < OutboundSearch
      # Keyword => query parameter.
      FILTERS = PAGING.merge(
        recipient: "recipient", tag: "tag", message_stream: "messagestream",
        from_date: "fromdate", to_date: "todate"
      ).freeze
      # Filters of #for_message.
      MESSAGE_FILTERS = PAGING.merge(recipient: "recipient", tag: "tag", message_stream: "messagestream").freeze

      # GET /messages/opens
      # @return [ApiObject] TotalCount, Opens[]
      def list(**filters)
        object(search("/messages/opens", filters, FILTERS))
      end

      # @return [Paginator]
      def each(page_size: MAX_PAGE_SIZE, **filters, &block)
        run(iterate("/messages/opens", "Opens", filters, FILTERS, page_size), block)
      end

      # GET /messages/opens/{messageid} — all opens of one email.
      def for_message(message_id, **filters)
        object(search(path("/messages/opens/%s", message_id), filters, MESSAGE_FILTERS))
      end
    end

    # Link clicks: https://haskimail.ru/developer/api/messages-api
    class Clicks < OutboundSearch
      # Same filters as Opens.
      FILTERS = Opens::FILTERS
      # Same filters as Opens#for_message.
      MESSAGE_FILTERS = Opens::MESSAGE_FILTERS

      # GET /messages/clicks
      # @return [ApiObject] TotalCount, Clicks[]
      def list(**filters)
        object(search("/messages/clicks", filters, FILTERS))
      end

      # @return [Paginator]
      def each(page_size: MAX_PAGE_SIZE, **filters, &block)
        run(iterate("/messages/clicks", "Clicks", filters, FILTERS, page_size), block)
      end

      # GET /messages/clicks/{messageid} — all clicks of one email.
      def for_message(message_id, **filters)
        object(search(path("/messages/clicks/%s", message_id), filters, MESSAGE_FILTERS))
      end
    end

    # Inbound messages (server token only): https://haskimail.ru/developer/api/messages-api
    class InboundMessages < Base
      # Keyword => query parameter.
      FILTERS = PAGING.merge(
        recipient: "recipient", from_email: "fromemail", subject: "subject",
        mailbox_hash: "mailboxhash", status: "status", from_date: "fromdate", to_date: "todate"
      ).freeze
      # Accepted values of the status filter.
      STATUSES = %w[queued processed blocked failed scheduled].freeze
      # Documented maximum of count.
      MAX_PAGE_SIZE = 500

      # GET /messages/inbound — last 45 days, newest first.
      # @option filters [String, Symbol] :status one of STATUSES, any case
      #   (the API itself reports statuses capitalized: "Blocked")
      # @return [ApiObject] TotalCount, InboundMessages[]
      def list(**filters)
        object(api_get("/messages/inbound", build_query(filters)))
      end

      # @return [Paginator]
      def each(page_size: MAX_PAGE_SIZE, **filters, &block)
        reject_paging!(filters)
        check_page_size!(page_size, MAX_PAGE_SIZE)
        base = build_query(filters)
        paginator = paginate("InboundMessages", page_size: page_size) do |count, offset|
          api_get("/messages/inbound", base.merge("count" => count, "offset" => offset))
        end
        run(paginator, block)
      end

      # GET /messages/inbound/{messageid}/details
      def details(message_id)
        object(api_get(path("/messages/inbound/%s/details", message_id)))
      end

      # PUT /messages/inbound/{messageid}/bypass — delivers a Blocked message to the webhook.
      def bypass(message_id)
        object(api_put(path("/messages/inbound/%s/bypass", message_id), idempotent: false))
      end

      # PUT /messages/inbound/{messageid}/retry — re-delivers a Failed message.
      def retry(message_id)
        object(api_put(path("/messages/inbound/%s/retry", message_id), idempotent: false))
      end

      private

      def build_query(filters)
        check_paging!(filters[:count], filters[:offset], max_count: MAX_PAGE_SIZE)
        unless filters[:status].nil?
          wanted = filters[:status].to_s.b.downcase # ASCII-only, safe for any bytes
          status = STATUSES.find { |name| name == wanted }
          raise ValidationError, "status must be one of: #{STATUSES.join(', ')}" unless status

          filters = filters.merge(status: status)
        end

        # This endpoint expects ISO-like "2026-09-01T12:00:00" timestamps.
        prepared = filters.to_h do |key, value|
          value = value.to_time if value.is_a?(DateTime)
          [key, value.is_a?(Time) ? Util.format_time(value, separator: "T") : value]
        end
        query(prepared, FILTERS)
      end
    end
  end
end
