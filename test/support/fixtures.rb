# frozen_string_literal: true

module Haskimail
  # Response bodies copied from https://haskimail.ru/developer (October 2026).
  module Fixtures
    SEND_OK = {
      "To" => "ivan@example.com", "SubmittedAt" => "2026-10-07 14:30:12",
      "MessageID" => "6f1c0b2d9e8a4f7b3c5d2e1a0b9c8d7e", "ErrorCode" => 0, "Message" => "OK"
    }.freeze

    BATCH = [
      { "To" => "ivan@example.com", "SubmittedAt" => "2026-10-13 14:30:12",
        "MessageID" => "6f1c0b2d9e8a4f7b3c5d2e1a0b9c8d7e", "ErrorCode" => 0, "Message" => "OK" },
      { "To" => "anna.example.com", "SubmittedAt" => "2026-10-13 14:30:12",
        "MessageID" => nil, "ErrorCode" => 6, "Message" => "Некорректный email-адрес получателя" }
    ].freeze

    TEMPLATE = {
      "TemplateId" => 4521, "Name" => "Заказ оформлен", "Subject" => "Заказ №{{order}} оформлен",
      "HtmlBody" => "<html><body><p>Здравствуйте, {{name}}! Заказ №{{order}} оформлен.</p></body></html>",
      "TextBody" => "Здравствуйте, {{name}}! Заказ №{{order}} оформлен.", "AssociatedServerId" => 11_834
    }.freeze

    TEMPLATE_LIST = {
      "TotalCount" => 2,
      "Templates" => [
        { "TemplateId" => 4521, "Name" => "Заказ оформлен" },
        { "TemplateId" => 4522, "Name" => "Восстановление пароля" }
      ]
    }.freeze

    TEMPLATE_VALIDATION = {
      "AllContentIsValid" => false,
      "Subject" => { "ContentIsValid" => true, "ValidationErrors" => [], "RenderedContent" => "Заказ 1042 оформлен" },
      "HtmlBody" => {
        "ContentIsValid" => false,
        "ValidationErrors" => [{ "Message" => "Нет значения для {{track}}: в TestRenderModel нет такого ключа",
                                 "Line" => 2, "CharacterPosition" => 16 }],
        "RenderedContent" => "<p>Здравствуйте, Иван!</p>\n<p>Трек-номер: {{track}}</p>"
      },
      "SuggestedTemplateModel" => { "{{order}}" => "1042", "{{name}}" => "Иван", "{{track}}" => "track_Value" }
    }.freeze

    MESSAGES = {
      "TotalCount" => 1,
      "Messages" => [{
        "Recipient" => "ivan@example.com", "ReceivedAt" => "2026-10-07 14:30:13", "Tag" => "orders",
        "From" => "shop@example.com", "MessageID" => "6f1c0b2d9e8a4f7b3c5d2e1a0b9c8d7e",
        "Subject" => "Ваш заказ №1042 оформлен", "MessageStream" => "2081", "Status" => "Sent"
      }]
    }.freeze

    DELIVERY_STATS = {
      "Bounces" => [
        { "Name" => "All", "Count" => 253 },
        { "Type" => "HardBounce", "Name" => "Hard bounce", "Count" => 195 }
      ]
    }.freeze

    STATS_SUMMARY = {
      "Sent" => 615, "Bounced" => 64, "Opened" => 166, "Clicked" => 72, "Unsubscribed" => 3,
      "Unsubsribed" => 3, "SpamComplaints" => 10, "BounceRate" => 10.41, "SpamComplaintsRate" => 1.63,
      "OpenRate" => 26.99, "ClickRate" => 11.71
    }.freeze

    EMAIL_CLIENTS = {
      "Days" => [{ "Date" => "2026-10-01", "Apple Mail" => 17, "Outlook 2016" => 12 }],
      "Apple Mail" => 32, "Outlook 2016" => 26, "Mail.ru" => 6
    }.freeze

    SERVER = {
      "ID" => 11_834, "Name" => "Интернет-магазин", "Color" => "purple", "SmtpApiActivated" => true,
      "TrackOpens" => true, "TrackLinks" => "HtmlAndText", "DeliveryType" => "Live",
      "InboundHash" => "451d9b70cf9364d23ff6f9d51d870251", "InboundHookUrl" => "https://example.com/inbound",
      "InboundDomain" => "", "InboundSpamThreshold" => 0, "RawEmailEnabled" => false,
      "ApiTokens" => ["8f3e0c7a-5b2d-4e1f-9a6c-3d7b1e0f2a94"],
      "InboundAddress" => "451d9b70cf9364d23ff6f9d51d870251@inbound.haskimail.ru"
    }.freeze

    DOMAIN = {
      "ID" => 3127, "Name" => "example.com", "DKIMVerified" => true, "WeakDKIM" => false,
      "SPFVerified" => true, "ReturnPathDomainVerified" => true,
      "SPFTextValue" => { "valid" => 1, "name" => "example.com.", "record_type" => "TXT",
                          "value" => "v=spf1 include:_spf.haskisender.ru ~all" },
      "DKIMTextValue" => { "valid" => 1, "name" => "dm._domainkey.example.com.", "record_type" => "TXT",
                           "value" => "v=DKIM1;p=MIGf…;t=s" }
    }.freeze

    WEBHOOK = {
      "ID" => 905, "Url" => "https://example.com/haski-events", "MessageStream" => "2081",
      "Triggers" => {
        "Delivery" => { "Enabled" => true }, "Bounce" => { "Enabled" => true },
        "SpamComplaint" => { "Enabled" => true }, "Open" => { "Enabled" => false },
        "Click" => { "Enabled" => false }, "SubscriptionChange" => { "Enabled" => false }
      }
    }.freeze

    BOUNCE_EVENT = {
      "event" => "bounced", "recipient" => "old-address@example.com", "email" => "old-address@example.com",
      "message_id" => "a41d7c9e2b6f4e0d8c3b5a1f9e7d2c60", "code" => "550",
      "description" => "550 5.1.1 The email account that you tried to reach does not exist",
      "error" => "550 5.1.1 The email account that you tried to reach does not exist",
      "bounce_category" => "hrd", "user_id" => "48213", "campaign_id" => "orders", "member_id" => "0",
      "event_time" => "2026-10-07 14:30:15", "event_time_utc" => "2026-10-07 11:30:15",
      "secret" => "PLACEHOLDER", "custom_vars" => "{\"order_id\":\"1042\"}",
      "server_id" => 11_834, "stream_id" => "2081"
    }.freeze

    INBOUND = {
      "FromName" => "Иван Петров", "MessageStream" => "2081", "From" => "ivan@example.com",
      "FromFull" => { "Email" => "ivan@example.com", "Name" => "Иван Петров", "MailboxHash" => "" },
      "OriginalRecipient" => "451d9b70cf9364d23ff6f9d51d870251+ticket-42@inbound.haskimail.ru",
      "Subject" => "Re: Заказ №42", "MessageID" => "22c74902-a0c1-4511-804f-341342852c90",
      "MailboxHash" => "ticket-42", "TextBody" => "Спасибо, всё получил!",
      "StrippedTextReply" => "Спасибо, всё получил!",
      "Headers" => [{ "Name" => "X-Spam-Score", "Value" => "0.3" },
                    { "Name" => "Message-ID", "Value" => "<CAE8+abc@mail.example.com>" }],
      "Attachments" => [{ "Name" => "check.pdf", "Content" => ["%PDF-1.4 test"].pack("m0"),
                          "ContentType" => "application/pdf", "ContentLength" => 13, "ContentID" => "" }]
    }.freeze
  end
end
