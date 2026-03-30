#!/bin/bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

LOGFILE="${LOGFILE:-/var/log/ads-bv.log}"

# Redirect logs
if [ "$(id -u)" -ne 0 ] || [ ! -w "$(dirname "$LOGFILE")" ]; then
  LOGFILE="$HOME/ads-bv.log"
fi
exec > >(tee -a "$LOGFILE") 2>&1

ts() { date "+%Y-%m-%d %H:%M:%S %Z"; }

echo "[log] script START at $(ts)"
START_TS=$(date +%s)

# Log helper
log() { echo "[$(ts)] $*"; }

# Create + attach + mkfs + mount + fstab
# Mount points adjusted to /export and /export-data
create_attach_prepare_volume() {
  local compartment_id="$1"
  local availability_domain="$2"
  local display_name="$3"
  local size_in_gbs="$4"
  local vpus_per_gb="$5"
  local oci_device="$6"
  local instance_id="$7"
  local fs_label="$8"
  local mount_point="$9"

#   log "Creating $display_name (${size_in_gbs}G vpus=$vpus_per_gb)"
#   local volume_id
#   volume_id=$(oci bv volume create \
#     --compartment-id "$compartment_id" \
#     --availability-domain "$availability_domain" \
#     --display-name "$display_name" \
#     --size-in-gbs "$size_in_gbs" \
#     --vpus-per-gb "$vpus_per_gb" \
#     --wait-for-state AVAILABLE \
#     --query 'data.id' --raw-output)
#   log "Created $display_name ($volume_id)"

#   log "Attaching $display_name to $oci_device"
#   oci compute volume-attachment attach --type paravirtualized \
#     --instance-id "$instance_id" --volume-id "$volume_id" \
#     --device "$oci_device" --wait-for-state ATTACHED
#   log "Attached $display_name"

    ##################
    max_retries=10
    retry_delay=30

    # --- Create volume with retry and error handling ---
    log "Creating $display_name (${size_in_gbs}G vpus=$vpus_per_gb)"
    volume_id=""
    for ((i=1; i<=max_retries; i++)); do
        log "Attempt $i: Creating volume $display_name (${size_in_gbs}G, vpus=$vpus_per_gb)..."
        output=$(oci bv volume create \
            --compartment-id "$compartment_id" \
            --availability-domain "$availability_domain" \
            --display-name "$display_name" \
            --size-in-gbs "$size_in_gbs" \
            --vpus-per-gb "$vpus_per_gb" \
            --wait-for-state AVAILABLE \
            --query 'data.id' --raw-output 2>&1) && status=0 || status=$?

        if [[ $status -eq 0 && -n "$output" ]]; then
            volume_id=$(echo "$output" | grep -o 'ocid1\.volume\.oc1[^ )]*' | head -1)
            log "Created $display_name ($volume_id)"
            break
        fi

        # Check for transient OCI API errors
        if echo "$output" | grep -q '"code": "Conflict"' || \
            echo "$output" | grep -q '"code": "TooManyRequests"' || \
            echo "$output" | grep -q '"code": "InternalError"'; then
            log "OCI returned transient error on attempt $i, retrying in ${retry_delay}s..."
        else
            log "Unexpected error creating volume on attempt $i:"
            echo "$output" >&2
        fi

        sleep "$retry_delay"
    done

    if [[ -z "$volume_id" ]]; then
        log "ERROR: Failed to create volume $display_name after $max_retries attempts."
        exit 1
    fi

    # --- Wait until instance is RUNNING in OCI ---
    log "Waiting for instance $instance_id to reach RUNNING state..."
    for ((i=1; i<=max_retries; i++)); do
        state=$(oci compute instance get --instance-id "$instance_id" \
            --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "UNKNOWN")

        if [[ "$state" == "RUNNING" ]]; then
            log "Instance $instance_id is RUNNING."
            break
        fi

        log "Instance state for $instance_id is $state. Retrying in ${retry_delay}s..."
        sleep "$retry_delay"
    done

    # --- Attach volume with retry and conflict handling ---
    for ((i=1; i<=max_retries; i++)); do
        log "Attempt $i: Attaching $display_name to $oci_device..."
        if oci compute volume-attachment attach \
                --type paravirtualized \
                --instance-id "$instance_id" \
                --volume-id "$volume_id" \
                --device "$oci_device" \
                --wait-for-state ATTACHED; then
            log "Attached $display_name successfully."
            break
        else
            log "Instance $instance_id - Attach failed (attempt $i). Retrying in ${retry_delay}s..."
            sleep "$retry_delay"
        fi
    done
}

log "Checking OCI CLI at $(ts)"
if ! command -v oci >/dev/null 2>&1; then
  log "Installing OCI CLI"
  sudo dnf -y install oraclelinux-developer-release-el8
  sudo dnf -y install python36-oci-cli
else
  log "OCI CLI: $(oci --version)"
fi

log "Fetching metadata at $(ts)"
export OCI_CLI_AUTH=instance_principal
META=$(curl -sS -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance)
instance=$(echo "$META" | jq -r '.id')
compartment=$(echo "$META" | jq -r '.compartmentId')
ad=$(echo "$META" | jq -r '.availabilityDomain' | tr -d '\r')
region=$(echo "$META" | jq -r '.regionInfo.regionIdentifier // .canonicalRegionName // .region')
export OCI_CLI_REGION="$region"
log "Metadata fetched"

#!/bin/bash

set -euo pipefail

LOGFILE="${LOGFILE:-/var/log/ads-bv.log}"

# Redirect logs
if [ "$(id -u)" -ne 0 ] || [ ! -w "$(dirname "$LOGFILE")" ]; then
  LOGFILE="$HOME/ads-bv.log"
fi
exec > >(tee -a "$LOGFILE") 2>&1

ts() { date "+%Y-%m-%d %H:%M:%S %Z"; }

echo "[log] script START at $(ts)"
START_TS=$(date +%s)

# Log helper
log() { echo "[$(ts)] $*"; }

# Create + attach + mkfs + mount + fstab
# Mount points adjusted to /export and /export-data
create_attach_prepare_volume() {
  local compartment_id="$1"
  local availability_domain="$2"
  local display_name="$3"
  local size_in_gbs="$4"
  local vpus_per_gb="$5"
  local oci_device="$6"
  local instance_id="$7"
  local fs_label="$8"
  local mount_point="$9"

#   log "Creating $display_name (${size_in_gbs}G vpus=$vpus_per_gb)"
#   local volume_id
#   volume_id=$(oci bv volume create \
#     --compartment-id "$compartment_id" \
#     --availability-domain "$availability_domain" \
#     --display-name "$display_name" \
#     --size-in-gbs "$size_in_gbs" \
#     --vpus-per-gb "$vpus_per_gb" \
#     --wait-for-state AVAILABLE \
#     --query 'data.id' --raw-output)
#   log "Created $display_name ($volume_id)"

#   log "Attaching $display_name to $oci_device"
#   oci compute volume-attachment attach --type paravirtualized \
#     --instance-id "$instance_id" --volume-id "$volume_id" \
#     --device "$oci_device" --wait-for-state ATTACHED
#   log "Attached $display_name"

    ##################
    max_retries=10
    retry_delay=30

    # --- Create volume with retry and error handling ---
    log "Creating $display_name (${size_in_gbs}G vpus=$vpus_per_gb)"
    volume_id=""
    for ((i=1; i<=max_retries; i++)); do
        log "Attempt $i: Creating volume $display_name (${size_in_gbs}G, vpus=$vpus_per_gb)..."
        output=$(oci bv volume create \
            --compartment-id "$compartment_id" \
            --availability-domain "$availability_domain" \
            --display-name "$display_name" \
            --size-in-gbs "$size_in_gbs" \
            --vpus-per-gb "$vpus_per_gb" \
            --wait-for-state AVAILABLE \
            --query 'data.id' --raw-output 2>&1) && status=0 || status=$?

        if [[ $status -eq 0 && -n "$output" ]]; then
            volume_id=$(echo "$output" | grep -o 'ocid1\.volume\.oc1[^ )]*' | head -1)
            log "Created $display_name ($volume_id)"
            break
        fi

        # Check for transient OCI API errors
        if echo "$output" | grep -q '"code": "Conflict"' || \
            echo "$output" | grep -q '"code": "TooManyRequests"' || \
            echo "$output" | grep -q '"code": "InternalError"'; then
            log "OCI returned transient error on attempt $i, retrying in ${retry_delay}s..."
        else
            log "Unexpected error creating volume on attempt $i:"
            echo "$output" >&2
        fi

        sleep "$retry_delay"
    done

    if [[ -z "$volume_id" ]]; then
        log "ERROR: Failed to create volume $display_name after $max_retries attempts."
        exit 1
    fi

    # --- Wait until instance is RUNNING in OCI ---
    log "Waiting for instance $instance_id to reach RUNNING state..."
    for ((i=1; i<=max_retries; i++)); do
        state=$(oci compute instance get --instance-id "$instance_id" \
            --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "UNKNOWN")

        if [[ "$state" == "RUNNING" ]]; then
            log "Instance $instance_id is RUNNING."
            break
        fi

        log "Instance state for $instance_id is $state. Retrying in ${retry_delay}s..."
        sleep "$retry_delay"
    done

    # --- Attach volume with retry and conflict handling ---
    for ((i=1; i<=max_retries; i++)); do
        log "Attempt $i: Attaching $display_name to $oci_device..."
        if oci compute volume-attachment attach \
                --type paravirtualized \
                --instance-id "$instance_id" \
                --volume-id "$volume_id" \
                --device "$oci_device" \
                --wait-for-state ATTACHED; then
            log "Attached $display_name successfully."
            break
        else
            log "Instance $instance_id - Attach failed (attempt $i). Retrying in ${retry_delay}s..."
            sleep "$retry_delay"
        fi
    done
}

log "Checking OCI CLI at $(ts)"
if ! command -v oci >/dev/null 2>&1; then
  log "Installing OCI CLI"
  sudo dnf -y install oraclelinux-developer-release-el8
  sudo dnf -y install python36-oci-cli
else
  log "OCI CLI: $(oci --version)"
fi

log "Fetching metadata at $(ts)"
export OCI_CLI_AUTH=instance_principal
META=$(curl -sS -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance)
instance=$(echo "$META" | jq -r '.id')
compartment=$(echo "$META" | jq -r '.compartmentId')
ad=$(echo "$META" | jq -r '.availabilityDomain' | tr -d '\r')
region=$(echo "$META" | jq -r '.regionInfo.regionIdentifier // .canonicalRegionName // .region')
export OCI_CLI_REGION="$region"
log "Metadata fetched"

log "Starting BV setup at $(ts)"
# Mount points changed to /export and /export-data to match your image conventions
create_attach_prepare_volume "$compartment" "$ad" "rook-osd-$(hostname -s)-data1" \
  350 10 "/dev/oracleoci/oraclevdb" "$instance" "export" "/export" &
create_attach_prepare_volume "$compartment" "$ad" "rook-osd-$(hostname -s)-data2" \
  700 120 "/dev/oracleoci/oraclevdc" "$instance" "export-data" "/export-data" &
wait
log "BV setup done at $(ts)"

exec > >(tee -a /var/log/ads-taints.log) 2>&1
log "Switched log to /var/log/ads-taints.log"

log "Downloading OKE init script at $(ts)"
curl -fsSL -H "Authorization: Bearer Oracle" \
  http://169.254.169.254/opc/v2/instance/metadata/oke_init_script \
  | base64 -d > /var/run/oke-init.sh
chmod +x /var/run/oke-init.sh

log "Running OKE init at $(ts)"
bash /var/run/oke-init.sh
log "OKE init done at $(ts)"

END_TS=$(date +%s)
DURATION=$(( END_TS - START_TS ))
echo "[log] script END at $(ts), total duration=${DURATION}s"

log "Downloading OKE init script at $(ts)"
curl -fsSL -H "Authorization: Bearer Oracle" \
  http://169.254.169.254/opc/v2/instance/metadata/oke_init_script \
  | base64 -d > /var/run/oke-init.sh
chmod +x /var/run/oke-init.sh

log "Running OKE init at $(ts)"
bash /var/run/oke-init.sh
log "OKE init done at $(ts)"

END_TS=$(date +%s)
DURATION=$(( END_TS - START_TS ))
echo "[log] script END at $(ts), total duration=${DURATION}s"