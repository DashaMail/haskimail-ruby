# frozen_string_literal: true

require_relative "../errors"
require_relative "../util"
require_relative "../api_object"
require_relative "../redacted"

module Haskimail
  # API resources. Instances are created by the clients — use
  # `client.emails`, `client.templates` etc. instead of instantiating them.
  module Resources
    # Shared plumbing of every resource: requests, paging checks, wrapping.
    # @api private
    class Base
      include Redacted

      # Query names of the paging parameters.
      PAGING = { count: "count", offset: "offset" }.freeze

      def initialize(client)
        @client = client
        freeze
      end

      # Resource name only.
      def inspect
        "#<#{self.class.name}>"
      end

      private

      def api_get(path, query = nil)
        @client.perform(:get, path, query: query)
      end

      # POSTs without side effects on repeat (validation, archive, suppression
      # lists) pass `idempotent: true` so network failures are retried.
      def api_post(path, body = nil, idempotent: nil)
        @client.perform(:post, path, body: body, idempotent: idempotent)
      end

      # PUTs that trigger side effects pass `idempotent: false` so they are
      # never repeated automatically.
      def api_put(path, body = nil, idempotent: nil)
        @client.perform(:put, path, body: body, idempotent: idempotent)
      end

      def api_patch(path, body = nil)
        @client.perform(:patch, path, body: body)
      end

      def api_delete(path)
        @client.perform(:delete, path)
      end

      def object(data)
        ApiObject.new(@client.expect_object(data))
      end

      # Every documented send response carries ErrorCode; without it the
      # outcome is unknown (the email may or may not have been accepted).
      def send_result(data)
        result = SendResult.new(@client.expect_object(data))
        return result unless result.error_code.nil?

        raise UnexpectedResponseError.new("Send response without ErrorCode. The email MAY have been accepted — " \
                                          "check the message log before re-sending", http_status: 200)
      end

      # Returns the paginator, or iterates it when a block is given.
      def run(paginator, block)
        block ? paginator.each(&block) : paginator
      end

      def path(template, *segments)
        Util.path(template, *segments)
      end

      def query(params, mapping)
        Util.query(params, mapping)
      end

      # Merges an optional positional Hash with keyword arguments, so both
      # `deliver(from: "a")` and `deliver({ "From" => "a" })` work.
      def merge_params(params, fields)
        raise ValidationError, "Expected a Hash of fields, got #{params.class}" unless params.nil? || params.is_a?(Hash)

        (params || {}).merge(fields)
      end

      def paginate(items_key, page_size:, max_window: nil)
        Paginator.new(items_key: items_key, page_size: page_size, max_window: max_window) do |count, offset|
          @client.expect_object(yield(count, offset))
        end
      end

      # Documented count/offset ranges (e.g. messages: count 1..500,
      # count + offset <= 10000), checked before the request. Without a
      # documented maximum, count must still be a positive Integer.
      def check_paging!(count, offset, max_count: nil, max_window: nil)
        check_integer!(:count, count, 1, max_count) unless count.nil?
        check_integer!(:offset, offset, 0, nil) unless offset.nil?
        return unless max_window && count.to_i + offset.to_i > max_window

        raise ValidationError, "count + offset must not exceed #{max_window}"
      end

      def check_integer!(name, value, min, max)
        return if value.is_a?(Integer) && value.between?(min, max || Float::INFINITY)

        range = max ? "between #{min} and #{max}" : "of at least #{min}"
        raise ValidationError, "#{name} must be an Integer #{range}"
      end

      # Without a documented maximum, Paginator itself checks page_size.
      def check_page_size!(page_size, max)
        return if page_size.is_a?(Integer) && page_size.between?(1, max)

        raise ValidationError, "page_size must be an Integer between 1 and #{max}"
      end

      def reject_paging!(filters)
        clash = filters.keys & %i[count offset]
        return if clash.empty?

        raise ValidationError, "Use page_size: instead of #{clash.join('/')} when iterating"
      end
    end
  end

  # Lazily walks through `count`/`offset` pages. Enumerable, so `first(10)`,
  # `lazy`, `each_slice` etc. only request the pages they actually need.
  #
  #   client.messages.each(tag: "orders").each { |message| ... }
  class Paginator
    include Enumerable

    def initialize(items_key:, page_size:, max_window: nil, &fetch)
      unless page_size.is_a?(Integer) && page_size.positive?
        raise ValidationError, "page_size must be a positive Integer"
      end

      @items_key = items_key
      @page_size = page_size
      @max_window = max_window
      @fetch = fetch
      freeze
    end

    # Yields every item, requesting pages lazily.
    # @yieldparam item [ApiObject]
    def each
      return enum_for(:each) unless block_given?

      offset = 0
      loop do
        count = @max_window ? [@page_size, @max_window - offset].min : @page_size
        break unless count.positive?

        page = @fetch.call(count, offset)
        items = page.fetch(@items_key, [])
        unless items.is_a?(Array) && items.all?(Hash)
          raise UnexpectedResponseError.new("Expected #{@items_key} to be an array of objects", http_status: 200)
        end

        items.each { |item| yield ApiObject.new(item) }
        offset += items.size
        break if last_page?(page["TotalCount"], items.size, count, offset)
      end
      self
    end

    # With TotalCount the API says how many records exist, so a short page
    # (the server may cap `count`) does not end the walk; only an empty page
    # or reaching the total does. Without it, a short page is the last one.
    def last_page?(total, size, count, offset)
      return size < count if total.nil?

      total = Integer(total, exception: false) if total.is_a?(String)
      unless total.is_a?(Integer)
        raise UnexpectedResponseError.new("TotalCount is not a number: #{total.inspect}", http_status: 200)
      end

      size.zero? || offset >= total
    end
    private :last_page?

    # Items key and page size.
    def inspect
      "#<#{self.class.name} items=#{@items_key.inspect} page_size=#{@page_size}>"
    end
  end
end
