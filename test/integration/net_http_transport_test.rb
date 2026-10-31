# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/https_server"
require "zlib"
require "stringio"

module Haskimail
  # End-to-end: real TLS socket, real Net::HTTP, real JSON — no stubs.
  class NetHttpTransportTest < Minitest::Test
    include TestWatchdog

    def setup
      Haskimail.reset_configuration!
      @responses = Queue.new
      @server = TestHttpsServer.new do |request|
        handler = @responses.empty? ? ->(_r) { [200, { "Content-Type" => "application/json" }, "{}"] } : @responses.pop
        handler.call(request)
      end
      @sleeps = []
    end

    def teardown
      @server.shutdown
      Haskimail.reset_configuration!
      raise "#{@responses.size} queued server response(s) were never requested" unless @responses.empty?
    end

    def enqueue(status = 200, body = {}, headers = { "Content-Type" => "application/json" }, &block)
      @responses << (block || ->(_r) { [status, headers, body.is_a?(String) ? body : JSON.generate(body)] })
    end

    def client(token = "real-token", **options)
      ServerClient.new(token, base_url: @server.base_url, ca_file: @server.ca_file,
                              sleeper: ->(s) { @sleeps << s }, **options)
    end

    def test_round_trip_over_tls
      enqueue(200, Fixtures::SEND_OK)
      result = client.emails.deliver(from: "Магазин <shop@example.com>", to: "ivan@example.com",
                                     subject: "Заказ №1042", text_body: "Здравствуйте!")

      request = @server.received.first
      assert_equal "POST", request.http_method
      assert_equal "/email", request.path
      assert_equal "real-token", request.headers["x-haskimail-server-token"]
      assert_equal "application/json", request.headers["accept"]
      assert_equal "application/json", request.headers["content-type"]
      assert_match(%r{\Ahaskimail-ruby/}, request.headers["user-agent"])
      assert_equal "Заказ №1042", JSON.parse(request.body.force_encoding("UTF-8"))["Subject"]
      assert_equal "6f1c0b2d9e8a4f7b3c5d2e1a0b9c8d7e", result.message_id
    end

    def test_one_client_is_safe_to_share_between_threads
      shared = client
      errors = Queue.new
      threads = Array.new(12) do |thread|
        Thread.new do
          8.times do |i|
            result = shared.request(:get, "/echo/#{thread}/#{i}")
            errors << "unexpected #{result.inspect}" unless result.is_a?(ApiObject)
          rescue StandardError => e
            errors << e
          end
        end
      end
      threads.each(&:join)

      assert_empty Array.new(errors.size) { errors.pop }
      received = @server.received
      assert_equal 96, received.size
      assert_equal 96, received.map(&:path).uniq.size
      assert(received.all? { |r| r.headers["x-haskimail-server-token"] == "real-token" })
    end

    def test_query_and_unicode_response
      enqueue(200, { "TotalCount" => 1, "Messages" => [{ "Subject" => "Ваш заказ" }] })
      result = client.messages.list(recipient: "ivan+tag@example.com", subject: "Ваш заказ")

      assert_equal "/messages?recipient=ivan%2Btag%40example.com" \
                   "&subject=%D0%92%D0%B0%D1%88+%D0%B7%D0%B0%D0%BA%D0%B0%D0%B7",
                   @server.received.first.path
      assert_equal "Ваш заказ", result.messages.first.subject
      assert_equal Encoding::UTF_8, result.messages.first.subject.encoding
    end

    def test_gzip_responses_are_decoded
      io = StringIO.new
      gzip = Zlib::GzipWriter.new(io)
      gzip.write(JSON.generate(Fixtures::STATS_SUMMARY))
      gzip.close
      enqueue(200, io.string, { "Content-Type" => "application/json", "Content-Encoding" => "gzip" })

      assert_equal 615, client.stats.summary.sent
    end

    def test_api_error_over_the_wire
      enqueue(401, { "ErrorCode" => 10, "Message" => "Invalid token" })
      error = assert_raises(AuthenticationError) { client.templates.list }

      assert_equal 10, error.error_code
      assert_equal "application/json", error.response_headers["content-type"]
    end

    def test_untrusted_certificate_is_rejected_without_retry
      unsafe = ServerClient.new("t", base_url: @server.base_url, sleeper: ->(s) { @sleeps << s })
      error = assert_raises(TlsError) { unsafe.templates.list }

      assert_match(/certificate verify failed/, error.message)
      assert_kind_of OpenSSL::SSL::SSLError, error.original_error
      assert_empty @sleeps
      assert_empty @server.received
    end

    def test_hostname_mismatch_is_rejected
      other = TestHttpsServer.new(san: "DNS:other.example") { [200, {}, "{}"] }
      mismatched = ServerClient.new("t", base_url: other.base_url, ca_file: other.ca_file)

      assert_raises(TlsError) { mismatched.templates.list }
    ensure
      other&.shutdown
    end

    def test_read_timeout_is_retried_for_get
      enqueue do |_request|
        sleep 3
        [200, {}, "{}"]
      end
      enqueue(200, Fixtures::TEMPLATE_LIST)
      result = client(read_timeout: 1.0, max_retries: 1).templates.list

      assert_equal 2, result.total_count
      assert_equal 2, @server.received.size
      assert_equal 1, @sleeps.size
    end

    def test_read_timeout_is_not_retried_for_post
      enqueue do |_request|
        sleep 3
        [200, {}, "{}"]
      end
      error = assert_raises(TimeoutError) do
        client(read_timeout: 1.0).emails.deliver(from: "a@example.com", to: "b@example.com", text_body: "x")
      end

      assert_predicate error, :request_sent?
      assert_equal 1, @server.received.size
    end

    def test_server_error_is_retried_for_get
      enqueue(503, "")
      enqueue(200, Fixtures::DELIVERY_STATS)

      assert_equal "All", client.bounces.delivery_stats.bounces.first.name
      assert_equal 2, @server.received.size
    end

    def test_connection_refused
      port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
      refused = ServerClient.new("t", base_url: "https://127.0.0.1:#{port}", max_retries: 1,
                                      sleeper: ->(s) { @sleeps << s })
      error = assert_raises(ConnectionError) do
        refused.emails.deliver(from: "a@example.com", to: "b@example.com", text_body: "x")
      end

      refute_predicate error, :request_sent?
      assert_equal 1, @sleeps.size, "a POST that never left the machine is retried"
    end

    def test_connection_reset_maps_to_connection_error
      enqueue { |_request| raise IOError, "boom" } # server drops the connection without answering
      error = assert_raises(ConnectionError) { client(max_retries: 0).templates.list }

      assert_predicate error, :request_sent?
    end

    def test_transport_configuration
      transport = HTTP::NetHttpTransport.new(proxy: URI.parse("http://user%40corp:p%3As+s@proxy.local:3128"))
      http = transport.send(:build_http, URI.parse("https://api.haskimail.ru"), 1, 2, 3)

      assert_equal "proxy.local", http.proxy_address
      assert_equal 3128, http.proxy_port
      assert_equal "user@corp", http.proxy_user
      assert_equal "p:s+s", http.proxy_pass, "'+' is literal in user info, not a space"
      assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
      assert_equal OpenSSL::SSL::TLS1_2_VERSION, http.min_version
      assert_equal 0, http.max_retries
      assert_equal [1, 2, 3], [http.open_timeout, http.read_timeout, http.write_timeout]
      assert_equal "#<Haskimail::HTTP::NetHttpTransport proxy=[set]>", transport.inspect
      assert_equal "#<Haskimail::HTTP::NetHttpTransport proxy=none>", HTTP::NetHttpTransport.new(env: {}).inspect

      request = HTTP::Request.new(method: :trace, url: "https://example.net/", headers: {}, body: nil)
      assert_raises(ValidationError) { transport.send(:build_request, request, URI.parse(request.url)) }
    end

    # A proxy that answers CONNECT with garbage, or never answers at all:
    # both surface as Haskimail errors, and the request was certainly not sent.
    def test_broken_proxies_fail_before_sending
      { "garbage\r\n\r\n" => ConnectionError, nil => TimeoutError }.each do |reply, error_class|
        proxy = TCPServer.new("127.0.0.1", 0)
        thread = Thread.new do
          socket = proxy.accept
          socket.gets
          reply ? socket.write(reply) : sleep(5)
          socket.close
        rescue IOError, SystemCallError
          nil
        end
        broken = ServerClient.new("t", proxy: "http://127.0.0.1:#{proxy.addr[1]}", read_timeout: 0.5, max_retries: 0)
        error = assert_raises(error_class) { broken.templates.list }
        refute_predicate error, :request_sent?
      ensure
        thread&.kill
        proxy&.close
      end
    end

    # The phase decides whether the request may have been sent, not the
    # error class: the same errno means "not sent" while connecting and
    # "maybe sent" once the connection is up.
    def test_error_phase_decides_request_sent
      errors = [Errno::ETIMEDOUT, Errno::ENETDOWN, Errno::EHOSTUNREACH, Errno::ECONNREFUSED, SocketError,
                OpenSSL::SSL::SSLError, Net::OpenTimeout, EOFError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError,
                Net::ReadTimeout, Net::WriteTimeout]
      errors.each do |klass|
        refute_predicate phase_error(klass, :connect), :request_sent?, "#{klass} while connecting"
        next if klass == Net::OpenTimeout # cannot happen after the connection is up

        exchange_error = phase_error(klass, :exchange)
        assert_predicate exchange_error, :request_sent?, "#{klass} after connecting"
        assert_kind_of klass, exchange_error.original_error
      end
      assert_kind_of TlsError, phase_error(OpenSSL::SSL::SSLError, :exchange)
      assert_predicate phase_error(EOFError, :exchange, closes: true), :request_sent?
      assert_kind_of TimeoutError, phase_error(Net::ReadTimeout, :exchange)
      assert_kind_of TimeoutError, phase_error(Net::ReadTimeout, :connect)
    end

    def test_response_size_is_capped
      stub_const_size = Class.new(HTTP::NetHttpTransport)
      original = HTTP::NetHttpTransport::MAX_RESPONSE_SIZE
      HTTP::NetHttpTransport.send(:remove_const, :MAX_RESPONSE_SIZE)
      HTTP::NetHttpTransport.const_set(:MAX_RESPONSE_SIZE, 1024)
      enqueue(200, { "Big" => "x" * 5000 })
      transport = stub_const_size.new(ca_file: @server.ca_file)
      client = ServerClient.new("t", base_url: @server.base_url, transport: transport, max_retries: 0)

      error = assert_raises(ConnectionError) { client.templates.list }
      assert_match(/exceeds 1024 bytes/, error.message)
    ensure
      HTTP::NetHttpTransport.send(:remove_const, :MAX_RESPONSE_SIZE)
      HTTP::NetHttpTransport.const_set(:MAX_RESPONSE_SIZE, original)
    end

    def test_open_timeout
      fake = Object.new
      def fake.start = raise(Net::OpenTimeout)
      transport = Class.new(HTTP::NetHttpTransport) { define_method(:build_http) { |*| fake } }.new
      request = HTTP::Request.new(method: :get, url: "https://example.net/", headers: {}, body: nil)
      error = assert_raises(TimeoutError) do
        transport.call(request, open_timeout: 1, read_timeout: 1, write_timeout: 1)
      end
      refute_predicate error, :request_sent?
    end

    private

    # Runs the transport with a fake Net::HTTP that raises `klass` either in
    # #start (connect phase) or in #request (exchange phase).
    def phase_error(klass, phase, closes: false)
      fake = Object.new
      started = false
      fake.define_singleton_method(:start) { phase == :connect ? raise(klass) : started = true }
      fake.define_singleton_method(:started?) { started }
      fake.define_singleton_method(:finish) { started = false }
      fake.define_singleton_method(:request) do |*|
        started = false if closes # Net::HTTP may close the socket itself before raising
        raise klass
      end
      transport = Class.new(HTTP::NetHttpTransport) { define_method(:build_http) { |*| fake } }.new(env: {})
      request = HTTP::Request.new(method: :post, url: "https://example.net/email", headers: {}, body: "{}")
      error = assert_raises(ConnectionError) do
        transport.call(request, open_timeout: 1, read_timeout: 1, write_timeout: 1)
      end
      refute started, "the connection is always closed"
      error
    end
  end
end
