#!/bin/zsh
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd -P)"
dist_directory="$repository_root/dist"
app_bundle="$dist_directory/Batteries Included.app"

case "$app_bundle" in
  "$repository_root/dist/"*) ;;
  *)
    print -u2 -- "Refusing to remove an app bundle outside $repository_root/dist/."
    exit 1
    ;;
esac

cd "$repository_root"
swift build -c release

rm -rf -- "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp ".build/release/BatteriesIncluded" "$app_bundle/Contents/MacOS/BatteriesIncluded"
cp "Resources/Info.plist" "$app_bundle/Contents/Info.plist"

/usr/bin/codesign --force --options runtime --timestamp=none --sign "${CODE_SIGN_IDENTITY:--}" "$app_bundle"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle"
