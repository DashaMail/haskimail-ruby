# frozen_string_literal: true

module Haskimail
  # Addresses that simulate bounces and spam complaints. The email goes nowhere
  # and Haskimail creates the event immediately — as for a real bounce — so you
  # can test bounce handling and webhooks. They work on live and sandbox
  # servers, do not use the email quota, but do NOT work with {TEST_TOKEN}.
  # https://haskimail.ru/developer/user-guide/sandbox-mode/generate-fake-bounces
  #
  #   client.emails.deliver(from: "shop@example.com", to: Haskimail::TestAddresses::HARD_BOUNCE,
  #                         subject: "Проверка", text_body: "Тест")
  module TestAddresses
    # Domain of the test addresses.
    DOMAIN = "bounce-testing.haskimail.ru"

    # Hard bounce, SMTP code 550 (the recipient does not exist).
    HARD_BOUNCE = "hardbounce@#{DOMAIN}".freeze
    # Soft bounce, SMTP code 450 (the mailbox is temporarily unavailable).
    SOFT_BOUNCE = "softbounce@#{DOMAIN}".freeze
    # Blocked by the recipient's mail server, SMTP code 554.
    BLOCKED = "blocked@#{DOMAIN}".freeze
    # Spam complaint.
    SPAM_COMPLAINT = "spamnotification@#{DOMAIN}".freeze
  end
end
