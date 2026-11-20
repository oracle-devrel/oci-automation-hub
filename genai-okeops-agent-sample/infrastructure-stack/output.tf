# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

output "stream_service_id" {
  value = module.stream.id
}

output "app_ocir_repository_url" {
  value = format(
    "ocir.%s.oci.oraclecloud.com/%s/%s",
    var.region,
    module.app_ocir.container_registry_namespace,
    module.app_ocir.container_repository_name
  )
}

output "mcp_ocir_repository_url" {
  value = format(
    "ocir.%s.oci.oraclecloud.com/%s/%s",
    var.region,
    module.mcp_ocir.container_registry_namespace,
    module.mcp_ocir.container_repository_name
  )
}

output "rag_agent_endpoint" {
  value = module.genai_agent_rag.agent_endpoint_id
}

output "oke_cluster_id" {
  value = module.oke.cluster_id
}

output "oke_node_pool_id" {
  value = module.oke.node_pool_id
}

output "unschedulable_pod" {
  value = "${kubernetes_namespace_v1.demo.metadata[0].name}/${kubernetes_pod_v1.unschedulable.metadata[0].name}"
}

output "unschedulable_pods_alarm_id" {
  value = module.unschedulable_pods_alarm.id
}
