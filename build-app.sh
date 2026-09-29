#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
app_dir="$project_dir/dist/钉笺.app"
contents_dir="$app_dir/Contents"

cd "$project_dir"
/bin/rm -rf -- "$app_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
clang -fobjc-arc -O2 -framework Cocoa -framework WebKit -framework UniformTypeIdentifiers -framework EventKit "app/main_web.m" -o "$contents_dir/MacOS/PinnedNote"
cp "Info.plist" "$contents_dir/Info.plist"
cp "assets/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
cp "web-prototype/dist/index.html" "$contents_dir/Resources/ui.html"

codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
