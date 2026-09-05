#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    printf '%s\n' "usage: $0 <version>" >&2
    exit 2
fi

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=$1
dist_dir="$project_dir/dist"
app_dir="$dist_dir/Aven.app"
notary_profile=${MACOS_NOTARY_PROFILE:-}

case "$version" in
    ''|*[!0-9A-Za-z.-]*) printf '%s\n' "Invalid version: $version" >&2; exit 2 ;;
esac
build_version=$(printf '%s' "$version" | /usr/bin/sed 's/[^0-9.].*$//')
case "$build_version" in
    ''|*[!0-9.]*|.*|*.|*..*) printf '%s\n' "Version has no valid numeric build component: $version" >&2; exit 2 ;;
esac
if [ -e "$dist_dir" ]; then
    /bin/rm -R "$dist_dir"
fi
/bin/mkdir -p "$dist_dir"
"$project_dir/scripts/build-app.sh" "$dist_dir" "$version" "$build_version"

zip_path="$dist_dir/Aven-$version.zip"
dmg_path="$dist_dir/Aven-$version.dmg"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$zip_path"
dmg_stage=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/aven-dmg.XXXXXX")
trap '/bin/rm -R "$dmg_stage"' EXIT HUP INT TERM
/usr/bin/ditto "$app_dir" "$dmg_stage/Aven.app"
/bin/ln -s /Applications "$dmg_stage/Applications"
/usr/bin/hdiutil create \
    -volname Aven \
    -srcfolder "$dmg_stage" \
    -ov \
    -format UDZO \
    "$dmg_path" >/dev/null
/usr/bin/hdiutil verify "$dmg_path" >/dev/null
if [ -n "$notary_profile" ]; then
    /usr/bin/xcrun notarytool submit \
        "$dmg_path" \
        --keychain-profile "$notary_profile" \
        --wait \
        --timeout 30m
    /usr/bin/xcrun stapler staple "$dmg_path"
fi
printf '%s\n' "$zip_path" "$dmg_path"
