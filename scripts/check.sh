#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ ! -x "$project_dir/.venv/bin/python" ]; then
    /usr/bin/python3 -m venv "$project_dir/.venv"
fi
if ! "$project_dir/.venv/bin/python" -c 'import yaml' 2>/dev/null; then
    "$project_dir/.venv/bin/python" -m pip install \
        --disable-pip-version-check \
        --requirement "$project_dir/requirements-dev.txt" >/dev/null
fi
"$project_dir/test.sh"
