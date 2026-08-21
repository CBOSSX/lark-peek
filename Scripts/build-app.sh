#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
signing_identity="${LARK_PEEK_CODESIGN_IDENTITY:-Lark Peek Local Code Signing}"
sdk_path="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
cache_root="${TMPDIR:-/tmp}/lark-peek-swiftpm"
scratch_path="$cache_root/build"

export SDKROOT="$sdk_path"
export CLANG_MODULE_CACHE_PATH="$cache_root/clang-modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_root/swift-modules"

swift build \
  --package-path "$project_dir" \
  --configuration release \
  --disable-sandbox \
  --cache-path "$cache_root/cache" \
  --config-path "$cache_root/config" \
  --security-path "$cache_root/security" \
  --scratch-path "$scratch_path" \
  --manifest-cache local

binary_path="$scratch_path/arm64-apple-macosx/release/LarkPeek"
if [[ ! -x "$binary_path" ]]; then
  binary_path="$(swift build --package-path "$project_dir" --configuration release --disable-sandbox --scratch-path "$scratch_path" --show-bin-path)/LarkPeek"
fi

app_path="$project_dir/dist/Lark Peek.app"
if [[ -e "$app_path" ]]; then
  find "$app_path" -depth -delete
fi
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
install -m 755 "$binary_path" "$app_path/Contents/MacOS/LarkPeek"
install -m 644 "$project_dir/Resources/Info.plist" "$app_path/Contents/Info.plist"
install -m 644 "$project_dir/Resources/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
plutil -lint "$app_path/Contents/Info.plist"
if ! security find-identity -v -p codesigning 2>/dev/null \
    | grep -Fq "\"$signing_identity\""; then
  echo "Missing stable signing identity: $signing_identity" >&2
  echo "Run: $project_dir/Scripts/setup-local-signing.sh" >&2
  exit 1
fi
codesign_args=(
  --force
  --options runtime
  --sign "$signing_identity"
)
if [[ "$signing_identity" == "Developer ID Application:"* ]]; then
  codesign_args+=(--timestamp)
else
  codesign_args+=(--timestamp=none)
fi
codesign "${codesign_args[@]}" "$app_path"
echo "$app_path"
