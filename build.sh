#!/bin/sh
set -eu

if [ "$#" -ne 0 ]; then
    printf '%s\n' "usage: $0" >&2
    exit 2
fi

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
"$project_dir/test.sh"
"$project_dir/scripts/build-app.sh" \
    "$project_dir/build" \
    "${AVEN_VERSION:-0.0.1}" \
    "${AVEN_BUILD_VERSION:-1}"
