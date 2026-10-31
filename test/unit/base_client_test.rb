# frozen_string_literal: true

require_relative "../test_helper"
require "logger"
require "stringio"

module Haskimail
  class BaseClientTest < TestCase
    def test_token_validation
      [nil, "", "   "].each do |token|
        assert_raises(ConfigurationError) { ServerClient.new(token, transport: @transport) }
      end
      ["tok\r\nX-Evil: 1", "tok en", "токен", "\xFFtok", "\xFF".b].each do |token|
        error = assert_raises(ConfigurationError) { ServerClient.new(token, transport: @transport) }
        assert_match(/forbidden characters/, error.message)
      end
    end

    def test_token_from_environment
      ENV["HASKIMAIL_SERVER_TOKEN"] = "env-server"
      ENV["HASKIMAIL_ACCOUNT_TOKEN"] = "env-account"
      ServerClient.new(transport: @transport).request(:get, "/x")
      assert_equal "env-server", last_request.headers["X-Haskimail-Server-Token"]
      AccountClient.new(transport: @transport).request(:get, "/x")
      assert_equal "env-account", last_request.headers["X-Haskimail-Account-Token"]
      refute last_request.headers.key?("X-Haskimail-Server-Token")
    ensure
      ENV.delete("HASKIMAIL_SERVER_TOKEN")
      ENV.delete("HASKIMAIL_ACCOUNT_TOKEN")
    end

    def test_inspect_never_reveals_token
      client = server_client
      [client.inspect, client.to_s].each do |text|
        refute_includes text, SERVER_TOKEN
        assert_includes text, "[FILTERED]"
      end
      refute_includes account_client.inspect, ACCOUNT_TOKEN
    end

    def test_client_is_frozen_and_snapshots_configuration
      Haskimail.configure { |config| config.read_timeout = 11 }
      client = server_client
      Haskimail.configure { |config| config.read_timeout = 99 }

      assert_predicate client, :frozen?
      assert_predicate client.config, :frozen?
      client.request(:get, "/messages")
      assert_equal({ open_timeout: 5, read_timeout: 11, write_timeout: 30 }, @transport.calls.last.timeouts)
    end

    def test_per_client_options_and_user_agent_suffix
      client = server_client(open_timeout: 1, read_timeout: 2, write_timeout: 3, user_agent: "my-shop/2.1",
                             base_url: "https://eu.example.test/v1/")
      client.request(:get, "/messages")

      assert_equal "https://eu.example.test/v1/messages", last_request.url
      assert_equal({ open_timeout: 1, read_timeout: 2, write_timeout: 3 }, @transport.calls.last.timeouts)
      assert_match(%r{ my-shop/2\.1\z}, last_request.headers["User-Agent"])
    end

    def test_raw_request_escape_hatch
      @transport.respond(body: [{ "a" => 1 }, 2])
      result = server_client.request(:post, "/custom", query: { "x" => "1 2" }, body: { "Raw" => true })

      assert_equal "https://api.haskimail.ru/custom?x=1+2", last_request.url
      assert_equal({ "Raw" => true }, last_json)
      assert_instance_of ApiObject, result.first
      assert_equal 2, result.last
      assert_raises(ValidationError) { server_client.request(:get, "relative") }
      server_client.request(:post, "/custom", body: { "Name" => "Привет".encode("Windows-1251"), "B" => ["é".b] })
      assert_equal({ "Name" => "Привет", "B" => ["é"] }, last_json)
      assert_raises(ValidationError) { server_client.request(:post, "/custom", body: { "x" => "\xFF".b }) }
    end

    def test_empty_and_invalid_bodies
      @transport.respond(body: "").respond(body: "<html>maintenance</html>")
      assert_nil server_client.request(:delete, "/x")
      error = assert_raises(UnexpectedResponseError) { server_client.request(:get, "/y") }
      assert_equal 200, error.http_status
      assert_match(/maintenance/, error.message)
      refute_match(/may have been executed/, error.message)

      @transport.respond(body: "<html>proxy page</html>")
      error = assert_raises(UnexpectedResponseError) do
        server_client.emails.deliver(from: "a@example.com", to: "b@example.com", text_body: "x")
      end
      assert_match(/may have been executed/, error.message)
    end

    def test_unexpected_success_shapes_are_errors_not_silent_data
      @transport.respond(body: "").respond(body: [1]).respond(body: { "Templates" => [1] })
                .respond(body: { "Templates" => "x" }).respond(body: [])
      client = server_client
      assert_raises(UnexpectedResponseError) do
        client.emails.deliver(from: "a@example.com", to: "b@example.com", text_body: "x")
      end
      assert_raises(UnexpectedResponseError) { client.templates.get(1) }
      assert_raises(UnexpectedResponseError) { client.templates.each.to_a }
      assert_raises(UnexpectedResponseError) { client.templates.each.to_a }
      assert_raises(UnexpectedResponseError) { client.templates.each.to_a }
      @transport.respond(body: [1])
      error = assert_raises(UnexpectedResponseError) do
        client.emails.deliver_batch([{ from: "a@example.com", to: "b@example.com", text_body: "x" }])
      end
      assert_match(/MAY have been accepted/, error.message)
    end

    def test_invalid_raw_path
      assert_raises(ValidationError) { server_client.request(:get, "/a b") }
    end

    def test_side_effect_puts_are_not_retried
      @transport.respond(status: 500, body: "")
      assert_raises(ServerError) { server_client.inbound_messages.retry("m1") }
      assert_equal 1, @transport.requests.size, "re-delivery to the inbound webhook must not repeat"

      @transport.respond(status: 503, body: "").respond(body: Fixtures::WEBHOOK)
      server_client.webhooks.update(905, url: "https://example.com/h")
      assert_equal 3, @transport.requests.size, "plain idempotent PUTs are retried"
    end

    def test_error_mapping
      {
        401 => AuthenticationError, 403 => ForbiddenError, 404 => NotFoundError,
        413 => PayloadTooLargeError, 422 => UnprocessableEntityError, 429 => RateLimitError,
        500 => ServerError, 503 => ServiceUnavailableError, 418 => ApiError
      }.each do |status, klass|
        @transport.respond(status: status, body: { "ErrorCode" => 10, "Message" => "nope" })
        error = assert_raises(klass) { server_client(max_retries: 0).request(:post, "/x", body: {}) }
        assert_instance_of klass, error
        assert_equal status, error.http_status
        assert_equal 10, error.error_code
        assert_kind_of Error, error
      end
    end

    def test_error_with_non_json_body
      @transport.respond(status: 502, body: "<html>Bad gateway</html>", headers: { "x-id" => "1" })
      error = assert_raises(ServerError) { server_client(max_retries: 0).request(:get, "/x") }

      assert_equal "HTTP 502: <html>Bad gateway</html>", error.message
      assert_nil error.error_code
      assert_equal({ "x-id" => "1" }, error.response_headers)
      assert_nil error.error_code_description
    end

    def test_ok_status_with_error_code_raises
      @transport.respond(status: 200, body: { "ErrorCode" => 702, "Message" => "only blocked" })
      error = assert_raises(UnprocessableEntityError) { server_client.inbound_messages.bypass("m1") }

      assert_equal 702, error.error_code
    end

    def test_idempotent_requests_are_retried_on_server_errors_and_rate_limits
      @transport.respond(status: 503, body: "").respond(status: 429, body: "", headers: { "retry-after" => "7" })
                .respond(body: Fixtures::MESSAGES)
      result = server_client.messages.list

      assert_equal 3, @transport.requests.size
      assert_equal 1, result.total_count
      assert_equal 2, @sleeps.size
      assert_operator @sleeps.first, :<=, 0.5
      assert_in_delta 7.0, @sleeps.last
    end

    def test_retry_after_is_capped
      @transport.respond(status: 503, body: "", headers: { "retry-after" => "3600" }).respond(body: {})
      server_client.request(:get, "/x")

      assert_in_delta 30.0, @sleeps.first
    end

    def test_retries_are_bounded
      3.times { @transport.respond(status: 500, body: "") }
      @transport.strict!
      assert_raises(ServerError) { server_client(max_retries: 2).request(:get, "/x") }

      assert_equal 3, @transport.requests.size
      assert_equal 2, @sleeps.size
      assert_operator @sleeps[1], :<=, 1.0
      assert_operator @sleeps[1], :>=, 0.5
    end

    def test_post_is_not_retried_on_server_errors
      @transport.respond(status: 500, body: "")
      assert_raises(ServerError) do
        server_client.emails.deliver(from: "a@example.com", to: "b@example.com", text_body: "x")
      end

      assert_equal 1, @transport.requests.size
    end

    def test_post_is_retried_on_rate_limit_and_temporary_sending_error
      @transport.respond(status: 429, body: "")
                .respond(status: 422, body: { "ErrorCode" => 36, "Message" => "try later" })
                .respond(body: Fixtures::SEND_OK)
      result = server_client.emails.deliver(from: "a@example.com", to: "b@example.com", text_body: "x")

      assert_predicate result, :success?
      assert_equal 3, @transport.requests.size
    end

    def test_connection_errors
      not_sent = ConnectionError.new("refused", request_sent: false)
      sent = ConnectionError.new("reset")

      @transport.fail_with(not_sent).respond(body: Fixtures::SEND_OK)
      server_client.emails.deliver(from: "a@example.com", to: "b@example.com", text_body: "x")
      assert_equal 2, @transport.requests.size, "POST is safe to retry when the request was never sent"

      @transport.fail_with(sent)
      error = assert_raises(ConnectionError) do
        server_client.emails.deliver(from: "a@example.com", to: "b@example.com", text_body: "x")
      end
      assert_same sent, error
      assert_equal 3, @transport.requests.size, "POST must not be repeated after it may have been sent"

      @transport.fail_with(TimeoutError.new("slow")).respond(body: {})
      server_client.request(:get, "/x")
      assert_equal 5, @transport.requests.size

      @transport.fail_with(TlsError.new("bad cert", request_sent: false))
      assert_raises(TlsError) { server_client.request(:get, "/x") }
      assert_equal 6, @transport.requests.size, "TLS failures are never retried"
    end

    def test_logging_excludes_secrets_and_personal_data
      io = StringIO.new
      logger = Logger.new(io, level: Logger::DEBUG)
      @transport.respond(status: 503, body: "").respond(body: {})
      server_client(logger: logger).messages.list(recipient: "ivan@example.com")

      log = io.string
      assert_match(%r{GET /messages -> 503}, log)
      assert_match(%r{retry 1/2}, log)
      assert_match(%r{GET /messages -> 200}, log)
      refute_includes log, "ivan@example.com"
      refute_includes log, SERVER_TOKEN
    end

    def test_reset_configuration
      Haskimail.configure { |config| config.max_retries = 5 }
      assert_equal 5, Haskimail.configuration.max_retries
      Haskimail.reset_configuration!
      assert_equal 2, Haskimail.configuration.max_retries
    end

    def test_parse_time_helper
      assert_equal Time.utc(2026, 10, 7, 11, 30, 12), Haskimail.parse_time("2026-10-07 14:30:12")
    end

    def test_base_client_is_abstract
      assert_raises(NotImplementedError) { BaseClient.new("x", transport: @transport).request(:get, "/x") }
    end
  end
end
