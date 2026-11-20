# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

###############################################################################
# OKE - cluster and worker node pool (terraform-oci-oke module)
#
# Provisioned through the official Oracle module instead of raw resources:
#   https://registry.terraform.io/modules/oracle-terraform-modules/oke/oci
#
# Scope is deliberately narrow: the module manages ONLY the OKE cluster and the
# worker node pool. It brings NOTHING of its own network or access layer -
#   * create_vcn      = false  -> reuses the VCN/subnets/gateways in network.tf
#   * nsgs ... never           -> attaches the hand-tuned NSGs from network.tf
#   * create_bastion  = false  -> the OCI Bastion *service* in bastion.tf stays
#   * create_operator = false  -> no operator host
#   * create_iam_*    = false  -> Workload Identity IAM stays in iam.tf
# so the strict security posture documented in README.md is preserved exactly.
#
# An ENHANCED cluster keeps OKE Workload Identity available; pod networking uses
# the flannel overlay.
###############################################################################

module "oke" {
  source  = "oracle-terraform-modules/oke/oci"
  version = "5.4.3"

  providers = {
    oci      = oci
    oci.home = oci.home
  }

  # ---- Identity / tenancy ------------------------------------------------
  tenancy_id     = var.tenancy_ocid
  compartment_id = var.compartment_ocid
  region         = var.region
  ssh_public_key = trimspace(var.ssh_public_key)

  # ---- Bring your own network (network.tf) -------------------------------
  create_vcn = false
  vcn_id     = oci_core_vcn.this.id

  # Map the module's roles onto the existing subnets. Everything we do not use is
  # pinned to create = "never" so the module provisions nothing here.
  #
  # The cluster module REQUIRES a service load balancer subnet (a hard
  # precondition), even though this stack never creates LoadBalancer Services.
  # int_lb points at a dedicated PRIVATE subnet (network.tf) - it must be
  # distinct from the workers subnet, or OKE rejects node placement ("service
  # subnets cannot be used by node pools"). preferred_load_balancer =
  # "internal" keeps any future service LB private, never public.
  # The operator shares the private nodes subnet (a plain VM there is fine, and
  # the nodes NSG already lets it reach the API endpoint on 6443).
  subnets = {
    cp       = { create = "never", id = oci_core_subnet.endpoint.id }
    workers  = { create = "never", id = oci_core_subnet.nodes.id }
    int_lb   = { create = "never", id = oci_core_subnet.int_lb.id }
    operator = { create = "never", id = oci_core_subnet.nodes.id }
    pods     = { create = "never" }
    pub_lb   = { create = "never" }
    bastion  = { create = "never" }
  }

  # The module must NOT create or even reference our NSGs through the `nsgs`
  # map: its per-NSG `count` is derived from the entry's `id`, and feeding it an
  # id that only exists after apply (our network.tf NSGs, created in this same
  # run) makes the count unknown at plan time ("Invalid count argument"). So we
  # pin every map entry to create = "never" with NO id, and instead attach our
  # existing NSGs via the additive control_plane_nsg_ids / worker_nsg_ids lists
  # below - lists tolerate apply-time-unknown values, counts do not.
  nsgs = {
    cp       = { create = "never" }
    workers  = { create = "never" }
    pods     = { create = "never" }
    int_lb   = { create = "never" }
    pub_lb   = { create = "never" }
    bastion  = { create = "never" }
    operator = { create = "never" }
  }

  # Attach the hand-tuned NSGs from network.tf to the control-plane endpoint and
  # the worker nodes.
  control_plane_nsg_ids = [oci_core_network_security_group.endpoint.id]
  worker_nsg_ids        = [oci_core_network_security_group.nodes.id]

  # Leave the VCN's default security list untouched - access control lives in
  # the NSGs (network.tf), matching the original hand-written stack.
  lockdown_default_seclist = false

  # ---- Cluster -----------------------------------------------------------
  create_cluster                    = true
  cluster_name                      = var.cluster_name
  cluster_type                      = "enhanced"
  cni_type                          = "flannel"
  kubernetes_version                = var.kubernetes_version
  control_plane_is_public           = var.cluster_endpoint_is_public
  assign_public_ip_to_control_plane = var.cluster_endpoint_is_public
  pods_cidr                         = "10.244.0.0/16"
  services_cidr                     = "10.96.0.0/16"

  # Keep any service load balancer private (internal). This stack does not
  # create LoadBalancer Services, but the module requires the setting.
  preferred_load_balancer = "internal"

  # ---- Access layer ------------------------------------------------------
  # Keep the OCI Bastion *service* (bastion.tf); do not create the module's
  # bastion VM. DO create the operator: a private VM inside the VCN that
  # installs the in-cluster platform from its cloud-init (platform.tf), so the
  # single apply never needs runner-to-API connectivity (works in Resource
  # Manager with a fully private cluster).
  create_bastion  = false
  create_operator = true

  operator_nsg_ids                        = [oci_core_network_security_group.nodes.id]
  operator_install_kubectl_from_repo      = true
  operator_install_helm                   = true
  operator_await_cloudinit                = false # module await needs its own bastion; we use the OCI Bastion service
  operator_cloud_init                     = local.operator_cloud_init
  operator_legacy_imds_endpoints_disabled = true

  # ---- IAM ---------------------------------------------------------------
  # Workload Identity (Spark -> Object Storage) is wired in iam.tf. The module
  # creates the operator's dynamic group + its base "manage clusters" policy.
  # iam.tf supplements that group with the cluster-family permission required
  # to download kubeconfig content. All other module IAM stays off. Writes go
  # to the home region via oci.home.
  # Note: the *_policy toggles are strings ("never"/"auto"/"always"), not bools.
  create_iam_resources         = true
  create_iam_operator_policy   = "always"
  create_iam_worker_policy     = "never"
  create_iam_autoscaler_policy = "never"
  create_iam_kms_policy        = "never"
  create_iam_tag_namespace     = false
  create_iam_defined_tags      = false

  # ---- Worker node pool --------------------------------------------------
  # OKE forwards this metadata entry to Compute when it launches managed
  # nodes. The tenancy enforces IMDSv2-only instances, so leaving the OKE
  # default (false) makes the node-pool work request fail at LaunchInstance.
  worker_node_metadata = {
    areLegacyImdsEndpointsDisabled = "true"
  }

  # Covers instance-pool/individual-instance modes if the pool mode changes.
  worker_legacy_imds_endpoints_disabled = true

  worker_pools = {
    "${var.cluster_name}-pool" = {
      description        = "hadoop-spark worker pool"
      mode               = "node-pool"
      size               = var.node_count
      shape              = var.node_shape
      ocpus              = var.node_ocpus
      memory             = var.node_memory_gbs
      boot_volume_size   = var.node_boot_volume_gbs
      kubernetes_version = var.kubernetes_version
      image_type         = "oke"
      os                 = "Oracle Linux"
      os_version         = "8"
      node_labels        = { workload = "hadoop-spark" }
    }
  }

  # ---- Tags --------------------------------------------------------------
  freeform_tags = {
    cluster = local.freeform_tags
    workers = local.freeform_tags
  }
}
