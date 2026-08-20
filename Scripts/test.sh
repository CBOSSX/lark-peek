#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
sdk_path="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
cache_root="${TMPDIR:-/tmp}/lark-peek-tests"
developer_frameworks="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
developer_libraries="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

export SDKROOT="$sdk_path"
export CLANG_MODULE_CACHE_PATH="$cache_root/clang-modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_root/swift-modules"

extra_flags=()
if [[ -d "$developer_frameworks/Testing.framework" ]]; then
  extra_flags=(
    -Xswiftc -F -Xswiftc "$developer_frameworks"
    -Xlinker -F -Xlinker "$developer_frameworks"
    -Xlinker -rpath -Xlinker "$developer_frameworks"
    -Xlinker -rpath -Xlinker "$developer_libraries"
  )
fi

swift test \
  --package-path "$project_dir" \
  --disable-sandbox \
  --cache-path "$cache_root/cache" \
  --config-path "$cache_root/config" \
  --security-path "$cache_root/security" \
  --scratch-path "$cache_root/build" \
  --manifest-cache local \
  --enable-swift-testing \
  --disable-xctest \
  "${extra_flags[@]}"
