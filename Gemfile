# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# Gemfile.lock is not committed: the gem supports Ruby 3.1–4.0 and no single
# lockfile resolves on all of them (rbs 4 needs Ruby 3.3+). CI resolves fresh
# on every run and weekly, so a breaking upstream release (like json 3.0) is
# caught before users hit it.

# CI sets JSON_VERSION to test both json 2.x (default gem) and json 3.x.
gem "json", ENV["JSON_VERSION"] if ENV["JSON_VERSION"]

group :test do
  gem "logger", "~> 1.6" # no longer a default gem on Ruby 4.0
  gem "minitest", "~> 6.0"
  gem "rake", "~> 13.0"
end

# Not installed in the release job (BUNDLE_WITHOUT=lint).
group :lint do
  gem "bundler-audit", "~> 0.9", ">= 0.9.3", require: false # 0.9.3+ supports Bundler 4
  gem "rbs", ">= 3.4"
  gem "rubocop", ">= 1.92", "< 2", require: false
  gem "rubocop-minitest", "~> 0.38", require: false
  gem "rubocop-performance", "~> 1.26", require: false
  gem "rubocop-rake", "~> 0.7", require: false
  gem "steep", ">= 1.9", require: false
  gem "yard", "~> 0.9", require: false
end
