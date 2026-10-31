# frozen_string_literal: true

require_relative "version"
require_relative "redacted"
require_relative "errors"
require_relative "configuration"
require_relative "util"
require_relative "api_object"
require_relative "http/net_http_transport"
require_relative "http/retry_policy"
require_relative "http/response_parser"

module Haskimail
  # Shared HTTP plumbing for {ServerClient} and {AccountClient}:
  # authentication, JSON, error mapping, retries and logging.
  class BaseClient
    include Redacted

    # Methods accepted by #request.
    HTTP_METHODS = %i[get post put patch delete].freeze

    attr_reader :config

    # @param token [String] API token
    # @param transport [#call, nil] custom HTTP transport (see HTTP::NetHttpTransport)
    # @param sleeper [#call, nil] used between retries; injectable for tests
    # @param options [Hash] overrides of {Configuration} attributes
    def initialize(token, transport: nil, sleeper: nil, **options)
      @token = self.class.validate_token!(token)
      @config = Haskimail.configuration.dup.update(**options).freeze
      @transport = transport || HTTP::NetHttpTransport.new(proxy: @config.proxy, ca_file: @config.ca_file)
      @retry_policy = HTTP::RetryPolicy.new(max_retries: @config.max_retries)
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @user_agent = build_user_agent
      build_resources
      freeze
    end

    # Low-level escape hatch for endpoints not wrapped by the SDK.
    #
    #   client.request(:get, "/messages", query: { "count" => 10 })
    #
    # @param method [Symbol] :get, :post, :put, :patch, :delete
    # @param path [String] path starting with "/"
    # @param query [Hash] query string parameters (sent verbatim)
    # @param body [Hash, Array, nil] JSON body (sent verbatim, strings converted to UTF-8)
    # @return [ApiObject, Array, nil]
    def request(method, path, query: nil, body: nil)
      wrap(perform(method, path, query: query, body: body))
    end

    # The token is never shown.
    def inspect
      "#<#{self.class.name} base_url=#{config.base_url.inspect} token=[FILTERED]>"
    end
    alias to_s inspect

    # @api private
    def self.validate_token!(token)
      raise ConfigurationError, "API token is required" if Util.blank?(token)

      value = token.to_s.b
      unless value.match?(/\A[\x21-\x7e]+\z/n)
        raise ConfigurationError, "API token contains forbidden characters (spaces, line breaks or non-ASCII)"
      end

      value.dup.freeze
    end

    # @api private
    # Performs the request with retries and returns the parsed JSON (Hash/Array/nil).
    def perform(method, path, query: nil, body: nil, idempotent: nil)
      request = build_request(method, path, query, body, idempotent)
      attempt = 0

      loop do
        response = attempt_request(request, attempt)
        data = HTTP::ResponseParser.parse(response)
        if @retry_policy.retry_response?(request, response, HTTP::ResponseParser.error_code(data), attempt)
          attempt += 1
          pause(attempt, response, "HTTP #{response.status}")
          next
        end

        return checked(request, response, data)
      rescue ConnectionError => e
        raise unless @retry_policy.retry_error?(request, e, attempt)

        attempt += 1
        pause(attempt, nil, e.class.name)
      end
    end

    # @api private
    # Ensures a documented JSON-object response.
    def expect_object(data)
      return data if data.is_a?(Hash)

      raise UnexpectedResponseError.new("Expected a JSON object from Haskimail, got #{data.class}. " \
                                        "If this was a send request, the email MAY have been accepted — " \
                                        "check the message log before re-sending", http_status: 200)
    end

    # Wraps parsed JSON: objects become ApiObject, arrays are mapped.
    # @api private
    def wrap(data)
      case data
      when Hash then ApiObject.new(data)
      when Array then data.map { |item| item.is_a?(Hash) ? ApiObject.new(item) : item }
      else data
      end
    end

    protected

    # Name of the authentication header.
    def token_header
      raise NotImplementedError
    end

    # Subclasses create their resource objects here.
    def build_resources; end

    private

    def build_request(method, path, query, body, idempotent)
      unless HTTP_METHODS.include?(method)
        raise ValidationError, "HTTP method must be one of #{HTTP_METHODS.map(&:inspect).join(', ')}"
      end
      raise ValidationError, "path must start with '/'" unless path.is_a?(String) && path.start_with?("/")

      headers = { "Accept" => "application/json", "User-Agent" => @user_agent, token_header => @token }
      payload = nil
      unless body.nil?
        headers["Content-Type"] = "application/json"
        payload = Util.generate_json(Util.utf8_strings(body))
      end
      HTTP::Request.new(method: method, url: build_url(path, query), headers: headers.freeze, body: payload,
                        idempotent: idempotent)
    end

    def build_url(path, query)
      url = config.base_url + path
      url += "?#{URI.encode_www_form(query)}" if query && !query.empty?
      URI.parse(url)
      url
    rescue URI::InvalidURIError
      raise ValidationError, "Invalid request path #{path.inspect}"
    end

    def checked(request, response, data)
      if (200..299).cover?(response.status) && HTTP::ResponseParser.malformed_error_code?(data)
        raise HTTP::ResponseParser.unexpected_body_error(request, response, "a non-numeric ErrorCode")
      end
      raise HTTP::ResponseParser.api_error(response, data) unless HTTP::ResponseParser.success?(response, data)
      if data.nil? && !HTTP::ResponseParser.blank_body?(response.body)
        raise HTTP::ResponseParser.unexpected_body_error(request, response)
      end

      data
    end

    def attempt_request(request, attempt)
      started = monotonic_now
      response = @transport.call(request, open_timeout: config.open_timeout,
                                          read_timeout: config.read_timeout,
                                          write_timeout: config.write_timeout)
      log(:debug) do
        "Haskimail #{request.method.upcase} #{log_path(request)} -> #{response.status} " \
          "(#{((monotonic_now - started) * 1000).round} ms, attempt #{attempt + 1})"
      end
      response
    end

    def pause(attempt, response, reason)
      delay = @retry_policy.delay(attempt, response)
      log(:warn) { "Haskimail retry #{attempt}/#{config.max_retries} in #{delay.round(2)}s (#{reason})" }
      @sleeper.call(delay)
    end

    # The query string is never logged: it contains recipient addresses (personal data).
    def log_path(request)
      URI.parse(request.url).path
    end

    def log(level, &)
      config.logger&.public_send(level, &)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def build_user_agent
      agent = "haskimail-ruby/#{VERSION} ruby/#{RUBY_VERSION} (#{RUBY_PLATFORM})"
      config.user_agent ? "#{agent} #{config.user_agent}" : agent
    end
  end
end
