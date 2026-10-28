# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
output "cluster_id" {
  value = oci_containerengine_cluster.this.id
}

output "node_pool_id" {
  value = oci_containerengine_node_pool.this.id
}
