#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    printf '%s\n' "usage: $0 <output-directory> <version> <build-version>" >&2
    exit 2
fi

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=$1
version=$2
build_version=$3
app_dir="$output_dir/Aven.app"
iconset="$output_dir/AppIcon.iconset"
project="$project_dir/Aven.xcodeproj"
signing_identity=${MACOS_SIGNING_IDENTITY:--}

case "$version" in
    ''|*[!0-9A-Za-z.-]*) printf '%s\n' "Invalid version: $version" >&2; exit 2 ;;
esac
case "$build_version" in
    ''|*[!0-9.]*|.*|*.|*..*) printf '%s\n' "Invalid build version: $build_version" >&2; exit 2 ;;
esac
if [ ! -d "$project" ]; then
    printf '%s\n' "Aven.xcodeproj is missing. Install XcodeGen and run: xcodegen generate" >&2
    exit 1
fi

/bin/mkdir -p "$output_dir"
if [ -e "$app_dir" ]; then
    /bin/rm -R "$app_dir"
fi
if [ -e "$iconset" ]; then
    /bin/rm -R "$iconset"
fi
/bin/mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$project_dir/Resources/AppIcon-1024.png" \
        --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    /usr/bin/sips -z "$retina" "$retina" "$project_dir/Resources/AppIcon-1024.png" \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

xcodebuild \
    -project "$project" \
    -scheme Aven \
    -configuration Release \
    -derivedDataPath "$output_dir/DerivedData" \
    CONFIGURATION_BUILD_DIR="$output_dir" \
    CODE_SIGNING_ALLOWED=NO \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build_version" \
    build >/dev/null

metadata="$app_dir/Contents/Resources/Metadata.appintents/extract.actionsdata"
if [ ! -s "$metadata" ]; then
    printf '%s\n' "Xcode did not produce discoverable App Intents metadata." >&2
    exit 3
fi
architectures=$(/usr/bin/lipo -archs "$app_dir/Contents/MacOS/Aven")
case " $architectures " in
    *" arm64 "*) ;;
    *) printf '%s\n' "Aven is missing the arm64 architecture." >&2; exit 4 ;;
esac
case " $architectures " in
    *" x86_64 "*) ;;
    *) printf '%s\n' "Aven is missing the x86_64 architecture." >&2; exit 5 ;;
esac

/bin/mkdir -p "$app_dir/Contents/Resources"
/usr/bin/iconutil -c icns "$iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
/bin/rm -R "$iconset"
if [ "$signing_identity" = '-' ]; then
    /usr/bin/codesign \
        --force \
        --sign - \
        --timestamp=none \
        --options runtime \
        --entitlements "$project_dir/Resources/Aven.entitlements" \
        "$app_dir" >/dev/null
else
    /usr/bin/codesign \
        --force \
        --sign "$signing_identity" \
        --timestamp \
        --options runtime \
        --entitlements "$project_dir/Resources/Aven.entitlements" \
        "$app_dir" >/dev/null
fi
/usr/bin/codesign --verify --deep --strict "$app_dir"
/usr/bin/plutil -lint "$app_dir/Contents/Info.plist" >/dev/null
test "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$app_dir/Contents/Info.plist")" = "$version"
test "$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$app_dir/Contents/Info.plist")" = "$build_version"

printf '%s\n' "$app_dir"
