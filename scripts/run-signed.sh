#!/usr/bin/env bash
set -euo pipefail

product="CodexNotionBridge"
identifier="${CODE_SIGN_IDENTIFIER:-com.jonathanbeckman.CodexNotionBridge.dev}"

identity="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(
    security find-identity -p codesigning -v \
      | awk -F '"' '/Apple Development/ { print $2; exit }'
  )"
fi

if [[ -z "$identity" ]]; then
  echo "No code-signing identity found. Set CODE_SIGN_IDENTITY or create an Apple Development certificate." >&2
  exit 1
fi

swift build --product "$product"
bin_path="$(swift build --show-bin-path)"
executable="$bin_path/$product"

codesign --force --sign "$identity" --identifier "$identifier" --timestamp=none "$executable"
exec "$executable" "$@"
