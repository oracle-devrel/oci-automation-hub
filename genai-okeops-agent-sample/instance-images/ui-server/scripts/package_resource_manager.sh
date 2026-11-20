#!/bin/bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/dist"
STACK_ROOT="$ROOT_DIR/deploy/resource-manager"

package_stack() {
  name="$1"
  stack_dir="$STACK_ROOT/$name"
  out_file="$OUT_DIR/oci-agent-$name-resource-manager.zip"

  if [ ! -d "$stack_dir" ]; then
    printf '%s\n' "Missing stack directory: $stack_dir" >&2
    exit 1
  fi

  mkdir -p "$OUT_DIR"
  rm -f "$out_file"
  if [ "$name" = "all-in-one-devops-container" ] || [ "$name" = "all-in-one-rm-docker-container" ]; then
    source_dir="$stack_dir/source"
    rm -rf "$source_dir"
    mkdir -p "$source_dir"
    (
      cd "$ROOT_DIR"
      tar \
        --exclude './.git' \
        --exclude './.env' \
        --exclude './.env.*' \
        --exclude './.DS_Store' \
        --exclude './__pycache__' \
        --exclude './backend/__pycache__' \
        --exclude './scripts/__pycache__' \
        --exclude './.vscode' \
        --exclude './data' \
        --exclude './certs' \
        --exclude './dist' \
        --exclude './deploy' \
        -cf - .
    ) | (
      cd "$source_dir"
      tar -xf -
    )
  fi

  cd "$stack_dir"
  zip -r "$out_file" . -x '*.DS_Store'
  printf '%s\n' "Created Resource Manager stack: $out_file"
}

if [ "$#" -gt 0 ]; then
  package_stack "$1"
else
  package_stack "all-in-one-rm-docker-container"
  package_stack "all-in-one-devops-container"
  package_stack "container-instance-lb"
  package_stack "enterprise-ai-application"
fi
