#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
cd "$project_dir"
signing_identity="${STUDYLENS_SIGNING_IDENTITY:--}"
configuration="release"
output_dir="$project_dir/.build"

usage() {
    cat <<'HELP'
Usage: ./build-app.sh [--identity <identity|->] [--configuration <debug|release>] [--output-dir <directory>]
Default: local ad-hoc signature. STUDYLENS_SIGNING_IDENTITY optionally selects an installed signing certificate.
Explicit certificate signing uses hardened runtime and a timestamp; notarization is a separate distribution step.
HELP
}

while (( $# > 0 )); do
    case "$1" in
        --identity|--configuration|--output-dir)
            if (( $# < 2 )); then usage >&2; exit 2; fi
            case "$1" in
                --identity) signing_identity="$2" ;;
                --configuration) configuration="$2" ;;
                --output-dir) output_dir="$2" ;;
            esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ "$configuration" == "debug" || "$configuration" == "release" ]] || { usage >&2; exit 2; }
[[ -n "$signing_identity" && ( "$signing_identity" == "-" || "$signing_identity" != -* ) ]] || { usage >&2; exit 2; }
[[ -n "$output_dir" ]] || { usage >&2; exit 2; }

swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
mkdir -p "$output_dir"
output_dir="${output_dir:A}"
app_dir="$output_dir/StudyLens.app"
staging_dir="$(mktemp -d "$output_dir/StudyLens-build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/StudyLens.app"
mkdir -p "$staged_app/Contents/MacOS"
cp "$project_dir/AppBundle/Info.plist" "$staged_app/Contents/Info.plist"
cp "$bin_dir/StudyLens" "$staged_app/Contents/MacOS/StudyLens"
chmod +x "$staged_app/Contents/MacOS/StudyLens"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$staged_app/Contents/Info.plist")"
if [[ "$signing_identity" == "-" ]]; then
    codesign --force --sign - --identifier "$bundle_id" "$staged_app"
else
    codesign --force --sign "$signing_identity" --identifier "$bundle_id" --options runtime --timestamp "$staged_app"
fi
codesign --verify --strict "$staged_app"
# Replace only after build and signature verification succeed.
rm -rf "$app_dir"
mv "$staged_app" "$app_dir"
echo "완료: $app_dir"
echo "Finder에서 같은 설치 경로의 앱을 교체한 뒤 실행하세요."
