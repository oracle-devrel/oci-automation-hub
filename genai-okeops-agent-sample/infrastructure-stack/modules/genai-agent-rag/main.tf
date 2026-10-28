# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
data "oci_objectstorage_namespace" "this" {
  compartment_id = var.tenancy_ocid
}

resource "oci_objectstorage_bucket" "this" {
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = "${var.display_name_prefix}bucket"
  access_type    = var.bucket_access_type

}

resource "oci_objectstorage_object" "seed" {

  bucket       = oci_objectstorage_bucket.this.name
  namespace    = data.oci_objectstorage_namespace.this.namespace
  object       = "${var.display_name_prefix}kb-file.pdf"
  source = var.kb_file_path

  depends_on = [oci_objectstorage_bucket.this]
}

resource "oci_generative_ai_agent_knowledge_base" "this" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.display_name_prefix}kb"
  description    = "${var.component_description} - Knowledge Base"

  index_config {
    index_config_type          = "DEFAULT_INDEX_CONFIG"
    should_enable_hybrid_search = var.knowledge_base_should_enable_hybrid_search
  }
}

resource "oci_generative_ai_agent_data_source" "this" {
  compartment_id    = var.compartment_ocid
  knowledge_base_id = oci_generative_ai_agent_knowledge_base.this.id
  display_name   = "${var.display_name_prefix}ds"
  description    = "${var.component_description} - Data Source"


  data_source_config {
    data_source_config_type = "OCI_OBJECT_STORAGE"

    object_storage_prefixes {
      bucket   = oci_objectstorage_bucket.this.name
      namespace = data.oci_objectstorage_namespace.this.namespace
    }

    # should_enable_multi_modality = var.data_source_should_enable_multi_modality
  }
}

resource "oci_generative_ai_agent_data_ingestion_job" "this" {
  compartment_id = var.compartment_ocid
  data_source_id = oci_generative_ai_agent_data_source.this.id
  display_name   = "${var.display_name_prefix}ingestion-job"
  description    = "${var.component_description} - Data Ingestion Job"
}

resource "oci_generative_ai_agent_agent" "this" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.display_name_prefix}agent"
  description    = "${var.component_description} - Agent"

  welcome_message = var.agent_welcome_message
}

resource "oci_generative_ai_agent_tool" "rag" {
  agent_id       = oci_generative_ai_agent_agent.this.id
  compartment_id = var.compartment_ocid
  display_name   = "${var.display_name_prefix}rag-tool"
  description    = "${var.component_description} - RAG Tool"

  tool_config {
    tool_config_type = "RAG_TOOL_CONFIG"

    knowledge_base_configs {
      knowledge_base_id = oci_generative_ai_agent_knowledge_base.this.id
    }
  }

  depends_on = [
    oci_generative_ai_agent_data_ingestion_job.this
  ]
}


resource "oci_generative_ai_agent_agent_endpoint" "this" {
  compartment_id = var.compartment_ocid
  agent_id       = oci_generative_ai_agent_agent.this.id
  display_name   = "${var.display_name_prefix}agent-endpoint"
  description    = "${var.component_description} - Agent Endpoint"

  should_enable_session  = true
  should_enable_citation = true
  should_enable_trace    = true

  depends_on = [
    oci_generative_ai_agent_tool.rag
  ]
}