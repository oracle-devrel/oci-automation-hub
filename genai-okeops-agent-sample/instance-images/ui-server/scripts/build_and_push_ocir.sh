#!/bin/bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -eu

OCIR_REGION_KEY="${OCIR_REGION_KEY:-iad}"
OCIR_NAMESPACE="${OCIR_NAMESPACE:?Set OCIR_NAMESPACE, for example mytenancynamespace}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-oci-agent}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
REGISTRY_USERNAME="${REGISTRY_USERNAME:?Set REGISTRY_USERNAME, for example namespace/user@example.com}"
REGISTRY_AUTH_TOKEN="${REGISTRY_AUTH_TOKEN:?Set REGISTRY_AUTH_TOKEN to an OCI auth token}"
CREATE_REPOSITORY="${CREATE_REPOSITORY:-false}"
REPOSITORY_COMPARTMENT_ID="${REPOSITORY_COMPARTMENT_ID:-}"
PLATFORM="${PLATFORM:-linux/arm64}"

REGISTRY="${OCIR_REGION_KEY}.ocir.io"
IMAGE_NAME="${REGISTRY}/${OCIR_NAMESPACE}/${IMAGE_REPOSITORY}"
IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [ "$CREATE_REPOSITORY" = "true" ]; then
  if [ -z "$REPOSITORY_COMPARTMENT_ID" ]; then
    printf '%s\n' "Set REPOSITORY_COMPARTMENT_ID when CREATE_REPOSITORY=true" >&2
    exit 1
  fi

  oci artifacts container repository create \
    --compartment-id "$REPOSITORY_COMPARTMENT_ID" \
    --display-name "$IMAGE_REPOSITORY" >/dev/null || true
fi

printf '%s' "$REGISTRY_AUTH_TOKEN" | docker login "$REGISTRY" --username "$REGISTRY_USERNAME" --password-stdin

if [ -n "$PLATFORM" ]; then
  docker buildx build --platform "$PLATFORM" -t "$IMAGE" --push .
else
  docker build -t "$IMAGE" .
  docker push "$IMAGE"
fi

printf '%s\n' "Pushed image: $IMAGE"
