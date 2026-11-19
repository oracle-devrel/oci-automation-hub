#!/bin/bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

# Retry transient package-manager failures, including RPM lock contention.
retry() {
    local attempt rc
    for ((attempt = 1; attempt <= 30; attempt++)); do
        if "$@"; then
            return 0
        else
            rc=$?
        fi

        if ((attempt == 30)); then
            echo "Failed after $attempt attempts: $*" >&2
            return "$rc"
        fi

        echo "Attempt $attempt failed (exit $rc); retrying in 10s: $*" >&2
        sleep 10
    done
}

# --- OL9 prep ---
retry dnf -y install git dnf-plugins-core
retry dnf -y remove podman-docker

# --- Install docker ---
# add Docker repository
retry dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo

# install Docker Engine
retry dnf -y install docker-ce docker-ce-cli containerd.io
# start Docker service
systemctl enable --now docker
# verify installation
docker version
# add user to docker group
usermod -aG docker opc
