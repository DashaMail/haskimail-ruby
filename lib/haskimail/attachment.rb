# frozen_string_literal: true

require_relative "errors"
require_relative "util"

module Haskimail
  # An email attachment. Encodes content to Base64 and refuses file types
  # that Haskimail rejects, before anything goes over the network.
  #
  #   Haskimail::Attachment.from_file("invoice.pdf")
  #   Haskimail::Attachment.new(name: "report.csv", content: csv_string, content_type: "text/csv")
  #   Haskimail::Attachment.from_file("logo.png", content_id: "cid:logo") # inline: <img src="cid:logo">
  #
  # Instances can be put straight into `attachments:` of any send method.
  class Attachment
    # https://haskimail.ru/developer/user-guide/send-email-with-api#attachments
    FORBIDDEN_EXTENSIONS = %w[
      vbs exe bin bat chm com cpl crt hlp hta inf ins isp jse lnk mdb pcd pif reg
      scr sct shs vbe vba wsf wsh wsl msc msi msp mst
    ].freeze

    # Total message size limit, attachments counted after Base64 encoding.
    MAX_MESSAGE_SIZE = 10 * 1024 * 1024

    # Content type guessed from the file extension.
    MIME_TYPES = {
      "pdf" => "application/pdf", "zip" => "application/zip", "json" => "application/json",
      "xml" => "application/xml", "txt" => "text/plain", "csv" => "text/csv", "html" => "text/html",
      "htm" => "text/html", "ics" => "text/calendar", "png" => "image/png", "jpg" => "image/jpeg",
      "jpeg" => "image/jpeg", "gif" => "image/gif", "webp" => "image/webp", "svg" => "image/svg+xml",
      "doc" => "application/msword", "xls" => "application/vnd.ms-excel",
      "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
      "odt" => "application/vnd.oasis.opendocument.text", "rtf" => "application/rtf",
      "mp3" => "audio/mpeg", "mp4" => "video/mp4", "eml" => "message/rfc822"
    }.freeze

    # Content type for unknown extensions.
    DEFAULT_CONTENT_TYPE = "application/octet-stream"

    # RFC 2045 type/subtype, optionally followed by parameters
    # ("text/plain; charset=utf-8").
    CONTENT_TYPE_FORMAT = %r{\A[!#$%&'*+.^_`|~0-9A-Za-z-]+/[!#$%&'*+.^_`|~0-9A-Za-z-]+(?:[ \t]*;.*)?\z}

    attr_reader :name, :content_type, :content_id

    # @param path [String, Pathname]
    # @raise [ValidationError] when the file cannot be read
    def self.from_file(path, name: nil, content_type: nil, content_id: nil)
      content = begin
        File.binread(path.to_s)
      rescue SystemCallError, IOError => e
        raise ValidationError, "Attachment file #{path.to_s.inspect} cannot be read: #{e.message}"
      end
      new(name: name || File.basename(path.to_s), content: content, content_type: content_type, content_id: content_id)
    end

    # @param name [String] file name shown to the recipient
    # @param content [String] raw (not encoded) bytes
    # @param content_type [String, nil] detected from the extension when nil
    # @param content_id [String, nil] makes the attachment inline (`cid:...`)
    def initialize(name:, content:, content_type: nil, content_id: nil)
      @name = self.class.validate_name!(name)
      raise ValidationError, "Attachment content must be a String" unless content.is_a?(String)

      @encoded = [content].pack("m0").freeze
      @content_type = self.class.validate_content_type!(content_type || self.class.detect_content_type(@name))
      @content_id = content_id.nil? ? nil : self.class.validate_content_id!(content_id)
      if @encoded.bytesize > MAX_MESSAGE_SIZE
        raise ValidationError, "Attachment #{@name} exceeds 10 MB after Base64 encoding"
      end

      freeze
    end

    # True for inline attachments (with a content ID).
    def inline?
      !@content_id.nil?
    end

    # Size after Base64 encoding — the number Haskimail checks against its limit.
    def encoded_size
      @encoded.bytesize
    end

    # @return [Hash] API representation
    def to_haskimail
      hash = { "Name" => @name, "Content" => @encoded, "ContentType" => @content_type }
      content_id = @content_id
      hash["ContentID"] = content_id if content_id
      hash
    end
    alias to_h to_haskimail

    # Name, type and size; never the content.
    def inspect
      "#<#{self.class.name} name=#{@name.inspect} content_type=#{@content_type.inspect} " \
        "encoded_size=#{encoded_size}#{" content_id=#{@content_id.inspect}" if inline?}>"
    end

    # @api private
    def self.validate_name!(name)
      text = name.to_s
      raise ValidationError, "Attachment name must be valid #{text.encoding} text" unless text.valid_encoding?

      text = Util.utf8(text) # binary names (e.g. from a multipart upload) are relabelled
      raise ValidationError, "Attachment name must not be blank" if text.strip.empty?
      if text.match?(/[[:cntrl:]]/) || Util::UNSAFE_HEADER_CHARS.match?(text)
        raise ValidationError, "Attachment name must not contain control characters or line separators"
      end

      extension = extension_of(text)
      if FORBIDDEN_EXTENSIONS.include?(extension)
        raise ValidationError, "Attachments of type .#{extension} are not accepted by Haskimail"
      end

      text.dup.freeze
    end

    # @api private
    # @return [String] frozen, valid content type
    def self.validate_content_type!(value)
      text = header_text!(value, "Attachment content type")
      raise ValidationError, "Invalid attachment content type #{text.inspect}" unless CONTENT_TYPE_FORMAT.match?(text)

      text
    end

    # @api private
    # @return [String] frozen content ID ("cid:logo" or "logo")
    def self.validate_content_id!(value)
      text = header_text!(value, "Attachment content ID")
      raise ValidationError, "Attachment content ID must not be blank" if text.strip.empty?

      text
    end

    # @api private
    def self.header_text!(value, label)
      unless value.is_a?(String) || value.is_a?(Symbol) || value.is_a?(Integer)
        raise ValidationError, "#{label} must be a String"
      end

      text = Util.utf8(value.to_s)
      # TAB is allowed: it may separate parameters ("text/plain;\tcharset=utf-8").
      raise ValidationError, "#{label} must not contain control characters" if text.match?(/[[:cntrl:]&&[^\t]]/)
      raise ValidationError, "#{label} must not contain line separators" if Util::UNSAFE_HEADER_CHARS.match?(text)

      text.dup.freeze
    end
    private_class_method :header_text!

    # Windows ignores trailing dots and spaces ("virus.exe. " runs as .exe),
    # so they are stripped before the check.
    # @api private
    def self.extension_of(name)
      base = File.basename(name.sub(/[.\s]+\z/, ""))
      # A name like ".exe" has no extname, but Windows still treats it as an .exe.
      extension = File.extname(base).delete_prefix(".")
      extension = base.delete_prefix(".") if extension.empty? && base.start_with?(".")
      extension.downcase
    end

    # Content type for a file name, from MIME_TYPES.
    # @api private
    def self.detect_content_type(name)
      MIME_TYPES.fetch(extension_of(name), DEFAULT_CONTENT_TYPE)
    end
  end
end
