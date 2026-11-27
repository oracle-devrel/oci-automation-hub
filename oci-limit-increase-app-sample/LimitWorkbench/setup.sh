#!/bin/sh

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -eu
LIMIT_SETUP_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LIMIT_SETUP_PYTHON=${LIMIT_SETUP_PYTHON:-python3}
if ! command -v "$LIMIT_SETUP_PYTHON" >/dev/null 2>&1; then
  echo 'Python was not found. Install an approved Python 3.10+ or set LIMIT_SETUP_PYTHON to its executable path.' >&2
  exit 1
fi
exec "$LIMIT_SETUP_PYTHON" "$LIMIT_SETUP_ROOT/scripts/setup_app.py" "$@"
