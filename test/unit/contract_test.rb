# frozen_string_literal: true

require_relative "../test_helper"

module Haskimail
  # Every operation of the API reference (https://haskimail.ru/developer/api/*)
  # mapped to the SDK call that performs it. Fails if an operation is missing,
  # hits a different method/path, or uses the wrong token header.
  class ContractTest < TestCase
    SERVER = ServerClient::TOKEN_HEADER
    ACCOUNT = AccountClient::TOKEN_HEADER
    MAIL = { from: "a@example.com", to: "b@example.com", text_body: "x" }.freeze
    TEMPLATE_MAIL = { template_id: 1, from: "a@example.com", to: "b@example.com" }.freeze
    TEMPLATE_FIELDS = { name: "N", subject: "S", html_body: "H", text_body: "T" }.freeze

    # [method, path, token header, call]
    OPERATIONS = [
      # Отправка писем
      [:post, "/email", SERVER, ->(s, _a) { s.emails.deliver(**MAIL) }],
      [:post, "/email/batch", SERVER, ->(s, _a) { s.emails.deliver_batch([MAIL]) }],
      # Шаблоны
      [:post, "/email/withTemplate", SERVER, ->(s, _a) { s.emails.deliver_with_template(**TEMPLATE_MAIL) }],
      [:post, "/email/batchWithTemplates", SERVER,
       ->(s, _a) { s.emails.deliver_batch_with_templates([TEMPLATE_MAIL]) }],
      [:put, "/templates/push", ACCOUNT,
       ->(_s, a) { a.templates.push(source_server_id: 1, destination_server_id: 2, perform_changes: false) }],
      [:get, "/templates/7", SERVER, ->(s, _a) { s.templates.get(7) }],
      [:post, "/templates", SERVER, ->(s, _a) { s.templates.create(**TEMPLATE_FIELDS) }],
      [:put, "/templates/7", SERVER, ->(s, _a) { s.templates.update(7, **TEMPLATE_FIELDS) }],
      [:get, "/templates", SERVER, ->(s, _a) { s.templates.list }],
      [:delete, "/templates/7", SERVER, ->(s, _a) { s.templates.delete(7) }],
      [:post, "/templates/validate", SERVER, ->(s, _a) { s.templates.validate(subject: "S") }],
      # Сообщения
      [:get, "/messages", SERVER, ->(s, _a) { s.messages.list }],
      [:get, "/messages/m1/details", SERVER, ->(s, _a) { s.messages.details("m1") }],
      [:get, "/messages/opens", SERVER, ->(s, _a) { s.opens.list }],
      [:get, "/messages/opens/m1", SERVER, ->(s, _a) { s.opens.for_message("m1") }],
      [:get, "/messages/clicks", SERVER, ->(s, _a) { s.clicks.list }],
      [:get, "/messages/clicks/m1", SERVER, ->(s, _a) { s.clicks.for_message("m1") }],
      [:get, "/messages/inbound", SERVER, ->(s, _a) { s.inbound_messages.list }],
      [:get, "/messages/inbound/m1/details", SERVER, ->(s, _a) { s.inbound_messages.details("m1") }],
      [:put, "/messages/inbound/m1/bypass", SERVER, ->(s, _a) { s.inbound_messages.bypass("m1") }],
      [:put, "/messages/inbound/m1/retry", SERVER, ->(s, _a) { s.inbound_messages.retry("m1") }],
      # Возвраты
      [:get, "/deliverystats", SERVER, ->(s, _a) { s.bounces.delivery_stats }],
      [:get, "/bounces", SERVER, ->(s, _a) { s.bounces.list }],
      # Серверы
      [:get, "/servers/3", ACCOUNT, ->(_s, a) { a.servers.get(3) }],
      [:post, "/servers", ACCOUNT, ->(_s, a) { a.servers.create(name: "N", color: "red") }],
      [:put, "/servers/3", ACCOUNT, ->(_s, a) { a.servers.update(3, name: "N") }],
      [:get, "/servers", ACCOUNT, ->(_s, a) { a.servers.list }],
      [:delete, "/servers/3", ACCOUNT, ->(_s, a) { a.servers.delete(3) }],
      [:post, "/servers/3/tokens/new", ACCOUNT, ->(_s, a) { a.servers.issue_token(3) }],
      # Каналы
      [:get, "/message-streams", SERVER, ->(s, _a) { s.message_streams.list }],
      [:get, "/message-streams/s1", SERVER, ->(s, _a) { s.message_streams.get("s1") }],
      [:patch, "/message-streams/s1", SERVER, ->(s, _a) { s.message_streams.update("s1", name: "N") }],
      [:post, "/message-streams", SERVER,
       ->(s, _a) { s.message_streams.create(name: "N", message_stream_type: "Transactional") }],
      [:post, "/message-streams/s1/archive", SERVER, ->(s, _a) { s.message_streams.archive("s1") }],
      [:post, "/message-streams/s1/unarchive", SERVER, ->(s, _a) { s.message_streams.unarchive("s1") }],
      # Домены
      [:get, "/domains", ACCOUNT, ->(_s, a) { a.domains.list }],
      [:get, "/domains/5", ACCOUNT, ->(_s, a) { a.domains.get(5) }],
      [:post, "/domains", ACCOUNT, ->(_s, a) { a.domains.create("example.com") }],
      [:delete, "/domains/5", ACCOUNT, ->(_s, a) { a.domains.delete(5) }],
      [:put, "/domains/5/verifyDkim", ACCOUNT, ->(_s, a) { a.domains.verify_dkim(5) }],
      [:put, "/domains/5/verifyspf", ACCOUNT, ->(_s, a) { a.domains.verify_spf(5) }],
      # Статистика
      [:get, "/stats", SERVER, ->(s, _a) { s.stats.summary }],
      [:get, "/stats/sends", SERVER, ->(s, _a) { s.stats.sends }],
      [:get, "/stats/bounces", SERVER, ->(s, _a) { s.stats.bounces }],
      [:get, "/stats/spam", SERVER, ->(s, _a) { s.stats.spam_complaints }],
      [:get, "/stats/opens", SERVER, ->(s, _a) { s.stats.opens }],
      [:get, "/stats/clicks", SERVER, ->(s, _a) { s.stats.clicks }],
      [:get, "/stats/opens/platforms", SERVER, ->(s, _a) { s.stats.opens_by_platform }],
      [:get, "/stats/opens/emailclients", SERVER, ->(s, _a) { s.stats.opens_by_email_client }],
      [:get, "/stats/clicks/browserfamilies", SERVER, ->(s, _a) { s.stats.clicks_by_browser_family }],
      [:get, "/stats/clicks/platforms", SERVER, ->(s, _a) { s.stats.clicks_by_platform }],
      # Вебхуки
      [:get, "/webhooks", SERVER, ->(s, _a) { s.webhooks.list }],
      [:get, "/webhooks/9", SERVER, ->(s, _a) { s.webhooks.get(9) }],
      [:post, "/webhooks", SERVER, ->(s, _a) { s.webhooks.create(url: "https://example.com/h") }],
      [:put, "/webhooks/9", SERVER, ->(s, _a) { s.webhooks.update(9, url: "https://example.com/h") }],
      [:delete, "/webhooks/9", SERVER, ->(s, _a) { s.webhooks.delete(9) }],
      # Правила для входящих
      [:get, "/triggers/inboundrules", SERVER, ->(s, _a) { s.inbound_rules.list }],
      [:post, "/triggers/inboundrules", SERVER, ->(s, _a) { s.inbound_rules.create("example.org") }],
      [:delete, "/triggers/inboundrules/4", SERVER, ->(s, _a) { s.inbound_rules.delete(4) }],
      # Стоп-листы
      [:get, "/message-streams/s1/suppressions/dump", SERVER, ->(s, _a) { s.suppressions.list("s1") }],
      [:post, "/message-streams/s1/suppressions", SERVER, ->(s, _a) { s.suppressions.create("s1", "a@b.example") }],
      [:post, "/message-streams/s1/suppressions/delete", SERVER, lambda { |s, _a|
        s.suppressions.delete("s1", "a@b.example")
      }]
    ].freeze

    # Account-token variants the documentation explicitly allows.
    ACCOUNT_OPERATIONS = [
      [:get, "/templates", ->(a) { a.templates.list }],
      [:post, "/templates", ->(a) { a.templates.create(**TEMPLATE_FIELDS, associated_server_id: 1) }],
      [:post, "/templates/validate", ->(a) { a.templates.validate(subject: "S") }],
      [:get, "/messages", ->(a) { a.messages.list }],
      [:get, "/messages/opens", ->(a) { a.opens.list }],
      [:get, "/messages/clicks", ->(a) { a.clicks.list }],
      [:get, "/bounces", ->(a) { a.bounces.list }],
      [:get, "/message-streams", ->(a) { a.message_streams.list }],
      [:post, "/message-streams",
       ->(a) { a.message_streams.create(name: "N", message_stream_type: :broadcasts, server_id: 1) }],
      [:get, "/webhooks", ->(a) { a.webhooks.list }],
      [:post, "/webhooks", ->(a) { a.webhooks.create(url: "https://example.com/h", message_stream: "s1") }],
      [:get, "/stats", ->(a) { a.stats.summary }]
    ].freeze

    def batch_body
      [{ "To" => "b@example.com", "ErrorCode" => 0, "MessageID" => "m" }]
    end

    def test_every_documented_operation_is_implemented
      assert_equal 62, OPERATIONS.size, "the API reference documents 62 operations"
      assert_equal OPERATIONS.size, OPERATIONS.map { |op| op[0..1] }.uniq.size

      OPERATIONS.each do |method, path, header, call|
        @transport.respond(body: path.include?("batch") ? batch_body : { "ErrorCode" => 0 })
        call.call(server_client, account_client)

        assert_equal method, last_request.method, path
        assert_equal path, last_path
        assert last_request.headers.key?(header), "#{method.upcase} #{path} must use #{header}"
        other = header == SERVER ? ACCOUNT : SERVER
        refute last_request.headers.key?(other), "#{method.upcase} #{path} must not send #{other}"
      end
      assert_equal OPERATIONS.size, @transport.requests.size
    end

    def test_account_token_operations
      ACCOUNT_OPERATIONS.each do |method, path, call|
        call.call(account_client)

        assert_equal [method, path], [last_request.method, last_path]
        assert_equal ACCOUNT_TOKEN, last_request.headers[ACCOUNT]
      end
    end

    def test_server_only_resources_are_not_on_the_account_client
      %i[emails inbound_messages inbound_rules suppressions].each do |name|
        refute_respond_to account_client, name
        assert_respond_to server_client, name
      end
      %i[servers domains].each { |name| refute_respond_to server_client, name }
    end

    def test_request_bodies_use_documented_field_names
      server_client.emails.deliver(from: "a@example.com", to: "b@example.com", cc: "c@example.com",
                                   bcc: "d@example.com", subject: "S", html_body: "H", text_body: "T",
                                   tag: "t", reply_to: "r@example.com", headers: { "X-A" => "1" },
                                   track_opens: true, track_links: false, metadata: { "k" => "v" },
                                   attachments: [{ name: "a.txt", content: "eA==", content_type: "text/plain",
                                                   content_id: "cid:a" }],
                                   message_stream: "s1")
      assert_equal %w[From To Cc Bcc Subject HtmlBody TextBody Tag ReplyTo Headers TrackOpens TrackLinks Metadata
                      Attachments MessageStream].sort, last_json.keys.sort
      assert_equal %w[Name Content ContentType ContentID].sort, last_json["Attachments"].first.keys.sort

      server_client.emails.deliver_with_template(template_alias: "a", template_model: { "{{x}}" => "1" },
                                                 from: "a@example.com", to: "b@example.com")
      assert_equal %w[TemplateAlias TemplateModel From To].sort, last_json.keys.sort

      account_client.servers.create(name: "N", color: "red", smtp_api_activated: true, track_opens: true,
                                    track_links: "None", delivery_type: "Live", inbound_hook_url: "https://example.net",
                                    inbound_domain: "in.example.com", inbound_spam_threshold: 5,
                                    raw_email_enabled: false)
      assert_equal %w[Name Color SmtpApiActivated TrackOpens TrackLinks DeliveryType InboundHookUrl InboundDomain
                      InboundSpamThreshold RawEmailEnabled].sort, last_json.keys.sort
    end
  end

  # Parses anonymized real responses of the live API and checks the quirks
  # the SDK has to cope with.
  class LiveResponsesTest < TestCase
    DIR = File.expand_path("../fixtures/live", __dir__)

    def fixture(name)
      File.read(File.join(DIR, "#{name}.json"), encoding: "UTF-8")
    end

    def test_every_live_fixture_parses_through_the_client
      Dir[File.join(DIR, "*.json")].reject { |file| File.basename(file).start_with?("error-") }.each do |file|
        transport = FakeTransport.new.respond(body: File.read(file, encoding: "UTF-8"))
        result = ServerClient.new("t", transport: transport).request(:get, "/x")

        assert_kind_of ApiObject, result, file
        assert_equal JSON.parse(File.read(file, encoding: "UTF-8")), result.to_h
      end
    end

    def test_quirks_of_real_responses
      @transport.respond(body: fixture("messages")).respond(body: fixture("opens"))
                .respond(body: fixture("stats-overview")).respond(body: fixture("stats-emailclients"))
                .respond(body: fixture("bounces"))
      messages = server_client.messages.list
      assert_operator messages.total_count, :>, messages.messages.size
      assert_match(/🛸/, messages.messages.first.subject)
      assert_equal Time.utc(2026, 10, 28, 8, 58, 50), Haskimail.parse_time(messages.messages.first.received_at)

      open = server_client.opens.list.opens.first
      assert_equal "", open.from
      assert_equal "0", open.tag # the API reports "no tag" as "0"
      assert_equal "26", open.region

      summary = server_client.stats.summary
      assert_equal 0, summary.spam_complaints_rate
      assert_equal summary.unsubscribed, summary.unsubsribed

      clients = server_client.stats.opens_by_email_client
      assert_equal 10, clients["Yandex Mail"]
      assert_equal 5, clients[:mail_ru]

      assert_equal "675", server_client.bounces.list.bounces.first.type_code
    end

    def test_real_error_responses
      @transport.respond(status: 422, body: fixture("error-message-not-found"))
                .respond(status: 404, body: fixture("error-template-not-found")) # live: GET answers 404

      error = assert_raises(UnprocessableEntityError) { server_client.messages.details("nope") }
      assert_equal ErrorCodes::MESSAGE_NOT_FOUND, error.error_code
      assert_equal "Сообщение не найдено", error.api_message
      error = assert_raises(NotFoundError) { server_client.templates.get("nope") }
      assert_equal ErrorCodes::TEMPLATE_NOT_FOUND, error.error_code
    end

    # Real webhook requests of every event type (anonymized; secrets re-signed
    # with LIVE_KEY because the real signing key is not published).
    LIVE_KEY = "live-webhook-key"

    def live_events
      JSON.parse(fixture("webhooks/events"))
    end

    def test_real_webhook_events
      events = live_events.transform_values do |data|
        Webhook.construct_event(JSON.generate(data), signing_key: LIVE_KEY)
      end
      expected = {
        "delivered" => :delivered, "delivered_novars" => :delivered, "hard" => :bounced, "soft" => :bounced,
        "spam" => :complained, "sub_hard" => :subscription_change, "sub_manual_on" => :subscription_change,
        "sub_manual_off" => :subscription_change, "opened" => :opened, "clicked" => :clicked
      }
      assert_equal expected, events.transform_values(&:type)

      delivered = events["delivered"]
      assert_equal({ "order" => "1042", "source" => "sdk-ruby" }, delivered.metadata)
      assert_equal "sdk-webhook-check", delivered.tag
      assert_equal 11_834, delivered.server_id
      assert_equal "2081", delivered.stream_id
      assert_equal Time.utc(2026, 10, 31, 18, 31, 26), delivered.occurred_at
      assert_empty events["delivered_novars"].metadata # custom_vars: ""

      assert_equal :hard_bounce, events["hard"].bounce_category
      assert_equal :soft_bounce, events["soft"].bounce_category
      assert_equal "550", events["hard"].code

      # A hard bounce also suppresses the address: same message, same secret,
      # different event, so the de-duplication keys differ.
      assert_equal events["hard"].secret, events["sub_hard"].secret
      refute_equal events["hard"].idempotency_key, events["sub_hard"].idempotency_key
      assert_predicate events["sub_hard"], :suppressed?
      assert_equal "HardBounce", events["sub_hard"].suppression_reason

      # Manual suppression is not tied to an email: message_id "" and no custom_vars.
      manual_on = events["sub_manual_on"]
      assert_equal "", manual_on.message_id
      assert_empty manual_on.metadata
      assert_predicate manual_on, :suppressed?
      refute_predicate events["sub_manual_off"], :suppressed? # "SuppressSending": "false"
      refute_equal manual_on.idempotency_key, events["sub_manual_off"].idempotency_key

      clicked = events["clicked"]
      assert_equal "https://haskimail.ru/developer", clicked.url_original
      assert_equal events["opened"].message_id, clicked.message_id
    end

    def test_real_webhook_signatures_need_the_key
      live_events.each_value do |data|
        refute Webhook.valid_signature?(data, signing_key: "another-key")
        tampered = data.merge("recipient" => "attacker@example.com")
        refute Webhook.valid_signature?(tampered, signing_key: LIVE_KEY)
      end
    end

    def test_real_inbound_webhook
      message = Webhook.parse_inbound(fixture("webhooks/inbound"))

      assert_equal "ticket-77", message.mailbox_hash
      assert_equal "2083", message.message_stream
      assert_equal "ticket-77", message.to_full.first.mailbox_hash
      assert_equal Time.utc(2026, 10, 31, 18, 31, 24), Haskimail.parse_time(message.date) # RFC 2822
      assert_equal "Входящее письмо для проверки вебхука.", message.stripped_text_reply
      assert_nil message.spam_score # no X-Spam-Score header without a spam threshold
      attachment = message.attachments.first
      assert_equal "Привет, Haskimail!", attachment.content.force_encoding(Encoding::UTF_8)
      assert_equal message.to_h["Attachments"].first["ContentLength"], attachment.size
      refute_predicate attachment, :inline?
    end

    def test_zero_dates_are_missing
      assert_nil Haskimail.parse_time("0000-00-00 00:00:00")
      # RFC 2822 (the Date of inbound mail) is a real date, not a missing one.
      assert_equal Time.utc(2026, 9, 29, 11, 5, 13), Haskimail.parse_time("Tue, 29 Sep 2026 14:05:13 +0300")
    end
  end
end
