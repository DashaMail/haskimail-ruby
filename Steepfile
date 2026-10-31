# frozen_string_literal: true

# Type-checks lib/ against sig/ (public API in sig/haskimail.rbs,
# internals in sig/haskimail/internal.rbs). Run: bundle exec steep check
target :lib do
  signature "sig"
  check "lib"
  library "uri", "openssl", "monitor", "json", "net-http", "digest", "zlib", "time", "date", "logger", "pp", "strscan"
  configure_code_diagnostics(Steep::Diagnostic::Ruby.default) do |hash|
    # `{}` / `[]` accumulators are typed by their use; annotating each adds noise.
    hash[Steep::Diagnostic::Ruby::UnannotatedEmptyCollection] = nil
  end
end
