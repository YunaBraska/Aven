#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_app="$project_dir/build/Aven.app"
target_app="/Applications/Aven.app"
legacy_app="/Applications/Voice Assistant.app"
codex_path=$(command -v codex 2>/dev/null || true)
brew_path=$(command -v brew 2>/dev/null || true)
bundle_identifier="com.yunabraska.aven"
# SHA-256 of the strictly allowlisted pre-release bundle identifier. Keeping only the
# digest prevents the retired organization name from leaking into the public project.
legacy_identifier_sha256="f6c2c8e1caab698e80f430381e421190ab6bb2a7bd8f29a3f84cca2e4acd3af4"
stage_root=""
staged_app=""
backup_app=""
backup_original_path=""
existing_app=""
existing_identifier=""
extra_legacy_app=""
swap_phase="idle"
installation_complete=false
preferences_changed=false
current_preferences_existed=false
current_preferences_backup=""

bundle_identifier_of() {
    /usr/bin/defaults read "$1/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || true
}

identifier_digest() {
    printf '%s' "$1" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

is_supported_existing_identifier() {
    [ "$1" = "$bundle_identifier" ] || [ "$(identifier_digest "$1")" = "$legacy_identifier_sha256" ]
}

aven_processes_running() {
    /usr/bin/pgrep -f '^/Applications/Aven[.]app/Contents/MacOS/Aven$' >/dev/null 2>&1 \
        || /usr/bin/pgrep -f '^/Applications/Aven[.]app/Contents/MacOS/VoiceAssistant$' >/dev/null 2>&1 \
        || /usr/bin/pgrep -f '^/Applications/Voice Assistant[.]app/Contents/MacOS/VoiceAssistant$' >/dev/null 2>&1
}

stop_aven_instances() {
    /usr/bin/pkill -f '^/Applications/Aven[.]app/Contents/MacOS/Aven$' 2>/dev/null || true
    /usr/bin/pkill -f '^/Applications/Aven[.]app/Contents/MacOS/VoiceAssistant$' 2>/dev/null || true
    /usr/bin/pkill -f '^/Applications/Voice Assistant[.]app/Contents/MacOS/VoiceAssistant$' 2>/dev/null || true
    attempts=0
    while aven_processes_running; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 50 ]; then
            /usr/bin/pkill -KILL -f '^/Applications/Aven[.]app/Contents/MacOS/Aven$' 2>/dev/null || true
            /usr/bin/pkill -KILL -f '^/Applications/Aven[.]app/Contents/MacOS/VoiceAssistant$' 2>/dev/null || true
            /usr/bin/pkill -KILL -f '^/Applications/Voice Assistant[.]app/Contents/MacOS/VoiceAssistant$' 2>/dev/null || true
            break
        fi
        /bin/sleep 0.1
    done
    attempts=0
    while aven_processes_running; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 50 ]; then
            printf '%s\n' "A previous Aven process could not be stopped; installation was not changed." >&2
            return 1
        fi
        /bin/sleep 0.1
    done
}

defaults_domain_exists() {
    /usr/bin/defaults domains \
        | /usr/bin/tr ',' '\n' \
        | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | /usr/bin/grep -Fqx "$1"
}

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ "$installation_complete" != true ] && [ "$swap_phase" = "started" ]; then
        if [ -n "$backup_app" ] && [ -e "$backup_app" ]; then
            if [ -e "$target_app" ]; then
                /bin/rm -R "$target_app"
            fi
            /bin/mv "$backup_app" "$backup_original_path"
            /usr/bin/open "$backup_original_path" >/dev/null 2>&1 || true
        elif [ -z "$existing_app" ] && [ -e "$target_app" ]; then
            /bin/rm -R "$target_app"
        fi
    fi
    if [ "$installation_complete" != true ] && [ "$preferences_changed" = true ]; then
        if [ "$current_preferences_existed" = true ]; then
            /usr/bin/defaults import "$bundle_identifier" "$current_preferences_backup" >/dev/null 2>&1 || true
        else
            /usr/bin/defaults delete "$bundle_identifier" >/dev/null 2>&1 || true
        fi
    fi
    if [ -n "$stage_root" ] && [ -d "$stage_root" ]; then
        /bin/rm -R "$stage_root"
    fi
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

if [ "$#" -ne 0 ]; then
    printf '%s\n' "usage: $0" >&2
    exit 2
fi

"$project_dir/build.sh"

source_identifier=$(bundle_identifier_of "$source_app")
if [ "$source_identifier" != "$bundle_identifier" ]; then
    printf '%s\n' "Refusing to install a build with unexpected bundle identifier: $source_identifier" >&2
    exit 3
fi
/usr/bin/codesign --verify --deep --strict "$source_app"

if [ -e "$target_app" ]; then
    existing_identifier=$(bundle_identifier_of "$target_app")
    if ! is_supported_existing_identifier "$existing_identifier"; then
        printf '%s\n' "Refusing to replace an unrelated application at $target_app" >&2
        exit 4
    fi
    existing_app="$target_app"
fi
if [ -e "$legacy_app" ]; then
    legacy_identifier=$(bundle_identifier_of "$legacy_app")
    if [ "$(identifier_digest "$legacy_identifier")" != "$legacy_identifier_sha256" ]; then
        printf '%s\n' "Refusing to migrate an unrelated application at $legacy_app" >&2
        exit 4
    fi
    if [ -n "$existing_app" ]; then
        extra_legacy_app="$legacy_app"
    else
        existing_app="$legacy_app"
        existing_identifier="$legacy_identifier"
    fi
fi

stage_root=$(/usr/bin/mktemp -d "/Applications/.aven-install.XXXXXX")
staged_app="$stage_root/Aven.app"
backup_app="$stage_root/Previous.app"
/usr/bin/ditto "$source_app" "$staged_app"
/usr/bin/codesign --verify --deep --strict "$staged_app"
staged_identifier=$(bundle_identifier_of "$staged_app")
if [ "$staged_identifier" != "$bundle_identifier" ]; then
    printf '%s\n' "Staged Aven failed identity verification." >&2
    exit 5
fi

if [ -n "$existing_identifier" ] && [ "$existing_identifier" != "$bundle_identifier" ]; then
    legacy_preferences="$stage_root/legacy-preferences.plist"
    current_preferences_backup="$stage_root/current-preferences.plist"
    if defaults_domain_exists "$bundle_identifier"; then
        if ! /usr/bin/defaults export "$bundle_identifier" "$current_preferences_backup" >/dev/null; then
            printf '%s\n' "Current Aven preferences could not be backed up; installation stopped." >&2
            exit 5
        fi
        current_preferences_existed=true
    fi
    if defaults_domain_exists "$existing_identifier"; then
        if ! /usr/bin/defaults export "$existing_identifier" "$legacy_preferences" >/dev/null; then
            printf '%s\n' "Existing assistant preferences could not be migrated; installation stopped." >&2
            exit 5
        fi
    fi
fi

stop_aven_instances
swap_phase="started"
if [ -n "$existing_app" ]; then
    backup_original_path="$existing_app"
    /bin/mv "$existing_app" "$backup_app"
fi
/bin/mv "$staged_app" "$target_app"

if [ -n "${legacy_preferences:-}" ] && [ -f "$legacy_preferences" ]; then
    /usr/bin/defaults import "$bundle_identifier" "$legacy_preferences" >/dev/null
    preferences_changed=true
fi

if [ -n "$codex_path" ]; then
    /usr/bin/defaults write "$bundle_identifier" voiceAssistant.codexExecutablePath "$codex_path"
fi
if [ -n "$brew_path" ]; then
    /usr/bin/defaults write "$bundle_identifier" voiceAssistant.homebrewExecutablePath "$brew_path"
fi
if ! /usr/bin/open "$target_app"; then
    printf '%s\n' "Aven could not be launched; the previous installation will be restored." >&2
    exit 6
fi
attempts=0
while ! /usr/bin/pgrep -f '^/Applications/Aven[.]app/Contents/MacOS/Aven$' >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 50 ]; then
        printf '%s\n' "Aven did not become ready; the previous installation will be restored." >&2
        exit 6
    fi
    /bin/sleep 0.1
done
installation_complete=true
swap_phase="complete"
if [ -e "$backup_app" ]; then
    /bin/rm -R "$backup_app"
fi
if [ -n "$extra_legacy_app" ] && [ -e "$extra_legacy_app" ]; then
    /bin/rm -R "$extra_legacy_app"
fi
printf '%s\n' "$target_app"
