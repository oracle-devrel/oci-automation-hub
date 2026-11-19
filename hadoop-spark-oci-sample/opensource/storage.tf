# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

###############################################################################
# OCI Object Storage  (created when deploy_object_storage = true)
#
# A private, versioned bucket used as a data lake. Spark pods reach it with no
# static credentials via OKE Workload Identity (see iam.tf). OCI Object Storage
# is encrypted at rest by default.
###############################################################################

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.compartment_ocid
}

resource "oci_objectstorage_bucket" "data" {
  count = var.deploy_object_storage ? 1 : 0

  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = local.bucket_name
  access_type    = "NoPublicAccess"
  versioning     = "Enabled"
  freeform_tags  = local.freeform_tags
}

# The OCI provider cannot delete a non-empty bucket (there is no force_destroy),
# and versioning keeps old object versions around - so `terraform destroy` fails
# with 409-BucketNotEmpty once any data has been written. When force_destroy_bucket
# is true, empty the bucket (all objects AND versions) at destroy time, BEFORE the
# bucket resource is removed (depends_on drives that ordering). Requires the `oci`
# CLI (which bundles python3) on the apply/destroy host - present in OCI Resource
# Manager. Set force_destroy_bucket = false to protect real data from teardown.
resource "null_resource" "empty_bucket_on_destroy" {
  count = var.deploy_object_storage && var.force_destroy_bucket ? 1 : 0

  triggers = {
    bucket    = local.bucket_name
    namespace = data.oci_objectstorage_namespace.this.namespace
    region    = var.region
  }

  depends_on = [oci_objectstorage_bucket.data]

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    environment = {
      B = self.triggers.bucket
      N = self.triggers.namespace
      R = self.triggers.region
    }
    command = <<-EOT
      set -uo pipefail
      oci os object bulk-delete -bn "$B" -ns "$N" --region "$R" --force 2>/dev/null || true
      oci os object list-object-versions -bn "$B" -ns "$N" --region "$R" --all --output json 2>/dev/null \
      | python3 -c 'import sys, json, subprocess, os
B, N, R = os.environ["B"], os.environ["N"], os.environ["R"]
data = json.load(sys.stdin).get("data", []) or []
items = data.get("items", []) if isinstance(data, dict) else data
for it in items:
    subprocess.run(["oci", "os", "object", "delete", "-bn", B, "-ns", N, "--region", R,
                    "--name", it["name"], "--version-id", it["version-id"], "--force"], check=False)
print("emptied %d object versions from %s" % (len(items), B))'
    EOT
  }
}
