# frozen_string_literal: true

module Haskimail
  # In-memory transport: records requests, replays queued responses.
  #
  # Lenient by default (an unqueued request gets `200 {}`), so contract tests
  # can check request shapes alone. `strict!` turns an unqueued request into
  # a failure — use it wherever the number of requests matters. Every test
  # also fails if queued responses are left unused (see TestCase#teardown).
  class FakeTransport
    Call = Struct.new(:request, :timeouts)

    # Answer to unqueued requests: an empty object that is also a valid send result.
    DEFAULT_BODY = '{"ErrorCode":0,"Message":"OK"}'

    # Raised for a request nobody expected in strict mode.
    class UnexpectedRequest < StandardError; end

    attr_reader :calls

    def initialize
      @calls = []
      @queue = []
      @strict = false
    end

    def strict!
      @strict = true
      self
    end

    # Number of queued responses not consumed yet.
    def pending
      @queue.size
    end

    def respond(status: 200, body: {}, headers: {})
      payload = body.is_a?(String) ? body : JSON.generate(body)
      @queue << HTTP::Response.new(status: status, headers: headers, body: payload)
      self
    end

    def fail_with(error)
      @queue << error
      self
    end

    def call(request, **timeouts)
      @calls << Call.new(request, timeouts)
      if @queue.empty? && @strict
        raise UnexpectedRequest, "unexpected request ##{@calls.size}: #{request.method.upcase} #{request.url}"
      end

      item = @queue.shift || HTTP::Response.new(status: 200, headers: {}, body: DEFAULT_BODY)
      raise item if item.is_a?(Exception)

      item
    end

    def requests
      @calls.map(&:request)
    end
  end
end
