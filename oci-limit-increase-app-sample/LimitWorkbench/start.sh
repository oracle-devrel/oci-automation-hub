#!/usr/bin/env sh

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -eu
APP_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ ! -x "$APP_ROOT/.venv/bin/python" ]; then
  echo 'App environment not found. Run sh setup.sh first.' >&2
  exit 1
fi
exec "$APP_ROOT/.venv/bin/python" "$APP_ROOT/scripts/run_app.py" "$@"
