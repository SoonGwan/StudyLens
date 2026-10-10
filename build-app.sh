#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
cd "$project_dir"

swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app_dir="$project_dir/.build/StudyLens.app"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS"
cp "$project_dir/AppBundle/Info.plist" "$app_dir/Contents/Info.plist"
cp "$bin_dir/StudyLens" "$app_dir/Contents/MacOS/StudyLens"
chmod +x "$app_dir/Contents/MacOS/StudyLens"
codesign --force --sign - "$app_dir"

echo "완료: $app_dir"
echo "Finder에서 응용 프로그램 폴더로 옮긴 뒤 실행하세요."
