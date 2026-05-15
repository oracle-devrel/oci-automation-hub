#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

LOG_FILE="/var/log/oke-optimized-image-build.log"
MARKER_DIR="/var/lib/oke-optimization"
MARKER_FILE="${MARKER_DIR}/image-build-complete"
MANIFEST_FILE="${MARKER_DIR}/image-build-manifest.json"

mkdir -p "${MARKER_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "Starting optimized OKE image build at $(date -Is)"
echo "Base image OCID: ${BASE_IMAGE_OCID:-unknown}"
echo "Base image name: ${BASE_IMAGE_NAME:-unknown}"
echo "Kubernetes version: ${KUBERNETES_VERSION:-unknown}"
echo "Optimization profile: ${OPTIMIZATION_PROFILE:-fast-start}"

echo "Installing packages that must not be downloaded during Karpenter node boot..."
dnf -y install oraclelinux-developer-release-el8
dnf -y install jq curl python36-oci-cli

if ! command -v crictl >/dev/null 2>&1; then
  echo "crictl is required on the OKE worker image but was not found."
  exit 1
fi

if [[ -z "${PREPULL_IMAGES:-}" ]]; then
  echo "PREPULL_IMAGES must contain at least one image reference."
  exit 1
fi

read -r -a PULL_IMAGES <<< "${PREPULL_IMAGES}"

echo "Starting CRI-O for image pre-pulls..."
systemctl start crio

echo "Pre-pulling OKE bootstrap images into CRI-O storage..."
pull_pids=()
for image in "${PULL_IMAGES[@]}"; do
  (
    echo "Pulling ${image}"
    crictl pull "${image}"
  ) &
  pull_pids+=("$!")
done

for pid in "${pull_pids[@]}"; do
  wait "${pid}"
done

echo "Verifying pre-pulled images..."
for image in "${PULL_IMAGES[@]}"; do
  image_repo="${image%@*}"
  if [[ "${image}" == *@sha256:* ]]; then
    image_digest="${image##*@}"
    crictl images --digests | grep -F "${image_repo}" | grep -F "${image_digest}" >/dev/null
  else
    crictl images --digests | grep -F "${image_repo}" >/dev/null
  fi
done

echo "Writing image build manifest..."
printf '%s\n' "${PULL_IMAGES[@]}" |
  jq -R . |
  jq -s \
    --arg build_time "$(date -Is)" \
    --arg base_image_ocid "${BASE_IMAGE_OCID:-unknown}" \
    --arg base_image_name "${BASE_IMAGE_NAME:-unknown}" \
    --arg kubernetes_version "${KUBERNETES_VERSION:-unknown}" \
    --arg optimization_profile "${OPTIMIZATION_PROFILE:-fast-start}" \
    '{
      build_time: $build_time,
      base_image_ocid: $base_image_ocid,
      base_image_name: $base_image_name,
      kubernetes_version: $kubernetes_version,
      optimization_profile: $optimization_profile,
      prepulled_images: .
    }' > "${MANIFEST_FILE}"

echo "Cleaning transient image-builder state while preserving OKE bootstrap assets and CRI-O image layers..."
dnf clean all
rm -rf /var/cache/dnf/* /var/tmp/* /tmp/*
rm -rf /var/lib/cloud/instances/* /var/lib/cloud/instance
rm -f /root/.bash_history /home/opc/.bash_history
find /var/log -type f ! -name "oke-optimized-image-build.log" -exec truncate -s 0 {} \; || true
truncate -s 0 /etc/machine-id || true

sync
touch "${MARKER_FILE}"
echo "Optimized OKE image build complete at $(date -Is)"
