# frozen_string_literal: true

require_relative "../test_helper"
require "digest"

module Haskimail
  class WebhookTest < TestCase
    KEY = "webhook-signing-key"

    def signed(payload)
      secret = Digest::MD5.hexdigest("#{payload['recipient']}#{payload['message_id']}#{KEY}")
      payload.merge("secret" => secret)
    end

    def test_construct_event_verifies_signature
      body = JSON.generate(signed(Fixtures::BOUNCE_EVENT))
      event = Webhook.construct_event(body, signing_key: KEY)

      assert_instance_of Webhook::Event, event
      assert_equal :bounced, event.type
      assert_predicate event, :bounced?
      refute_predicate event, :delivered?
      assert_equal "old-address@example.com", event.recipient
      assert_equal "a41d7c9e2b6f4e0d8c3b5a1f9e7d2c60", event.message_id
      assert_equal "orders", event.tag
      assert_equal({ "order_id" => "1042" }, event.metadata)
      assert_equal 11_834, event.server_id
      assert_equal "2081", event.stream_id
      assert_equal :hard_bounce, event.bounce_category
      assert_equal "550", event.code
      assert_equal Time.utc(2026, 10, 7, 11, 30, 15), event.occurred_at
      assert_equal "bounced|a41d7c9e2b6f4e0d8c3b5a1f9e7d2c60|old-address@example.com|2026-10-07 14:30:15|",
                   event.idempotency_key
    end

    def test_signature_failures
      tampered = signed(Fixtures::BOUNCE_EVENT).merge("recipient" => "attacker@example.com")
      [
        JSON.generate(tampered),
        JSON.generate(Fixtures::BOUNCE_EVENT.merge("secret" => "")),
        JSON.generate(Fixtures::BOUNCE_EVENT.except("secret"))
      ].each do |body|
        assert_raises(SignatureVerificationError) { Webhook.construct_event(body, signing_key: KEY) }
      end
      assert_raises(SignatureVerificationError) do
        Webhook.construct_event(JSON.generate(signed(Fixtures::BOUNCE_EVENT)), signing_key: "other")
      end
      assert_raises(ConfigurationError) do
        Webhook.construct_event(JSON.generate(signed(Fixtures::BOUNCE_EVENT)), signing_key: " ")
      end
    end

    # Regression: reviewer's forgery — reuse one leaked signature, move the
    # signed recipient into message_id and supply a look-alike field.
    def test_cannot_forge_recipient_with_look_alike_fields
      leaked = signed(Fixtures::BOUNCE_EVENT)
      shifted = leaked["recipient"] + leaked["message_id"]
      base = { "event" => "subscriptionchange", "message_id" => shifted, "secret" => leaked["secret"],
               "SuppressSending" => "true" }

      [
        base.merge("Recipient" => "victim@other.example"),
        base.merge("email" => "victim@other.example"),
        base.merge("RECIPIENT" => "victim@other.example", "recipient" => "")
      ].each do |forged|
        error = assert_raises(SignatureVerificationError, ValidationError) do
          Webhook.construct_event(JSON.generate(forged), signing_key: KEY)
        end
        refute_nil error
      end
    end

    def test_rejects_ambiguous_duplicate_fields
      %w[Recipient MESSAGE_ID Secret Event Email].each do |look_alike|
        payload = signed(Fixtures::BOUNCE_EVENT).merge(look_alike => "victim@other.example")
        assert_raises(ValidationError, look_alike) do
          Webhook.construct_event(JSON.generate(payload), signing_key: KEY)
        end
      end
      # Unrelated look-alike fields (a future API addition) must not drop events.
      harmless = signed(Fixtures::BOUNCE_EVENT).merge("UserID" => "1", "ServerId" => 2)
      assert_predicate Webhook.construct_event(JSON.generate(harmless), signing_key: KEY), :bounced?
    end

    def test_signed_fields_must_have_expected_shape
      [
        { "recipient" => "no-at-sign", "message_id" => "abc" },
        { "recipient" => "a@b.example", "message_id" => "a.b@c" },
        { "recipient" => 5, "message_id" => "abc" },
        { "recipient" => "a@b.example", "message_id" => 7 }
      ].each do |fields|
        payload = fields.merge("secret" => Digest::MD5.hexdigest("#{fields['recipient']}#{fields['message_id']}#{KEY}"))
        refute Webhook.valid_signature?(payload, signing_key: KEY), fields.inspect
      end
      refute Webhook.valid_signature?({ "recipient" => "a@b.example", "message_id" => "", "secret" => 5 },
                                      signing_key: KEY)
      # A missing/null message_id is signed as "" (event not tied to an email).
      no_message = { "recipient" => "a@b.example", "secret" => Digest::MD5.hexdigest("a@b.example#{KEY}") }
      assert Webhook.valid_signature?(no_message, signing_key: KEY)
      assert Webhook.valid_signature?(no_message.merge("message_id" => nil), signing_key: KEY)
      assert Webhook.valid_signature?(
        { "recipient" => "a@b.example", "message_id" => "id_1",
          "secret" => Digest::MD5.hexdigest("a@b.exampleid_1#{KEY}") }, signing_key: KEY
      )
    end

    def test_rejects_hostile_payloads_quickly
      # CPU time, not wall-clock: a busy CI runner must not fail this test.
      # Without the guards the first payload alone takes tens of CPU seconds.
      started = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
      assert_raises(ValidationError) { Webhook.parse_inbound("{\"a\": #{'9' * 5_000_000}}") }
      assert_raises(ValidationError) { Webhook.parse_inbound("9" * 5_000_000) }
      assert_raises(ValidationError) { Webhook.parse_inbound("{\"a\":#{' ' * 5_000_000}1") }
      many = "{\"a\":[#{(['1' * 9_999] * 500).join(',')}]}"
      assert_equal 500, Webhook.parse_inbound(many).a.size
      assert_operator Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - started, :<, 10.0
      assert_equal 12_345, Webhook.parse_event(' {"n": 12345}').n
      iban = Webhook.parse_inbound(JSON.generate("TextBody" => "IBAN: #{'1' * 120}"))
      assert_equal "IBAN: #{'1' * 120}", iban.text_body
    end

    def test_signature_is_case_insensitive_and_accepts_hashes
      payload = signed(Fixtures::BOUNCE_EVENT)
      payload["secret"] = payload["secret"].upcase

      assert Webhook.valid_signature?(payload, signing_key: KEY)
      assert Webhook.valid_signature?(Webhook.parse_event(JSON.generate(payload)), signing_key: KEY)
      refute Webhook.valid_signature?(nil, signing_key: KEY)
      refute Webhook.valid_signature?(Object.new, signing_key: KEY)
    end

    def test_event_without_message_signs_empty_message_id
      payload = signed(Fixtures::BOUNCE_EVENT.merge("event" => "subscriptionchange", "message_id" => "",
                                                    "campaign_id" => "", "SuppressSending" => "true",
                                                    "SuppressionReason" => "ManualSuppression")
                                            .except("custom_vars"))
      event = Webhook.construct_event(JSON.generate(payload), signing_key: KEY)

      assert_equal :subscription_change, event.type
      assert_predicate event, :subscription_change?
      assert_predicate event, :suppressed?
      assert_equal "", event.message_id
      assert_empty event.metadata
      assert_equal "ManualSuppression", event.suppression_reason
    end

    def test_documented_casing_variants
      clicked = Webhook.parse_event(JSON.generate("event" => "CLICKED", "custom_vars" => { "a_key" => "a_value" },
                                                  "server_id" => 23, "stream_id" => 25,
                                                  "event_time" => "2019-11-05 16:33:54",
                                                  "url_original" => "https://haskimail.ru"))
      assert_equal :clicked, clicked.type
      assert_predicate clicked, :clicked?
      assert_equal({ "a_key" => "a_value" }, clicked.metadata)
      assert_equal "25", clicked.stream_id
      assert_equal Time.utc(2019, 11, 5, 13, 33, 54), clicked.occurred_at
      assert_equal "https://haskimail.ru", clicked.url_original

      assert_equal :complained, Webhook.parse_event('{"event":"COMPLAINED"}').type
      sent = Webhook.parse_event('{"event":"sent"}') # sandbox servers report "sent" instead of delivery
      assert_equal :sent, sent.type
      assert_predicate sent, :sent?
      assert_predicate Webhook.parse_event('{"SuppressSending":"1"}'), :suppressed?
      assert_predicate Webhook.parse_event('{"SuppressSending":true}'), :suppressed?
      refute_predicate Webhook.parse_event('{"SuppressSending":"0"}'), :suppressed?
      assert_equal :unknown, Webhook.parse_event('{"event":"new-type"}').type
    end

    def test_defensive_field_parsing
      event = Webhook.parse_event(JSON.generate("email" => "x@example.com", "custom_vars" => "{broken",
                                                "server_id" => "abc", "event_time_utc" => "bad",
                                                "bounce_category" => "zzz"))
      assert_nil event.recipient, "only the signed `recipient` field is used, never `email`"
      assert_equal "x@example.com", event.email
      assert_empty event.metadata
      assert_nil event.server_id
      assert_nil event.stream_id
      assert_nil event.occurred_at
      assert_nil event.bounce_category
      refute_predicate event, :suppressed?

      assert_empty Webhook.parse_event('{"custom_vars":"[1]"}').metadata
      assert_empty Webhook.parse_event('{"custom_vars":5}').metadata
      assert_empty Webhook.parse_event('{"custom_vars":" "}').metadata
      assert_nil Webhook.parse_event("{}").server_id
      assert_equal 7, Webhook.parse_event('{"server_id":"7"}').server_id
      assert_nil Webhook.parse_event('{"event_time_utc":"2026-13-45 99:00:00"}').occurred_at
    end

    def test_binary_bodies
      body = JSON.generate(signed(Fixtures::BOUNCE_EVENT)).b # Rack's raw_post is ASCII-8BIT
      assert_predicate Webhook.construct_event(body, signing_key: KEY), :bounced?
      error = assert_raises(ValidationError) { Webhook.parse_event("{\"a\":\"\xFF\"}".b) }
      assert_match(/not valid UTF-8/, error.message)
    end

    def test_rejects_malformed_payloads
      ["", "[]", "not json", "#{'[' * 200}#{']' * 200}", "{\"a\":\"#{'x' * Webhook::MAX_EVENT_SIZE}\"}"].each do |body|
        assert_raises(ValidationError, body[0, 20]) { Webhook.parse_event(body) }
      end
    end

    def test_inbound_message
      message = Webhook.parse_inbound(JSON.generate(Fixtures::INBOUND))

      assert_equal "ticket-42", message.mailbox_hash
      assert_equal "Иван Петров", message.from_full.name
      assert_in_delta 0.3, message.spam_score
      assert_equal "<CAE8+abc@mail.example.com>", message.header("message-id")
      assert_nil message.header("X-Missing")
      attachment = message.attachments.first
      assert_equal "check.pdf", attachment.name
      assert_equal "%PDF-1.4 test", attachment.content
      assert_equal 13, attachment.size
      refute_predicate attachment, :inline?
      assert_match(/size=13/, attachment.inspect)
      refute_includes attachment.to_s, "PDF", "to_s must not dump attachment content"
      require "pp"
      refute_includes attachment.pretty_inspect, "PDF", "pp must not dump attachment content"

      odd = Webhook.parse_inbound(JSON.generate("Headers" => [{ "Name" => "X-Spam-Score", "Value" => "n/a" }, 1],
                                                "Attachments" => [1, { "ContentID" => "cid:x" }]))
      assert_nil odd.spam_score
      assert_equal 1, odd.attachments.size
      assert_predicate odd.attachments.first, :inline?
      assert_nil Webhook.parse_inbound("{}").spam_score
      assert_empty Webhook.parse_inbound("{}").attachments
    end
  end
end
