# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

locals {
  litellm_enabled   = var.litellm_install
  litellm_templates = coalesce(one(data.helm_template.litellm[*].manifests), {})
  litellm_resources = {
    for path, manifest in local.litellm_templates : path => yamldecode(manifest)
    if trimspace(manifest) != ""
  }
  litellm_workload_kinds = ["Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"]
  litellm_migrations = {
    for path, resource in local.litellm_resources : path => resource
    if resource.kind == "Job" && try(resource.metadata.labels["app.kubernetes.io/component"], "") == "migrations"
  }

  # kubectl does not execute Helm hooks. Apply prerequisites, then the migration
  # Job, then workloads so schema initialization cannot race application startup.
  litellm_prerequisite_manifest = sensitive(join("\n---\n", [
    for path, resource in local.litellm_resources : local.litellm_templates[path]
    if !contains(local.litellm_workload_kinds, resource.kind)
  ]))
  litellm_migration_manifest = sensitive(join("\n---\n", [
    for path, resource in local.litellm_migrations : local.litellm_templates[path]
  ]))
  litellm_manifest = sensitive(join("\n---\n", [
    for path, resource in local.litellm_resources : local.litellm_templates[path]
    if contains(local.litellm_workload_kinds, resource.kind) && !contains(keys(local.litellm_migrations), path)
  ]))
  litellm_migration_name = try(one(values(local.litellm_migrations)).metadata.name, "")
  litellm_rollout_targets = [
    for path, resource in local.litellm_resources : format("%s/%s", lower(resource.kind), resource.metadata.name)
    if contains(["Deployment", "StatefulSet", "DaemonSet"], resource.kind)
  ]
  litellm_postgresql_manifest = local.litellm_enabled && fileexists(var.litellm_postgresql_manifest_file) ? file(var.litellm_postgresql_manifest_file) : ""

  litellm_manifest_path              = join("/", [local.yaml_manifest_path, "litellm.manifest.yaml"])
  litellm_prerequisite_manifest_path = join("/", [local.yaml_manifest_path, "litellm.prerequisites.yaml"])
  litellm_migration_manifest_path    = join("/", [local.yaml_manifest_path, "litellm.migration.yaml"])
  litellm_postgresql_manifest_path   = join("/", [local.yaml_manifest_path, "litellm.postgresql.yaml"])

  litellm_apply_commands = concat(
    [
      "set -eu",
      format(local.kubectl_apply_server_ns_file, local.litellm_command_arguments.namespace, local.litellm_command_arguments.postgresql),
      format(local.kubectl_rollout_ns_status, local.litellm_command_arguments.namespace, "statefulset/litellm-postgresql"),
    ],
    local.litellm_prerequisite_manifest == "" ? [] : [
      format(local.kubectl_apply_server_ns_file, local.litellm_command_arguments.namespace, local.litellm_command_arguments.prerequisites),
    ],
    [
      # Delete only this Job before recreating it; completed Jobs do not rerun
      # and their pod templates cannot be updated in place.
      format(local.kubectl_delete_ns_job, local.litellm_command_arguments.namespace, local.litellm_command_arguments.migration_name),
      format(local.kubectl_apply_server_ns_file, local.litellm_command_arguments.namespace, local.litellm_command_arguments.migration),
      format(local.kubectl_wait_ns_job, local.litellm_command_arguments.namespace, local.litellm_command_arguments.migration_name),
      format(local.kubectl_apply_server_ns_file, local.litellm_command_arguments.namespace, local.litellm_command_arguments.workloads),
    ],
    [
      for target in local.litellm_rollout_targets :
      format(local.kubectl_rollout_ns_status, local.litellm_command_arguments.namespace, format("'%s'", replace(target, "'", "'\"'\"'")))
    ],
  )
}

data "helm_template" "litellm" {
  count      = local.litellm_enabled ? 1 : 0
  chart      = "litellm"
  repository = "oci://ghcr.io/berriai/litellm/chart"
  version    = var.litellm_helm_version

  name             = var.litellm_release_name
  namespace        = var.litellm_namespace
  create_namespace = true
  include_crds     = true
  skip_tests       = true
  values = length(var.litellm_helm_values_files) > 0 ? [
    for path in var.litellm_helm_values_files : file(path)
  ] : null

  set = concat(
    [for k, v in var.litellm_helm_values :
      {
        name  = k,
        value = v
      }
    ]
  )

  lifecycle {
    precondition {
      condition = alltrue([for path in var.litellm_helm_values_files : fileexists(path)])
      error_message = format("Missing Helm values files in configuration: %s",
        jsonencode([for path in var.litellm_helm_values_files : path if !fileexists(path)])
      )
    }
  }
}

resource "null_resource" "litellm" {
  count = local.litellm_enabled ? 1 : 0

  depends_on = [time_sleep.await_operator_iam]

  triggers = {
    chart      = data.helm_template.litellm[0].chart
    version    = var.litellm_helm_version
    release    = var.litellm_release_name
    namespace  = var.litellm_namespace
    manifests  = sha256(jsonencode(local.litellm_templates))
    postgresql = sha256(local.litellm_postgresql_manifest)
    commands   = sha256(join("", [for filename in ["main.tf", "locals.tf"] : filesha256("${path.module}/${filename}")]))
    operator = jsonencode({
      bastion_host  = var.bastion_host
      bastion_user  = var.bastion_user
      operator_host = var.operator_host
      operator_user = var.operator_user
    })
  }

  lifecycle {
    precondition {
      condition     = fileexists(var.litellm_postgresql_manifest_file)
      error_message = "Missing PostgreSQL manifest file: ${var.litellm_postgresql_manifest_file}"
    }
    precondition {
      condition     = length(local.litellm_migrations) == 1
      error_message = "The LiteLLM chart must render exactly one migrations Job. Keep migrationJob.enabled=true."
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
    inline = [format("mkdir -p %s", local.litellm_command_arguments.directory)]
  }

  provisioner "file" {
    content     = local.litellm_postgresql_manifest
    destination = local.litellm_postgresql_manifest_path
  }

  provisioner "file" {
    content     = local.litellm_prerequisite_manifest
    destination = local.litellm_prerequisite_manifest_path
  }

  provisioner "file" {
    content     = local.litellm_migration_manifest
    destination = local.litellm_migration_manifest_path
  }

  provisioner "file" {
    content     = local.litellm_manifest
    destination = local.litellm_manifest_path
  }

  provisioner "remote-exec" {
    inline = compact([
      "set -eu",
      contains(["kube-system", "default"], var.litellm_namespace) ? null : format(local.kubectl_create_missing_ns, local.litellm_command_arguments.namespace),
      format(
        local.kubectl_create_litellm_secrets, local.litellm_command_arguments.namespace, local.litellm_nvidia_api_key_argument
      ),
      format(local.kubectl_create_litellm_db_secret, local.litellm_command_arguments.namespace),
    ])
  }

  provisioner "remote-exec" {
    inline = local.litellm_apply_commands
  }
}
