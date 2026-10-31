# frozen_string_literal: true

require_relative "../errors"
require_relative "../util"

module Haskimail
  module HTTP
    # @api private
    # Turns an HTTP response into data or into the matching {ApiError}.
    module ResponseParser
      # Error class raised for each HTTP status (others: see #error_class).
      ERROR_CLASSES = {
        401 => AuthenticationError,
        403 => ForbiddenError,
        404 => NotFoundError,
        413 => PayloadTooLargeError,
        422 => UnprocessableEntityError,
        429 => RateLimitError,
        503 => ServiceUnavailableError
      }.freeze

      module_function

      # @return [Hash, Array, nil] parsed JSON; nil for an empty or non-JSON body
      def parse(response)
        body = response.body.to_s
        return nil if blank_body?(body)

        Util.parse_json(body)
      rescue JSON::ParserError # includes JSON::NestingError
        nil
      end

      # True for an empty or whitespace-only body.
      def blank_body?(body)
        body.to_s.b.strip.empty?
      end

      # ErrorCode as Integer; the API may also send it as a numeric String.
      # @return [Integer, nil] nil when absent or not an integral number
      def error_code(data)
        value = data.is_a?(Hash) ? data["ErrorCode"] : nil
        case value
        when Integer then value
        when Float then value.to_i if value.finite? && value == value.floor
        when String then Integer(value.strip, 10, exception: false)
        end
      end

      # True when ErrorCode is present but is not a number: the outcome of
      # the request cannot be determined.
      def malformed_error_code?(data)
        data.is_a?(Hash) && !data["ErrorCode"].nil? && error_code(data).nil?
      end

      # A 2xx carrying a non-zero ErrorCode is still a failure (single objects
      # only: batch arrays report per-item errors and never raise).
      def success?(response, data)
        return false unless (200..299).cover?(response.status)
        return true unless data.is_a?(Hash) && !data["ErrorCode"].nil?

        error_code(data)&.zero? || false
      end

      # @return [ApiError]
      def api_error(response, data)
        code = error_code(data)
        message = data.is_a?(Hash) ? data["Message"] : nil
        status = response.status

        text = "HTTP #{status}"
        text += " [ErrorCode #{code}]" if code
        text += ": #{message}" unless message.to_s.empty?
        text += ": #{response.body.to_s[0, 200]}" if data.nil? && !response.body.to_s.empty?

        error_class(status).new(text, http_status: status, error_code: code, api_message: message,
                                      response_body: response.body, response_headers: response.headers)
      end

      # A 2xx whose body cannot be interpreted: not JSON (e.g. a proxy page)
      # or an ErrorCode that is not a number.
      # @return [UnexpectedResponseError]
      def unexpected_body_error(request, response, reason = "a non-JSON body")
        text = "HTTP #{response.status} with #{reason}: #{response.body.to_s[0, 200]}"
        unless request.idempotent?
          text += " (the request may have been executed — for a send, check the message log before re-sending)"
        end
        UnexpectedResponseError.new(text, http_status: response.status, response_body: response.body,
                                          response_headers: response.headers)
      end

      # @return [Class] the ApiError subclass for an HTTP status
      def error_class(status)
        ERROR_CLASSES.fetch(status) do
          case status
          when 500.. then ServerError
          when 200..299 then UnprocessableEntityError
          else ApiError
          end
        end
      end
    end
  end
end
