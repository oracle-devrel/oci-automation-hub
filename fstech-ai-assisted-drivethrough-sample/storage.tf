# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_objectstorage_bucket" "app" {
  compartment_id = oci_identity_compartment.application_layers["application"].id
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = "${var.name_prefix}-drive-thru-${random_string.deployment.result}"
  access_type    = "NoPublicAccess"
  auto_tiering   = "InfrequentAccess"
  freeform_tags  = var.freeform_tags
}

resource "oci_objectstorage_object" "runtime" {
  namespace = data.oci_objectstorage_namespace.this.namespace
  bucket    = oci_objectstorage_bucket.app.name
  object    = "deployment/fstech-runtime-${data.archive_file.runtime.output_md5}.zip"
  source    = data.archive_file.runtime.output_path
  # Serialize the two uploads. The wallet object can only complete after the
  # bucket create operation has returned successfully.
  depends_on = [oci_objectstorage_object.wallet]
}

resource "oci_objectstorage_object" "wallet" {
  namespace    = data.oci_objectstorage_namespace.this.namespace
  bucket       = oci_objectstorage_bucket.app.name
  object       = "deployment/adb-wallet.zip.b64"
  content      = oci_database_autonomous_database_wallet.app.content
  content_type = "text/plain"
  depends_on   = [oci_objectstorage_bucket.app]
}

resource "oci_objectstorage_preauthrequest" "runtime" {
  namespace    = data.oci_objectstorage_namespace.this.namespace
  bucket       = oci_objectstorage_bucket.app.name
  name         = "${var.name_prefix}-runtime-bootstrap"
  access_type  = "ObjectRead"
  object_name  = oci_objectstorage_object.runtime.object
  time_expires = timeadd(timestamp(), "87600h")

  lifecycle {
    ignore_changes = [time_expires]
  }
}

resource "oci_objectstorage_preauthrequest" "wallet" {
  namespace    = data.oci_objectstorage_namespace.this.namespace
  bucket       = oci_objectstorage_bucket.app.name
  name         = "${var.name_prefix}-wallet-bootstrap"
  access_type  = "ObjectRead"
  object_name  = oci_objectstorage_object.wallet.object
  time_expires = timeadd(timestamp(), "87600h")

  lifecycle {
    ignore_changes = [time_expires]
  }
}
