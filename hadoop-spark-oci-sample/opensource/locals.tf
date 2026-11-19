# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

###############################################################################
# Locals - derived values
###############################################################################

locals {
  ad_name = data.oci_identity_availability_domains.ads.availability_domains[0].name

  # Tolerate stray whitespace from RM forms / copy-paste.
  admin_cidr = trimspace(var.admin_cidr)

  # Tenancy home region - global IAM writes must target it.
  home_region = one([
    for r in data.oci_identity_region_subscriptions.this.region_subscriptions :
    r.region_name if r.is_home_region
  ])

  # ---- Kerberos naming -----------------------------------------------------
  realm  = upper(var.kerberos_realm)
  domain = lower(var.kerberos_realm)

  # ---- HDFS ----------------------------------------------------------------
  effective_replication = min(var.hdfs_replication, var.hdfs_datanode_count)

  # ---- In-cluster naming / DNS ---------------------------------------------
  namespace     = var.cluster_name
  kdc_host      = "kdc.${var.cluster_name}.svc.cluster.local"
  namenode_host = "namenode-0.hdfs-nn.${var.cluster_name}.svc.cluster.local"
  hdfs_default  = "hdfs://${local.namenode_host}:9000"

  # ---- Networking ----------------------------------------------------------
  service_cidr = data.oci_core_services.all_services.services[0]["cidr_block"]
  service_id   = data.oci_core_services.all_services.services[0]["id"]
  regional_osn_cidrs = flatten([
    for region in jsondecode(data.http.oci_public_ip_ranges.response_body).regions : [
      for entry in region.cidrs : entry.cidr if contains(entry.tags, "OSN")
    ] if region.region == var.region
  ])

  # ---- Object Storage ------------------------------------------------------
  bucket_name  = "${var.cluster_name}-data"
  os_namespace = data.oci_objectstorage_namespace.this.namespace

  freeform_tags = {
    "project"    = "hadoop-spark-oke"
    "cluster"    = var.cluster_name
    "managed-by" = "terraform"
  }

  common_labels = {
    "app.kubernetes.io/part-of"    = "hadoop-spark"
    "app.kubernetes.io/managed-by" = "terraform"
  }
}
