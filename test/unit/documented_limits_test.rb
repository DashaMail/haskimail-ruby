# frozen_string_literal: true

require_relative "../test_helper"

module Haskimail
  # Checks added after the second documentation review.
  class DocumentedLimitsTest < TestCase
    BASE = { from: "a@example.com", to: "b@example.com" }.freeze

    def deliver(**fields)
      server_client.emails.deliver(**BASE, **fields)
    end

    def test_whole_message_including_attachments_fits_into_ten_megabytes
      four_mb = "a" * (4 * 1024 * 1024)
      attachment = { "Name" => "a.txt", "Content" => "a" * (2 * 1024 * 1024) }
      deliver(html_body: four_mb, text_body: four_mb, attachments: [attachment])

      error = assert_raises(ValidationError) do
        deliver(html_body: four_mb, text_body: four_mb, attachments: [attachment, attachment])
      end
      assert_match(/limit is 10 MB/, error.message)
    end

    def test_a_body_must_not_be_empty
      assert_raises(ValidationError) { deliver(html_body: "", text_body: "") }
      deliver(html_body: "", text_body: "x")
      assert_equal "x", last_json["TextBody"]
    end

    def test_template_id_or_alias_exactly_once
      error = assert_raises(ValidationError) do
        server_client.emails.deliver_with_template(**BASE, template_id: 1, template_alias: "a")
      end
      assert_match(/not both/, error.message)
    end

    def test_batch_mixes_plain_and_template_emails
      @transport.respond(body: [{ "ErrorCode" => 0 }, { "ErrorCode" => 0 }])
      server_client.emails.deliver_batch([BASE.merge(text_body: "x"), BASE.merge(template_alias: "welcome")])

      assert_equal([nil, "welcome"], last_json.map { |email| email["TemplateAlias"] })
      assert_raises(ValidationError) do
        server_client.emails.deliver_batch([BASE.merge(template_id: 1, template_alias: "a")])
      end
    end

    def test_batch_request_must_not_exceed_fifty_megabytes
      original = Resources::Emails::MAX_BATCH_BYTES
      Resources::Emails.send(:remove_const, :MAX_BATCH_BYTES)
      Resources::Emails.const_set(:MAX_BATCH_BYTES, 1000)
      error = assert_raises(ValidationError) do
        server_client.emails.deliver_batch(Array.new(3) { BASE.merge(text_body: "x" * 400) })
      end
      assert_match(/limit is 50 MB/, error.message)
      assert_raises(ValidationError) do
        server_client.emails.deliver_batch_with_templates(Array.new(3) { BASE.merge(template_alias: "y" * 400) })
      end
      assert_empty @transport.requests
    ensure
      Resources::Emails.send(:remove_const, :MAX_BATCH_BYTES)
      Resources::Emails.const_set(:MAX_BATCH_BYTES, original)
    end

    def test_comments_in_address_lists_do_not_count_as_recipients
      assert_equal 1, Resources::Emails.count_addresses("Иванов (CEO, Acme) <a@b.example>")
    end

    def test_file_named_only_by_a_forbidden_extension
      assert_raises(ValidationError) { Attachment.new(name: ".exe", content: "") }
      assert_raises(ValidationError) { Attachment.new(name: "dir/.BAT", content: "") }
      assert_equal "application/octet-stream", Attachment.new(name: ".profile", content: "").content_type
    end

    def test_account_token_needs_the_server
      error = assert_raises(ValidationError) { account_client.templates.create(name: "N") }
      assert_match(/associated_server_id/, error.message)
      error = assert_raises(ValidationError) do
        account_client.message_streams.create(name: "N", message_stream_type: "broadcasts")
      end
      assert_match(/server_id/, error.message)
      assert_empty @transport.requests

      account_client.templates.create({ "Name" => "N", "AssociatedServerId" => 5 })
      assert_equal 5, last_json["AssociatedServerId"]
      server_client.message_streams.create(name: "N", message_stream_type: "broadcasts")
      refute last_json.key?("ServerID")
    end

    def test_documented_count_and_offset_ranges
      client = server_client
      [
        -> { client.messages.list(count: 501) },
        -> { client.messages.list(count: 0) },
        -> { client.messages.list(count: 500, offset: 9_501) },
        -> { client.opens.list(offset: -1) },
        -> { client.clicks.for_message("m", count: "10") },
        -> { client.inbound_messages.list(count: 501) },
        -> { client.inbound_messages.each(page_size: 501) },
        -> { client.inbound_rules.list(count: 501) },
        -> { client.inbound_rules.each(page_size: 0) }
      ].each { |call| assert_raises(ValidationError) { call.call } }
      assert_empty @transport.requests

      client.messages.list(count: 500, offset: 9_500)
      assert_equal({ "count" => "500", "offset" => "9500" }, last_query)
      client.inbound_rules.list(count: 500)
    end

    def test_error_code_100_is_retried_only_for_reads
      @transport.respond(status: 422, body: { "ErrorCode" => 100 }).respond(body: Fixtures::TEMPLATE_LIST)
      assert_equal 2, server_client.templates.list.total_count

      @transport.respond(status: 422, body: { "ErrorCode" => 100, "Message" => "Internal" })
      assert_raises(UnprocessableEntityError) { server_client.emails.deliver(**BASE, text_body: "x") }
      assert_equal 3, @transport.requests.size
    end

    def test_webhook_size_limits_are_configurable
      big = JSON.generate("TextBody" => "x" * 2048)
      error = assert_raises(WebhookPayloadTooLargeError) { Webhook.parse_inbound(big, max_size: 1024) }
      assert_kind_of ValidationError, error
      assert_equal "x" * 2048, Webhook.parse_inbound(big).text_body
      assert_raises(WebhookPayloadTooLargeError) { Webhook.parse_event(big, max_size: 100) }
      assert_raises(WebhookPayloadTooLargeError) { Webhook.construct_event(big, signing_key: "k", max_size: 100) }
      assert_equal 64 * 1024 * 1024, Webhook::MAX_INBOUND_SIZE
    end
  end
end
