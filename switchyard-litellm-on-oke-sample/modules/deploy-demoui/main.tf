# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_artifacts_container_repository" "this" {
  for_each = var.repositories

  compartment_id = each.value.compartment_id
  display_name   = each.key
  defined_tags   = each.value.defined_tags
  freeform_tags  = each.value.freeform_tags
  is_immutable   = each.value.container_repository_is_immutable
  is_public      = each.value.container_repository_is_public
  lifecycle {
    ignore_changes = [defined_tags]
  }
}

data "oci_objectstorage_namespace" "this" {
}

data "oci_containerengine_cluster" "demoui" {
  count      = local.demoui_lb_enabled ? 1 : 0
  cluster_id = var.demoui_cluster_id
}

locals {
  demoui_enabled = var.demoui_install
  image_files = setunion(
    toset(["Dockerfile", ".dockerignore", "requirements.txt", "app.py"]),
    fileset(local.demoui_app_path, "static/**"),
  )
  image_hash = sha256(jsonencode({
    for file in local.image_files : file => filesha256("${local.demoui_app_path}/${file}")
  }))
  chart_files = setunion(
    toset(["Chart.yaml", ".helmignore", "values.yaml", "values.schema.json"]),
    fileset(local.demoui_chart_path, "templates/**"),
  )
  chart_hash = sha256(jsonencode({
    for file in local.chart_files : file => filesha256("${local.demoui_chart_path}/${file}")
  }))
  deployment_hash = sha256(jsonencode({
    for file in ["main.tf", "locals.tf"] : file => filesha256("${path.module}/${file}")
  }))
  chart_values      = yamldecode(file("${local.demoui_chart_path}/values.yaml"))
  max_output_tokens = local.chart_values.routing.maxOutputTokens
  repository_url    = format("%s.ocir.io/%s/%s:%s", var.region, data.oci_objectstorage_namespace.this.namespace, oci_artifacts_container_repository.this[var.demoui_repository_name].display_name, random_id.demoui_rand_tag.hex)
  demoui_lb_enabled = local.demoui_enabled && local.chart_values.loadbalancer.enabled

  # Service tag overrides replace the cluster's initial tag configuration.
  # Preserve both tag types and add an identity scoped by the attached NSG.
  demoui_lb_release_tag           = format("%s/%s", var.demoui_namespace, var.demoui_release_name)
  demoui_lb_initial_tags          = try(data.oci_containerengine_cluster.demoui[0].options[0].service_lb_config[0], {})
  demoui_lb_initial_freeform_tags = coalesce(try(local.demoui_lb_initial_tags.freeform_tags, null), {})
  demoui_lb_initial_defined_tags  = coalesce(try(local.demoui_lb_initial_tags.defined_tags, null), {})
  # OCI provider keys are Namespace.Tag; the CCM annotation expects nested JSON.
  demoui_lb_defined_tags = {
    for namespace in toset([for name in keys(local.demoui_lb_initial_defined_tags) : split(".", name)[0]]) :
    namespace => {
      for name, value in local.demoui_lb_initial_defined_tags : trimprefix(name, "${namespace}.") => value
      if startswith(name, "${namespace}.")
    }
  }
  demoui_lb_values = yamlencode({
    loadbalancer = {
      annotations = local.demoui_lb_enabled ? merge(
        {
          "service.beta.kubernetes.io/oci-load-balancer-internal" = tostring(!var.is_demoui_lb_public)
          "oci.oraclecloud.com/oci-network-security-groups"       = var.demoui_load_balancer_nsg_id
          "oci.oraclecloud.com/initial-freeform-tags-override" = jsonencode(merge(
            local.demoui_lb_initial_freeform_tags,
            { demoui_release = local.demoui_lb_release_tag },
          ))
        },
        length(local.demoui_lb_initial_defined_tags) == 0 ? {} : {
          "oci.oraclecloud.com/initial-defined-tags-override" = jsonencode(local.demoui_lb_defined_tags)
        },
      ) : {}
    }
  })
}

resource "random_id" "demoui_rand_tag" {
  keepers = {
    # Rebuild whenever an input copied into the application image changes.
    demoui_img_tag = local.image_hash
  }

  byte_length = 2
}

# Keep release cleanup separate from the deployment's changing hashes. This
# resource has no create-time provisioners, so a failed deployment cannot taint
# the resource responsible for uninstalling its partially installed release.
resource "null_resource" "demoui_release" {
  count = local.demoui_enabled ? 1 : 0

  triggers = {
    release_name    = var.demoui_release_name
    namespace       = var.demoui_namespace
    cluster_id      = var.demoui_cluster_id
    bastion_host    = var.bastion_host
    bastion_user    = var.bastion_user
    operator_host   = var.operator_host
    operator_user   = var.operator_user
    ssh_private_key = var.ssh_private_key
  }

  depends_on = [oci_artifacts_container_repository.this]

  connection {
    bastion_host        = self.triggers.bastion_host
    bastion_user        = self.triggers.bastion_user
    bastion_private_key = self.triggers.ssh_private_key
    host                = self.triggers.operator_host
    user                = self.triggers.operator_user
    private_key         = self.triggers.ssh_private_key
    timeout             = "40m"
    type                = "ssh"
  }

  provisioner "remote-exec" {
    when       = destroy
    on_failure = fail
    inline = [
      "set -eu",
      # Only self references are permitted here; a local command template
      # would be an invalid external reference in a destroy-time provisioner.
      format(
        "helm uninstall %s -n %s --ignore-not-found --wait --cascade=foreground --timeout=20m",
        format("'%s'", replace(self.triggers.release_name, "'", "'\"'\"'")),
        format("'%s'", replace(self.triggers.namespace, "'", "'\"'\"'")),
      ),
    ]
  }
}

resource "null_resource" "demoui" {
  count = local.demoui_enabled ? 1 : 0

  triggers = {
    # Reinstall after a release identity/connection replacement; ordinary
    # image/chart updates leave the release-lifecycle resource intact.
    release      = null_resource.demoui_release[0].id
    image        = local.repository_url
    chart        = local.chart_hash
    deployment   = local.deployment_hash
    loadbalancer = sha256(local.demoui_lb_values)
  }

  depends_on = [null_resource.demoui_release]

  lifecycle {
    precondition {
      condition     = !local.demoui_lb_enabled || (var.demoui_load_balancer_nsg_id != null && var.demoui_load_balancer_nsg_id != "")
      error_message = "demoui_load_balancer_nsg_id is required when the demo load balancer is enabled."
    }
  }

  connection {
    bastion_host        = var.bastion_host
    bastion_user        = var.bastion_user
    bastion_private_key = var.ssh_private_key
    host                = var.operator_host
    user                = var.operator_user
    private_key         = var.ssh_private_key
    timeout             = "40m"
    type                = "ssh"
  }

  provisioner "remote-exec" {
    inline = ["mkdir -p '${local.yaml_manifest_path}' '${local.chart_manifest_path}'"]
  }

  provisioner "file" {
    source      = local.demoui_app_path
    destination = local.yaml_manifest_path
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
        set -eu

        OCIR_USERNAME="$(printf '%s' '${base64encode(var.ocir_username)}' | base64 -d)"
        REGISTRY_HOST="$(printf '%s' '${base64encode(split("/", local.repository_url)[0])}' | base64 -d)"

        # IMAGE_NAME="${local.repository_url}:${random_id.demoui_rand_tag.hex}"
        IMAGE_NAME="${local.repository_url}"
        BUILD_CONTEXT="${local.yaml_manifest_path}"

        printf '%s' '${base64encode(var.ocir_auth_token)}' | base64 -d | \
          docker login "$REGISTRY_HOST" \
            --username "$OCIR_USERNAME" \
            --password-stdin

        docker build -t "$IMAGE_NAME" "$BUILD_CONTEXT/demo-ui"
        docker push "$IMAGE_NAME"
      EOT
    ]
  }

  provisioner "file" {
    # Copy the chart contents directly into the directory passed to Helm.
    source      = "${local.demoui_chart_path}/"
    destination = local.chart_manifest_path
  }

  provisioner "file" {
    content     = local.demoui_lb_values
    destination = local.demoui_lb_values_path
  }

  provisioner "remote-exec" {
    inline = [local.kubectl_create_ocir_secrets]
  }

  provisioner "remote-exec" {
    inline = [
      format(
        "${local.helm_upgrade_install} --set-string image.repository='%s' --set-string image.tag='%s' --set routing.maxOutputTokens=%d --values %s --wait --timeout=20m",
        var.demoui_release_name,
        local.chart_manifest_path,
        var.demoui_namespace,
        split(":", local.repository_url)[0],
        random_id.demoui_rand_tag.hex,
        local.max_output_tokens,
        format("'%s'", replace(local.demoui_lb_values_path, "'", "'\"'\"'")),
      )
    ]
  }
}

# After Helm completes on the operator, wait 90 seconds before the OCI provider
# reads the address for Terraform outputs without executing local SSH commands.
data "oci_load_balancer_load_balancers" "demoui" {
  count          = local.demoui_lb_enabled ? 1 : 0
  compartment_id = data.oci_containerengine_cluster.demoui[0].compartment_id
  state          = "ACTIVE"
  detail         = "full"
  depends_on     = [time_sleep.await_demoui_lb]
}

locals {
  demoui_lb_matches = [
    for lb in flatten(data.oci_load_balancer_load_balancers.demoui[*].load_balancers) : lb
    if lookup(coalesce(lb.freeform_tags, {}), "demoui_release", "") == local.demoui_lb_release_tag
    && contains(coalesce(lb.network_security_group_ids, []), var.demoui_load_balancer_nsg_id)
  ]
  demoui_lb              = try(one(local.demoui_lb_matches), null)
  demoui_lb_mode_matches = try(local.demoui_lb.is_private == !var.is_demoui_lb_public, false)
  demoui_lb_addresses = distinct([
    for address in coalesce(try(local.demoui_lb.ip_address_details, null), []) : address.ip_address
    if address.is_public == var.is_demoui_lb_public && can(cidrnetmask("${address.ip_address}/32"))
  ])
  demoui_lb_address = try(one(local.demoui_lb_addresses), null)
  demoui_lb_url = local.demoui_lb_address == null ? null : format(
    "http://%s%s", local.demoui_lb_address,
    local.chart_values.loadbalancer.port == 80 ? "" : format(":%d", local.chart_values.loadbalancer.port),
  )
}

output "access_instructions" {
  description = "Browser URL assigned to the demo load balancer and access requirements."
  value = !local.demoui_enabled ? null : (
    local.demoui_lb_enabled ? (local.demoui_lb_url == null ? null : (
      var.is_demoui_lb_public
      ? format("Open %s in your browser.", local.demoui_lb_url)
      : format("Open %s from a machine that has network access to the private load balancer.", local.demoui_lb_url)
    )) : "The demo LoadBalancer is disabled. Use the existing ClusterIP Service and port-forward access."
  )

  precondition {
    condition = !local.demoui_lb_enabled || length(local.demoui_lb_matches) == 1
    error_message = format(
      "Expected exactly one ACTIVE load balancer with freeform tag demoui_release=%s and the configured NSG; found %d. For an existing untagged LB, add that tag once in OCI while preserving its other tags. Resolve duplicate matches before retrying.",
      local.demoui_lb_release_tag, length(local.demoui_lb_matches),
    )
  }
  precondition {
    condition     = !local.demoui_lb_enabled || length(local.demoui_lb_matches) != 1 || local.demoui_lb_mode_matches
    error_message = "The load balancer's public/private mode differs from is_demoui_lb_public. OCI requires disabling the additional Service and applying before re-enabling it in a different mode."
  }
  precondition {
    condition     = !local.demoui_lb_enabled || length(local.demoui_lb_matches) != 1 || !local.demoui_lb_mode_matches || length(local.demoui_lb_addresses) == 1
    error_message = "The matching load balancer must have exactly one assigned IPv4 address with the requested public/private visibility."
  }
}
