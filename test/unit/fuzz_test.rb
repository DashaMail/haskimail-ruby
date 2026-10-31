# frozen_string_literal: true

require_relative "../test_helper"

module Haskimail
  # Randomized inputs (fixed seed, reproducible): whatever comes in, the SDK
  # either works or raises its own documented errors — never NoMethodError,
  # TypeError, Encoding errors and the like.
  class FuzzTest < TestCase
    SEED = Integer(ENV.fetch("FUZZ_SEED", "20261030"))
    ITERATIONS = Integer(ENV.fetch("FUZZ_ITERATIONS", "400"))
    ALLOWED = [Haskimail::Error].freeze

    def setup
      super
      @random = Random.new(SEED)
    end

    def random_string
      pool = ["a", "Я", "🚀", "\r", "\n", "\t", " ", "\x00", ",", "\"", "<", ">", "@", "/", "..", "%", "?",
              "#", " ", "{{x}}", "\xFF".b, "1" * 3]
      Array.new(@random.rand(0..12)) { pool.sample(random: @random).b }.join.then do |text|
        text.force_encoding(@random.rand < 0.2 ? Encoding::BINARY : Encoding::UTF_8)
      end
    end

    def random_value(depth = 0)
      case @random.rand(depth > 2 ? 6 : 8)
      when 0 then nil
      when 1 then @random.rand(-5..5)
      when 2 then [true, false].sample(random: @random)
      when 3 then :sym
      when 4, 5 then random_string
      when 6 then Array.new(@random.rand(0..3)) { random_value(depth + 1) }
      else Array.new(@random.rand(0..3)) { [random_key, random_value(depth + 1)] }.to_h
      end
    end

    def random_key
      [:from, :to, :cc, :subject, :html_body, :text_body, :headers, :attachments, :metadata, :tag, "HtmlBody",
       :template_id, 3, nil, "subject", :replyTo, "BCC", :reply_to].sample(random: @random)
    end

    # Whatever the SDK lets through must be safe to put into email headers.
    def assert_safe_email(json)
      Resources::Emails::HEADER_FIELDS.each do |field|
        refute_match Util::UNSAFE_HEADER_CHARS, json[field].to_s, "#{field} in #{json.inspect}"
      end
      json.each_key do |key|
        canonical = Resources::Emails::EMAIL_FIELDS.find { |name| ApiObject.normalize(name) == ApiObject.normalize(key) }
        assert_equal canonical, key, "a field was sent under a non-canonical name" if canonical
      end
      Array(json["Headers"]).each do |header|
        assert_match Resources::Emails::HEADER_NAME, header["Name"].b
        refute_match Util::UNSAFE_HEADER_CHARS, header["Value"]
      end
    end

    def random_response
      status = [200, 200, 200, 201, 204, 400, 401, 404, 422, 429, 500, 503, 599].sample(random: @random)
      body = case @random.rand(5)
             when 0 then random_string
             when 1 then JSON.generate(jsonable(random_value(1)))
             when 2 then JSON.generate(jsonable({ "ErrorCode" => random_value(2), "Message" => random_string }))
             when 3 then JSON.generate(jsonable([{ "ErrorCode" => random_value(2) }]))
             else ""
             end
      HTTP::Response.new(status: status, headers: {}, body: body.dup.force_encoding(Encoding::UTF_8))
    end

    def jsonable(value)
      case value
      when String, Symbol then value.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      when Array then value.map { |item| jsonable(item) }
      when Hash then value.to_h { |key, item| [jsonable(key.to_s), jsonable(item)] }
      else value
      end
    end

    def survive
      yield
    rescue *ALLOWED
      nil
    end

    def test_email_fields
      client = server_client
      sent = 0
      ITERATIONS.times do
        fields = Array.new(@random.rand(0..6)) { [random_key, random_value] }.to_h
        # Half of the inputs start from a valid email, so the oracle below
        # also sees what the SDK lets through.
        fields = { from: "a@example.com", to: "b@example.com", text_body: "x" }.merge(fields) if @random.rand < 0.5
        before = @transport.requests.size
        survive { client.emails.deliver(fields) }
        survive { client.emails.deliver_with_template(fields) }
        survive { client.emails.deliver_batch([fields]) }
        @transport.requests.drop(before).each do |request|
          json = JSON.parse(request.body)
          (json.is_a?(Array) ? json : [json]).each { |email| assert_safe_email(email) }
          sent += 1
        end
      end
      assert_operator sent, :>, 0, "the generator must also produce valid emails"
    end

    def test_path_segments_never_escape_their_segment
      ITERATIONS.times do
        value = random_value
        survive do
          path = Util.path("/templates/%s", value)
          segment = path.delete_prefix("/templates/")
          refute_includes segment, "/"
          refute_includes %w[. ..], segment
          refute_match(/[?#\s]/, segment)
        end
      end
    end

    # Any response the network could produce maps to data or to a
    # Haskimail::Error, and a 2xx with a non-zero or broken ErrorCode is
    # never reported as success.
    def test_any_response_is_handled
      ITERATIONS.times do
        transport = FakeTransport.new
        response = random_response
        transport.respond(status: response.status, body: response.body)
        client = ServerClient.new(SERVER_TOKEN, transport: transport, max_retries: 0)
        result = survive { client.emails.deliver(from: "a@example.com", to: "b@example.com", text_body: "x") }
        next if result.nil?

        assert_includes 200..299, response.status
        assert_predicate result, :success?, "#{response.status} #{response.body.inspect}"
      end
    end

    def test_api_object_accepts_any_json_object
      ITERATIONS.times do
        data = Array.new(@random.rand(0..5)) { [random_string.scrub, random_value] }.to_h
        object = ApiObject.new(data)
        data.each_key { |key| object[key] }
        object.to_h
        object.inspect
      end
    end

    def test_webhook_parsers_survive_garbage
      ITERATIONS.times do
        body = [random_string, JSON.generate(jsonable(random_value(2))), "{#{random_string.scrub}}"]
               .sample(random: @random)
        survive { Webhook.parse_event(body) }
        survive { Webhook.construct_event(body, signing_key: "k") }
        survive { Webhook.parse_inbound(body)&.attachments }
      end
    end

    def test_resource_arguments
      server = server_client
      account = account_client
      calls = [
        -> { server.templates.get(random_value) },
        -> { server.templates.create(name: random_value, subject: random_value, html_body: random_value) },
        lambda do
          server.templates.update(random_value, name: random_value, subject: random_value, html_body: "", text_body: "")
        end,
        -> { server.templates.validate(subject: random_value, test_render_model: random_value) },
        -> { server.webhooks.create(url: random_value, message_stream: random_value, triggers: random_value) },
        -> { server.webhooks.update(random_value, url: random_value, triggers: random_value) },
        -> { server.suppressions.create(random_value, random_value) },
        -> { server.inbound_rules.create(random_value) },
        -> { server.inbound_messages.list(status: random_value, from_date: random_value) },
        -> { server.bounces.list(type: random_value, to_date: random_value) },
        -> { server.message_streams.create(name: random_value, message_stream_type: random_value) },
        -> { account.servers.create(name: random_value, color: random_value, track_links: random_value) },
        -> { account.domains.create(random_value) },
        -> { Attachment.new(name: random_value, content: random_value) }
      ]
      ITERATIONS.times { survive { calls.sample(random: @random).call } }
    end

    def test_query_and_dates
      ITERATIONS.times do
        survive { server_client.messages.list(from_date: random_value, tag: random_value) }
        survive { server_client.stats.summary(to_date: random_value) }
        survive { Util.parse_time(random_value) }
      end
    end
  end
end
