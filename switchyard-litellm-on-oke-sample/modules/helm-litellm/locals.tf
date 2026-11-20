# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

locals {
  yaml_manifest_path               = "/home/${var.operator_user}/yaml"
  kubectl                          = "set -o pipefail; kubectl"
  helm                             = "set -o pipefail; helm"
  kubectl_apply_ns_file            = "${local.kubectl} apply -n %s -f %s"
  kubectl_apply_file               = "${local.kubectl} apply -f %s"
  kubectl_apply_server_file        = "${local.kubectl} apply --force-conflicts=true --server-side -f %s"
  kubectl_apply_server_ns_file     = "${local.kubectl} apply -n %s --force-conflicts=true --server-side -f %s"
  kubectl_create_missing_ns        = "${local.kubectl} create ns %s --dry-run=client -o yaml | kubectl apply -f -"
  kubectl_rollout_ns_status        = "${local.kubectl} rollout status -n %s %s --timeout=20m"
  kubectl_delete_ns_job            = "${local.kubectl} delete job -n %s %s --ignore-not-found=true --wait=true --timeout=2m"
  kubectl_create_litellm_secrets   = "bash -c 'set -euo pipefail; kubectl -n \"$1\" get secret litellm-secrets >/dev/null 2>&1 || { master_key=$(openssl rand -hex 32); salt_key=$(openssl rand -hex 32); kubectl -n \"$1\" create secret generic litellm-secrets --from-literal=NVIDIA_API_KEY=\"$2\" --from-literal=LITELLM_MASTER_KEY=\"sk-$master_key\" --from-literal=LITELLM_SALT_KEY=\"sk-$salt_key\"; }' _ %s %s"
  kubectl_create_litellm_db_secret = "bash -c 'set -euo pipefail; kubectl -n \"$1\" get secret litellm-db >/dev/null 2>&1 || { password=$(openssl rand -hex 32); kubectl -n \"$1\" create secret generic litellm-db --from-literal=username=litellm --from-literal=password=\"$password\"; }' _ %s"

  # Use the same shell-literal quoting as the demo module. Secrets are supplied
  # as positional arguments, never interpolated into the inner Bash program.
  litellm_nvidia_api_key_argument = format("'%s'", replace(var.nvidia_api_key, "'", "'\"'\"'"))
  litellm_command_arguments = {
    for name, value in {
      directory      = local.yaml_manifest_path
      namespace      = var.litellm_namespace
      postgresql     = local.litellm_postgresql_manifest_path
      prerequisites  = local.litellm_prerequisite_manifest_path
      migration      = local.litellm_migration_manifest_path
      migration_name = local.litellm_migration_name
      workloads      = local.litellm_manifest_path
    } : name => format("'%s'", replace(value, "'", "'\"'\"'"))
  }

  # Detect failure as well as completion; waiting only for Complete hides a
  # failed migration until timeout. The Job also has activeDeadlineSeconds.
  kubectl_wait_ns_job  = <<-EOT
    bash -c 'set -euo pipefail
      deadline=$((SECONDS + 2100))
      while ((SECONDS < deadline)); do
        conditions=$(kubectl -n "$1" get job "$2" --request-timeout=15s -o "jsonpath={.status.conditions[?(@.status==\"True\")].type}")
        case "$conditions" in
          *Failed*|*FailureTarget*)
            echo "LiteLLM migration Job failed; application workloads were not applied." >&2
            exit 1
            ;;
          *Complete*) exit 0 ;;
        esac
        sleep 5
      done
      echo "Timed out waiting for the LiteLLM migration Job." >&2
      exit 1' _ %s %s
  EOT
  selector_linux       = { "kubernetes.io/os" = "linux" }
  output_log           = "bash -c \"%s | tee >(systemd-cat -t %s -p info)\""
  helm_upgrade_install = "${local.helm} upgrade --install %s %s --repo %s --version %s --namespace %s --create-namespace --skip-crds -f %s"
}
