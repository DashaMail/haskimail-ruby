# frozen_string_literal: true

require "time"

require_relative "../errors"

module Haskimail
  # HTTP layer: requests, transport, response parsing and retry rules.
  module HTTP
    # Decides whether a failed attempt may be repeated and how long to wait.
    #
    # The rule of thumb: never repeat a request the server may already have
    # executed — a duplicate email is worse than an error.
    class RetryPolicy
      # Statuses retried for idempotent requests.
      RETRYABLE_STATUSES = [429, 500, 502, 503, 504].freeze
      # "Refused before processing": the documentation says to repeat the
      # request later, so even a POST is safe. 500/502/504 are excluded for
      # POST — the email may already be accepted.
      REFUSED_STATUSES = [429, 503].freeze
      # ErrorCode 36 — "Временная ошибка отправки. Повторите запрос позже":
      # the email was not accepted.
      RETRYABLE_ERROR_CODES = [ErrorCodes::TEMPORARY_SENDING_ERROR].freeze
      # ErrorCode 100 — "Внутренняя ошибка. Повторите запрос позже": repeated
      # only for idempotent requests (a send may have been processed).
      IDEMPOTENT_RETRYABLE_ERROR_CODES = [ErrorCodes::INTERNAL_ERROR].freeze
      # Upper bound for Retry-After, seconds.
      MAX_RETRY_AFTER = 30
      # First backoff step, seconds (doubles each attempt).
      BASE_DELAY = 0.5
      # Upper bound of the backoff, seconds.
      MAX_DELAY = 8.0

      attr_reader :max_retries

      # @param max_retries [Integer]
      # @param random [#rand] source of jitter (injectable for tests)
      # @param clock [#call] current Time, for Retry-After dates (injectable for tests)
      def initialize(max_retries:, random: Random, clock: -> { Time.now })
        @max_retries = max_retries
        @random = random
        @clock = clock
        freeze
      end

      # @param error_code [Integer, nil] API ErrorCode of the response body
      def retry_response?(request, response, error_code, attempt)
        return false if attempt >= max_retries

        if RETRYABLE_STATUSES.include?(response.status)
          return request.idempotent? || REFUSED_STATUSES.include?(response.status)
        end

        return false unless response.status == 422

        RETRYABLE_ERROR_CODES.include?(error_code) ||
          (request.idempotent? && IDEMPOTENT_RETRYABLE_ERROR_CODES.include?(error_code))
      end

      # TLS failures are never repeated; other network errors are repeated for
      # idempotent requests, or when the request certainly never left.
      def retry_error?(request, error, attempt)
        return false if attempt >= max_retries || error.is_a?(TlsError)

        request.idempotent? || !error.request_sent?
      end

      # Seconds to wait before attempt number `attempt` (1-based retry count):
      # Retry-After when the server sent one, otherwise exponential backoff
      # with "equal jitter".
      def delay(attempt, response = nil)
        retry_after(response) || begin
          base = [BASE_DELAY * (2**(attempt - 1)), MAX_DELAY].min
          (base / 2) + (@random.rand * base / 2)
        end
      end

      private

      # Retry-After as delta-seconds or an HTTP date, capped at MAX_RETRY_AFTER.
      def retry_after(response)
        value = response&.headers&.fetch("retry-after", nil).to_s.b.strip
        return nil if value.empty?

        seconds = value.match?(/\A\d+\z/) ? value.to_i : (Time.httpdate(value) - @clock.call).ceil
        seconds.clamp(0, MAX_RETRY_AFTER).to_f
      rescue ArgumentError
        nil
      end
    end
  end
end
