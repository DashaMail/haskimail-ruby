# frozen_string_literal: true

require_relative "../test_helper"

module Haskimail
  class LimitsTest < TestCase
    BASE = { from: "a@example.com", to: "b@example.com", text_body: "x" }.freeze

    def deliver(**fields)
      server_client.emails.deliver(**BASE, **fields)
    end

    def test_length_limits_count_utf16_units
      deliver(subject: "я" * 2000, tag: "t" * 1000, from: "#{'a' * 243}@example.com")
      assert_equal 2000, last_json["Subject"].length

      error = assert_raises(ValidationError) { deliver(subject: "я" * 2001) }
      assert_match(/Subject is longer than 2000/, error.message)
      # An emoji outside the BMP counts as two units, as Haskimail counts it.
      assert_raises(ValidationError) { deliver(subject: "#{'a' * 1999}🚀") }
      deliver(subject: "#{'a' * 1998}🚀")
      assert_raises(ValidationError) { deliver(tag: "t" * 1001) }
      assert_raises(ValidationError) { deliver(from: "#{'a' * 244}@example.com") }
    end

    def test_body_size_limit_is_in_bytes
      deliver(html_body: "a" * Resources::Emails::MAX_BODY_BYTES)
      error = assert_raises(ValidationError) { deliver(text_body: "я" * ((Resources::Emails::MAX_BODY_BYTES / 2) + 1)) }
      assert_match(/TextBody exceeds 5 MB/, error.message)
    end

    def test_at_most_fifty_recipients_across_to_cc_bcc
      fifty = Array.new(48) { |i| "u#{i}@example.com" }
      deliver(to: fifty, cc: "c@example.com", bcc: "d@example.com")

      error = assert_raises(ValidationError) do
        deliver(to: fifty, cc: "c@example.com, e@example.com", bcc: "d@example.com")
      end
      assert_match(/51 recipients/, error.message)
      # Commas inside quoted names or angle brackets do not split addresses.
      quoted = Array.new(50) { |i| "\"Фамилия, Имя #{i}\" <u#{i}@example.com>" }
      deliver(to: quoted.join(", "))
    end

    def test_count_addresses
      count = ->(list) { Resources::Emails.count_addresses(list) }

      assert_equal 0, count.call(nil)
      assert_equal 0, count.call(" , ")
      assert_equal 1, count.call("a@b.example")
      assert_equal 2, count.call("a@b.example, c@d.example,")
      assert_equal 1, count.call('"Иванов, Иван" <a@b.example>')
      assert_equal 1, count.call('"q\",x" <a@b.example>')
      assert_equal 1, count.call("<a,b@c.example>")
      assert_equal 1, count.call('"Ann <Sales>, team" <a@b.example>')
      assert_equal 2, count.call("x> a@b.example, c@d.example") # stray ">" is ignored
    end

    def test_test_addresses_match_documentation
      assert_equal "hardbounce@bounce-testing.haskimail.ru", TestAddresses::HARD_BOUNCE
      assert_equal "softbounce@bounce-testing.haskimail.ru", TestAddresses::SOFT_BOUNCE
      assert_equal "blocked@bounce-testing.haskimail.ru", TestAddresses::BLOCKED
      assert_equal "spamnotification@bounce-testing.haskimail.ru", TestAddresses::SPAM_COMPLAINT
      deliver(to: TestAddresses::HARD_BOUNCE)
      assert_equal TestAddresses::HARD_BOUNCE, last_json["To"]
    end
  end

  class RetryPolicyTest < TestCase
    def deliver
      server_client.emails.deliver(from: "a@example.com", to: "b@example.com", text_body: "x")
    end

    def test_post_is_retried_only_when_the_api_refused_before_processing
      @transport.respond(status: 503, body: "").respond(body: Fixtures::SEND_OK)
      assert_predicate deliver, :success?
      assert_equal 2, @transport.requests.size

      [500, 502, 504].each do |status|
        @transport.respond(status: status, body: "")
        assert_raises(ServerError) { deliver }
      end
      assert_equal 5, @transport.requests.size, "500/502/504 on a send are never repeated"
    end

    def test_retry_after_http_date
      now = Time.utc(2026, 10, 30, 12, 0, 0)
      policy = HTTP::RetryPolicy.new(max_retries: 2, random: Struct.new(:rand).new(0.0), clock: -> { now })
      after = ->(value) { policy.delay(1, HTTP::Response.new(status: 503, headers: { "retry-after" => value }, body: "")) }

      assert_in_delta 12.0, after.call((now + 12).httpdate)
      assert_in_delta 30.0, after.call((now + 3600).httpdate), 0.001, "capped at MAX_RETRY_AFTER"
      assert_in_delta 0.0, after.call("Wed, 21 Oct 2015 07:28:00 GMT"), 0.001, "a date in the past means now"
      assert_in_delta 7.0, after.call(" 7 ")
      assert_in_delta 0.25, after.call("soon"), 0.001, "an unparsable Retry-After falls back to backoff"
    end

    def test_retry_after_reaches_the_sleeper
      @transport.strict!.respond(status: 503, body: "", headers: { "retry-after" => "4" }).respond(body: {})
                .respond(status: 503, body: "", headers: { "retry-after" => "Wed, 21 Oct 2015 07:28:00 GMT" })
                .respond(body: {})
      2.times { server_client.request(:get, "/x") }

      assert_equal [4.0, 0.0], @sleeps
    end

    def test_error_code_sent_as_string
      @transport.respond(status: 422, body: { "ErrorCode" => "701", "Message" => "x" })
      error = assert_raises(UnprocessableEntityError) { server_client.messages.details("m") }
      assert_equal 701, error.error_code

      @transport.respond(status: 422, body: { "ErrorCode" => "36", "Message" => "later" })
                .respond(body: Fixtures::SEND_OK)
      assert_predicate deliver, :success?
      @transport.respond(status: 200, body: { "ErrorCode" => "0", "Message" => "OK" })
      server_client.templates.delete(1)
      @transport.respond(status: 422, body: { "ErrorCode" => "n/a" })
      assert_nil assert_raises(UnprocessableEntityError) { server_client.templates.delete(1) }.error_code
    end

    def test_safe_posts_are_retried_after_network_failures
      sent = ConnectionError.new("reset")
      @transport.fail_with(sent).respond(body: {}).fail_with(sent).respond(body: {})
                .fail_with(sent).respond(body: {}).fail_with(sent).respond(body: {})
      client = server_client
      client.message_streams.archive("s1")
      client.message_streams.unarchive("s1")
      client.suppressions.create("s1", "a@b.example")
      client.templates.validate(subject: "S")
      assert_equal 8, @transport.requests.size

      @transport.fail_with(sent) # the next (default) response succeeds
      client.suppressions.delete("s1", "a@b.example")
      assert_equal 10, @transport.requests.size
    end

    def test_template_push_is_never_repeated
      @transport.respond(status: 502, body: "")
      assert_raises(ServerError) do
        account_client.templates.push(source_server_id: 1, destination_server_id: 2, perform_changes: true)
      end
      assert_equal 1, @transport.requests.size
    end

    def test_request_arguments_are_validated
      assert_raises(ValidationError) { server_client.request(:head, "/x") }
      assert_raises(ValidationError) { server_client.request("get", "/x") }
      assert_raises(ValidationError) { server_client.request(:get, :x) }
      assert_empty @transport.requests
    end
  end
end
