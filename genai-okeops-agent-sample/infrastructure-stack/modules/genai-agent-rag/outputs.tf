# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
output "bucket_id" {
  description = "OCID of the created bucket."
  value       = oci_objectstorage_bucket.this.id
}

output "bucket_name" {
  description = "Name of the created bucket."
  value       = oci_objectstorage_bucket.this.name
}

output "bucket_namespace" {
  description = "Object Storage namespace used by the bucket."
  value       = data.oci_objectstorage_namespace.this.namespace
}

output "knowledge_base_id" {
  description = "OCID of the knowledge base."
  value       = oci_generative_ai_agent_knowledge_base.this.id
}

output "data_source_id" {
  description = "OCID of the knowledge source data source."
  value       = oci_generative_ai_agent_data_source.this.id
}

output "data_ingestion_job_id" {
  description = "OCID of the ingestion job."
  value       = oci_generative_ai_agent_data_ingestion_job.this.id
}

output "agent_id" {
  description = "OCID of the agent."
  value       = oci_generative_ai_agent_agent.this.id
}

output "rag_tool_id" {
  description = "OCID of the RAG tool."
  value       = oci_generative_ai_agent_tool.rag.id
}

output "agent_endpoint_id" {
  description = "OCID of the agent endpoint."
  value       = oci_generative_ai_agent_agent_endpoint.this.id
}

output "agent_endpoint_display_name" {
  description = "Display name of the agent endpoint."
  value       = oci_generative_ai_agent_agent_endpoint.this.display_name
}