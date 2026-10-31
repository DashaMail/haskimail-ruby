# frozen_string_literal: true

require_relative "lib/haskimail/version"

Gem::Specification.new do |spec|
  spec.name = "haskimail"
  spec.version = Haskimail::VERSION
  spec.authors = ["Dashamail"]
  spec.email = ["support@haskimail.ru"]

  spec.summary = "Ruby SDK for the Haskimail transactional email API"
  spec.description = "Send transactional email, manage templates, streams, webhooks, suppressions, " \
                     "servers and domains, read stats and verify webhooks with Haskimail. " \
                     "Zero runtime dependencies."
  spec.homepage = "https://haskimail.ru"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "documentation_uri" => "https://haskimail.ru/developer",
    "changelog_uri" => "https://github.com/Dashamail/haskimail-ruby/blob/main/CHANGELOG.md",
    "source_code_uri" => "https://github.com/Dashamail/haskimail-ruby",
    "bug_tracker_uri" => "https://github.com/Dashamail/haskimail-ruby/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "README.md", "CHANGELOG.md", "LICENSE", "SECURITY.md"]
  spec.require_paths = ["lib"]
end
