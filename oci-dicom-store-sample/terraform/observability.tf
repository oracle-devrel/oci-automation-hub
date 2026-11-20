# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_logging_log_group" "dicom" {
  compartment_id = var.compartment_id
  display_name   = "${local.resource_name}-logs"
  description    = "API access and execution logs for ${local.resource_name}"
  freeform_tags  = local.tags
}

resource "oci_logging_log" "api_access" {
  display_name = "${local.resource_name}-api-access"
  log_group_id = oci_logging_log_group.dicom.id
  log_type     = "SERVICE"
  is_enabled   = true

  configuration {
    compartment_id = var.compartment_id

    source {
      category    = "access"
      resource    = oci_apigateway_deployment.orthanc.id
      service     = "apigateway"
      source_type = "OCISERVICE"
    }
  }
}

resource "oci_logging_log" "api_execution" {
  display_name = "${local.resource_name}-api-execution"
  log_group_id = oci_logging_log_group.dicom.id
  log_type     = "SERVICE"
  is_enabled   = true

  configuration {
    compartment_id = var.compartment_id

    source {
      category    = "execution"
      resource    = oci_apigateway_deployment.orthanc.id
      service     = "apigateway"
      source_type = "OCISERVICE"
    }
  }
}

resource "oci_logging_log" "keycloak_access" {
  display_name = "${local.resource_name}-keycloak-access"
  log_group_id = oci_logging_log_group.dicom.id
  log_type     = "SERVICE"
  is_enabled   = true

  configuration {
    compartment_id = var.compartment_id

    source {
      category    = "access"
      resource    = oci_apigateway_deployment.keycloak.id
      service     = "apigateway"
      source_type = "OCISERVICE"
    }
  }
}

resource "oci_logging_log" "keycloak_execution" {
  display_name = "${local.resource_name}-keycloak-execution"
  log_group_id = oci_logging_log_group.dicom.id
  log_type     = "SERVICE"
  is_enabled   = true

  configuration {
    compartment_id = var.compartment_id

    source {
      category    = "execution"
      resource    = oci_apigateway_deployment.keycloak.id
      service     = "apigateway"
      source_type = "OCISERVICE"
    }
  }
}

resource "oci_monitoring_alarm" "api_5xx" {
  count = var.alarm_notification_topic_id == null ? 0 : 1

  compartment_id        = var.compartment_id
  metric_compartment_id = var.compartment_id
  display_name          = "${local.resource_name}-api-5xx"
  namespace             = "oci_apigateway"
  query                 = "HttpResponses[1m]{resourceId = \"${oci_apigateway_gateway.orthanc.id}\", httpStatusCategory = \"5xx\"}.sum() > 5"
  severity              = "ERROR"
  is_enabled            = true
  pending_duration      = "PT5M"
  body                  = "The DICOM API Gateway returned more than five 5xx responses per minute."
  destinations          = [var.alarm_notification_topic_id]
  freeform_tags         = local.tags
}
