# frozen_string_literal: true

require "openssl"
require "socket"
require "tempfile"

module Haskimail
  # Minimal real HTTPS server for end-to-end tests of the Net::HTTP transport.
  # Uses a freshly generated self-signed certificate per instance.
  class TestHttpsServer
    Received = Struct.new(:http_method, :path, :headers, :body)

    attr_reader :port, :requests

    # One RSA key for every server in the run: key generation is the slowest
    # part of setup. Certificates are still fresh per server.
    def self.key
      @key ||= OpenSSL::PKey::RSA.new(2048)
    end

    # @param san [String] subjectAltName of the certificate
    # @yield [Received] returns [status, headers, body]
    def initialize(san: "IP:127.0.0.1,DNS:localhost", &handler)
      @handler = handler
      @requests = Queue.new
      @key = self.class.key
      @cert = build_certificate(san)
      @tcp = TCPServer.new("127.0.0.1", 0)
      @port = @tcp.addr[1]
      context = OpenSSL::SSL::SSLContext.new
      context.cert = @cert
      context.key = @key
      @ssl = OpenSSL::SSL::SSLServer.new(@tcp, context)
      @threads = []
      @acceptor = Thread.new { accept_loop }
    end

    def base_url
      "https://127.0.0.1:#{port}"
    end

    # PEM file trusting this server's certificate.
    def ca_file
      @ca_file ||= Tempfile.new(["haskimail-test-ca", ".pem"]).tap do |file|
        file.write(@cert.to_pem)
        file.flush
      end
      @ca_file.path
    end

    def received
      list = []
      list << @requests.pop until @requests.empty?
      list
    end

    def shutdown
      @acceptor.kill
      @threads.each(&:kill)
      @ssl.close
    rescue IOError
      nil
    ensure
      @ca_file&.close!
    end

    private

    def build_certificate(san)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = rand(1..(2**32))
      cert.subject = OpenSSL::X509::Name.parse("/CN=haskimail-test")
      cert.issuer = cert.subject
      cert.public_key = @key
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + 3600
      extensions = OpenSSL::X509::ExtensionFactory.new
      extensions.subject_certificate = cert
      extensions.issuer_certificate = cert
      cert.add_extension(extensions.create_extension("basicConstraints", "CA:TRUE", true))
      cert.add_extension(extensions.create_extension("keyUsage", "keyCertSign,digitalSignature,keyEncipherment", true))
      cert.add_extension(extensions.create_extension("subjectAltName", san))
      cert.sign(@key, OpenSSL::Digest.new("SHA256"))
      cert
    end

    def accept_loop
      loop do
        socket = @ssl.accept
        @threads << Thread.new(socket) { |client| serve(client) }
      rescue OpenSSL::SSL::SSLError, Errno::ECONNRESET, IOError
        next # client rejected our certificate — expected in TLS tests
      end
    end

    def serve(socket)
      request_line = socket.gets.to_s
      method, path = request_line.split
      headers = {}
      while (line = socket.gets) && line != "\r\n"
        name, value = line.split(":", 2)
        headers[name.downcase] = value.to_s.strip
      end
      body = headers["content-length"] ? socket.read(headers["content-length"].to_i) : nil
      request = Received.new(method, path, headers, body)
      @requests << request

      status, response_headers, response_body = @handler.call(request)
      response_body = response_body.to_s.b
      socket.write("HTTP/1.1 #{status} X\r\n")
      response_headers.merge("Content-Length" => response_body.bytesize, "Connection" => "close")
                      .each { |key, val| socket.write("#{key}: #{val}\r\n") }
      socket.write("\r\n")
      socket.write(response_body)
    rescue IOError, OpenSSL::SSL::SSLError, Errno::ECONNRESET, Errno::EPIPE
      nil
    ensure
      socket.close rescue nil # rubocop:disable Style/RescueModifier
    end
  end
end
