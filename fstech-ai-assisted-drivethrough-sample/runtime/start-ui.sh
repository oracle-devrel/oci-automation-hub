#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/


set -euo pipefail

cd /opt/fstech/app/ui
export NEXT_PUBLIC_AGENT_API_URL=""

if [[ -x /usr/bin/npm ]]; then
  NPM=/usr/bin/npm
elif [[ -x /usr/local/bin/npm ]]; then
  NPM=/usr/local/bin/npm
else
  echo "npm executable was not found" >&2
  exit 127
fi

if [[ ! -f .fstech-build-ready ]]; then
  echo "UI build is missing; installing dependencies and building now"
  NEXT_PUBLIC_AGENT_API_URL="" "$NPM" ci --include=dev
  NEXT_PUBLIC_AGENT_API_URL="" "$NPM" run build
  touch .fstech-build-ready
fi

exec "$NPM" run start -- --hostname 127.0.0.1 --port 3000
