# frozen_string_literal: true

require_relative "../test_helper"
require "tempfile"

module Haskimail
  class ConfigurationTest < TestCase
    def test_defaults
      config = Configuration.new

      assert_equal "https://api.haskimail.ru", config.base_url
      assert_equal({ base_url: "https://api.haskimail.ru", open_timeout: 5, read_timeout: 30, write_timeout: 30,
                     max_retries: 2, logger: nil, proxy: nil, ca_file: nil, user_agent: nil }, config.to_h)
    end

    def test_rejects_insecure_or_invalid_values
      [
        { base_url: "http://api.haskimail.ru" },
        { base_url: "https://" },
        { base_url: "https://user:pass@api.haskimail.ru" },
        { base_url: "https://api.haskimail.ru?x=1" },
        { base_url: "https://api.haskimail.ru#x" },
        { base_url: "https://exa mple.com" },
        { open_timeout: 0 }, { read_timeout: -1 }, { write_timeout: "5" },
        { max_retries: -1 }, { max_retries: 11 }, { max_retries: 1.5 },
        { logger: Object.new },
        { proxy: "ftp://proxy" }, { proxy: "http://" }, { proxy: "http://bad host" },
        { ca_file: "/definitely/missing.pem" },
        { user_agent: "x\r\nEvil: 1" },
        { unknown: 1 }
      ].each do |options|
        assert_raises(ConfigurationError, options.inspect) { Configuration.new(**options) }
      end
    end

    def test_update_is_atomic
      config = Configuration.new
      assert_raises(ConfigurationError) { config.update(read_timeout: 99, max_retries: 50) }
      assert_equal 30, config.read_timeout
    end

    def test_global_configuration_is_frozen_and_configure_is_atomic
      assert_predicate Haskimail.configuration, :frozen?
      assert_raises(FrozenError) { Haskimail.configuration.read_timeout = 1 }
      assert_raises(ConfigurationError) do
        Haskimail.configure do |config|
          config.read_timeout = 99
          config.max_retries = 50
        end
      end
      assert_equal 30, Haskimail.configuration.read_timeout
      Haskimail.configure { |config| config.read_timeout = 12 }
      assert_equal 12, Haskimail.configuration.read_timeout
      Haskimail.configure do |config|
        config.max_retries = Haskimail.configuration.max_retries + 1 # re-entrant, no deadlock
        ServerClient.new("t")
      end
      assert_equal 3, Haskimail.configuration.max_retries
    end

    def test_secrets_are_redacted
      config = Configuration.new(proxy: "http://bob:pa%40ss@proxy.local:3128")

      refute_includes config.inspect, "pa%40ss"
      refute_includes config.to_s, "pa%40ss"
      assert_equal "http://bob:[FILTERED]@proxy.local:3128", config.to_h[:proxy]
      assert_equal "pa%40ss", config.proxy.password
      assert_equal "http://proxy.local:3128", Configuration.new(proxy: "http://proxy.local:3128").to_h[:proxy]
      assert_match(/plain text|not supported/, assert_raises(ConfigurationError) do
        Configuration.new(proxy: "https://proxy.local:3128")
      end.message)

      request = HTTP::Request.new(method: :post, url: "https://example.net/",
                                  headers: { "X-Haskimail-Server-Token" => "SECRET-1",
                                             "X-Haskimail-Account-Token" => "SECRET-2", "Accept" => "a" },
                                  body: "{}")
      [request.inspect, request.to_s].each do |text|
        refute_includes text, "SECRET"
        assert_includes text, "Accept"
      end
      assert_includes HTTP::Request.new(method: :get, url: "u", headers: {}, body: nil).inspect, "body=nil"
      require "pp"
      refute_includes request.pretty_inspect, "SECRET"
      refute_respond_to request, :to_h
      assert_predicate request, :frozen?
      assert_equal "http://[FILTERED]@proxy.local:3128",
                   Configuration.new(proxy: "http://tok123@proxy.local:3128").to_h[:proxy]
    end

    def test_accepts_valid_values
      Tempfile.create(["ca", ".pem"]) do |file|
        config = Configuration.new(proxy: "http://u%40x:p@proxy.local:3128", ca_file: file.path,
                                   user_agent: "app/1", max_retries: 0)

        assert_equal "proxy.local", config.proxy.host
        assert_equal file.path, config.ca_file
        config.proxy = nil
        config.ca_file = nil
        config.user_agent = nil
        assert_nil config.proxy
        assert_nil config.ca_file
        assert_nil config.user_agent
      end
    end
  end

  class UtilTest < TestCase
    def test_api_key
      assert_equal "HtmlBody", Util.api_key(:html_body)
      assert_equal "HtmlBody", Util.api_key(:HtmlBody)
      assert_equal "any thing", Util.api_key("any thing")
      assert_equal "ID", Util.api_key(:id)
      assert_equal "TemplateId", Util.api_key(:template_id)
      assert_equal "ServerID", Util.api_key(:server_id)
      assert_equal "AssociatedServerId", Util.api_key(:associated_server_id)
      assert_equal "EnableSmtpApiErrorHooks", Util.api_key(:enable_smtp_api_error_hooks)
      assert_raises(ValidationError) { Util.api_key(1) }
    end

    def test_blank_and_strip_text_never_raise_encoding_errors
      assert Util.blank?(nil)
      assert Util.blank?(" \t")
      assert Util.blank?((+" \xFF").force_encoding("UTF-8").byteslice(0, 1))
      refute Util.blank?("\xFFa")
      assert_equal "a", Util.strip_text(" a ", "x")
      assert_raises(ValidationError) { Util.strip_text("\xFF", "x") }
    end

    def test_path_escaping_blocks_traversal_and_injection
      assert_equal "/templates/4521", Util.path("/templates/%s", 4521)
      assert_equal "/templates/order%20created", Util.path("/templates/%s", "order created")
      assert_equal "/templates/a%2F..%2Fservers", Util.path("/templates/%s", "a/../servers")
      assert_equal "/templates/x%3Fy%3D1%23z", Util.path("/templates/%s", "x?y=1#z")
      assert_equal "/templates/%D0%B7%D0%B0%D0%BA%D0%B0%D0%B7", Util.path("/templates/%s", "заказ")
      assert_equal "/templates/a%2Bb%25", Util.path("/templates/%s", "a+b%")
      assert_equal "/templates/sym", Util.path("/templates/%s", :sym)
      [nil, "", "  ", ".", "..", 0, -1, 1.5, []].each do |bad|
        assert_raises(ValidationError, bad.inspect) { Util.path("/templates/%s", bad) }
      end
    end

    def test_query_conversion
      time = Time.utc(2026, 10, 1, 9, 0, 0)
      result = Util.query({ count: 5, flag: true, from: time, day: Date.new(2026, 10, 2), name: :x,
                            "Raw" => "v", skip: nil },
                          { count: "count", flag: "flag", from: "fromdate", day: "d", name: "n", skip: "s" })

      assert_equal({ "count" => "5", "flag" => "true", "fromdate" => "2026-10-01 12:00:00", "d" => "2026-10-02",
                     "n" => "x", "Raw" => "v" }, result)
      assert_match(/Allowed: :a/, assert_raises(ValidationError) { Util.query({ typo: 1 }, { a: "a" }) }.message)
      assert_raises(ValidationError) { Util.query({ 1 => 1 }, {}) }
      assert_raises(ValidationError) { Util.query({ a: [1] }, { a: "a" }) }
    end

    def test_datetime_keeps_time
      date_time = DateTime.new(2026, 10, 1, 9, 30, 0, "+00:00")
      assert_equal "2026-10-01 12:30:00", Util.query_value(date_time)
      assert_equal "2026-10-02", Util.format_date(DateTime.new(2026, 10, 1, 22, 0, 0, "+00:00"))
    end

    def test_iso_time_without_offset_is_moscow_regardless_of_host_zone
      original = ENV.fetch("TZ", nil)
      ENV["TZ"] = "America/New_York"
      assert_equal Time.utc(2026, 9, 1, 9, 0, 0), Util.parse_time("2026-09-01T12:00:00")
      assert_equal Time.utc(2026, 9, 1, 12, 0, 0), Util.parse_time("2026-09-01T12:00:00Z")
      assert_equal Time.utc(2026, 9, 1, 12, 0, 0), Util.parse_time("2026-09-01T12:00:00z")
      assert_equal Time.utc(2026, 9, 1, 9, 0, 0), Util.parse_time("2026-09-01T12:00:00+03")
    ensure
      ENV["TZ"] = original
    end

    def test_dates
      assert_equal "2026-10-02", Util.format_date(Time.new(2026, 10, 1, 22, 0, 0, "+00:00"))
      assert_equal "2026-10-01", Util.format_date(Date.new(2026, 10, 1))
      assert_equal "2026-10-01", Util.format_date("2026-10-01")
      assert_nil Util.format_date(nil)
      assert_raises(ValidationError) { Util.format_date(1) }
      assert_equal "2026-10-01T12:00:00", Util.format_time(Time.utc(2026, 10, 1, 9), separator: "T")
    end

    def test_parse_time
      assert_equal Time.utc(2026, 10, 7, 11, 30, 12), Util.parse_time("2026-10-07 14:30:12")
      assert_equal Time.utc(2026, 9, 29, 11, 5, 14), Util.parse_time("2026-09-29T14:05:14+03:00")
      assert_nil Util.parse_time(nil)
      assert_nil Util.parse_time("")
      assert_nil Util.parse_time("garbage")
    end

    def test_to_api_keeps_opaque_values
      result = Util.to_api(test_render_model: { "{{a}}" => nil, b_c: 1 }, list: [{ a_b: 1, c: nil }])

      assert_equal({ "TestRenderModel" => { "{{a}}" => nil, b_c: 1 }, "List" => [{ "AB" => 1 }] }, result)
    end

    def test_deep_helpers
      data = { "a" => [{ "b" => +"c" }] }
      frozen = Util.deep_freeze(Util.deep_dup(data))
      assert_predicate frozen["a"].first["b"], :frozen?
      refute_predicate data["a"].first["b"], :frozen?
      assert_equal data, Util.deep_dup(frozen)
    end

    def test_unencodable_values_are_validation_errors
      assert_raises(ValidationError) { Util.generate_json({ "n" => Float::NAN }) }
    end

    def test_json_limits
      assert_raises(JSON::NestingError) { Util.parse_json("#{'[' * 150}#{']' * 150}") }
      assert_equal({ "json_class" => "String" }, Util.parse_json('{"json_class":"String"}'))
    end
  end

  class ApiObjectTest < TestCase
    def setup
      super
      @object = ApiObject.new(Fixtures::DOMAIN.merge("Days" => [{ "Date" => "2026-10-01" }], "Apple Mail" => 3,
                                                     "Unsubscribed" => 3, "Unsubsribed" => 4))
    end

    def test_lossless_access
      assert_equal 3127, @object.id
      assert_equal 3127, @object["ID"]
      assert_equal 3127, @object[:id]
      assert @object.dkim_verified
      assert_equal "TXT", @object.spf_text_value.record_type
      assert_equal "TXT", @object.dig(:spf_text_value, :record_type)
      assert_nil @object.dig(:missing, :x)
      assert_nil @object.dig(:id, :x)
      assert_equal "2026-10-01", @object.days.first.date
      assert_equal 3, @object["Apple Mail"]
      assert_equal 3, @object[:apple_mail]
      assert_equal 3, @object.unsubscribed
      assert_equal 4, @object.unsubsribed
      assert_nil @object[:missing]
      assert_nil @object[123]
    end

    def test_hash_like_api
      assert @object.key?(:dkim_verified)
      assert_includes @object, "Name"
      refute @object.key?(:nope)
      assert_equal 3127, @object.fetch(:id)
      assert_equal :d, @object.fetch(:nope, :d)
      assert_equal "nope!", @object.fetch(:nope) { |key| "#{key}!" }
      assert_raises(KeyError) { @object.fetch(:nope) }
      assert_includes @object.keys, "DKIMVerified"
      assert_equal @object.keys.size, @object.each.count
      assert_same(@object, @object.each { |_key, _value| nil })
      assert_respond_to @object, :spf_verified
      refute_respond_to @object, :nope
      assert_raises(NoMethodError) { @object.nope }
      assert_raises(NoMethodError) { @object.id(1) }
    end

    def test_immutability_and_conversions
      assert_predicate @object, :frozen?
      assert_raises(FrozenError) { @object.days.first.to_h.tap { nil } && (@object.days << 1) }
      copy = @object.to_h
      copy["Name"] << "!"
      assert_equal "example.com", @object.name
      assert_equal copy.keys, @object.to_hash.keys
      assert_equal JSON.parse(@object.to_json), @object.to_h
      assert_equal ApiObject.new(@object.to_h), @object
      assert_equal ApiObject.new(@object.to_h).hash, @object.hash
      refute_equal @object, @object.to_h
      assert_match(/\A#<Haskimail::ApiObject \{/, @object.inspect)
      assert_equal @object.inspect, @object.to_s
      assert_raises(ArgumentError) { ApiObject.new([1]) }
    end
  end

  class AttachmentTest < TestCase
    def test_from_file_detects_type_and_encodes
      Tempfile.create(["invoice", ".PDF"]) do |file|
        file.binmode
        file.write("%PDF\x00\xFF".b)
        file.flush
        attachment = Attachment.from_file(file.path)

        assert_equal File.basename(file.path), attachment.name
        assert_equal "application/pdf", attachment.content_type
        assert_equal "%PDF\x00\xFF".b, attachment.to_h["Content"].unpack1("m0")
        refute_predicate attachment, :inline?
        assert_equal 8, attachment.encoded_size
        assert_predicate attachment, :frozen?
        refute_match(/Content/, attachment.inspect)
      end
    end

    def test_inline_and_overrides
      attachment = Attachment.new(name: "logo", content: "x", content_type: "image/svg+xml", content_id: "cid:l")

      assert_predicate attachment, :inline?
      assert_equal "cid:l", attachment.to_haskimail["ContentID"]
      assert_equal "image/svg+xml", attachment.content_type
      assert_match(/content_id="cid:l"/, attachment.inspect)
      assert_equal "application/octet-stream", Attachment.new(name: "data.unknown", content: "").content_type
    end

    def test_rejects_name_with_broken_encoding
      assert_raises(ValidationError) { Attachment.new(name: "\xFF.txt", content: "") }
    end

    def test_rejects_dangerous_or_invalid_input
      ["a.exe", "A.BAT", "x.scr.", "y.msi ", "z.vbs"].each do |name|
        assert_raises(ValidationError, name) { Attachment.new(name: name, content: "") }
      end
      assert_raises(ValidationError) { Attachment.new(name: "", content: "") }
      assert_raises(ValidationError) { Attachment.new(name: "a\nb.txt", content: "") }
      assert_raises(ValidationError) { Attachment.new(name: "a.txt", content: nil) }
      assert_raises(ValidationError) do
        Attachment.new(name: "big.txt", content: "a" * ((Attachment::MAX_MESSAGE_SIZE * 3 / 4) + 3))
      end
    end
  end

  class ErrorsTest < TestCase
    def test_hierarchy
      assert_operator TimeoutError, :<, ConnectionError
      assert_operator TlsError, :<, ConnectionError
      assert_operator ServiceUnavailableError, :<, ServerError
      assert_operator ServerError, :<, ApiError
      [ConfigurationError, ValidationError, SignatureVerificationError, ConnectionError, ApiError].each do |klass|
        assert_operator klass, :<, Error
      end
    end

    def test_connection_error_details
      cause = Errno::ECONNREFUSED.new
      error = ConnectionError.new("x", original_error: cause, request_sent: false)

      assert_same cause, error.original_error
      refute_predicate error, :request_sent?
      assert_predicate ConnectionError.new("y"), :request_sent?
    end

    def test_descriptions_are_unique_per_code
      assert_equal "Шаблон не найден", ErrorCodes.describe(1101)
      assert_nil ErrorCodes.describe(999_999)
      codes = ErrorCodes.constants.reject { |c| c == :DESCRIPTIONS }.map { |c| ErrorCodes.const_get(c) }
      assert_equal codes.uniq.size, codes.size
      assert_empty codes - ErrorCodes::DESCRIPTIONS.keys
    end
  end
end
