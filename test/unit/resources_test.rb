# frozen_string_literal: true

require_relative "../test_helper"

module Haskimail
  class TemplatesTest < TestCase
    def test_crud
      t = server_client.templates

      @transport.respond(body: Fixtures::TEMPLATE_LIST)
      assert_equal "Заказ оформлен", t.list(count: 100, offset: 0).templates.first.name
      assert_request :get, "/templates", query: { "count" => "100", "offset" => "0" }

      @transport.respond(body: Fixtures::TEMPLATE)
      assert_equal 11_834, t.get("Заказ оформлен").associated_server_id
      assert_equal "/templates/%D0%97%D0%B0%D0%BA%D0%B0%D0%B7%20%D0%BE%D1%84%D0%BE%D1%80%D0%BC%D0%BB%D0%B5%D0%BD",
                   URI.parse(last_request.url).path

      t.create(name: "Заказ оформлен", subject: "S", html_body: "H", text_body: "T", associated_server_id: 11_834)
      assert_request :post, "/templates"
      assert_equal({ "Name" => "Заказ оформлен", "Subject" => "S", "HtmlBody" => "H", "TextBody" => "T",
                     "AssociatedServerId" => 11_834 }, last_json)

      t.update(4521, name: "N", subject: "S", html_body: "H", text_body: "")
      assert_request :put, "/templates/4521"
      assert_equal({ "Name" => "N", "Subject" => "S", "HtmlBody" => "H", "TextBody" => "" }, last_json)

      @transport.respond(body: { "ErrorCode" => 0, "Message" => "Template 4521 removed." })
      assert_equal "Template 4521 removed.", t.delete(4521).message
      assert_request :delete, "/templates/4521"
      assert_nil last_request.body
      refute last_request.headers.key?("Content-Type")
    end

    def test_update_requires_all_fields
      assert_raises(ArgumentError) { server_client.templates.update(1, name: "N") }
      assert_raises(ValidationError) do
        server_client.templates.update(1, name: " ", subject: "", html_body: "", text_body: "")
      end
      assert_raises(ValidationError) { server_client.templates.create(subject: "x") }
      assert_raises(ValidationError) do
        server_client.templates.update(1, name: "N", subject: nil, html_body: "", text_body: "")
      end
    end

    def test_validate
      @transport.respond(body: Fixtures::TEMPLATE_VALIDATION)
      result = server_client.templates.validate(subject: "Заказ {{order}}",
                                                test_render_model: { "{{order}}" => "1042" })

      assert_request :post, "/templates/validate"
      assert_equal({ "Subject" => "Заказ {{order}}", "TestRenderModel" => { "{{order}}" => "1042" } }, last_json)
      refute result.all_content_is_valid
      assert_equal 2, result.html_body.validation_errors.first.line
      assert_equal "track_Value", result.suggested_template_model["{{track}}"]
      assert_raises(ValidationError) { server_client.templates.validate(test_render_model: {}) }
    end

    def test_each_paginates_lazily
      @transport.respond(body: { "TotalCount" => 3, "Templates" => [{ "TemplateId" => 1 }, { "TemplateId" => 2 }] })
                .respond(body: { "TotalCount" => 3, "Templates" => [{ "TemplateId" => 3 }] })
      ids = server_client.templates.each(page_size: 2).map(&:template_id)

      assert_equal [1, 2, 3], ids
      paginator = server_client.templates.each
      assert_instance_of Enumerator, paginator.each
      assert_equal([%w[2 0], %w[2 2]],
                   @transport.requests.map { |r| URI.decode_www_form(URI.parse(r.url).query).to_h.values })

      @transport.respond(body: Fixtures::TEMPLATE_LIST)
      count = 0
      server_client.templates.each { |_template| count += 1 }
      assert_equal 2, count
      assert_raises(ValidationError) { server_client.templates.each(page_size: 0) }
    end

    def test_push_is_account_only_and_explicit
      account = account_client
      @transport.respond(body: Fixtures::TEMPLATE_LIST)
      account.templates.push(source_server_id: 11_834, destination_server_id: 11_835, perform_changes: false)

      assert_request :put, "/templates/push"
      assert_equal "account-token-5678", last_request.headers["X-Haskimail-Account-Token"]
      assert_equal({ "SourceServerID" => 11_834, "DestinationServerID" => 11_835, "PerformChanges" => false },
                   last_json)
      assert_raises(ValidationError) do
        account.templates.push(source_server_id: 1, destination_server_id: 2, perform_changes: "yes")
      end
      refute_respond_to server_client.templates, :push
    end
  end

  class MessagesTest < TestCase
    def test_search_with_filters
      @transport.respond(body: Fixtures::MESSAGES)
      result = server_client.messages.list(count: 50, recipient: "ivan@example.com", from_email: "shop@example.com",
                                           tag: "orders", subject: "Заказ", message_stream: "2081",
                                           from_date: Date.new(2026, 10, 1), to_date: Time.utc(2026, 10, 7, 9))

      assert_request :get, "/messages", query: {
        "count" => "50", "recipient" => "ivan@example.com", "fromemail" => "shop@example.com", "tag" => "orders",
        "subject" => "Заказ", "messagestream" => "2081", "fromdate" => "2026-10-01", "todate" => "2026-10-07 12:00:00"
      }
      assert_equal "Sent", result.messages.first.status
      assert_raises(ValidationError) { server_client.messages.list(form_email: "typo") }
    end

    def test_details
      @transport.respond(body: Fixtures::MESSAGES["Messages"].first)
      assert_equal "2081", server_client.messages.details("6f1c0b2d").message_stream
      assert_request :get, "/messages/6f1c0b2d/details"
    end

    def test_each_respects_the_10000_window
      @transport.respond(body: { "TotalCount" => 20_000, "Messages" => Array.new(500) { { "MessageID" => "x" } } })
      enumerator = server_client.messages.each(tag: "orders")

      assert_equal 3, enumerator.first(3).size
      assert_equal 1, @transport.requests.size
      assert_equal({ "tag" => "orders", "count" => "500", "offset" => "0" }, last_query)

      transport = FakeTransport.new
      21.times { transport.respond(body: { "TotalCount" => 20_000, "Messages" => Array.new(500) { {} } }) }
      client = ServerClient.new("t", transport: transport)
      assert_equal 10_000, client.messages.each.count
      assert_equal 20, transport.requests.size
      assert_raises(ValidationError) { server_client.messages.each(count: 5) }
      assert_raises(ValidationError) { server_client.messages.each(page_size: 501) }
    end

    def test_each_with_block_and_short_page
      @transport.respond(body: { "Messages" => [{ "MessageID" => "a" }] })
      last_id = nil
      server_client.messages.each(page_size: 10) { |message| last_id = message.message_id }

      assert_equal "a", last_id
      assert_equal 1, @transport.requests.size
    end

    def test_opens_and_clicks
      client = server_client
      client.opens.list(recipient: "ivan@example.com", from_date: "2026-10-01")
      assert_request :get, "/messages/opens", query: { "recipient" => "ivan@example.com", "fromdate" => "2026-10-01" }
      client.opens.for_message("m1", count: 10)
      assert_request :get, "/messages/opens/m1", query: { "count" => "10" }
      assert_raises(ValidationError) { client.opens.for_message("m1", from_date: "2026-10-01") }
      @transport.respond(body: { "TotalCount" => 1, "Opens" => [{ "Os" => "Windows" }] })
      assert_equal ["Windows"], client.opens.each.map(&:os)

      client.clicks.list(tag: "orders")
      assert_request :get, "/messages/clicks", query: { "tag" => "orders" }
      client.clicks.for_message("m1")
      assert_request :get, "/messages/clicks/m1"
      @transport.respond(body: { "TotalCount" => 1, "Clicks" => [{ "OriginalLink" => "https://x" }] })
      link = nil
      client.clicks.each { |click| link = click.original_link }
      assert_equal "https://x", link
    end

    def test_inbound_messages
      inbound = server_client.inbound_messages
      inbound.list(status: :blocked, mailbox_hash: "ticket-42", from_date: Time.utc(2026, 9, 1, 9))
      assert_request :get, "/messages/inbound",
                     query: { "status" => "blocked", "mailboxhash" => "ticket-42", "fromdate" => "2026-09-01T12:00:00" }
      assert_raises(ValidationError) { inbound.list(status: "deleted") }
      inbound.list(status: "Failed") # the API itself reports statuses capitalized
      assert_equal({ "status" => "failed" }, last_query)
      inbound.list(to_date: DateTime.new(2026, 9, 1, 9, 0, 0, "+00:00"))
      assert_equal({ "todate" => "2026-09-01T12:00:00" }, last_query)

      inbound.details("22c7")
      assert_request :get, "/messages/inbound/22c7/details"
      inbound.bypass("22c7")
      assert_request :put, "/messages/inbound/22c7/bypass"
      inbound.retry("22c7")
      assert_request :put, "/messages/inbound/22c7/retry"

      @transport.respond(body: { "TotalCount" => 1, "InboundMessages" => [{ "Status" => "Failed" }] })
      assert_equal ["Failed"], inbound.each(status: "failed").map(&:status)
      @transport.respond(body: { "TotalCount" => 0, "InboundMessages" => [] })
      assert_equal 0, inbound.each { nil }.count
    end
  end

  class ServerResourcesTest < TestCase
    def test_bounces
      bounces = server_client.bounces
      @transport.respond(body: Fixtures::DELIVERY_STATS)
      stats = bounces.delivery_stats
      assert_request :get, "/deliverystats"
      assert_equal 253, stats.bounces.first.count
      assert_nil stats.bounces.first[:type] # optional field: use [] to get nil instead of NoMethodError
      assert_equal "HardBounce", stats.bounces.last.type

      bounces.list(type: "HardBounce", email_filter: "x@example.com", message_id: "m1",
                   from_date: Time.new(2026, 10, 1, 23, 0, 0, "+00:00"), to_date: "2026-10-07")
      assert_request :get, "/bounces", query: { "type" => "HardBounce", "emailFilter" => "x@example.com",
                                                "messageID" => "m1", "fromdate" => "2026-10-02",
                                                "todate" => "2026-10-07" }
      assert_raises(ValidationError) { bounces.list(type: "Hard") }

      @transport.respond(body: { "TotalCount" => 1, "Bounces" => [{ "Email" => "a@example.com" }] })
      assert_equal ["a@example.com"], bounces.each(tag: "x").map(&:email)
      @transport.respond(body: { "TotalCount" => 0, "Bounces" => [] })
      assert_equal 0, bounces.each { nil }.count
    end

    def test_message_streams
      streams = server_client.message_streams
      streams.list
      assert_request :get, "/message-streams"
      streams.get("2081")
      assert_request :get, "/message-streams/2081"
      streams.create(name: "Заказы", message_stream_type: :Transactional)
      assert_equal({ "Name" => "Заказы", "MessageStreamType" => "Transactional" }, last_json)
      streams.create(name: "News", message_stream_type: "broadcasts", server_id: 11_834)
      assert_equal 11_834, last_json["ServerID"]
      assert_raises(ValidationError) { streams.create(name: "In", message_stream_type: "inbound") }
      streams.update("2081", name: "Заказы и оплаты")
      assert_request :patch, "/message-streams/2081"
      assert_equal({ "Name" => "Заказы и оплаты" }, last_json)
      assert_raises(ValidationError) { streams.update("2081", name: "") }
      streams.archive("2081")
      assert_request :post, "/message-streams/2081/archive"
      assert_nil last_request.body
      streams.unarchive("2081")
      assert_request :post, "/message-streams/2081/unarchive"
    end

    def test_suppressions
      suppressions = server_client.suppressions
      suppressions.list("2081")
      assert_request :get, "/message-streams/2081/suppressions/dump"
      suppressions.create("2081", ["no-mail@example.com", " not-an-email "])
      assert_request :post, "/message-streams/2081/suppressions"
      assert_equal({ "Suppressions" => [{ "EmailAddress" => "no-mail@example.com" },
                                        { "EmailAddress" => "not-an-email" }] }, last_json)
      suppressions.delete("2081", "no-mail@example.com")
      assert_request :post, "/message-streams/2081/suppressions/delete"
      assert_raises(ValidationError) { suppressions.create("2081", []) }
      assert_raises(ValidationError) { suppressions.create("2081", ["a@example.com", ""]) }
    end

    def test_webhooks
      webhooks = server_client.webhooks
      @transport.respond(body: { "Webhooks" => [Fixtures::WEBHOOK] })
      assert webhooks.list.webhooks.first.triggers.bounce.enabled
      webhooks.get(905)
      assert_request :get, "/webhooks/905"

      webhooks.create(url: "https://user:pass@example.com/haski", message_stream: 2081,
                      triggers: { delivery: true, bounce: { enabled: true },
                                  "SpamComplaint" => { "Enabled" => false } })
      assert_request :post, "/webhooks"
      assert_equal({ "Url" => "https://user:pass@example.com/haski", "MessageStream" => "2081",
                     "Triggers" => { "Delivery" => { "Enabled" => true }, "Bounce" => { "Enabled" => true },
                                     "SpamComplaint" => { "Enabled" => false } } }, last_json)
      webhooks.create(url: "http://example.com/h")
      assert_equal({ "Url" => "http://example.com/h", "Triggers" => {} }, last_json)

      webhooks.update(905, triggers: { open: true, click: false })
      assert_request :put, "/webhooks/905"
      assert_equal({ "Triggers" => { "Open" => { "Enabled" => true }, "Click" => { "Enabled" => false } } }, last_json)
      webhooks.update(905, url: "https://example.com/new")
      assert_equal({ "Url" => "https://example.com/new" }, last_json)
      webhooks.delete(905)
      assert_request :delete, "/webhooks/905"

      [
        -> { webhooks.create(url: "ftp://example.com") },
        -> { webhooks.create(url: "https://") },
        -> { webhooks.create(url: "http://bad host") },
        -> { webhooks.create(url: "https://example.net", triggers: { opened: true }) },
        -> { webhooks.create(url: "https://example.net", triggers: { "Opened" => true }) },
        -> { webhooks.create(url: "https://example.net", triggers: { open: "yes" }) },
        -> { webhooks.create(url: "https://example.net", triggers: { open: {} }) },
        -> { webhooks.create(url: "https://example.net", triggers: [:open]) },
        -> { webhooks.update(905) },
        -> { webhooks.update(905, triggers: {}) }
      ].each { |call| assert_raises(ValidationError) { call.call } }
    end

    def test_inbound_rules
      rules = server_client.inbound_rules
      rules.list(count: 50, offset: 0)
      assert_request :get, "/triggers/inboundrules", query: { "count" => "50", "offset" => "0" }
      rules.create(" example.org ")
      assert_equal({ "Rule" => "example.org" }, last_json)
      assert_raises(ValidationError) { rules.create(" ") }
      rules.delete(5)
      assert_request :delete, "/triggers/inboundrules/5"
      @transport.respond(body: { "TotalCount" => 2, "InboundRules" => [{ "ID" => 3 }, { "ID" => 5 }] })
      assert_equal [3, 5], rules.each.map(&:id)
      @transport.respond(body: { "TotalCount" => 0, "InboundRules" => [] })
      assert_equal 0, rules.each { nil }.count
    end

    def test_stats
      stats = server_client.stats
      @transport.respond(body: Fixtures::STATS_SUMMARY)
      summary = stats.summary(from_date: Date.new(2026, 10, 1), to_date: "2026-10-07", message_stream: "2081")
      assert_request :get, "/stats", query: { "fromdate" => "2026-10-01", "todate" => "2026-10-07",
                                              "messagestream" => "2081" }
      assert_in_delta 26.99, summary.open_rate
      assert_equal 3, summary.unsubscribed

      {
        sends: "/stats/sends", bounces: "/stats/bounces", spam_complaints: "/stats/spam", opens: "/stats/opens",
        clicks: "/stats/clicks", opens_by_platform: "/stats/opens/platforms",
        opens_by_email_client: "/stats/opens/emailclients",
        clicks_by_browser_family: "/stats/clicks/browserfamilies", clicks_by_platform: "/stats/clicks/platforms"
      }.each do |method, endpoint|
        stats.public_send(method)
        assert_request :get, endpoint
      end

      @transport.respond(body: Fixtures::EMAIL_CLIENTS)
      clients = stats.opens_by_email_client
      assert_equal 32, clients["Apple Mail"]
      assert_equal 6, clients[:mail_ru]
      assert_equal 17, clients.days.first["Apple Mail"]
      assert_raises(ValidationError) { stats.summary(tag: "x") }
    end
  end

  class AccountResourcesTest < TestCase
    def test_servers
      servers = account_client.servers
      @transport.respond(body: { "TotalCount" => 1, "Servers" => [Fixtures::SERVER] })
      assert_equal "Интернет-магазин", servers.list(count: 50).servers.first.name
      assert_equal "account-token-5678", last_request.headers["X-Haskimail-Account-Token"]
      refute last_request.headers.key?("X-Haskimail-Server-Token")

      servers.get(11_834)
      assert_request :get, "/servers/11834"
      servers.create(name: "Shop", color: "Purple", track_links: "HtmlAndText", inbound_hook_url: "https://example.net/in",
                     delivery_type: "Sandbox", inbound_spam_threshold: 15, smtp_api_activated: true)
      assert_equal({ "Name" => "Shop", "Color" => "Purple", "TrackLinks" => "HtmlAndText",
                     "InboundHookUrl" => "https://example.net/in", "DeliveryType" => "Sandbox",
                     "InboundSpamThreshold" => 15, "SmtpApiActivated" => true }, last_json)
      servers.update(11_834, track_links: false, raw_email_enabled: true)
      assert_request :put, "/servers/11834"
      assert_equal({ "TrackLinks" => false, "RawEmailEnabled" => true }, last_json)

      servers.issue_token(11_834, name: "Интеграция 1С")
      assert_request :post, "/servers/11834/tokens/new"
      assert_equal({ "Name" => "Интеграция 1С" }, last_json)

      servers.issue_token(11_834)
      assert_nil last_request.body

      servers.delete(11_834)
      assert_request :delete, "/servers/11834"

      [
        -> { servers.create(color: "purple") },
        -> { servers.create(name: "x") },
        -> { servers.create(name: "x", color: "pink") },
        -> { servers.create(name: "x", color: "red", track_links: "Always") },
        -> { servers.create(name: "x", color: "red", delivery_type: "Test") },
        -> { servers.create(name: "x", color: "red", inbound_spam_threshold: 7) },
        -> { servers.create(name: "x", color: "red", inbound_spam_threshold: 35) },
        -> { servers.update(1) },
        -> { servers.update(1, delivery_type: "Live") }
      ].each { |call| assert_raises(ValidationError) { call.call } }

      transport = FakeTransport.new
      transport.respond(body: { "TotalCount" => 51, "Servers" => Array.new(50) { { "ID" => 1 } } })
               .respond(body: { "TotalCount" => 51, "Servers" => [{ "ID" => 2 }] })
      assert_equal 51, AccountClient.new("t", transport: transport).servers.each.count
      transport.respond(body: { "TotalCount" => 0, "Servers" => [] })
      assert_equal 0, AccountClient.new("t", transport: transport).servers.each { nil }.count
    end

    def test_domains
      domains = account_client.domains
      @transport.respond(body: Fixtures::DOMAIN)
      domain = domains.get(3127)
      assert_request :get, "/domains/3127"
      assert_equal "dm._domainkey.example.com.", domain.dkim_text_value.name
      domains.list(count: 50, offset: 0)
      assert_request :get, "/domains", query: { "count" => "50", "offset" => "0" }
      domains.create(" example.com ")
      assert_equal({ "Name" => "example.com" }, last_json)
      assert_raises(ValidationError) { domains.create("") }
      domains.delete(3127)
      assert_request :delete, "/domains/3127"
      domains.verify_dkim(3127)
      assert_request :put, "/domains/3127/verifyDkim"
      domains.verify_spf(3127)
      assert_request :put, "/domains/3127/verifyspf"
      @transport.respond(body: { "TotalCount" => 1, "Domains" => [{ "Name" => "example.com" }] })
      assert_equal ["example.com"], domains.each.map(&:name)
      @transport.respond(body: { "TotalCount" => 0, "Domains" => [] })
      assert_equal 0, domains.each { nil }.count
    end

    def test_account_templates_inherit_reads
      account_client.templates.list
      assert_equal "account-token-5678", last_request.headers["X-Haskimail-Account-Token"]
    end

    def test_resources_inspect
      assert_equal "#<Haskimail::Resources::Servers>", account_client.servers.inspect
      assert_match(/Paginator items="Domains"/, account_client.domains.each.inspect)
    end
  end
end
