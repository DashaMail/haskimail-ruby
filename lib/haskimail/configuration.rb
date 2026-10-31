# frozen_string_literal: true

require "monitor"
require "uri"

require_relative "errors"

# Ruby SDK for the Haskimail transactional email API.
module Haskimail
  # Client settings. A global instance lives in {Haskimail.configuration};
  # every client takes a frozen snapshot of it at construction time, so
  # changing global settings later never affects clients that already exist.
  #
  #   Haskimail.configure do |config|
  #     config.read_timeout = 15
  #     config.max_retries  = 3
  #     config.logger       = Rails.logger
  #   end
  class Configuration
    # Production API endpoint.
    DEFAULT_BASE_URL = "https://api.haskimail.ru"

    # Every setting, in the order shown by #inspect.
    ATTRIBUTES = %i[
      base_url open_timeout read_timeout write_timeout max_retries
      logger proxy ca_file user_agent
    ].freeze

    # @!attribute [r] base_url
    #   @return [String] API endpoint (HTTPS)
    # @!attribute [r] open_timeout
    #   @return [Numeric] seconds to establish the connection
    # @!attribute [r] read_timeout
    #   @return [Numeric] seconds to wait for each read
    # @!attribute [r] write_timeout
    #   @return [Numeric] seconds to wait for each write
    # @!attribute [r] max_retries
    #   @return [Integer] automatic retries (0..10)
    # @!attribute [r] logger
    #   @return [Logger, nil] request log without tokens or addresses
    # @!attribute [r] proxy
    #   @return [URI::HTTP, false, nil] explicit proxy; false = direct; nil = from the environment
    # @!attribute [r] ca_file
    #   @return [String, nil] extra trusted CA bundle
    # @!attribute [r] user_agent
    #   @return [String, nil] suffix of the User-Agent header
    attr_reader :base_url, :open_timeout, :read_timeout, :write_timeout, :max_retries,
                :logger, :proxy, :ca_file, :user_agent

    def initialize(**options)
      @base_url = DEFAULT_BASE_URL
      @open_timeout = 5
      @read_timeout = 30
      @write_timeout = 30
      @max_retries = 2
      @logger = nil
      @proxy = nil
      @ca_file = nil
      @user_agent = nil
      update(**options)
    end

    # Bulk assignment with validation.
    # @return [self]
    def update(**options)
      unknown = options.keys - ATTRIBUTES
      raise ConfigurationError, "Unknown option(s): #{unknown.join(', ')}" unless unknown.empty?

      # All-or-nothing: validate on a copy, then apply.
      staged = dup
      options.each { |key, value| staged.public_send(:"#{key}=", value) }
      ATTRIBUTES.each { |key| instance_variable_set(:"@#{key}", staged.public_send(key)) }
      self
    end

    # HTTPS URL without credentials, query or fragment.
    def base_url=(value)
      @base_url = self.class.normalize_base_url(value)
    end

    # Seconds to establish the connection.
    def open_timeout=(value)
      @open_timeout = positive_number!(:open_timeout, value)
    end

    # Seconds to wait for each read of the response.
    def read_timeout=(value)
      @read_timeout = positive_number!(:read_timeout, value)
    end

    # Seconds to wait for each write of the request.
    def write_timeout=(value)
      @write_timeout = positive_number!(:write_timeout, value)
    end

    # Automatic retries after a failed attempt (0..10), see HTTP::RetryPolicy.
    def max_retries=(value)
      unless value.is_a?(Integer) && value.between?(0, 10)
        raise ConfigurationError, "max_retries must be an Integer between 0 and 10"
      end

      @max_retries = value
    end

    # Any object responding to #debug/#info/#warn (Logger, Rails.logger...).
    def logger=(value)
      unless value.nil? || %i[debug info warn].all? { |m| value.respond_to?(m) }
        raise ConfigurationError, "logger must respond to #debug, #info and #warn"
      end

      @logger = value
    end

    # Explicit HTTP proxy, e.g. "http://user:pass@proxy.local:3128". Traffic to
    # Haskimail is still end-to-end TLS through the proxy (CONNECT tunnel).
    # When nil, the `https_proxy`, `HTTPS_PROXY` or `http_proxy` environment
    # variable is used (with `no_proxy`), validated the same way; `false`
    # connects directly and ignores the environment.
    def proxy=(value)
      @proxy = value.nil? || value == false ? value : self.class.parse_proxy(value)
    end

    # Path to a PEM bundle of CAs trusted in addition to the system CAs
    # (e.g. a corporate TLS proxy). Verification itself can never be disabled.
    def ca_file=(value)
      raise ConfigurationError, "ca_file #{value.inspect} does not exist" if value && !File.file?(value.to_s)

      @ca_file = value&.to_s&.freeze
    end

    # Suffix appended to the SDK User-Agent, e.g. "my-shop/2.1".
    # Visible ASCII and spaces only (it becomes an HTTP header value).
    def user_agent=(value)
      if !value.nil? && !value.to_s.b.match?(/\A[\x20-\x7e]*\z/n)
        raise ConfigurationError, "user_agent may contain only printable ASCII characters"
      end

      @user_agent = value.nil? ? nil : value.to_s.dup.freeze
    end

    # Proxy password is masked; use #proxy for the real value.
    def to_h
      ATTRIBUTES.to_h { |key| [key, key == :proxy ? redacted_proxy : public_send(key)] }
    end

    # Like #to_h: the proxy password is masked.
    def inspect
      "#<#{self.class.name} #{to_h.map { |key, value| "#{key}=#{value.inspect}" }.join(' ')}>"
    end
    alias to_s inspect

    # The proxy password must not end up in caches or dumps.
    def marshal_dump
      raise TypeError, "#{self.class.name} may hold credentials and cannot be marshalled"
    end

    # YAML (Psych) gets the redacted view, like #inspect.
    def encode_with(coder)
      coder.map = to_h.transform_keys(&:to_s).transform_values { |value| value.is_a?(String) ? value : value.inspect }
    end

    # @api private
    # Validates a proxy URL. Net::HTTP talks to proxies in plain text, so an
    # https:// proxy would silently send its credentials unencrypted: refused.
    # @return [URI::HTTP] frozen
    def self.parse_proxy(value, source: "proxy")
      text = value.to_s.strip
      text = "http://#{text}" unless text.include?("://") # "proxy.local:3128", as in many environments
      uri = URI.parse(text)
      unless uri.scheme == "http" && !uri.host.to_s.empty?
        raise ConfigurationError, "#{source} must be an http:// URL (TLS to the proxy is not supported by Net::HTTP)"
      end

      uri.freeze
    rescue URI::InvalidURIError
      raise ConfigurationError, "#{source} is not a valid URL"
    end

    # @api private
    # @return [String] frozen base URL without a trailing slash
    def self.normalize_base_url(value)
      uri = URI.parse(value.to_s)
      raise ConfigurationError, "base_url must use https" unless uri.scheme == "https"
      raise ConfigurationError, "base_url must contain a host" if uri.host.nil? || uri.host.empty?
      raise ConfigurationError, "base_url must not contain credentials" if uri.userinfo
      raise ConfigurationError, "base_url must not contain a query or fragment" if uri.query || uri.fragment

      uri.to_s.chomp("/").freeze
    rescue URI::InvalidURIError
      raise ConfigurationError, "base_url is not a valid URL"
    end

    private

    def redacted_proxy
      proxy = @proxy
      return proxy unless proxy
      return proxy.to_s unless proxy.userinfo

      # A lone user name may itself be a token, so it is masked too.
      user = proxy.password ? "#{proxy.user}:[FILTERED]" : "[FILTERED]"
      "#{proxy.scheme}://#{user}@#{proxy.host}:#{proxy.port}"
    end

    def positive_number!(name, value)
      return value if value.is_a?(Numeric) && value.positive?

      raise ConfigurationError, "#{name} must be a positive number of seconds"
    end
  end

  # Global defaults live here (not in haskimail.rb) so that every file of the
  # gem can be required on its own.
  @configuration = Configuration.new.freeze
  # Re-entrant: reading the configuration inside a configure block is fine.
  @config_mutex = Monitor.new

  class << self
    # Global defaults (frozen), snapshotted by every client when it is created.
    # Change them with {configure}.
    # @return [Configuration]
    def configuration
      @config_mutex.synchronize { @configuration }
    end

    # Changes global defaults atomically: if the block raises, nothing changes.
    #
    #   Haskimail.configure { |config| config.max_retries = 3 }
    #
    # @yieldparam config [Configuration]
    def configure
      raise ConfigurationError, "Haskimail.configure needs a block" unless block_given?

      @config_mutex.synchronize do
        draft = @configuration.dup
        yield draft
        @configuration = draft.freeze
      end
    end

    # Restores defaults (handy in tests).
    def reset_configuration!
      @config_mutex.synchronize { @configuration = Configuration.new.freeze }
    end
  end
end
