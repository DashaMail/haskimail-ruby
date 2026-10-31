# frozen_string_literal: true

require "date"
require "json"
require "time"
require "uri"

require_relative "errors"

module Haskimail
  # @api private
  # Internal helpers: request-key conversion, path escaping, date formatting.
  module Util
    # API field names that do not follow plain CamelCase of the snake_case key.
    IRREGULAR_KEYS = {
      id: "ID",
      server_id: "ServerID",
      template_id: "TemplateId",
      associated_server_id: "AssociatedServerId"
    }.freeze

    # Values under these keys are user data and are sent verbatim:
    # their keys are never renamed and nil values are kept.
    OPAQUE_KEYS = %w[Metadata TemplateModel TestRenderModel].freeze

    # The API interprets every timestamp as Moscow time.
    MOSCOW_OFFSET = "+03:00"
    # The same offset in seconds, for Time#getlocal.
    MOSCOW_UTC_OFFSET = 3 * 60 * 60

    # Characters that must never reach an email header: control characters
    # (except TAB) and Unicode line separators.
    UNSAFE_HEADER_CHARS = /[\x00-\x08\x0A-\x1F\x7F\u0085\u2028\u2029]/

    module_function

    # Converts a Ruby-style key into the API field name.
    #   :html_body  => "HtmlBody"
    #   :HtmlBody   => "HtmlBody"
    #   "HtmlBody"  => "HtmlBody" (strings are always taken verbatim)
    def api_key(key)
      case key
      when String then key
      when Symbol
        IRREGULAR_KEYS.fetch(key) do
          name = key.to_s
          name.match?(/[A-Z]/) ? name : name.split("_").map(&:capitalize).join
        end
      else
        raise ValidationError, "Field names must be Symbols or Strings, got #{key.class}"
      end
    end

    # Deep-converts a request body into API form: renames keys, drops nil
    # values (except inside opaque user data) and rejects duplicate fields
    # such as `{ html_body: "a", "HtmlBody" => "b" }`.
    def to_api(value, depth = 0)
      check_depth!(depth)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), result|
          next if item.nil?

          name = api_key(key)
          raise ValidationError, "Field #{name} is given more than once" if result.key?(name)

          result[name] = OPAQUE_KEYS.include?(name) ? utf8_strings(item, depth + 1) : to_api(item, depth + 1)
        end
      when Array then value.map { |item| to_api(item, depth + 1) }
      when String then utf8(value)
      else value.respond_to?(:to_haskimail) ? to_api(value.to_haskimail, depth + 1) : value
      end
    end

    # JSON is UTF-8: binary strings holding UTF-8 are relabelled, other
    # encodings converted. Broken text raises ValidationError (json 3.0 will
    # raise on binary input, so this keeps behaviour identical everywhere).
    def utf8(text)
      return text if text.encoding == Encoding::UTF_8 && text.valid_encoding?

      converted = if text.encoding == Encoding::BINARY
                    text.dup.force_encoding(Encoding::UTF_8)
                  else
                    text.encode(Encoding::UTF_8)
                  end
      raise ValidationError, "Text is not valid UTF-8: #{text.b[0, 40].inspect}" unless converted.valid_encoding?

      converted
    rescue EncodingError
      raise ValidationError, "Text in #{text.encoding} cannot be converted to UTF-8"
    end

    # Converts strings inside opaque user data, keeping its keys as given.
    def utf8_strings(value, depth = 0)
      check_depth!(depth)
      case value
      when Hash then value.to_h { |key, item| [key.is_a?(String) ? utf8(key) : key, utf8_strings(item, depth + 1)] }
      when Array then value.map { |item| utf8_strings(item, depth + 1) }
      when String then utf8(value)
      else value
      end
    end

    # Request bodies deeper than JSON's own nesting limit (or cyclic ones)
    # are refused before they reach the encoder.
    MAX_DEPTH = 100

    def check_depth!(depth)
      raise ValidationError, "Request body is nested deeper than #{MAX_DEPTH} levels (or cyclic)" if depth > MAX_DEPTH
    end

    # True for nil, "" and whitespace — never raises on broken encodings.
    def blank?(value)
      text = value.to_s
      text = text.scrub unless text.valid_encoding?
      text.strip.empty?
    end

    # Stripped text; raises ValidationError instead of Encoding errors.
    def strip_text(value, field)
      text = value.to_s
      raise ValidationError, "#{field} contains invalid #{text.encoding} bytes" unless text.valid_encoding?

      text.strip
    end

    # Builds "/a/<escaped>/b" from a template with `%s` placeholders.
    def path(template, *segments)
      format(template, *segments.map { |segment| escape_segment(segment) })
    end

    # Escapes one URL path segment. Prevents path traversal and injection of
    # extra segments or query strings through user-supplied IDs/aliases.
    def escape_segment(value)
      text = case value
             when Integer
               raise ValidationError, "ID must be positive, got #{value}" unless value.positive?

               value.to_s
             when String, Symbol then value.to_s
             else raise ValidationError, "ID must be an Integer or String, got #{value.class}"
             end

      raise ValidationError, "ID must not be blank" if strip_text(text, "ID").empty?
      raise ValidationError, "ID must not be #{text.inspect}" if %w[. ..].include?(text)

      URI.encode_www_form_component(text).gsub("+", "%20")
    end

    # Converts a query hash: symbol keys are mapped through `mapping`
    # (unknown symbols raise), string keys are sent verbatim; nil is dropped.
    def query(params, mapping)
      params.each_with_object({}) do |(key, value), result|
        next if value.nil?

        name = case key
               when String then key
               when Symbol
                 mapping.fetch(key) do
                   raise ValidationError,
                         "Unknown parameter #{key.inspect}. Allowed: #{mapping.keys.map(&:inspect).join(', ')}"
                 end
               else raise ValidationError, "Parameter names must be Symbols or Strings"
               end
        result[name] = query_value(value)
      end
    end

    # Converts one query value to its API string form.
    def query_value(value)
      case value
      when Time then format_time(value)
      when DateTime then format_time(value.to_time)
      when Date then value.strftime("%Y-%m-%d")
      when true, false, Numeric, String, Symbol then value.to_s
      else raise ValidationError, "Unsupported query value #{value.class}"
      end
    end

    # Time is converted to Moscow time — the API interprets all timestamps as MSK.
    def format_time(time, separator: " ")
      time.getlocal(MOSCOW_UTC_OFFSET).strftime("%Y-%m-%d#{separator}%H:%M:%S")
    end

    # Date-only parameter (stats, bounces): Time is reduced to its Moscow date.
    def format_date(value)
      case value
      when nil then nil
      when DateTime then format_date(value.to_time)
      when Time then value.getlocal(MOSCOW_UTC_OFFSET).strftime("%Y-%m-%d")
      when Date then value.strftime("%Y-%m-%d")
      when String then value
      else raise ValidationError, "Expected Date, Time or String, got #{value.class}"
      end
    end

    # Parses an API timestamp: "YYYY-MM-DD HH:MM:SS" (Moscow time), ISO 8601,
    # or RFC 2822 ("Sat, 31 Oct 2026 21:15:56 +0300", the Date of inbound mail).
    # @return [Time, nil] nil for an empty or zero ("0000-00-00 00:00:00") value
    def parse_time(value)
      text = value.to_s.strip
      return nil if text.empty?
      return Time.rfc2822(text) if text.match?(/\A(?:[A-Za-z]{3},\s*)?\d{1,2}\s+[A-Za-z]{3}\s+\d{4}\s/)

      if text.match?(/\A\d{4}-\d\d-\d\dT/)
        # Timestamps without an offset are Moscow time, not the host's zone.
        text = text.sub(/z\z/, "Z").sub(/([+-]\d\d)\z/, '\\1:00')
        text += MOSCOW_OFFSET unless text.match?(/(?:Z|[+-]\d\d:?\d\d)\z/)
        return Time.iso8601(text)
      end

      Time.strptime("#{text} #{MOSCOW_OFFSET}", "%Y-%m-%d %H:%M:%S %z")
    rescue ArgumentError, EncodingError
      nil
    end

    # Freezes a Hash/Array tree in place.
    def deep_freeze(value)
      case value
      when Hash then value.each_value { |item| deep_freeze(item) }
      when Array then value.each { |item| deep_freeze(item) }
      end
      value.freeze
    end

    # Mutable deep copy of a Hash/Array tree.
    def deep_dup(value)
      case value
      when Hash then value.to_h { |key, item| [key.dup, deep_dup(item)] }
      when Array then value.map { |item| deep_dup(item) }
      when String then value.dup
      else value
      end
    end

    # Parses JSON from the network. `JSON.parse` never instantiates classes
    # from "json_class" keys (unlike `JSON.load`), on json 2.x and 3.x alike.
    # @raise [JSON::ParserError] including JSON::NestingError
    def parse_json(body)
      JSON.parse(body, max_nesting: 100)
    end

    # @raise [ValidationError] when the value cannot be encoded
    def generate_json(value)
      JSON.generate(value)
    rescue JSON::JSONError, Encoding::UndefinedConversionError => e
      raise ValidationError, "Request body cannot be encoded as JSON: #{e.message}"
    end
  end
end
