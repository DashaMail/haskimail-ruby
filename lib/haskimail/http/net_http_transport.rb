# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"
require "zlib"

require_relative "../errors"
require_relative "../redacted"
require_relative "../configuration"
require_relative "../util"

module Haskimail
  module HTTP
    # Header names whose values are never printed.
    SENSITIVE_HEADERS = %w[x-haskimail-server-token x-haskimail-account-token authorization].freeze

    # Immutable HTTP request handed to a transport. A plain class (not a
    # Struct) so that no generic accessor — #to_h, #to_a, pp — exposes the token.
    class Request
      include Redacted

      attr_reader :method, :url, :headers, :body, :idempotent

      # @param idempotent [Boolean, nil] nil decides by HTTP method; false for
      #   PUTs with side effects (e.g. re-delivering an inbound message)
      def initialize(method:, url:, headers:, body:, idempotent: nil)
        @method = method
        @url = url
        @headers = headers
        @body = body
        @idempotent = idempotent
        freeze
      end

      def idempotent?
        return idempotent unless idempotent.nil?

        %i[get put delete head options].include?(method)
      end

      # Sensitive header values are replaced with [FILTERED].
      def inspect
        safe = headers.to_h { |name, value| [name, SENSITIVE_HEADERS.include?(name.downcase) ? "[FILTERED]" : value] }
        "#<#{self.class.name} method=#{method.inspect} url=#{url.inspect} headers=#{safe.inspect} " \
          "body=#{body ? "#{body.bytesize} bytes" : 'nil'}>"
      end
      alias to_s inspect

      # `pp` shows the same redacted text as #inspect.
      def pretty_print(printer)
        printer.text(inspect)
      end
    end

    # Immutable HTTP response returned by a transport.
    # `headers` keys are lower-case Strings.
    class Response
      # @return [Integer] HTTP status
      attr_reader :status
      # @return [Hash{String => String}] lower-case header names
      attr_reader :headers
      # @return [String] raw body
      attr_reader :body

      def initialize(status:, headers:, body:)
        @status = status
        @headers = headers
        @body = body
        freeze
      end

      # Same status, headers and body.
      def ==(other)
        other.instance_of?(self.class) && [other.status, other.headers, other.body] == [status, headers, body]
      end
    end

    # Default transport built on Net::HTTP from the standard library.
    #
    # Security properties:
    # * TLS certificate and hostname verification is always on (VERIFY_PEER);
    # * TLS 1.2 is the minimum protocol version;
    # * redirects are never followed (credentials cannot leak to another host);
    # * a fresh connection per request — the transport is thread-safe.
    #
    # Whether a failed request may have reached Haskimail is decided by the
    # phase it failed in, not by the error class: anything raised while
    # connecting (DNS, TCP, proxy CONNECT, TLS handshake) means "not sent";
    # anything raised after the connection is up means "maybe sent".
    #
    # Any object with `#call(request, open_timeout:, read_timeout:, write_timeout:)`
    # returning {Response} can replace it via `transport:` client option.
    class NetHttpTransport
      include Redacted

      # Net::HTTPBadResponse and Net::HTTPHeaderSyntaxError are plain
      # StandardErrors, not Net::ProtocolErrors, so they are listed explicitly.
      CONNECT_ERRORS = [
        SocketError, IOError, Net::ProtocolError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, SystemCallError
      ].freeze

      EXCHANGE_ERRORS = (CONNECT_ERRORS + [Zlib::Error]).freeze

      # Protection against decompression bombs and runaway responses.
      MAX_RESPONSE_SIZE = 64 * 1024 * 1024

      class ResponseTooLarge < StandardError; end

      METHODS = {
        get: Net::HTTP::Get,
        post: Net::HTTP::Post,
        put: Net::HTTP::Put,
        patch: Net::HTTP::Patch,
        delete: Net::HTTP::Delete
      }.freeze
      private_constant :CONNECT_ERRORS, :EXCHANGE_ERRORS, :METHODS, :ResponseTooLarge

      # Environment variables checked for a proxy, in this order. http_proxy
      # is kept as a fallback because Net::HTTP itself uses it for HTTPS too.
      # Upper-case HTTP_PROXY is ignored on purpose: CGI servers set it from
      # the request header "Proxy:" ("httpoxy").
      PROXY_ENV = %w[https_proxy HTTPS_PROXY http_proxy].freeze

      # @param proxy [URI::Generic, false, nil] explicit proxy; false connects
      #   directly; nil reads {PROXY_ENV} (honouring no_proxy)
      # @param ca_file [String, nil] PEM bundle trusted IN ADDITION to the system CAs
      # @param env [Hash] environment (injectable for tests)
      # @raise [ConfigurationError] for an invalid or https:// proxy in the environment
      def initialize(proxy: nil, ca_file: nil, env: ENV)
        from_env = proxy.nil?
        @proxy = from_env ? self.class.env_proxy(env) : (proxy || nil)
        @no_proxy = self.class.normalize_no_proxy(env["no_proxy"] || env["NO_PROXY"]) if from_env
        @cert_store = ca_file && self.class.cert_store(ca_file)
        freeze
      end

      # @api private
      # no_proxy in URI#find_proxy form. Also accepts the conventions of
      # curl and most other tools: "*" (no proxy at all) and "*.example.com".
      # @return [String, false] false when every host bypasses the proxy
      def self.normalize_no_proxy(value)
        entries = value.to_s.split(/[\s,]+/).reject(&:empty?)
        return false if entries.include?("*")

        entries.map { |entry| entry.sub(/\A\*\./, ".") }.join(",").freeze
      end

      # @api private
      # System CAs plus the given bundle. (Setting Net::HTTP#ca_file instead
      # would replace the system CAs: a corporate-proxy CA configured
      # globally would then break direct connections to Haskimail.)
      # @return [OpenSSL::X509::Store]
      # @raise [ConfigurationError] when the file is not a readable PEM bundle
      def self.cert_store(ca_file)
        store = OpenSSL::X509::Store.new
        store.set_default_paths
        store.add_file(ca_file.to_s)
        store
      rescue OpenSSL::X509::StoreError, SystemCallError => e
        raise ConfigurationError, "ca_file #{ca_file.inspect} cannot be loaded: #{e.message}"
      end

      # @api private
      # @return [URI::HTTP, nil] validated proxy from the environment
      def self.env_proxy(env)
        name = PROXY_ENV.find { |key| !Util.blank?(env[key]) }
        name && Configuration.parse_proxy(env[name], source: name)
      end

      # @param request [Request]
      # @return [Response]
      def call(request, open_timeout:, read_timeout:, write_timeout:)
        uri = URI.parse(request.url)
        net_request = build_request(request, uri)
        http = build_http(uri, open_timeout, read_timeout, write_timeout)
        connect(http, uri)
        begin
          exchange(http, net_request, uri)
        ensure
          http.finish if http.started?
        end
      end

      # Shows whether a proxy is used, never its credentials.
      def inspect
        "#<#{self.class.name} proxy=#{@proxy ? '[set]' : 'none'}>"
      end

      private

      # DNS, TCP, proxy CONNECT and TLS handshake: nothing has been sent yet.
      def connect(http, uri)
        http.start
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout => e
        # Read/write timeouts here come from a proxy that never answers CONNECT.
        raise TimeoutError.new("Connection to #{uri.host} timed out", original_error: e, request_sent: false)
      rescue OpenSSL::SSL::SSLError => e
        # Never retried: a certificate problem is not transient and may signal an attack.
        raise TlsError.new("TLS error talking to #{uri.host}: #{e.message}", original_error: e, request_sent: false)
      rescue *CONNECT_ERRORS => e
        raise ConnectionError.new("Could not connect to #{uri.host}: #{e.class}: #{e.message}",
                                  original_error: e, request_sent: false)
      end

      # Sends the request and reads the body in chunks, so an oversized
      # response is cut off early. Any failure here may come after Haskimail
      # received the request.
      def exchange(http, net_request, uri)
        body = +""
        net_response = http.request(net_request) do |response|
          response.read_body do |chunk|
            body << chunk
            raise ResponseTooLarge if body.bytesize > MAX_RESPONSE_SIZE
          end
        end
        Response.new(status: net_response.code.to_i, headers: net_response.each_header.to_h,
                     body: body.force_encoding(Encoding::UTF_8))
      rescue ResponseTooLarge => e
        raise ConnectionError.new("Response from #{uri.host} exceeds #{MAX_RESPONSE_SIZE} bytes", original_error: e)
      rescue Net::ReadTimeout, Net::WriteTimeout => e
        raise TimeoutError.new("Request to #{uri.host} timed out", original_error: e)
      rescue OpenSSL::SSL::SSLError => e
        raise TlsError.new("TLS error talking to #{uri.host}: #{e.message}", original_error: e)
      rescue *EXCHANGE_ERRORS => e
        raise ConnectionError.new("Connection to #{uri.host} failed: #{e.class}: #{e.message}", original_error: e)
      end

      def build_http(uri, open_timeout, read_timeout, write_timeout)
        # Net::HTTP is never left to read the environment itself: it would
        # use http_proxy unchecked and ignore https_proxy.
        proxy = @proxy if @proxy && use_proxy?(uri)
        http = if proxy
                 Net::HTTP.new(uri.host, uri.port, proxy.host, proxy.port, decode(proxy.user), decode(proxy.password))
               else
                 Net::HTTP.new(uri.host, uri.port, nil)
               end
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.min_version = OpenSSL::SSL::TLS1_2_VERSION
        http.cert_store = @cert_store if @cert_store
        http.open_timeout = open_timeout
        http.read_timeout = read_timeout
        http.write_timeout = write_timeout
        http.max_retries = 0 # retries are handled by the client with proper rules
        http
      end

      def build_request(request, uri)
        klass = METHODS.fetch(request.method) do
          raise ValidationError, "Unsupported HTTP method #{request.method.inspect}"
        end
        net_request = klass.new(uri.request_uri)
        request.headers.each { |name, value| net_request[name] = value }
        net_request.body = request.body if request.body
        net_request
      end

      # Same rules as URI#find_proxy: an environment proxy is skipped for
      # loopback addresses and for hosts matched by no_proxy (names, domain
      # suffixes, IP ranges in CIDR form). An explicit proxy is always used.
      def use_proxy?(uri)
        no_proxy = @no_proxy
        return true if no_proxy.nil?
        return false if no_proxy == false

        address = resolve(uri.hostname.to_s)
        return false if address&.match?(/\A127\.|\A::1\z/)

        # An unresolved name ("") is matched by name only, exactly like nil.
        URI::Generic.use_proxy?(uri.hostname.to_s, address.to_s, uri.port || 443, no_proxy)
      end

      def resolve(host)
        IPSocket.getaddress(host)
      rescue SocketError
        nil
      end

      # Percent-decoding of URL user info ("+" stays "+", unlike form decoding).
      def decode(value)
        return nil if value.nil?

        value.b.gsub(/%\h\h/n) { |escape| escape.delete_prefix("%").hex.chr }.force_encoding(Encoding::UTF_8)
      end
    end
  end
end
