# frozen_string_literal: true

require "bundler/gem_tasks" if File.exist?(File.expand_path("Gemfile.lock", __dir__))
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = true
end

desc "Run the test suite and fail below 100% line and branch coverage"
task :coverage do
  ENV["COVERAGE_MIN"] = "100"
  Rake::Task[:test].invoke
end

# Runs a gem executable with the current Ruby, without relying on binstubs in PATH.
def gem_exec(gem, *args)
  sh Gem.ruby, Gem.bin_path(gem, gem), *args
end

desc "Validate RBS signatures"
task :rbs do
  libraries = %w[uri openssl monitor json net-http zlib digest time date].flat_map { |name| ["-r", name] }
  gem_exec "rbs", *libraries, "-I", "sig", "validate"
end

desc "Type-check lib/ with Steep"
task :steep do
  gem_exec "steep", "check"
end

default_tasks = %i[coverage]
begin
  require "rubocop/rake_task"
  RuboCop::RakeTask.new
  default_tasks.push(:rbs, :steep, :rubocop)
rescue LoadError
  warn "Lint tools are not installed (BUNDLE_WITHOUT=lint?); `rake` runs the tests only"
end

task default: default_tasks
