#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

cd /opt/fstech/app
set -a
source /etc/fstech.env
set +a
export TNS_ADMIN=/opt/fstech/wallet

for attempt in $(seq 1 30); do
  if /opt/fstech/venv/bin/python db_init.py; then
    break
  fi
  if [ "$attempt" -eq 30 ]; then
    echo "Database initialization failed after 30 attempts" >&2
    exit 1
  fi
  sleep 20
done

for attempt in $(seq 1 12); do
  if /opt/fstech/venv/bin/python agent_init.py; then
    break
  fi
  if [ "$attempt" -eq 12 ]; then
    echo "OCI Agent tool reconciliation failed after 12 attempts" >&2
    exit 1
  fi
  sleep 20
done

exec /opt/fstech/venv/bin/uvicorn web_api:app --host 127.0.0.1 --port 8000
