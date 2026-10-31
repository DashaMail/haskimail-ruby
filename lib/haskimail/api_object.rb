# frozen_string_literal: true

require_relative "util"
require_relative "http/response_parser"

module Haskimail
  # Immutable wrapper around a JSON object returned by the API.
  #
  # Field access is lossless: the original keys are kept, and snake_case
  # names are resolved to them on the fly.
  #
  #   result = client.emails.deliver(...)
  #   result.message_id        # => "6f1c0b2d..."
  #   result[:message_id]      # same
  #   result["MessageID"]      # exact API key
  #   result.to_h              # => { "MessageID" => "...", ... } (mutable deep copy)
  #
  # Keys that are not identifiers (e.g. "Apple Mail" in e-mail client stats)
  # are available through #[] with either spelling: `stats["Apple Mail"]`,
  # `stats[:apple_mail]`.
  class ApiObject
    # @param data [Hash] parsed API object (deep-copied and frozen)
    def initialize(data)
      raise ArgumentError, "ApiObject expects a Hash, got #{data.class}" unless data.is_a?(Hash)

      setup(Util.deep_freeze(Util.deep_dup(data)))
    end

    # @param key [String, Symbol] exact API key or snake_case alias
    # @return [Object, ApiObject, Array, nil]
    def [](key)
      original = resolve(key)
      original.nil? ? nil : self.class.wrap(@data[original])
    end

    # Like Hash#fetch, with the same key resolution as #[].
    def fetch(key, *default, &block)
      original = resolve(key)
      return self.class.wrap(@data[original]) unless original.nil?
      return yield(key) if block
      return default.first unless default.empty?

      raise KeyError.new("key not found: #{key.inspect}", receiver: self, key: key)
    end

    # True when the key exists under any accepted spelling.
    def key?(key)
      !resolve(key).nil?
    end
    alias include? key?

    # Like Hash#dig, with the same key resolution as #[].
    def dig(key, *rest)
      value = self[key]
      return value if rest.empty? || value.nil?

      value.respond_to?(:dig) ? value.dig(*rest) : nil
    end

    # Original API keys.
    def keys
      @data.keys
    end

    # Yields each original key with its (wrapped) value.
    def each(&block)
      return enum_for(:each) unless block

      @data.each_key { |key| yield key, self[key] }
      self
    end

    # @return [Hash] deep, mutable copy of the raw API data (String keys)
    def to_h
      Util.deep_dup(@data)
    end
    alias to_hash to_h

    # JSON of the original API data.
    def to_json(*args)
      @data.to_json(*args)
    end

    # Value equality: same class and same data.
    def ==(other)
      other.instance_of?(self.class) && other.data == @data
    end

    # Strict equality (numbers compared by type too), consistent with #hash.
    def eql?(other)
      other.instance_of?(self.class) && other.data.eql?(@data)
    end

    # Consistent with #eql?.
    def hash
      [self.class, @data].hash
    end

    # Marshal support (e.g. Rails.cache): only the data is stored, and the
    # loaded object is frozen again.
    def marshal_dump
      @data
    end

    # Restores an object written by #marshal_dump, frozen again.
    # @api private
    def marshal_load(data)
      setup(Util.deep_freeze(data))
    end

    # Full data, for debugging.
    def inspect
      "#<#{self.class.name} #{@data.inspect}>"
    end
    alias to_s inspect

    # `result.message_id` reads "MessageID". Setters, bang and predicate
    # names are never resolved: the object is read-only.
    def method_missing(name, *args, &block)
      return super unless args.empty? && block.nil? && reader_name?(name)

      original = resolve(name)
      original.nil? ? super : self.class.wrap(@data[original])
    end

    def respond_to_missing?(name, include_private = false)
      (reader_name?(name) && !resolve(name).nil?) || super
    end

    # Key form used for case- and punctuation-insensitive lookup:
    # "MessageID", :message_id and "message-id" all become "messageid".
    # @api private
    def self.normalize(key)
      key.to_s.downcase.gsub(/[^[:alnum:]]/, "")
    end

    # @api private
    # Wraps already-frozen nested data without copying it again.
    def self.wrap(value)
      case value
      when Hash then ApiObject.allocate.tap { |object| object.send(:setup, value) }
      when Array then value.map { |item| wrap(item) }.freeze
      else value
      end
    end

    protected

    # Frozen raw data, for comparisons between objects.
    # @api private
    attr_reader :data

    private

    def reader_name?(name)
      !name.end_with?("=", "!", "?")
    end

    # Value under the exact API key, without case-insensitive matching.
    def exact(key)
      self.class.wrap(@data[key])
    end

    def setup(frozen_data)
      @data = frozen_data
      @index = @data.keys.each_with_object({}) do |key, index|
        index[self.class.normalize(key)] ||= key
      end.freeze
      freeze
    end

    def resolve(key)
      return key if key.is_a?(String) && @data.key?(key)
      return nil unless key.is_a?(String) || key.is_a?(Symbol)

      @index[self.class.normalize(key)]
    end
  end

  # Result of sending one email (also one element of a batch result).
  class SendResult < ApiObject
    # @return [Integer, nil] nil when the API did not send a numeric code
    def error_code
      HTTP::ResponseParser.error_code(@data)
    end

    # True only for ErrorCode 0. `false` appears inside batch results —
    # single sends raise instead.
    def success?
      error_code&.zero? == true
    end

    # MessageID, one per recipient (the API joins them with commas).
    # @return [Array<String>]
    def message_ids
      self["MessageID"].to_s.split(",").map(&:strip).reject(&:empty?)
    end

    # @return [Time, nil]
    def submitted_at_time
      Util.parse_time(self["SubmittedAt"])
    end
  end

  # Result of /email/batch and /email/batchWithTemplates.
  # The API answers 200 even if some emails were rejected,
  # so check #success? or #failed.
  class BatchResult
    include Enumerable

    # @return [Array<SendResult>] frozen, in the order the emails were given
    attr_reader :results

    # @param results [Array<SendResult>]
    def initialize(results)
      @results = results.dup.freeze
      freeze
    end

    # Yields each SendResult.
    def each(&block)
      return enum_for(:each) unless block

      @results.each(&block)
      self
    end

    # @return [SendResult, nil]
    def [](index)
      @results[index]
    end

    # Number of results (equals the number of emails sent).
    def size
      @results.size
    end
    alias length size

    def empty?
      @results.empty?
    end

    # True when every email was accepted.
    def success?
      @results.all?(&:success?)
    end

    # @return [Array<SendResult>]
    def successful
      @results.select(&:success?)
    end

    # @return [Array<SendResult>]
    def failed
      @results.reject(&:success?)
    end

    # @return [Array<SendResult>] mutable copy
    def to_a
      @results.dup
    end

    # @return [Array<Hash>] raw API data of every result
    def as_json(*)
      @results.map(&:to_h)
    end

    # JSON array of the raw API results.
    # json's RBS types the state argument of Array#to_json too narrowly.
    def to_json(*args)
      as_json.to_json(*args) # steep:ignore
    end

    # Same class and equal results.
    def ==(other)
      other.instance_of?(self.class) && other.results == @results
    end

    def eql?(other)
      other.instance_of?(self.class) && other.results.eql?(@results)
    end

    # Consistent with #eql?.
    def hash
      [self.class, @results].hash
    end

    # Summary: number of results and failures.
    def inspect
      "#<#{self.class.name} size=#{size} failed=#{failed.size}>"
    end
    alias to_s inspect
  end
end
