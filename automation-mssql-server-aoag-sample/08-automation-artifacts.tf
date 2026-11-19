# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
data "oci_objectstorage_namespace" "automation" {
  compartment_id = var.compartment_id
}

locals {
  automation_bucket_name = "aoag-automation-${substr(md5(var.compartment_id), 0, 12)}"
  automation_object_urls = {
    sql           = "https://objectstorage.${var.region}.oraclecloud.com${oci_objectstorage_preauthrequest.sql.access_uri}"
    wsfc          = "https://objectstorage.${var.region}.oraclecloud.com${oci_objectstorage_preauthrequest.wsfc.access_uri}"
    sample        = "https://objectstorage.${var.region}.oraclecloud.com${oci_objectstorage_preauthrequest.sample.access_uri}"
    ag            = "https://objectstorage.${var.region}.oraclecloud.com${oci_objectstorage_preauthrequest.ag.access_uri}"
    safe_failover = "https://objectstorage.${var.region}.oraclecloud.com${oci_objectstorage_preauthrequest.safe_failover.access_uri}"
    reconcile     = "https://objectstorage.${var.region}.oraclecloud.com${oci_objectstorage_preauthrequest.reconcile.access_uri}"
  }
}

resource "oci_objectstorage_bucket" "automation" {
  compartment_id = var.compartment_id
  namespace      = data.oci_objectstorage_namespace.automation.namespace
  name           = local.automation_bucket_name
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"

  freeform_tags = merge(var.freeform_tags, {
    Purpose = "terraform-first-boot-automation"
  })
}

resource "oci_objectstorage_object" "sql" {
  namespace    = data.oci_objectstorage_namespace.automation.namespace
  bucket       = oci_objectstorage_bucket.automation.name
  object       = "scripts/02-configure-sql-node.ps1"
  source       = "${path.module}/scripts/sql/02-configure-sql-node.ps1"
  content_type = "text/plain"
}

resource "oci_objectstorage_object" "wsfc" {
  namespace    = data.oci_objectstorage_namespace.automation.namespace
  bucket       = oci_objectstorage_bucket.automation.name
  object       = "scripts/03-configure-wsfc.ps1"
  source       = "${path.module}/scripts/wsfc/03-configure-wsfc.ps1"
  content_type = "text/plain"
}

resource "oci_objectstorage_object" "sample" {
  namespace    = data.oci_objectstorage_namespace.automation.namespace
  bucket       = oci_objectstorage_bucket.automation.name
  object       = "scripts/04-prepare-sample-database.ps1"
  source       = "${path.module}/scripts/aoag/04-prepare-sample-database.ps1"
  content_type = "text/plain"
}

resource "oci_objectstorage_object" "ag" {
  namespace    = data.oci_objectstorage_namespace.automation.namespace
  bucket       = oci_objectstorage_bucket.automation.name
  object       = "scripts/05-configure-availability-group.ps1"
  source       = "${path.module}/scripts/aoag/05-configure-availability-group.ps1"
  content_type = "text/plain"
}

resource "oci_objectstorage_object" "safe_failover" {
  namespace    = data.oci_objectstorage_namespace.automation.namespace
  bucket       = oci_objectstorage_bucket.automation.name
  object       = "scripts/06-safe-planned-failover.ps1"
  source       = "${path.module}/scripts/aoag/06-safe-planned-failover.ps1"
  content_type = "text/plain"
}

resource "oci_objectstorage_object" "reconcile" {
  namespace    = data.oci_objectstorage_namespace.automation.namespace
  bucket       = oci_objectstorage_bucket.automation.name
  object       = "scripts/07-reconcile-availability-group.ps1"
  source       = "${path.module}/scripts/aoag/07-reconcile-availability-group.ps1"
  content_type = "text/plain"
}

resource "oci_objectstorage_preauthrequest" "sql" {
  access_type  = "ObjectRead"
  bucket       = oci_objectstorage_bucket.automation.name
  name         = "sql-node-bootstrap"
  namespace    = data.oci_objectstorage_namespace.automation.namespace
  object_name  = oci_objectstorage_object.sql.object
  time_expires = var.automation_artifact_expiration
}

resource "oci_objectstorage_preauthrequest" "wsfc" {
  access_type  = "ObjectRead"
  bucket       = oci_objectstorage_bucket.automation.name
  name         = "wsfc-bootstrap"
  namespace    = data.oci_objectstorage_namespace.automation.namespace
  object_name  = oci_objectstorage_object.wsfc.object
  time_expires = var.automation_artifact_expiration
}

resource "oci_objectstorage_preauthrequest" "sample" {
  access_type  = "ObjectRead"
  bucket       = oci_objectstorage_bucket.automation.name
  name         = "sample-database-bootstrap"
  namespace    = data.oci_objectstorage_namespace.automation.namespace
  object_name  = oci_objectstorage_object.sample.object
  time_expires = var.automation_artifact_expiration
}

resource "oci_objectstorage_preauthrequest" "ag" {
  access_type  = "ObjectRead"
  bucket       = oci_objectstorage_bucket.automation.name
  name         = "availability-group-bootstrap"
  namespace    = data.oci_objectstorage_namespace.automation.namespace
  object_name  = oci_objectstorage_object.ag.object
  time_expires = var.automation_artifact_expiration
}

resource "oci_objectstorage_preauthrequest" "safe_failover" {
  access_type  = "ObjectRead"
  bucket       = oci_objectstorage_bucket.automation.name
  name         = "safe-planned-failover"
  namespace    = data.oci_objectstorage_namespace.automation.namespace
  object_name  = oci_objectstorage_object.safe_failover.object
  time_expires = var.automation_artifact_expiration
}

resource "oci_objectstorage_preauthrequest" "reconcile" {
  access_type  = "ObjectRead"
  bucket       = oci_objectstorage_bucket.automation.name
  name         = "availability-group-reconciliation"
  namespace    = data.oci_objectstorage_namespace.automation.namespace
  object_name  = oci_objectstorage_object.reconcile.object
  time_expires = var.automation_artifact_expiration
}
