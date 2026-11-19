# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
###############################################################################
# Teardown helpers
#
# Running the use cases creates state that Terraform does NOT track and that
# blocks `destroy`:
#   * Object Storage objects — uploaded job scripts, Data Flow run logs, and
#     job output. A bucket cannot be deleted while it still holds objects.
#   * The Data Flow warm pool ends up running, and a pool cannot be deleted
#     unless it is stopped first.
#
# These destroy-time hooks stop the pool and empty the buckets just before
# Terraform deletes them. They run `oci` on the machine performing the destroy
# (your workstation for a CLI destroy, the Resource Manager runner for an RM
# destroy). Each command is `|| true`, so if that host has no OCI CLI auth the
# hook simply no-ops and `destroy` still proceeds — in that case run
# `use-cases/cleanup.sh` from the operator (instance-principal auth) before
# destroying.
###############################################################################

resource "null_resource" "pool_stop_on_destroy" {
  count = var.deploy_dataflow && var.dataflow_create_pool ? 1 : 0

  triggers = {
    pool_id = oci_dataflow_pool.this[0].id
    region  = var.region
  }

  provisioner "local-exec" {
    when    = destroy
    command = "oci data-flow pool stop --pool-id ${self.triggers.pool_id} --region ${self.triggers.region} --wait-for-state SUCCEEDED || true"
  }

  depends_on = [oci_dataflow_pool.this]
}

resource "null_resource" "buckets_empty_on_destroy" {
  count = var.deploy_dataflow ? 1 : 0

  triggers = {
    namespace = local.os_namespace
    region    = var.region
    buckets = join(" ", compact([
      var.dataflow_create_scripts_bucket ? local.scripts_bucket_name : "",
      var.dataflow_create_logs_bucket ? local.logs_bucket_name : "",
      var.dataflow_create_warehouse_bucket ? local.warehouse_bucket_name : "",
    ]))
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      for b in ${self.triggers.buckets}; do
        echo "emptying bucket $b"
        oci os object bulk-delete -bn "$b" --namespace ${self.triggers.namespace} --region ${self.triggers.region} --force || true
      done
    EOT
  }

  depends_on = [
    oci_objectstorage_bucket.scripts,
    oci_objectstorage_bucket.logs,
    oci_objectstorage_bucket.warehouse,
  ]
}
