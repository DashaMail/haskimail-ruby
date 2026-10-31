# frozen_string_literal: true

# Live smoke test against the real Haskimail API. Nothing is sent and nothing
# is changed: sending uses the HASKIMAIL_API_TEST token, everything else is read-only.
#
#   ruby -Ilib examples/smoke_test.rb
#   HASKIMAIL_SERVER_TOKEN=... HASKIMAIL_ACCOUNT_TOKEN=... ruby -Ilib examples/smoke_test.rb
#
# Optional: SMOKE_FROM (a confirmed sender address), SMOKE_TO.

require "haskimail"
require "logger"

failures = 0
step = lambda do |title, &block|
  print "#{title.ljust(48, '.')} "
  detail = block.call
  puts "OK #{detail}"
rescue Haskimail::Error => e
  failures += 1
  puts "FAIL #{e.class}: #{e.message}"
end

from = ENV.fetch("SMOKE_FROM", "sender@example.com")
to = ENV.fetch("SMOKE_TO", "receiver@example.com")
logger = ENV["DEBUG"] ? Logger.new($stderr) : nil

test_client = Haskimail::ServerClient.new(Haskimail::TEST_TOKEN, logger: logger)

step.call("test token: valid email is accepted") do
  result = test_client.emails.deliver(from: from, to: to, subject: "Haskimail Ruby SDK smoke test",
                                      text_body: "Проверка SDK", html_body: "<p>Проверка SDK</p>",
                                      attachments: [Haskimail::Attachment.new(name: "a.txt", content: "hi")])
  "ErrorCode=#{result.error_code}"
end

step.call("test token: invalid email raises 422") do
  test_client.emails.deliver(from: from, to: "not-an-email", text_body: "x")
  raise Haskimail::Error, "expected UnprocessableEntityError"
rescue Haskimail::UnprocessableEntityError => e
  "ErrorCode=#{e.error_code} (#{e.api_message})"
end

step.call("test token: batch reports per-item errors") do
  result = test_client.emails.deliver_batch([
                                              { from: from, to: to, subject: "1", text_body: "ok" },
                                              { from: from, to: "anna.example.com", subject: "2", text_body: "bad" }
                                            ])
  "ok=#{result.successful.size} failed=#{result.failed.map(&:error_code).inspect}"
end

if ENV["HASKIMAIL_SERVER_TOKEN"]
  server = Haskimail::ServerClient.new(logger: logger)
  step.call("message streams") { "#{server.message_streams.list.total_count} streams" }
  step.call("templates (first page)") { "#{server.templates.list(count: 5).total_count} templates" }
  step.call("template validation (no side effects)") do
    result = server.templates.validate(subject: "Заказ {{order}}", test_render_model: { "{{order}}" => "1" })
    "valid=#{result.all_content_is_valid}"
  end
  step.call("outbound messages (last 5)") { "#{server.messages.list(count: 5).total_count} total" }
  step.call("bounce delivery stats") do
    server.bounces.delivery_stats.bounces.map { |bounce| "#{bounce.name}=#{bounce.count}" }.join(", ")
  end
  step.call("stats summary (last 30 days)") do
    stats = server.stats.summary(from_date: Date.today - 30)
    "sent=#{stats.sent} open_rate=#{stats.open_rate}"
  end
  step.call("webhooks") { "#{server.webhooks.list.webhooks.size} webhooks" }
  step.call("inbound rules") { "#{server.inbound_rules.list(count: 5).total_count} rules" }
else
  puts "HASKIMAIL_SERVER_TOKEN not set — server read-only checks skipped"
end

if ENV["HASKIMAIL_ACCOUNT_TOKEN"]
  account = Haskimail::AccountClient.new(logger: logger)
  step.call("servers") { "#{account.servers.list(count: 5).total_count} servers" }
  step.call("domains") { "#{account.domains.list(count: 5).total_count} domains" }
else
  puts "HASKIMAIL_ACCOUNT_TOKEN not set — account read-only checks skipped"
end

puts failures.zero? ? "\nAll checks passed" : "\n#{failures} check(s) failed"
exit(failures.zero? ? 0 : 1)
