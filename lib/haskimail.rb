# frozen_string_literal: true

require_relative "haskimail/version"
require_relative "haskimail/errors"
require_relative "haskimail/redacted"
require_relative "haskimail/configuration"
require_relative "haskimail/util"
require_relative "haskimail/api_object"
require_relative "haskimail/attachment"
require_relative "haskimail/http/net_http_transport"
require_relative "haskimail/http/retry_policy"
require_relative "haskimail/http/response_parser"
require_relative "haskimail/base_client"
require_relative "haskimail/resources/base"
require_relative "haskimail/resources/emails"
require_relative "haskimail/resources/templates"
require_relative "haskimail/resources/messages"
require_relative "haskimail/resources/server_resources"
require_relative "haskimail/resources/account_resources"
require_relative "haskimail/clients"
require_relative "haskimail/webhook"
require_relative "haskimail/test_addresses"

# Ruby SDK for the Haskimail transactional email API.
# https://haskimail.ru/developer
module Haskimail
  class << self
    # Parses an API timestamp ("YYYY-MM-DD HH:MM:SS" in Moscow time) into Time.
    # @return [Time, nil]
    def parse_time(value)
      Util.parse_time(value)
    end
  end
end
