# Real API responses

Anonymized responses of the live Haskimail API (October 2026). Addresses,
domains, keys and the DKIM key are replaced; structure, types and quirks are
kept as returned: `"Tag": "0"` for untagged emails, `"Region": "26"`, an integer
`0` in `SpamComplaintsRate`, an empty `From` in opens and clicks, emoji in
subjects and the legacy `Unsubsribed` field. Contract tests parse every file.

`webhooks/` holds real webhook requests of every event type and an inbound
email, with the same anonymization. Their `secret` values are re-signed with
the test key `live-webhook-key`, since the real signing key is private. The
original descriptions, codes and field order are kept.
