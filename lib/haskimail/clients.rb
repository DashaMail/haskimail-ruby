# frozen_string_literal: true

require_relative "base_client"
require_relative "resources/emails"
require_relative "resources/templates"
require_relative "resources/messages"
require_relative "resources/server_resources"
require_relative "resources/account_resources"

module Haskimail
  # Token that validates send requests without sending anything.
  TEST_TOKEN = "HASKIMAIL_API_TEST"

  # Client authenticated with a server token (`X-Haskimail-Server-Token`):
  # everything that belongs to one server, including sending email.
  #
  #   client = Haskimail::ServerClient.new(ENV.fetch("HASKIMAIL_SERVER_TOKEN"))
  #   client.emails.deliver(from: "shop@example.com", to: "ivan@example.com",
  #                         subject: "Привет", text_body: "Привет!")
  #
  # Pass {Haskimail::TEST_TOKEN} to validate send requests without sending.
  # Instances are immutable and safe to share between threads.
  class ServerClient < BaseClient
    # Header that carries the server token.
    TOKEN_HEADER = "X-Haskimail-Server-Token"

    # @return [Resources::Emails]
    attr_reader :emails
    # @return [Resources::Templates]
    attr_reader :templates
    # @return [Resources::Messages]
    attr_reader :messages
    # @return [Resources::Opens]
    attr_reader :opens
    # @return [Resources::Clicks]
    attr_reader :clicks
    # @return [Resources::InboundMessages]
    attr_reader :inbound_messages
    # @return [Resources::Bounces]
    attr_reader :bounces
    # @return [Resources::MessageStreams]
    attr_reader :message_streams
    # @return [Resources::Suppressions]
    attr_reader :suppressions
    # @return [Resources::Webhooks]
    attr_reader :webhooks
    # @return [Resources::InboundRules]
    attr_reader :inbound_rules
    # @return [Resources::Stats]
    attr_reader :stats

    # @param token [String, nil] server token; defaults to ENV["HASKIMAIL_SERVER_TOKEN"]
    def initialize(token = ENV.fetch("HASKIMAIL_SERVER_TOKEN", nil), **options)
      super
    end

    protected

    # Name of the authentication header.
    def token_header
      TOKEN_HEADER
    end

    # Creates the resource objects available with this token.
    def build_resources
      @emails = Resources::Emails.new(self)
      @templates = Resources::Templates.new(self)
      @messages = Resources::Messages.new(self)
      @opens = Resources::Opens.new(self)
      @clicks = Resources::Clicks.new(self)
      @inbound_messages = Resources::InboundMessages.new(self)
      @bounces = Resources::Bounces.new(self)
      @message_streams = Resources::MessageStreams.new(self)
      @suppressions = Resources::Suppressions.new(self)
      @webhooks = Resources::Webhooks.new(self)
      @inbound_rules = Resources::InboundRules.new(self)
      @stats = Resources::Stats.new(self)
    end
  end

  # Client authenticated with the account token (`X-Haskimail-Account-Token`).
  #
  # Manages servers and domains, moves templates between servers and — as the
  # documentation allows for the account key — reads and manages data of all
  # servers of the account at once: templates, messages, opens, clicks,
  # bounces, message streams, webhooks and statistics.
  #
  # Sending email, inbound messages, inbound rules and suppression lists need a
  # server token: use {ServerClient} for them.
  #
  #   account = Haskimail::AccountClient.new(ENV.fetch("HASKIMAIL_ACCOUNT_TOKEN"))
  #   account.servers.each { |server| puts server.name }
  class AccountClient < BaseClient
    # Header that carries the account token.
    TOKEN_HEADER = "X-Haskimail-Account-Token"

    # @return [Resources::Servers]
    attr_reader :servers
    # @return [Resources::Domains]
    attr_reader :domains
    # @return [Resources::AccountTemplates]
    attr_reader :templates
    # @return [Resources::Messages]
    attr_reader :messages
    # @return [Resources::Opens]
    attr_reader :opens
    # @return [Resources::Clicks]
    attr_reader :clicks
    # @return [Resources::Bounces]
    attr_reader :bounces
    # With the account token `create` needs `server_id:`.
    # @return [Resources::MessageStreams]
    attr_reader :message_streams
    # With the account token pass `message_stream:` to `create` explicitly.
    # @return [Resources::Webhooks]
    attr_reader :webhooks
    # @return [Resources::Stats]
    attr_reader :stats

    # @param token [String, nil] account token; defaults to ENV["HASKIMAIL_ACCOUNT_TOKEN"]
    def initialize(token = ENV.fetch("HASKIMAIL_ACCOUNT_TOKEN", nil), **options)
      super
    end

    protected

    # Name of the authentication header.
    def token_header
      TOKEN_HEADER
    end

    # Creates the resource objects available with this token.
    def build_resources
      @servers = Resources::Servers.new(self)
      @domains = Resources::Domains.new(self)
      @templates = Resources::AccountTemplates.new(self)
      @messages = Resources::Messages.new(self)
      @opens = Resources::Opens.new(self)
      @clicks = Resources::Clicks.new(self)
      @bounces = Resources::Bounces.new(self)
      @message_streams = Resources::MessageStreams.new(self)
      @webhooks = Resources::Webhooks.new(self)
      @stats = Resources::Stats.new(self)
    end
  end
end
