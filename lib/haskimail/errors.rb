# frozen_string_literal: true

module Haskimail
  # Base class for every error raised by this library.
  # `rescue Haskimail::Error` catches every failure of an API call, of input
  # validation and of webhook parsing. Only calling a Ruby method with the
  # wrong arguments (e.g. a missing keyword) raises Ruby's own ArgumentError.
  class Error < StandardError; end

  # Invalid client configuration (missing token, non-HTTPS base URL, bad timeout...).
  class ConfigurationError < Error; end

  # The request was rejected on the client side before anything was sent.
  class ValidationError < Error; end

  # Webhook payload signature does not match.
  class SignatureVerificationError < Error; end

  # Webhook body is larger than the configured limit. A subclass of
  # ValidationError, so answer it with a 413 rather than a 403: for inbound
  # email a 403 stops Haskimail's retries and the message is lost.
  class WebhookPayloadTooLargeError < ValidationError; end

  # Network-level failure: DNS, refused connection, TLS, timeout.
  class ConnectionError < Error
    # @return [Exception, nil] the low-level exception
    attr_reader :original_error

    def initialize(message = nil, original_error: nil, request_sent: true)
      super(message)
      @original_error = original_error
      @request_sent = request_sent
    end

    # `false` means the request certainly never reached Haskimail, so even a
    # non-idempotent call (sending an email) is safe to repeat.
    def request_sent?
      @request_sent
    end
  end

  # Connect, read or write timeout.
  class TimeoutError < ConnectionError; end

  # TLS handshake or certificate verification failure. Never retried.
  class TlsError < ConnectionError; end

  # Haskimail answered with an error. Carries the HTTP status and the API
  # `ErrorCode` (see {Haskimail::ErrorCodes}).
  class ApiError < Error
    attr_reader :http_status, :error_code, :api_message, :response_body, :response_headers

    def initialize(message = nil, http_status: nil, error_code: nil, api_message: nil,
                   response_body: nil, response_headers: {})
      super(message)
      @http_status = http_status
      @error_code = error_code
      @api_message = api_message
      @response_body = response_body
      @response_headers = response_headers
    end

    # Description of {#error_code} from the documentation, if known.
    def error_code_description
      ErrorCodes.describe(error_code)
    end
  end

  # HTTP 401 — the token is missing, wrong, or of the wrong kind
  # (e.g. a server token used for account-level methods; ErrorCode 10).
  class AuthenticationError < ApiError; end

  # HTTP 403 — the IP address is not in the account allow-list.
  class ForbiddenError < ApiError; end

  # HTTP 404 — unknown API method or object.
  class NotFoundError < ApiError; end

  # HTTP 413 — the batch is larger than 50 MB.
  class PayloadTooLargeError < ApiError; end

  # HTTP 422 — validation failed; inspect {#error_code}.
  class UnprocessableEntityError < ApiError; end

  # HTTP 429 — not described in the docs, handled defensively.
  class RateLimitError < ApiError; end

  # HTTP 5xx — server-side failure. GET/PUT/DELETE are retried automatically;
  # a POST that got 500/502/504 MAY already have been executed (an email may
  # have been sent), so check the message log before repeating it.
  class ServerError < ApiError; end

  # HTTP 503 — temporary unavailability; the request was not executed.
  class ServiceUnavailableError < ServerError; end

  # A successful status with a body the SDK cannot interpret (not JSON, or
  # not the documented shape). For send calls the email MAY have been
  # accepted — check the message log before re-sending.
  class UnexpectedResponseError < ApiError; end

  # Numeric `ErrorCode` values documented at
  # https://haskimail.ru/developer/api/overview#error-codes
  module ErrorCodes
    # Неверный API-ключ.
    INVALID_API_TOKEN = 10
    # Объект не найден или неполный запрос.
    NOT_FOUND_OR_INCOMPLETE_REQUEST = 12
    # Внутренняя ошибка, повторите запрос позже.
    INTERNAL_ERROR = 100
    # Неизвестный метод API.
    UNKNOWN_API_METHOD = 404

    # Не все обязательные параметры.
    MISSING_REQUIRED_FIELDS = 3
    # Аккаунт не может отправлять.
    ACCOUNT_CANNOT_SEND = 4
    # Некорректный email-адрес.
    INVALID_EMAIL_ADDRESS = 6
    # Действие запрещено.
    ACTION_NOT_ALLOWED = 15
    # Слишком большое вложение.
    ATTACHMENT_TOO_LARGE = 26
    # Недопустимый тип вложения.
    INVALID_ATTACHMENT_TYPE = 33
    # Отправка недоступна.
    SENDING_UNAVAILABLE = 35
    # Временная ошибка отправки, повторите запрос позже.
    TEMPORARY_SENDING_ERROR = 36
    # Некорректные заголовки письма.
    INVALID_HEADERS = 40
    # Адрес отправителя не подтвержден.
    SENDER_SIGNATURE_NOT_CONFIRMED = 52
    # Неверное значение поля или неверный пакет писем.
    INVALID_FIELD_VALUE_OR_BATCH = 300
    # Отправитель не подтвержден (аккаунт на модерации).
    SENDER_NOT_CONFIRMED = 400
    # Неверное поле запроса (тестовый режим).
    INVALID_REQUEST_FIELD = 403
    # Запрещенный тип вложения (тестовый режим).
    FORBIDDEN_ATTACHMENT_TYPE = 411
    # Получатель не подтвержден (аккаунт на модерации).
    RECIPIENT_NOT_CONFIRMED = 412
    # Шаблон не найден.
    TEMPLATE_NOT_FOUND = 1101
    # Канал не найден.
    MESSAGE_STREAM_NOT_FOUND = 1226
    # Через входящий канал нельзя отправлять письма.
    CANNOT_SEND_VIA_INBOUND_STREAM = 1236

    # Неверные параметры запроса сообщений.
    INVALID_MESSAGES_QUERY = 700
    # Сообщение не найдено.
    MESSAGE_NOT_FOUND = 701
    # Пропустить можно только заблокированное входящее письмо.
    BYPASS_ONLY_BLOCKED = 702
    # Повторить можно только входящее письмо с ошибкой.
    RETRY_ONLY_FAILED = 703
    # Неверные параметры запроса правил.
    INVALID_RULE_REQUEST = 800
    # Такое правило уже есть.
    RULE_ALREADY_EXISTS = 810
    # Правило не найдено.
    RULE_NOT_FOUND = 812
    # Неверное правило.
    INVALID_RULE = 813

    # Не найден домен или сервер.
    DOMAIN_OR_SERVER_NOT_FOUND = 510
    # Домен уже добавлен.
    DOMAIN_ALREADY_EXISTS = 512
    # Неверный формат домена.
    INVALID_DOMAIN = 516
    # Нечего проверять или неверная модель.
    TEMPLATE_VALIDATION_NOTHING_TO_CHECK = 1120

    # Некорректный входящий домен.
    INVALID_INBOUND_DOMAIN = 600
    # Входящий домен уже используется.
    INBOUND_DOMAIN_IN_USE = 602
    # Неверный InboundHookUrl.
    INVALID_INBOUND_HOOK_URL = 606
    # У входящего домена нет MX-записи inbound.haskimail.ru.
    INBOUND_DOMAIN_MISSING_MX = 610
    # Неверный InboundSpamThreshold.
    INVALID_INBOUND_SPAM_THRESHOLD = 611

    # Неверный MessageStreamType.
    INVALID_MESSAGE_STREAM_TYPE = 1221
    # Входящий канал создать нельзя.
    CANNOT_CREATE_INBOUND_STREAM = 1228
    # Входящий канал нельзя архивировать.
    CANNOT_ARCHIVE_INBOUND_STREAM = 1229

    # Russian description of every documented code.
    DESCRIPTIONS = {
      INVALID_API_TOKEN => "Неверный API-ключ",
      NOT_FOUND_OR_INCOMPLETE_REQUEST => "Объект не найден или неполный запрос",
      INTERNAL_ERROR => "Внутренняя ошибка, повторите запрос позже",
      UNKNOWN_API_METHOD => "Неизвестный метод API",
      MISSING_REQUIRED_FIELDS => "Не все обязательные параметры",
      ACCOUNT_CANNOT_SEND => "Аккаунт не может отправлять",
      INVALID_EMAIL_ADDRESS => "Некорректный email-адрес",
      ACTION_NOT_ALLOWED => "Действие запрещено",
      ATTACHMENT_TOO_LARGE => "Слишком большое вложение",
      INVALID_ATTACHMENT_TYPE => "Недопустимый тип вложения",
      SENDING_UNAVAILABLE => "Отправка недоступна",
      TEMPORARY_SENDING_ERROR => "Временная ошибка отправки, повторите запрос позже",
      INVALID_HEADERS => "Некорректные заголовки письма",
      SENDER_SIGNATURE_NOT_CONFIRMED => "Адрес отправителя не подтвержден",
      INVALID_FIELD_VALUE_OR_BATCH => "Неверное значение поля или неверный пакет писем",
      SENDER_NOT_CONFIRMED => "Отправитель не подтвержден (аккаунт на модерации)",
      INVALID_REQUEST_FIELD => "Неверное поле запроса (тестовый режим)",
      FORBIDDEN_ATTACHMENT_TYPE => "Запрещенный тип вложения (тестовый режим)",
      RECIPIENT_NOT_CONFIRMED => "Получатель не подтвержден (аккаунт на модерации)",
      TEMPLATE_NOT_FOUND => "Шаблон не найден",
      MESSAGE_STREAM_NOT_FOUND => "Канал не найден",
      CANNOT_SEND_VIA_INBOUND_STREAM => "Через входящий канал нельзя отправлять письма",
      INVALID_MESSAGES_QUERY => "Неверные параметры запроса сообщений",
      MESSAGE_NOT_FOUND => "Сообщение не найдено",
      BYPASS_ONLY_BLOCKED => "Пропустить можно только заблокированное входящее письмо",
      RETRY_ONLY_FAILED => "Повторить можно только входящее письмо с ошибкой",
      INVALID_RULE_REQUEST => "Неверные параметры запроса правил",
      RULE_ALREADY_EXISTS => "Такое правило уже есть",
      RULE_NOT_FOUND => "Правило не найдено",
      INVALID_RULE => "Неверное правило",
      DOMAIN_OR_SERVER_NOT_FOUND => "Не найден домен или сервер",
      DOMAIN_ALREADY_EXISTS => "Домен уже добавлен",
      INVALID_DOMAIN => "Неверный формат домена",
      TEMPLATE_VALIDATION_NOTHING_TO_CHECK => "Нечего проверять или неверная модель",
      INVALID_INBOUND_DOMAIN => "Некорректный входящий домен",
      INBOUND_DOMAIN_IN_USE => "Входящий домен уже используется",
      INVALID_INBOUND_HOOK_URL => "Неверный InboundHookUrl",
      INBOUND_DOMAIN_MISSING_MX => "У входящего домена нет MX-записи inbound.haskimail.ru",
      INVALID_INBOUND_SPAM_THRESHOLD => "Неверный InboundSpamThreshold",
      INVALID_MESSAGE_STREAM_TYPE => "Неверный MessageStreamType",
      CANNOT_CREATE_INBOUND_STREAM => "Входящий канал создать нельзя",
      CANNOT_ARCHIVE_INBOUND_STREAM => "Входящий канал нельзя архивировать"
    }.freeze

    # @param code [Integer, nil]
    # @return [String, nil]
    def self.describe(code)
      DESCRIPTIONS[code]
    end
  end
end
