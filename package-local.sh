#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Info.plist")"
archive="$project_dir/dist/钉笺-macOS-$version.zip"
dmg="$project_dir/dist/钉笺-macOS-$version.dmg"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/pinnednote-dmg.XXXXXX")"

cleanup() {
  rm -rf "$staging_dir"
}
trap cleanup EXIT

"$project_dir/build-app.sh" >/dev/null
rm -f "$archive" "$dmg"
ditto -c -k --sequesterRsrc --keepParent "$project_dir/dist/钉笺.app" "$archive"

ditto "$project_dir/dist/钉笺.app" "$staging_dir/钉笺.app"
cp "$project_dir/安装与升级说明.txt" "$staging_dir/安装与升级说明.txt"
ln -s /Applications "$staging_dir/应用程序"
hdiutil create -volname "钉笺" -srcfolder "$staging_dir" -ov -format UDZO "$dmg" >/dev/null

echo "$archive"
echo "$dmg"
