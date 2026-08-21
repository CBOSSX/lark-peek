#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
signing_identity="${LARK_PEEK_CODESIGN_IDENTITY:-}"
notary_profile="${LARK_PEEK_NOTARY_PROFILE:-LarkPeekNotary}"
app_path="$project_dir/dist/Lark Peek.app"
archive_path="$project_dir/dist/Lark-Peek.zip"

if [[ "$signing_identity" != "Developer ID Application:"* ]]; then
  echo "Set LARK_PEEK_CODESIGN_IDENTITY to a Developer ID Application identity." >&2
  exit 1
fi

LARK_PEEK_CODESIGN_IDENTITY="$signing_identity" "$project_dir/Scripts/build-app.sh"
codesign --verify --deep --strict --verbose=2 "$app_path"

submission_dir="$(mktemp -d "${TMPDIR:-/tmp}/lark-peek-notary.XXXXXX")"
cleanup() {
  if [[ -d "$submission_dir" ]]; then
    find "$submission_dir" -type f -delete
    find "$submission_dir" -depth -type d -delete
  fi
}
trap cleanup EXIT

submission_archive="$submission_dir/Lark-Peek.zip"
ditto -c -k --keepParent "$app_path" "$submission_archive"
xcrun notarytool submit "$submission_archive" \
  --keychain-profile "$notary_profile" \
  --wait \
  --timeout 30m

xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

if [[ -e "$archive_path" ]]; then
  find "$archive_path" -maxdepth 0 -delete
fi
ditto -c -k --keepParent "$app_path" "$archive_path"
echo "$archive_path"
