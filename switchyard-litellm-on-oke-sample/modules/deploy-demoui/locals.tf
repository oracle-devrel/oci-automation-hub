# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

locals {
  demoui_app_path              = format("%s/%s", path.module, "/demoui-app/demo-ui")
  demoui_chart_path            = format("%s/%s", path.module, "/demoui-app/charts/demo-ui")
  yaml_manifest_path           = "/home/${var.operator_user}/demoui"
  chart_manifest_path          = "/home/${var.operator_user}/chart"
  demoui_lb_values_path        = "${local.yaml_manifest_path}/loadbalancer.values.yaml"
  kubectl                      = "set -o pipefail; kubectl"
  helm                         = "set -o pipefail; helm"
  kubectl_apply_ns_file        = "${local.kubectl} apply -n %s -f %s"
  kubectl_apply_file           = "${local.kubectl} apply -f %s"
  kubectl_apply_server_file    = "${local.kubectl} apply --force-conflicts=true --server-side -f %s"
  kubectl_apply_server_ns_file = "${local.kubectl} apply -n %s --force-conflicts=true --server-side -f %s"
  kubectl_create_missing_ns    = "${local.kubectl} create ns %s --dry-run=client -o yaml | kubectl apply -f -"

  # Quote values as shell literals before placing them in the remote command.
  # Embedded apostrophes close the quote, emit a literal apostrophe, and reopen it.
  ocir_secret_arguments = [
    for value in [var.demoui_namespace, split("/", local.repository_url)[0], var.ocir_username, var.ocir_auth_token] :
    format("'%s'", replace(value, "'", "'\"'\"'"))
  ]
  kubectl_create_ocir_secrets = format(
    "${local.kubectl} -n %s get secret ocir-pull-secret >/dev/null 2>&1 || kubectl -n %s create secret docker-registry ocir-pull-secret --docker-server=%s --docker-username=%s --docker-password=%s",
    local.ocir_secret_arguments[0], local.ocir_secret_arguments[0],
    local.ocir_secret_arguments[1], local.ocir_secret_arguments[2], local.ocir_secret_arguments[3]
  )
  selector_linux       = { "kubernetes.io/os" = "linux" }
  output_log           = "bash -c \"%s | tee >(systemd-cat -t %s -p info)\""
  helm_upgrade_install = "${local.helm} upgrade --install %s %s --namespace %s"
}
