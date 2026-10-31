# frozen_string_literal: true

# Coverage from the standard library (no simplecov needed).
# COVERAGE_MIN (percent of lines) and COVERAGE_BRANCH_MIN (percent of
# branches, defaults to COVERAGE_MIN) fail the run when not reached.
if ENV["COVERAGE"] != "0"
  require "coverage"
  Coverage.start(lines: true, branches: true)
end

# Tests must never reach a real proxy or the real API.
%w[http_proxy https_proxy HTTP_PROXY HTTPS_PROXY].each { |name| ENV.delete(name) }
ENV.delete("HASKIMAIL_SERVER_TOKEN")
ENV.delete("HASKIMAIL_ACCOUNT_TOKEN")

LIB_DIR = File.expand_path("../lib", __dir__)

# A Ruby warning raised from the gem's own code fails the run.
module FailOnLibraryWarnings
  def warn(message, *args, **kwargs)
    raise "Ruby warning from lib/: #{message}" if message.include?(LIB_DIR)

    super
  end
end
Warning.singleton_class.prepend(FailOnLibraryWarnings)

$LOAD_PATH.unshift LIB_DIR
require "haskimail"
require "json"
require "minitest/autorun"

require_relative "support/fake_transport"
require_relative "support/fixtures"

# Aborts the run when one test hangs (e.g. a pagination loop that never
# ends), instead of waiting for the CI job timeout.
module TestWatchdog
  LIMIT = Float(ENV.fetch("TEST_TIMEOUT", "60"))
  @current = nil
  @lock = Mutex.new

  class << self
    def arm(name)
      @lock.synchronize { @current = [name, Process.clock_gettime(Process::CLOCK_MONOTONIC) + LIMIT] }
    end

    def disarm
      @lock.synchronize { @current = nil }
    end

    def expired
      @lock.synchronize { @current if @current && Process.clock_gettime(Process::CLOCK_MONOTONIC) > @current[1] }
    end
  end

  Thread.new do
    loop do
      sleep 1
      next unless (name, = expired)

      warn "Test #{name} ran longer than #{LIMIT}s; aborting (set TEST_TIMEOUT to change)"
      $stderr.flush
      exit!(2)
    end
  end

  def before_setup
    TestWatchdog.arm("#{self.class}##{name}")
    super
  end

  def after_teardown
    super
  ensure
    TestWatchdog.disarm
  end
end

module Haskimail
  class TestCase < Minitest::Test
    include TestWatchdog

    SERVER_TOKEN = "server-token-1234"
    ACCOUNT_TOKEN = "account-token-5678"

    def setup
      Haskimail.reset_configuration!
      @transport = FakeTransport.new
      @sleeps = []
    end

    def teardown
      Haskimail.reset_configuration!
      # Raised, not asserted: assertions do not belong in lifecycle hooks.
      raise "#{@transport.pending} queued fake response(s) were never requested" if @transport&.pending&.positive?
    end

    def server_client(**options)
      ServerClient.new(SERVER_TOKEN, transport: @transport, sleeper: ->(s) { @sleeps << s }, **options)
    end

    def account_client(**options)
      AccountClient.new(ACCOUNT_TOKEN, transport: @transport, sleeper: ->(s) { @sleeps << s }, **options)
    end

    def last_request
      @transport.requests.last
    end

    def last_json
      JSON.parse(last_request.body)
    end

    def last_query
      URI.decode_www_form(URI.parse(last_request.url).query.to_s).to_h
    end

    def last_path
      URI.parse(last_request.url).path
    end

    def assert_request(method, path, query: nil)
      assert_equal method, last_request.method
      assert_equal path, last_path
      assert_equal query, last_query if query
    end
  end
end

if defined?(Coverage) && Coverage.running?
  Minitest.after_run do
    lib_dir = LIB_DIR
    results = Coverage.result.select { |file, _| file.start_with?(lib_dir) }
    total = covered = 0
    branch_total = branch_covered = 0
    missed = []
    results.sort.each do |file, data|
      data[:lines].each_with_index do |count, index|
        next if count.nil?

        total += 1
        count.zero? ? missed << "#{file.delete_prefix("#{lib_dir}/")}:#{index + 1}" : covered += 1
      end
      data[:branches]&.each do |(type, *), branches|
        branches.each do |(branch, _id, line, *), count|
          branch_total += 1
          next branch_covered += 1 if count.positive?

          missed << "#{file.delete_prefix("#{lib_dir}/")}:#{line} (#{type} -> #{branch} branch)"
        end
      end
    end
    line_pct = total.zero? ? 100.0 : (covered * 100.0 / total)
    branch_pct = branch_total.zero? ? 100.0 : (branch_covered * 100.0 / branch_total)
    puts format("\nCoverage: lines %.2f%% (%d/%d), branches %.2f%% (%d/%d)",
                line_pct, covered, total, branch_pct, branch_covered, branch_total)
    puts "Uncovered lines:\n  #{missed.join("\n  ")}" unless missed.empty?
    minimum = Float(ENV.fetch("COVERAGE_MIN", "0"))
    branch_minimum = Float(ENV.fetch("COVERAGE_BRANCH_MIN", minimum.to_s))
    failures = []
    failures << format("line coverage %.2f%% < %.2f%%", line_pct, minimum) if line_pct < minimum
    failures << format("branch coverage %.2f%% < %.2f%%", branch_pct, branch_minimum) if branch_pct < branch_minimum
    unless failures.empty?
      warn "Coverage gate failed: #{failures.join(', ')}"
      $stdout.flush
      exit!(1)
    end
  end
end
