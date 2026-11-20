#!/bin/bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -eu

IMAGE_NAME="${IMAGE_NAME:-oci-agent}"
VERSION="${VERSION:-latest}"
PLATFORM="${PLATFORM:-linux/arm64}"
PUSH="${PUSH:-false}"

TAG="${IMAGE_NAME}:${VERSION}"

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [ -n "$PLATFORM" ]; then
  docker buildx build --platform "$PLATFORM" -t "$TAG" .
else
  docker build -t "$TAG" .
fi

if [ "$PUSH" = "true" ]; then
  docker push "$TAG"
fi

printf '%s\n' "Built image: $TAG"
