#!/bin/zsh
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd -P)"
dist_directory="$repository_root/dist"
expected_dist_directory="$repository_root/dist"
expected_app_bundle="$expected_dist_directory/Batteries Included.app"
swift_executable="${SWIFT_EXECUTABLE:-swift}"
codesign_executable="${CODESIGN_EXECUTABLE:-/usr/bin/codesign}"
signing_identity="${CODE_SIGN_IDENTITY:--}"

if [[ -L "$dist_directory" ]]; then
  print -u2 -- "Refusing to use a symlinked dist directory."
  exit 1
fi

mkdir -p "$dist_directory"
physical_dist_directory="$(cd "$dist_directory" && pwd -P)"
if [[ "$physical_dist_directory" != "$expected_dist_directory" ]]; then
  print -u2 -- "Refusing to use a dist directory outside $repository_root."
  exit 1
fi

app_bundle="$physical_dist_directory/Batteries Included.app"
if [[ "$app_bundle" != "$expected_app_bundle" || -L "$app_bundle" ]]; then
  print -u2 -- "Refusing to remove an unexpected app bundle path."
  exit 1
fi

cd "$repository_root"
"$swift_executable" build -c release

rm -rf -- "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp ".build/release/BatteriesIncluded" "$app_bundle/Contents/MacOS/BatteriesIncluded"
cp "Resources/Info.plist" "$app_bundle/Contents/Info.plist"

if [[ "$signing_identity" == "-" ]]; then
  timestamp_argument="--timestamp=none"
else
  timestamp_argument="--timestamp"
fi

"$codesign_executable" --force --options runtime "$timestamp_argument" --sign "$signing_identity" "$app_bundle"
"$codesign_executable" --verify --deep --strict --verbose=2 "$app_bundle"
