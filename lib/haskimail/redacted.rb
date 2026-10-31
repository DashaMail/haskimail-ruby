# frozen_string_literal: true

module Haskimail
  # @api private
  # For objects that hold credentials (API token, proxy password): every
  # generic serializer gets the redacted #inspect text instead of the
  # instance variables. Covers YAML (Psych), Marshal and JSON, including
  # ActiveSupport's `as_json`, which would otherwise dump instance variables.
  module Redacted
    # YAML shows only the redacted description.
    def encode_with(coder)
      coder.scalar = inspect
    end

    # Never written to caches or dumps.
    def marshal_dump
      raise TypeError, "#{self.class.name} holds credentials and cannot be marshalled"
    end

    # JSON shows only the redacted description.
    def as_json(*)
      inspect
    end

    # JSON shows only the redacted description. (json's RBS types the state
    # argument of String#to_json too narrowly for a splat.)
    def to_json(*args)
      inspect.to_json(*args) # steep:ignore
    end
  end
end
