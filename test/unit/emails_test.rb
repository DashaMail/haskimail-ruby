# frozen_string_literal: true

require_relative "../test_helper"

module Haskimail
  class EmailsTest < TestCase
    def test_deliver_sends_documented_request
      @transport.respond(body: Fixtures::SEND_OK)
      result = server_client.emails.deliver(
        from: "Магазин <shop@example.com>",
        to: "ivan@example.com",
        subject: "Ваш заказ №1042 оформлен",
        html_body: "<p>Заказ</p>",
        text_body: "Заказ",
        tag: "orders",
        reply_to: "support@example.com",
        headers: { "X-Order-Id" => "1042" },
        track_opens: true,
        track_links: true,
        metadata: { order_id: "1042", nested_key: { keep_me: 1 } },
        message_stream: "2081"
      )

      assert_request :post, "/email"
      assert_equal "server-token-1234", last_request.headers["X-Haskimail-Server-Token"]
      assert_equal "application/json", last_request.headers["Content-Type"]
      assert_equal "application/json", last_request.headers["Accept"]
      assert_match %r{\Ahaskimail-ruby/#{VERSION} ruby/}o, last_request.headers["User-Agent"]
      assert_equal(
        {
          "From" => "Магазин <shop@example.com>", "To" => "ivan@example.com",
          "Subject" => "Ваш заказ №1042 оформлен", "HtmlBody" => "<p>Заказ</p>", "TextBody" => "Заказ",
          "Tag" => "orders", "ReplyTo" => "support@example.com",
          "Headers" => [{ "Name" => "X-Order-Id", "Value" => "1042" }],
          "TrackOpens" => true, "TrackLinks" => true,
          "Metadata" => { "order_id" => "1042", "nested_key" => { "keep_me" => 1 } },
          "MessageStream" => "2081"
        },
        last_json
      )
      assert_instance_of SendResult, result
      assert_predicate result, :success?
      assert_equal "6f1c0b2d9e8a4f7b3c5d2e1a0b9c8d7e", result.message_id
      assert_equal ["6f1c0b2d9e8a4f7b3c5d2e1a0b9c8d7e"], result.message_ids
      assert_equal Time.utc(2026, 10, 7, 11, 30, 12), result.submitted_at_time
    end

    def test_deliver_accepts_exact_api_keys_and_positional_hash
      @transport.respond(body: Fixtures::SEND_OK)
      server_client.emails.deliver({ "From" => "a@example.com", "To" => "b@example.com", "TextBody" => "x" },
                                   subject: "Hi")

      assert_equal({ "From" => "a@example.com", "To" => "b@example.com", "TextBody" => "x", "Subject" => "Hi" },
                   last_json)
    end

    def test_deliver_keeps_array_headers_and_drops_nil
      server_client.emails.deliver(from: "a@example.com", to: "b@example.com", text_body: "x", cc: nil,
                                   headers: [{ name: "Message-ID", value: "<id@example.com>" }])

      refute last_json.key?("Cc")
      assert_equal [{ "Name" => "Message-ID", "Value" => "<id@example.com>" }], last_json["Headers"]
    end

    def test_multiple_message_ids
      @transport.respond(body: Fixtures::SEND_OK.merge("MessageID" => "a1, b2"))
      result = server_client.emails.deliver(from: "a@example.com", to: "b@example.com, c@example.com",
                                            text_body: "x")

      assert_equal %w[a1 b2], result.message_ids
    end

    def test_deliver_with_attachment_objects
      attachment = Attachment.new(name: "readme.txt", content: "test content")
      inline = Attachment.new(name: "logo.png", content: "png", content_id: "cid:logo")
      server_client.emails.deliver(from: "a@example.com", to: "b@example.com", html_body: "<img src='cid:logo'>",
                                   attachments: [attachment, inline])

      assert_equal(
        [
          { "Name" => "readme.txt", "Content" => "dGVzdCBjb250ZW50", "ContentType" => "text/plain" },
          { "Name" => "logo.png", "Content" => "cG5n", "ContentType" => "image/png", "ContentID" => "cid:logo" }
        ],
        last_json["Attachments"]
      )
    end

    def test_deliver_validates_before_sending
      emails = server_client.emails
      cases = {
        { to: "b@example.com", text_body: "x" } => /From is required/,
        { from: "a@example.com", to: " ", text_body: "x" } => /To is required/,
        { from: "a@example.com", to: "b@example.com" } => /html_body or text_body/,
        { from: "a@example.com", to: "b@example.com", text_body: "x", "TextBody" => "y" } => /more than once/,
        { from: "a@example.com", to: "b@example.com", text_body: "x",
          attachments: [{ "Name" => "virus.exe", "Content" => "" }] } => /\.exe/,
        { from: "a@example.com", to: "b@example.com", text_body: "x",
          attachments: [{ "Name" => "virus.ExE. ", "Content" => "" }] } => /\.exe/,
        { from: "a@example.com", to: "b@example.com", text_body: "x", attachments: "nope" } => /Array/,
        { from: "a@example.com", to: "b@example.com", text_body: "x", attachments: ["nope"] } => /Hash/,
        { from: "a@example.com", to: "b@example.com", text_body: "x",
          attachments: [{ "Name" => "big.bin.txt", "Content" => "a" * (Attachment::MAX_MESSAGE_SIZE + 1) }] } =>
          /10 MB/,
        { from: "a@example.com", to: "b@example.com", text_body: "x", headers: "X-A: 1" } => /headers must be/,
        { from: "a@example.com", to: "b@example.com", text_body: "x",
          headers: { "X-Evil" => "1\r\nBcc: victim@example.com" } } => /line breaks/,
        { from: "a@example.com", to: "b@example.com", text_body: "x", 42 => "y" } => /Symbols or Strings/
      }
      cases.each do |fields, message|
        error = assert_raises(ValidationError, fields.inspect) { emails.deliver(fields) }
        assert_match message, error.message
      end
      assert_raises(ValidationError) { emails.deliver("not a hash") }
      assert_empty @transport.requests
    end

    def test_address_arrays_are_joined
      server_client.emails.deliver(from: "a@example.com", to: %w[b@example.com c@example.com],
                                   cc: ["d@example.com"], reply_to: %w[e@example.com f@example.com], text_body: "x")

      assert_equal "b@example.com, c@example.com", last_json["To"]
      assert_equal "d@example.com", last_json["Cc"]
      assert_equal "e@example.com, f@example.com", last_json["ReplyTo"]
      assert_raises(ValidationError) do
        server_client.emails.deliver(from: "a@example.com", to: ["b@example.com", 1], text_body: "x")
      end
    end

    def test_header_injection_is_blocked_everywhere
      base = { from: "a@example.com", to: "b@example.com", text_body: "x" }
      [
        { subject: "Hi\r\nBcc: spy@evil.example" },
        { subject: "Hi\u2028Bcc: spy@evil.example" },
        { from: "a@example.com\nBcc: spy@evil.example" },
        { reply_to: "r@example.com\u0085X: y" },
        { tag: "t\x00" },
        { subject: [1] },
        { headers: { "Bcc: spy@evil.example\tX" => "1" } },
        { headers: { "X Space" => "1" } },
        { headers: { "" => "1" } },
        { headers: { "X-Ok" => "1\u2029Bcc: spy" } },
        { headers: { "X-Ok" => "1\x7F" } }
      ].each do |extra|
        assert_raises(ValidationError, extra.inspect) { server_client.emails.deliver(**base, **extra) }
      end
      assert_empty @transport.requests

      server_client.emails.deliver(**base, subject: "Tab\tis fine — and Unicode «ok»",
                                           headers: { "X-Tab" => "a\tb" })
      assert_equal "Tab\tis fine — and Unicode «ok»", last_json["Subject"]
      server_client.emails.deliver(**base, subject: :greeting, tag: 42)
      assert_equal %w[greeting 42], last_json.values_at("Subject", "Tag")
    end

    def test_header_check_handles_any_encoding
      assert_raises(ValidationError) do
        server_client.emails.deliver(from: "a@example.com", to: "b@example.com", subject: "\xFF\n".b,
                                     text_body: "x")
      end
      server_client.emails.deliver(from: "a@example.com", to: "b@example.com", text_body: "x",
                                   subject: "Привет".encode("Windows-1251"))
      assert_equal "Привет", last_json["Subject"]
      assert_raises(ValidationError) do
        server_client.emails.deliver(from: "a@example.com", to: "b@example.com", text_body: "x",
                                     subject: (+"\x98").force_encoding("Windows-1251"))
      end
      assert_raises(ValidationError) do
        server_client.emails.deliver(from: "a@example.com", to: "b@example.com", text_body: "x",
                                     subject: "Привет\n".encode("UTF-16LE"))
      end
    end

    def test_broken_encodings_are_validation_errors
      base = { from: "a@example.com", to: "b@example.com", text_body: "x" }
      error = assert_raises(ValidationError) do
        server_client.emails.deliver(**base, subject: (+"\xFF").force_encoding(Encoding::UTF_16LE))
      end
      assert_match(/cannot be converted to UTF-8/, error.message)
      # Mixed encodings are converted to UTF-8 before joining.
      server_client.emails.deliver(**base, to: ["Я <ya@example.com>".encode("Windows-1251"), "я@example.com"])
      assert_equal "Я <ya@example.com>, я@example.com", last_json["To"]
      assert_raises(ValidationError) { server_client.emails.deliver(**base, cc: "\xFFa@b.example".b) }
      assert_raises(ValidationError) { server_client.emails.deliver(**base, headers: { "X-A" => "\xFF".b }) }
      assert_raises(ValidationError) { server_client.emails.deliver(**base, headers: { "\xD0\xAF".b => "1" }) }
      assert_equal 1, @transport.requests.size
    end

    def test_invalid_utf8_body_is_a_validation_error
      error = assert_raises(ValidationError) do
        server_client.emails.deliver(from: "a@example.com", to: "b@example.com", text_body: "\xFF".b)
      end
      assert_match(/not valid UTF-8/, error.message)
      server_client.emails.deliver(from: "a@example.com", to: "b@example.com", text_body: "Привет".b)
      assert_equal "Привет", last_json["TextBody"], "binary strings holding UTF-8 are accepted"
      server_client.emails.deliver(from: "a@example.com", to: "b@example.com", text_body: "x",
                                   metadata: { "ключ".b => "значение".encode("Windows-1251"), list: ["\u00e9".b] })
      assert_equal({ "ключ" => "значение", "list" => ["\u00e9"] }, last_json["Metadata"])
    end

    def test_deliver_rejected_raises_with_error_code
      @transport.respond(status: 422, body: { "ErrorCode" => 1226, "Message" => "MessageStream doesn't match api key" })
      error = assert_raises(UnprocessableEntityError) do
        server_client.emails.deliver(from: "a@example.com", to: "b@example.com", text_body: "x")
      end

      assert_equal 422, error.http_status
      assert_equal ErrorCodes::MESSAGE_STREAM_NOT_FOUND, error.error_code
      assert_equal "MessageStream doesn't match api key", error.api_message
      assert_equal "Канал не найден", error.error_code_description
      assert_equal "HTTP 422 [ErrorCode 1226]: MessageStream doesn't match api key", error.message
      assert_equal 1, @transport.requests.size, "POST /email must not be retried on a plain 422"
    end

    def test_deliver_batch_returns_per_item_results
      @transport.respond(body: Fixtures::BATCH)
      result = server_client.emails.deliver_batch([
                                                    { from: "a@example.com", to: "ivan@example.com",
                                                      html_body: "x" },
                                                    { from: "a@example.com", to: "anna.example.com",
                                                      template_alias: "welcome" }
                                                  ])

      assert_request :post, "/email/batch"
      assert_equal "HtmlBody", last_json.first.keys.last
      assert_equal "welcome", last_json.last["TemplateAlias"]
      assert_instance_of BatchResult, result
      assert_equal 2, result.size
      assert_equal 2, result.length
      refute_predicate result, :success?
      assert_equal ["ivan@example.com"], result.successful.map(&:to)
      assert_equal [6], result.failed.map(&:error_code)
      assert_empty result.failed.first.message_ids
      assert_equal "ivan@example.com", result[0].to
      assert_equal 2, result.to_a.size
      assert_equal 2, result.each.count
      assert_same(result, result.each { |_item| nil })
      assert_match(/size=2 failed=1/, result.inspect)
    end

    def test_batch_validation
      emails = server_client.emails
      assert_raises(ValidationError) { emails.deliver_batch([]) }
      assert_raises(ValidationError) { emails.deliver_batch("x") }
      assert_raises(ValidationError) { emails.deliver_batch([1]) }
      too_many = Array.new(501) { { from: "a@example.com", to: "b@example.com", text_body: "x" } }
      assert_match(/1\.\.500/, assert_raises(ValidationError) { emails.deliver_batch(too_many) }.message)
      error = assert_raises(ValidationError) do
        emails.deliver_batch([{ from: "a@example.com", to: "b@example.com", text_body: "x" },
                              { from: "a@example.com", to: "b@example.com" }])
      end
      assert_match(/\AEmail #1: /, error.message)
      assert_empty @transport.requests
    end

    def test_batch_malformed_response
      @transport.respond(body: { "unexpected" => true })
      assert_raises(ApiError) do
        server_client.emails.deliver_batch([{ from: "a@example.com", to: "b@example.com", text_body: "x" }])
      end
    end

    def test_batch_whole_request_rejected
      @transport.respond(status: 413, body: "")
      error = assert_raises(PayloadTooLargeError) do
        server_client.emails.deliver_batch([{ from: "a@example.com", to: "b@example.com", text_body: "x" }])
      end
      assert_equal 413, error.http_status
    end

    def test_deliver_with_template
      @transport.respond(body: Fixtures::SEND_OK)
      server_client.emails.deliver_with_template(
        template_id: 4521,
        template_model: { "{{name}}" => "Иван", "{{order}}" => "1042", plain_symbol: "kept" },
        from: "Магазин <shop@example.com>", to: "ivan@example.com", tag: "orders", message_stream: "2081"
      )

      assert_request :post, "/email/withTemplate"
      assert_equal 4521, last_json["TemplateId"]
      assert_equal({ "{{name}}" => "Иван", "{{order}}" => "1042", "plain_symbol" => "kept" },
                   last_json["TemplateModel"])
    end

    def test_deliver_with_template_requires_template
      assert_raises(ValidationError) do
        server_client.emails.deliver_with_template(from: "a@example.com", to: "b@example.com")
      end
    end

    def test_deliver_batch_with_templates
      @transport.respond(body: Fixtures::BATCH)
      result = server_client.emails.deliver_batch_with_templates([
                                                                   { template_id: 1, from: "a@example.com",
                                                                     to: "b@example.com" },
                                                                   { template_alias: "x", from: "a@example.com",
                                                                     to: "c@example.com" }
                                                                 ])

      assert_request :post, "/email/batchWithTemplates"
      assert_equal 2, last_json["Messages"].size
      assert_equal 1, result.failed.size
      assert_raises(ValidationError) do
        server_client.emails.deliver_batch_with_templates([{ from: "a@example.com", to: "b@example.com" }])
      end
    end

    def test_test_token_constant
      client = ServerClient.new(TEST_TOKEN, transport: @transport)
      client.emails.deliver(from: "a@example.com", to: "b@example.com", text_body: "x")

      assert_equal "HASKIMAIL_API_TEST", last_request.headers["X-Haskimail-Server-Token"]
    end
  end
end
