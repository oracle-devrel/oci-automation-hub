# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

# This is a template for the rook-ceph-cluster Helm chart values.
# It is rendered by Terraform and passed to the helm_release resource.

# For a production deployment on OKE, you should provision your worker nodes
# with additional block storage devices. Rook/Ceph will then use those raw,
# unformatted devices to create its OSDs (Object Storage Daemons).
# Setting 'useAllDevices: true' tells Rook to automatically discover and use
# any available block devices on the nodes.
operatorNamespace: rook-ceph
clusterName: rook-ceph

cephClusterSpec:
  dataDirHostPath: /var/lib/rook

  mon:
    count: 3
    allowMultiplePerNode: false
  mgr:
    count: 2
    allowMultiplePerNode: false

  dashboard:
    enabled: true

  # Use ONLY your attached BV device on each node
  storage:
    useAllNodes: true
    useAllDevices: false
    deviceFilter: ^sd[b-c]$

cephBlockPools:
  - name: ceph-blockpool
    spec:
      failureDomain: host
      replicated:
        size: 3
    storageClass:
      enabled: true
      name: rook-ceph-block
      isDefault: true
      reclaimPolicy: Delete
      allowVolumeExpansion: true
      volumeBindingMode: WaitForFirstConsumer
      parameters:
        clusterID: rook-ceph
        imageFeatures: "layering,fast-diff,object-map,deep-flatten,exclusive-lock"

# Toolbox deployed by the same chart
toolbox:
  enabled: true
  