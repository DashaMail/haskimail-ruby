# frozen_string_literal: true

require_relative "../test_helper"
require "digest"
require "English"
require "pp"
require "rbconfig"
require "tempfile"
require "tmpdir"
require "yaml"

module Haskimail
  # Regression tests for the pre-release review: each test pins down a defect
  # that was found, or a mutation of lib/ that the suite used to miss.
  class HardeningEmailTest < TestCase
    PLAIN = { from: "shop@example.com", to: "ivan@example.com", text_body: "x" }.freeze

    def deliver(fields)
      server_client.emails.deliver(fields)
    end

    def test_json_parsing_never_instantiates_classes
      data = Util.parse_json('{"json_class":"String","raw":[104,105]}')

      assert_equal({ "json_class" => "String", "raw" => [104, 105] }, data)
      assert_raises(JSON::ParserError) { Util.parse_json("{") }
      assert_raises(JSON::NestingError) { Util.parse_json("#{'[' * 150}#{']' * 150}") }
    end

    def test_header_checks_cannot_be_bypassed_by_spelling_a_field_differently
      injection = "x\r\nBcc: spy@example.net"
      [{ "subject" => injection }, { SUBJECT: injection }, { replyTo: injection }, { "reply_to" => injection },
       { "bcc" => injection }, { "tag" => injection }].each do |field|
        error = assert_raises(ValidationError, field.inspect) { deliver(PLAIN.merge(field)) }
        assert_match(/line breaks/, error.message)
      end
      [{ "FROM" => injection }, { "to" => injection }].each do |field|
        message = PLAIN.reject { |key, _| ApiObject.normalize(key) == ApiObject.normalize(field.keys.first) }
        error = assert_raises(ValidationError, field.inspect) { deliver(message.merge(field)) }
        assert_match(/line breaks/, error.message)
      end
      assert_empty @transport.requests
    end

    def test_unicode_look_alike_field_names_are_canonicalized
      injection = "x\r\nBcc: spy@example.net"
      ["ſubject", "Ｓｕｂｊｅｃｔ", "SUBJECT\u200B"].each do |name|
        assert_raises(ValidationError, name.inspect) { deliver(PLAIN.merge(name => injection)) }
      end
    end

    def test_user_data_is_untouched_under_any_spelling
      deliver(PLAIN.merge("metadata" => { order_id: "1", "Note" => nil }))
      assert_equal({ "order_id" => "1", "Note" => nil }, last_json["Metadata"])

      server_client.emails.deliver_with_template(from: "a@example.com", to: "b@example.com", template_alias: "t",
                                                 "template_model" => { user_name: "Ivan", items: [{ sku_id: 1 }] })
      assert_equal({ "user_name" => "Ivan", "items" => [{ "sku_id" => 1 }] }, last_json["TemplateModel"])

      deliver(PLAIN.merge(templateModel: { "{{a}}" => nil }, "Metadata" => {}))
      assert_equal({ "{{a}}" => nil }, last_json["TemplateModel"])
    end

    def test_other_spellings_are_sent_under_the_documented_name
      deliver(PLAIN.merge("subject" => "Hi", replyTo: "r@example.com", "message_stream" => "2081"))

      assert_equal %w[From MessageStream ReplyTo Subject TextBody To], last_json.keys.sort
      assert_raises(ValidationError) { deliver(PLAIN.merge(subject: "a", "subject" => "b")) }
    end

    def test_recipient_limit_counts_every_spelling
      many = (1..50).map { |i| "u#{i}@example.com" }.join(",")
      error = assert_raises(ValidationError) { deliver(PLAIN.merge("bcc" => many)) }

      assert_match(/51 recipients/, error.message)
    end

    def test_header_items_and_their_keys_are_validated_in_any_spelling
      deliver(PLAIN.merge("headers" => { "X-Order" => "1" }))
      assert_equal [{ "Name" => "X-Order", "Value" => "1" }], last_json["Headers"]

      deliver(PLAIN.merge(headers: [{ "name" => "X-A", "value" => "1" }]))
      assert_equal [{ "Name" => "X-A", "Value" => "1" }], last_json["Headers"]

      [[{ "name" => "X-A\r\nBcc", "value" => "1" }], [{ "Name" => "X-A", "value" => "x\nBcc: a@b.c" }],
       [{ "Name" => "X:Y", "Value" => "1" }], [{ "Name" => "X Y", "Value" => "1" }],
       [{ "Value" => "no name" }], [{ "Name" => "X", "Value" => "1", "value" => "2" }], ["X-A: 1"],
       [%w[X-A 1]]].each do |headers|
        assert_raises(ValidationError, headers.inspect) { deliver(PLAIN.merge(headers: headers)) }
      end
    end

    def test_attachment_fields_become_mime_headers_and_are_checked
      bad = [
        { content_type: "text/plain\r\nBcc: spy@example.net" },
        { content_type: "text/plain x" },
        { content_type: "not a type" },
        { content_id: "cid:a\r\nBcc: spy@example.net" },
        { content_id: " " },
        { name: "report .pdf" },
        { name: "report\u0085.pdf" },
        { content_type: 5 },
        { content_id: ["cid:a"] },
        { content_id: "cid:a\u2028b" },
        { content_id: "cid:a\u0085b" }
      ]
      bad.each do |options|
        assert_raises(ValidationError, options.inspect) do
          Attachment.new(name: "a.txt", content: "x", **options)
        end
      end

      ok = Attachment.new(name: "a.txt", content: "x", content_type: "text/plain; charset=utf-8", content_id: "cid:a")
      assert_equal "text/plain; charset=utf-8", ok.content_type
      tab = Attachment.new(name: "a.txt", content: "x", content_type: "text/plain;\tcharset=utf-8", content_id: 123)
      assert_equal ["text/plain;\tcharset=utf-8", "123"], [tab.content_type, tab.content_id]
    end

    def test_attachment_hashes_are_checked_in_any_spelling
      attachment = { "name" => "a.txt", "content" => "eA==", "contenttype" => "text/plain\r\nX: y" }
      assert_raises(ValidationError) { deliver(PLAIN.merge(attachments: [attachment])) }
      assert_raises(ValidationError) do
        deliver(PLAIN.merge(attachments: [{ "Name" => "a.txt", "Content" => "eA==", "ContentID" => "a\nb" }]))
      end

      deliver(PLAIN.merge(attachments: [{ "name" => "a.txt", "content" => "eA==", "content_type" => "text/plain" }]))
      assert_equal [{ "Name" => "a.txt", "Content" => "eA==", "ContentType" => "text/plain" }],
                   last_json["Attachments"]
    end

    def test_attachment_size_limit_is_inclusive
      exact = "a" * (Attachment::MAX_MESSAGE_SIZE / 4 * 3) # Base64 of exactly 10 MB

      assert_equal Attachment::MAX_MESSAGE_SIZE, Attachment.new(name: "a.dat", content: exact).encoded_size
      error = assert_raises(ValidationError) { Attachment.new(name: "a.dat", content: "#{exact}abc") }
      assert_match(/exceeds 10 MB/, error.message)
    end

    def test_batch_result_must_have_one_result_per_email
      messages = [PLAIN, PLAIN]
      [[Fixtures::BATCH.first], Fixtures::BATCH * 2, []].each do |answer|
        @transport.respond(body: answer)
        error = assert_raises(UnexpectedResponseError) { server_client.emails.deliver_batch(messages) }
        assert_match(/results for 2 emails.*MAY have been accepted/, error.message)
      end

      template = { from: "a@example.com", to: "b@example.com", template_alias: "t" }
      @transport.respond(body: [Fixtures::BATCH.first])
      assert_raises(UnexpectedResponseError) do
        server_client.emails.deliver_batch_with_templates([template, template])
      end
    end

    def test_batch_size_limit_is_inclusive
      payload = { "Messages" => [{ "From" => "a@example.com" }] }
      limit = Util.generate_json(payload).bytesize
      with_constant(Resources::Emails, :MAX_BATCH_BYTES, limit) do
        assert_same payload, server_client.emails.send(:check_batch_size!, payload)
      end
      with_constant(Resources::Emails, :MAX_BATCH_BYTES, limit - 1) do
        assert_raises(ValidationError) { server_client.emails.send(:check_batch_size!, payload) }
      end
    end

    def test_batch_items_need_a_numeric_error_code
      [[{ "Message" => "OK" }, { "ErrorCode" => 0 }], [{ "ErrorCode" => "abc" }, { "ErrorCode" => 0 }],
       [{ "ErrorCode" => nil }, { "ErrorCode" => 0 }]].each do |answer|
        @transport.respond(body: answer)
        error = assert_raises(UnexpectedResponseError, answer.inspect) do
          server_client.emails.deliver_batch([PLAIN, PLAIN])
        end
        assert_match(/without a numeric ErrorCode/, error.message)
      end
    end

    def test_null_error_code_means_no_error_code
      @transport.respond(body: { "ErrorCode" => nil, "Name" => "t" })
      assert_equal "t", server_client.templates.get(1).name

      @transport.respond(body: { "ErrorCode" => nil, "Message" => "OK" })
      assert_raises(UnexpectedResponseError) { deliver(PLAIN) }
    end

    def test_send_result_needs_a_numeric_zero_error_code
      refute_predicate SendResult.new({}), :success?
      refute_predicate SendResult.new("ErrorCode" => "abc"), :success?
      assert_nil SendResult.new("ErrorCode" => true).error_code
      assert_predicate SendResult.new("ErrorCode" => "0"), :success?
      assert_predicate SendResult.new("ErrorCode" => 0.0), :success?
      assert_equal 36, SendResult.new("ErrorCode" => 36.0).error_code
      assert_nil SendResult.new("ErrorCode" => 36.5).error_code
      assert_nil SendResult.new("ErrorCode" => Float::NAN).error_code
    end

    def test_send_response_without_error_code_is_unexpected
      @transport.respond(body: { "MessageID" => "m" })
      error = assert_raises(UnexpectedResponseError) { deliver(PLAIN) }

      assert_match(/without ErrorCode.*MAY have been accepted/, error.message)
    end

    def test_binary_attachment_names_are_relabelled_not_rejected
      attachment = Attachment.new(name: "отчёт.pdf".b, content: "x")

      assert_equal Encoding::UTF_8, attachment.name.encoding
      assert_equal "отчёт.pdf", attachment.name
      assert_raises(ValidationError) { Attachment.new(name: "a\xFF.pdf".b, content: "x") }
    end

    def test_non_numeric_error_code_on_success_is_unexpected
      ["E36", true, { "x" => 1 }].each do |code|
        @transport.respond(body: { "ErrorCode" => code, "Message" => "OK" })
        error = assert_raises(UnexpectedResponseError, code.inspect) { deliver(PLAIN) }
        assert_match(/non-numeric ErrorCode.*check the message log/, error.message)
      end

      @transport.respond(body: { "ErrorCode" => 36.0, "Message" => "later" })
      assert_equal 36, assert_raises(UnprocessableEntityError) { deliver(PLAIN) }.error_code
    end

    private

    def with_constant(owner, name, value)
      original = owner.const_get(name)
      owner.send(:remove_const, name)
      owner.const_set(name, value)
      yield
    ensure
      owner.send(:remove_const, name)
      owner.const_set(name, original)
    end
  end

  class HardeningRetryTest < TestCase
    def test_reads_are_retried_on_every_retryable_status
      [500, 502, 503, 504, 429].each do |status|
        transport = FakeTransport.new.strict!
        transport.respond(status: status, body: "").respond(body: { "TotalCount" => 0, "Messages" => [] })
        ServerClient.new(SERVER_TOKEN, transport: transport, sleeper: ->(_) {}).messages.list

        assert_equal 2, transport.requests.size, "GET after #{status}"
      end
    end

    def test_put_is_idempotent_by_default
      @transport.strict!.respond(status: 502, body: "").respond(body: { "ID" => 1 })
      server_client.webhooks.update(1, url: "https://example.com/hook")
      assert_equal 2, @transport.requests.size

      @transport.fail_with(ConnectionError.new("reset", request_sent: true)).respond(body: { "Name" => "N" })
      server_client.templates.update(1, name: "N", subject: "", html_body: "", text_body: "")
      assert_equal 4, @transport.requests.size
    end

    def test_inbound_bypass_and_retry_are_never_repeated
      %i[bypass retry].each do |action|
        transport = FakeTransport.new.strict!
        transport.respond(status: 500, body: "")
        client = ServerClient.new(SERVER_TOKEN, transport: transport, sleeper: ->(_) {})
        assert_raises(ServerError) { client.inbound_messages.public_send(action, 7) }
        assert_equal 1, transport.requests.size, action

        transport.fail_with(ConnectionError.new("reset", request_sent: true))
        assert_raises(ConnectionError) { client.inbound_messages.public_send(action, 7) }
        assert_equal 2, transport.requests.size, action
      end
    end

    def test_temporary_sending_error_is_retried_only_with_status_unprocessable
      @transport.strict!.respond(status: 400, body: { "ErrorCode" => 36, "Message" => "later" })
      assert_raises(ApiError) do
        server_client.emails.deliver(from: "a@example.com", to: "b@example.com", text_body: "x")
      end
      assert_equal 1, @transport.requests.size
    end

    def test_backoff_formula_and_jitter
      low = Struct.new(:value) { def rand = value }.new(0.0)
      high = Struct.new(:value) { def rand = value }.new(0.999)
      policy = ->(random) { HTTP::RetryPolicy.new(max_retries: 10, random: random) }

      assert_in_delta 0.25, policy.call(low).delay(1)
      assert_in_delta 0.4995, policy.call(high).delay(1)
      assert_in_delta 0.5, policy.call(low).delay(2)
      assert_in_delta 4.0, policy.call(low).delay(5)
      assert_in_delta 4.0, policy.call(low).delay(10), 1e-9, "capped at MAX_DELAY"
      assert_in_delta 7.996, policy.call(high).delay(10)
      refute_in_delta policy.call(low).delay(3), policy.call(high).delay(3), 0.5
    end

    def test_authorization_and_token_headers_are_redacted
      headers = { "Authorization" => "Basic SECRET1", "X-Haskimail-Server-Token" => "SECRET2",
                  "x-haskimail-account-token" => "SECRET3", "Accept" => "application/json" }
      text = HTTP::Request.new(method: :get, url: "https://example.net/", headers: headers, body: nil).inspect

      refute_match(/SECRET/, text)
      assert_includes text, "application/json"
    end

    def test_success_needs_a_numeric_zero_error_code
      ok = HTTP::Response.new(status: 200, headers: {}, body: "")

      assert HTTP::ResponseParser.success?(ok, { "ErrorCode" => 0 })
      assert HTTP::ResponseParser.success?(ok, { "Message" => "no code" })
      refute HTTP::ResponseParser.success?(ok, { "ErrorCode" => "x" })
      assert HTTP::ResponseParser.malformed_error_code?({ "ErrorCode" => "x" })
      refute HTTP::ResponseParser.malformed_error_code?({ "ErrorCode" => nil })
    end

    def test_empty_query_adds_no_question_mark
      server_client.request(:get, "/x", query: {})

      refute_includes last_request.url, "?"
    end
  end

  class HardeningPaginationTest < TestCase
    def page(items, total = nil)
      body = { "Templates" => items }
      body["TotalCount"] = total if total
      @transport.respond(body: body)
    end

    def test_stops_when_total_count_is_reached_exactly
      @transport.strict!
      page([{ "Name" => "a" }, { "Name" => "b" }], 4)
      page([{ "Name" => "c" }, { "Name" => "d" }], 4)

      assert_equal 4, server_client.templates.each(page_size: 2).count
      assert_equal 2, @transport.requests.size
    end

    def test_stops_after_a_short_page_without_total_count
      @transport.strict!
      page([{ "Name" => "a" }])

      assert_equal 1, server_client.templates.each(page_size: 2).count
      assert_equal 1, @transport.requests.size
    end

    def test_stops_on_an_empty_page
      @transport.strict!
      page([{ "Name" => "a" }, { "Name" => "b" }], 10)
      page([], 10)

      assert_equal 2, server_client.templates.each(page_size: 2).count
    end

    def test_window_exhaustion_terminates
      @transport.strict!
      20.times { @transport.respond(body: { "TotalCount" => 50_000, "Messages" => Array.new(500) { {} } }) }

      assert_equal 10_000, server_client.messages.each.count
      assert_equal 20, @transport.requests.size
    end

    def test_paginator_page_size_must_be_positive
      assert_raises(ValidationError) { Paginator.new(items_key: "X", page_size: 0) { {} } }
    end

    def test_count_and_page_size_are_checked_everywhere
      client = account_client
      [-> { client.templates.list(count: 0) }, -> { client.servers.list(count: "5") },
       -> { client.domains.list(offset: -1) }, -> { client.bounces.list(count: 0) },
       -> { client.templates.each(page_size: 0).first }, -> { client.servers.each(page_size: 1.5).first },
       -> { client.messages.each(page_size: 501).first }, -> { server_client.inbound_rules.each(page_size: 501).first },
       -> { client.domains.each(page_size: nil).first }, -> { client.bounces.each(page_size: -1).first }].each do |call|
        assert_raises(ValidationError) { call.call }
      end
      assert_empty @transport.requests

      client.templates.list(count: 100_000, offset: 3)
      assert_equal({ "count" => "100000", "offset" => "3" }, last_query)
    end
  end

  class HardeningWebhookTest < TestCase
    KEY = "webhook-signing-key"

    def signed(fields)
      fields.merge("secret" => Digest::MD5.hexdigest("#{fields['recipient']}#{fields['message_id']}#{KEY}"))
    end

    def test_each_signed_field_rule_on_its_own
      ["a.b", "a b", "a/b", "a+b"].each do |message_id|
        payload = signed("recipient" => "a@b.example", "message_id" => message_id)
        refute Webhook.valid_signature?(payload, signing_key: KEY),
               message_id
      end
      ["a@b@c.example", "a @b.example", "a@b .example", "@b.example", "a@"].each do |recipient|
        refute Webhook.valid_signature?(signed("recipient" => recipient, "message_id" => "m"), signing_key: KEY),
               recipient
      end
      assert Webhook.valid_signature?(signed("recipient" => "a.b+c@b.example", "message_id" => "A-b_1"),
                                      signing_key: KEY)
    end

    def test_blank_signing_key_is_a_configuration_error
      ["", "  ", nil].each do |key|
        assert_raises(ConfigurationError) { Webhook.valid_signature?({}, signing_key: key) }
      end
    end

    def test_size_limit_is_inclusive
      body = JSON.generate(signed(Fixtures::BOUNCE_EVENT))

      assert_predicate Webhook.construct_event(body, signing_key: KEY, max_size: body.bytesize), :bounced?
      assert_raises(WebhookPayloadTooLargeError) do
        Webhook.construct_event(body, signing_key: KEY, max_size: body.bytesize - 1)
      end
    end

    def test_number_length_guard_starts_at_ten_thousand_digits
      assert_raises(ValidationError) { Webhook.parse_event(%({"n": #{'9' * 10_000}})) }
      assert_equal 9999, Webhook.parse_event(%({"n": #{'9' * 9_999}}))["n"].to_s.size
    end

    def test_mime_style_base64_in_inbound_attachments
      content = "%PDF-1.4 #{'x' * 100}"
      payload = Fixtures::INBOUND.merge("Attachments" => [{ "Name" => "a.pdf", "Content" => [content].pack("m") }])

      assert_includes [content].pack("m"), "\n"
      assert_equal content, Webhook.parse_inbound(JSON.generate(payload)).attachments.first.content
    end

    def test_click_idempotency_keys_include_the_link
      click = Fixtures::BOUNCE_EVENT.merge("event" => "clicked")
      first = Webhook.parse_event(JSON.generate(click.merge("url_original" => "https://a.example/1")))
      second = Webhook.parse_event(JSON.generate(click.merge("url_original" => "https://a.example/2")))

      refute_equal first.idempotency_key, second.idempotency_key
    end

    def test_inbound_message_inspect_is_short
      big = Fixtures::INBOUND.merge("Attachments" => [{ "Name" => "a.bin", "Content" => ["x" * 100_000].pack("m0") }])
      message = Webhook.parse_inbound(JSON.generate(big))
      text = message.inspect

      assert_operator text.size, :<, 300
      assert_includes text, "attachments=1"
      assert_includes text, "Subject="
      refute_includes text, "TextBody"
      assert_equal text, message.to_s
      assert_equal "#{text}\n", PP.pp(message, +"")
      assert_equal "#<Haskimail::Webhook::InboundMessage >", Webhook::InboundMessage.new({}).inspect
    end
  end

  class HardeningObjectTest < TestCase
    def test_equality_hash_and_eql_are_consistent
      int = ApiObject.new("A" => 1)
      float = ApiObject.new("A" => 1.0)

      assert_equal int, float
      refute int.eql?(float)
      assert int.eql?(ApiObject.new("A" => 1))
      assert_equal int.hash, ApiObject.new("A" => 1).hash
      assert_equal 2, [int, float].uniq.size
      assert_equal :x, { int => :x }[ApiObject.new("A" => 1)]
      refute_equal SendResult.new("A" => 1), int
      refute_equal SendResult.new("A" => 1).hash, int.hash, "the class is part of the hash"
    end

    def test_read_only_names_only
      object = ApiObject.new("MessageID" => "x")

      refute_respond_to object, :message_id=
      refute_respond_to object, :message_id!
      refute_respond_to object, :message_id?
      assert_respond_to object, :message_id
      assert_raises(NoMethodError) { object.message_id = "y" }
      assert_raises(NoMethodError) { object.message_id? }
    end

    def test_marshal_round_trip_stays_frozen
      object = SendResult.new("ErrorCode" => 0, "Nested" => { "A" => [1] })
      copy = Marshal.load(Marshal.dump(object))

      assert_equal object, copy
      assert_instance_of SendResult, copy
      assert_predicate copy, :frozen?
      refute_predicate copy.to_h, :frozen?, "to_h stays a mutable copy"
      assert_raises(FrozenError) { copy.nested.instance_variable_get(:@data)["A"] << 2 }
    end

    def test_batch_result_value_semantics_and_json
      results = Fixtures::BATCH.map { |item| SendResult.new(item) }
      batch = BatchResult.new(results)

      assert_equal Fixtures::BATCH, JSON.parse(batch.to_json)
      assert_equal batch.as_json, JSON.parse(JSON.generate(batch.as_json))
      assert_equal batch, BatchResult.new(Fixtures::BATCH.map { |item| SendResult.new(item) })
      assert batch.eql?(BatchResult.new(results))
      assert_equal batch.hash, BatchResult.new(results).hash
      refute_equal batch, results
      refute_equal batch, BatchResult.new([])
      refute_equal batch, BatchResult.new(results.reverse)
      refute_predicate batch, :empty?
      assert_predicate BatchResult.new([]), :empty?
      assert_equal batch.inspect, batch.to_s
      refute_same results, batch.results
    end

    def test_response_is_an_immutable_value
      response = HTTP::Response.new(status: 200, headers: {}, body: "")

      assert_predicate response, :frozen?
      refute_respond_to response, :status=
      assert_equal response, HTTP::Response.new(status: 200, headers: {}, body: "")
      refute_equal response, HTTP::Response.new(status: 201, headers: {}, body: "")
      refute_equal response, Object.new
    end

    def test_inbound_attachment_is_a_value
      attachment = Webhook::InboundAttachment.new(name: "a", content_type: "t", content_id: "", content: "x")
      same = Webhook::InboundAttachment.new(**attachment.to_h)

      assert_predicate attachment, :frozen?
      assert_equal attachment, same
      assert attachment.eql?(same)
      assert_equal attachment.hash, same.hash
      refute_equal attachment, attachment.to_h
    end
  end

  class HardeningConfigurationTest < TestCase
    def test_every_attribute_has_a_reader_and_a_writer
      Configuration::ATTRIBUTES.each do |name|
        assert_includes Configuration.public_instance_methods, name
        assert_includes Configuration.public_instance_methods, :"#{name}="
      end
    end

    def test_configure_needs_a_block
      assert_raises(ConfigurationError) { Haskimail.configure }
    end

    def test_user_agent_is_printable_ascii
      ["a\u0000b", "a b", "Магазин", "a\tb", "a\nb", "\xFF".b].each do |value|
        assert_raises(ConfigurationError, value.inspect) { Configuration.new(user_agent: value) }
      end
      assert_equal "my-shop/2.1 (+https://example.com)",
                   Configuration.new(user_agent: "my-shop/2.1 (+https://example.com)").user_agent
    end

    def test_credentials_never_serialized
      config = Configuration.new(proxy: "http://user:secret@proxy.local:3128")

      assert_raises(TypeError) { Marshal.dump(config) }
      yaml = YAML.dump(config)
      refute_includes yaml, "secret"
      assert_includes yaml, "[FILTERED]"
    end

    def test_proxy_comes_from_the_environment_and_is_validated
      env_proxy = ->(env) { HTTP::NetHttpTransport.env_proxy(env)&.to_s }

      assert_equal "http://p1:1", env_proxy.call("https_proxy" => "http://p1:1", "http_proxy" => "http://p3:3")
      assert_equal "http://p2:2", env_proxy.call("HTTPS_PROXY" => "http://p2:2", "http_proxy" => "http://p3:3")
      assert_equal "http://p3:3", env_proxy.call("http_proxy" => "http://p3:3")
      assert_nil env_proxy.call("HTTP_PROXY" => "http://httpoxy:1"), "HTTP_PROXY is ignored (httpoxy)"
      assert_nil env_proxy.call("https_proxy" => " ")
      ["https://user:pw@p:1", "socks5://p:1", "http://", "http://bad host:1"].each do |value|
        assert_raises(ConfigurationError, value) { env_proxy.call("https_proxy" => value) }
      end
    end

    def test_clients_fail_fast_on_a_bad_environment_proxy
      ENV["https_proxy"] = "https://user:pw@proxy.local:3128"
      error = assert_raises(ConfigurationError) { ServerClient.new(SERVER_TOKEN) }
      assert_match(/https_proxy must be an http:/, error.message)
      assert ServerClient.new(SERVER_TOKEN, proxy: "http://explicit:1"), "an explicit proxy wins"
    ensure
      ENV.delete("https_proxy")
    end

    def test_proxy_false_connects_directly_and_ignores_the_environment
      ENV["https_proxy"] = "socks5://ignored:1"
      client = ServerClient.new(SERVER_TOKEN, proxy: false)
      transport = client.instance_variable_get(:@transport)

      refute_predicate transport.send(:build_http, URI.parse("https://api.haskimail.ru"), 1, 1, 1), :proxy?
      assert_same false, Configuration.new(proxy: false).proxy
      assert_same false, Configuration.new(proxy: false).to_h[:proxy]
    ensure
      ENV.delete("https_proxy")
    end

    def test_environment_proxy_without_a_scheme
      assert_equal "http://proxy.local:3128",
                   HTTP::NetHttpTransport.env_proxy({ "http_proxy" => "proxy.local:3128" }).to_s
    end

    def test_environment_proxy_skips_loopback_and_cidr_matches
      transport = HTTP::NetHttpTransport.new(env: { "https_proxy" => "http://proxy.local:3128",
                                                    "no_proxy" => "10.0.0.0/8" })
      proxied = ->(url) { transport.send(:build_http, URI.parse(url), 1, 1, 1).proxy? }

      refute proxied.call("https://127.0.0.1:8443"), "loopback is never proxied"
      refute proxied.call("https://localhost:8443")
      refute proxied.call("https://10.1.2.3"), "no_proxy CIDR matches the address"
      assert proxied.call("https://192.0.2.10")
      assert proxied.call("https://unresolvable.invalid"), "unknown names still go through the proxy"
      explicit = HTTP::NetHttpTransport.new(proxy: URI.parse("http://proxy.local:3128"), env: { "no_proxy" => "*" })
      assert_predicate explicit.send(:build_http, URI.parse("https://127.0.0.1"), 1, 1, 1), :proxy?,
                       "explicit proxy wins"
    end

    def test_no_proxy_and_proxy_choice
      uri = URI.parse("https://api.haskimail.ru")
      via_env = HTTP::NetHttpTransport.new(env: { "https_proxy" => "http://u:p%2Bq@proxy.local:3128" })
      http = via_env.send(:build_http, uri, 1, 1, 1)

      assert_equal ["proxy.local", 3128, "u", "p+q"],
                   [http.proxy_address, http.proxy_port, http.proxy_user, http.proxy_pass]
      excluded = HTTP::NetHttpTransport.new(env: { "https_proxy" => "http://proxy.local:3128",
                                                   "no_proxy" => "localhost,.haskimail.ru" })
      refute_predicate excluded.send(:build_http, uri, 1, 1, 1), :proxy?
      anonymous = HTTP::NetHttpTransport.new(env: { "http_proxy" => "http://proxy.local:8080" })
      assert_equal(["proxy.local", nil, nil], anonymous.send(:build_http, uri, 1, 1, 1).then do |h|
        [h.proxy_address, h.proxy_user, h.proxy_pass]
      end)
      direct = HTTP::NetHttpTransport.new(env: { "http_proxy" => "" }).send(:build_http, uri, 1, 1, 1)
      refute_predicate direct, :proxy?
      refute_predicate direct, :proxy_from_env?, "Net::HTTP never reads the environment itself"
    end
  end

  class HardeningPackagingTest < Minitest::Test
    LIB = File.expand_path("../../lib", __dir__)

    def test_every_file_can_be_required_on_its_own_without_warnings
      files = Dir[File.join(LIB, "haskimail", "**", "*.rb")].map do |file|
        file.delete_prefix("#{LIB}/").delete_suffix(".rb")
      end
      script = files.map do |file|
        "fork { require #{file.inspect}; exit!(0) }; Process.wait; exit!(1) unless $?.success?"
      end
      output = IO.popen([RbConfig.ruby, "-w", "-I", LIB, "-e", script.join("\n")], err: %i[child out], &:read)

      assert_predicate $CHILD_STATUS, :success?, output
      assert_empty output
    end

    def test_examples_are_valid_ruby
      Dir[File.expand_path("../../examples/*.rb", __dir__)].each do |file|
        assert_kind_of RubyVM::InstructionSequence, RubyVM::InstructionSequence.compile_file(file), file
      end
    end
  end

  # Findings of the independent pre-release review.
  class IndependentReviewTest < TestCase
    PLAIN = { from: "shop@example.com", to: "ivan@example.com", text_body: "x" }.freeze

    def test_ca_file_adds_to_the_system_store
      Tempfile.create(["ca", ".pem"]) do |file|
        file.write(OpenSSL::X509::Certificate.new.tap { |cert| self.class.self_signed(cert) }.to_pem)
        file.flush
        http = HTTP::NetHttpTransport.new(ca_file: file.path, env: {})
                                     .send(:build_http, URI.parse("https://api.haskimail.ru"), 1, 1, 1)

        assert_nil http.ca_file, "ca_file would replace the system CAs"
        assert_kind_of OpenSSL::X509::Store, http.cert_store
        system_root = self.class.system_root
        assert http.cert_store.verify(system_root), "system CAs stay trusted" if system_root
      end
      Tempfile.create(["broken", ".pem"]) do |file|
        file.write("not a certificate")
        file.flush
        assert_raises(ConfigurationError) { ServerClient.new(SERVER_TOKEN, ca_file: file.path) }
      end
    end

    # Any root certificate of the system store, if the platform has a bundle file.
    def self.system_root
      file = OpenSSL::X509::DEFAULT_CERT_FILE
      return nil unless File.file?(file)

      pem = File.read(file)[/-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m]
      pem && OpenSSL::X509::Certificate.new(pem)
    end

    def self.self_signed(cert)
      key = OpenSSL::PKey::EC.generate("prime256v1")
      cert.version = 2
      cert.serial = 1
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=corp-proxy")
      cert.public_key = key
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + 3600
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
    end

    def test_credentials_never_leave_through_serializers
      client = ServerClient.new("SECRET-TOKEN", proxy: "http://user:pw-secret@proxy.local:3128", transport: nil)
      request = HTTP::Request.new(method: :get, url: "https://api.haskimail.ru/x",
                                  headers: { "X-Haskimail-Server-Token" => "SECRET-TOKEN" }, body: nil)
      transport = client.instance_variable_get(:@transport)

      [client, client.emails, request, transport].each do |object|
        [YAML.dump(object), object.to_json, JSON.generate([object]), object.as_json.to_s].each do |text|
          refute_match(/SECRET|pw-secret/, text, object.class.name)
        end
        assert_equal object.inspect, object.as_json
        assert_raises(TypeError) { Marshal.dump(object) }
      end
    end

    def test_paging_trusts_total_count_over_a_short_page
      @transport.strict!
      @transport.respond(body: { "TotalCount" => 5, "Servers" => Array.new(3) { { "ID" => 1 } } })
      @transport.respond(body: { "TotalCount" => 5, "Servers" => [{ "ID" => 2 }] })
      @transport.respond(body: { "TotalCount" => 5, "Servers" => [{ "ID" => 3 }] })

      assert_equal 5, account_client.servers.each(page_size: 100).count
      offsets = @transport.requests.map { |r| URI.decode_www_form(URI.parse(r.url).query).to_h["offset"].to_i }
      assert_equal [0, 3, 4], offsets
    end

    def test_total_count_must_be_a_number
      [{ "a" => 1 }, [1], true, "many"].each do |total|
        @transport.respond(body: { "TotalCount" => total, "Templates" => [{ "Name" => "a" }] })
        assert_raises(UnexpectedResponseError, total.inspect) { server_client.templates.each.to_a }
      end
      @transport.respond(body: { "TotalCount" => "1", "Templates" => [{ "Name" => "a" }] })
      assert_equal 1, server_client.templates.each.count, "a numeric string is accepted"
    end

    def test_deep_or_cyclic_bodies_are_validation_errors
      deep = 120.times.reduce({}) { |inner, _| { "a" => inner } }
      cyclic = {}
      cyclic["self"] = cyclic

      [deep, cyclic].each do |metadata|
        assert_raises(ValidationError) { server_client.emails.deliver(**PLAIN, metadata: metadata) }
        assert_raises(ValidationError) do
          server_client.emails.deliver(**PLAIN, headers: [{ "Name" => "X", "Value" => "1", "Extra" => metadata }])
        end
      end
      assert_raises(ValidationError) { Util.generate_json(deep) }
    end

    def test_spam_score_of_any_shape
      [%w[1 2], { "a" => 1 }, true].each do |value|
        message = Webhook.parse_inbound(JSON.generate("Headers" => [{ "Name" => "X-Spam-Score", "Value" => value }]))
        assert_nil message.spam_score, value.inspect
      end
    end

    def test_unreadable_attachment_files
      assert_raises(ValidationError) { Attachment.from_file("/definitely/missing.pdf") }
      assert_raises(ValidationError) { Attachment.from_file(Dir.tmpdir) }
    end

    def test_long_digit_runs_inside_strings_are_fine
      body = JSON.generate(Fixtures::INBOUND.merge("TextBody" => "Номер: #{'7' * 20_000}"))

      assert_equal "Номер: #{'7' * 20_000}", Webhook.parse_inbound(body).text_body
      assert_raises(ValidationError) { Webhook.parse_inbound(%({"a": "#{'1' * 10_000}", "b": #{'2' * 10_000}})) }
      refute Webhook.send(:huge_number?, %({"a": "\\", "b": "x"#{'3' * 10_000}"}))
      refute Webhook.send(:huge_number?, %({"a": "#{'4' * 10_000}))
      assert Webhook.send(:huge_number?, %({"a": [#{'5' * 9_999}, #{'6' * 10_000}]}))
    end

    def test_integer_message_stream_is_sent_as_a_string
      server_client.emails.deliver(**PLAIN, message_stream: 2081)

      assert_equal "2081", last_json["MessageStream"]
    end

    def test_no_proxy_wildcards
      uri = URI.parse("https://api.haskimail.ru")
      proxied = lambda do |no_proxy|
        HTTP::NetHttpTransport.new(env: { "https_proxy" => "http://proxy.local:3128", "no_proxy" => no_proxy })
                              .send(:build_http, uri, 1, 1, 1).proxy?
      end

      refute proxied.call("*")
      refute proxied.call("localhost, *")
      refute proxied.call("*.haskimail.ru")
      refute proxied.call(".haskimail.ru")
      assert proxied.call("*.example.com")
      assert proxied.call("")
    end

    def test_parse_time_live_formats
      # Inbound details: Date is RFC 2822, ReceivedAt is ISO 8601.
      expected = Time.utc(2026, 10, 31, 18, 15, 56)
      assert_equal expected, Haskimail.parse_time("Sat, 31 Oct 2026 21:15:56 +0300")
      assert_equal expected, Haskimail.parse_time("31 Oct 2026 21:15:56 +0300")
      assert_equal expected, Haskimail.parse_time("2026-10-31T21:15:56+03:00")
      # Unarchived streams keep ArchivedAt "0000-00-00 00:00:00".
      assert_nil Haskimail.parse_time("0000-00-00 00:00:00")
      assert_nil Haskimail.parse_time("Sat, 99 Foo 2026 21:15:56 +0300")
      assert_nil Haskimail.parse_time("  ")
    end
  end
end
