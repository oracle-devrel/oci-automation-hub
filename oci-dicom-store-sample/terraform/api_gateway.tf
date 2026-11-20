# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_apigateway_gateway" "orthanc" {
  compartment_id = var.compartment_id
  display_name   = "${local.resource_name}-gateway"
  endpoint_type  = "PUBLIC"
  subnet_id      = oci_core_subnet.gateway.id

  network_security_group_ids = [
    local.gateway_nsg.id,
  ]

  freeform_tags = local.tags

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}

resource "oci_apigateway_deployment" "orthanc" {
  compartment_id = var.compartment_id
  gateway_id     = oci_apigateway_gateway.orthanc.id
  display_name   = "${local.resource_name}-api"
  path_prefix    = "/orthanc"
  freeform_tags  = local.tags

  specification {
    logging_policies {
      access_log {
        is_enabled = true
      }

      execution_log {
        is_enabled = true
        log_level  = "WARN"
      }
    }

    request_policies {
      rate_limiting {
        rate_in_requests_per_second = var.api_rate_limit_rps
        rate_key                    = "CLIENT_IP"
      }

      dynamic "cors" {
        for_each = length(var.cors_allowed_origins) == 0 ? [] : [1]
        content {
          allowed_origins              = var.cors_allowed_origins
          allowed_methods              = ["GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS"]
          allowed_headers              = ["Authorization", "Content-Type", "Accept", "Origin"]
          exposed_headers              = ["Content-Length", "Content-Type", "ETag", "Location", "Warning"]
          is_allow_credentials_enabled = true
          max_age_in_seconds           = 3600
        }
      }
    }

    routes {
      path    = "/"
      methods = ["GET", "HEAD", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"]

      backend {
        type                       = "HTTP_BACKEND"
        url                        = "http://${local.nlb_private_ip}:8080/orthanc/"
        connect_timeout_in_seconds = 10
        read_timeout_in_seconds    = 300
        send_timeout_in_seconds    = 300
      }
    }

    routes {
      path    = "/{request_path*}"
      methods = ["GET", "HEAD", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"]

      backend {
        type                       = "HTTP_BACKEND"
        url                        = "http://${local.nlb_private_ip}:8080/orthanc/$${request.path[request_path]}"
        connect_timeout_in_seconds = 10
        read_timeout_in_seconds    = 300
        send_timeout_in_seconds    = 300
      }
    }
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}

resource "oci_apigateway_deployment" "keycloak" {
  compartment_id = var.compartment_id
  gateway_id     = oci_apigateway_gateway.orthanc.id
  display_name   = "${local.resource_name}-keycloak"
  path_prefix    = "/keycloak"
  freeform_tags  = local.tags

  specification {
    logging_policies {
      access_log {
        is_enabled = true
      }

      execution_log {
        is_enabled = true
        log_level  = "WARN"
      }
    }

    request_policies {
      rate_limiting {
        rate_in_requests_per_second = var.api_rate_limit_rps
        rate_key                    = "CLIENT_IP"
      }

      dynamic "cors" {
        for_each = length(var.cors_allowed_origins) == 0 ? [] : [1]
        content {
          allowed_origins              = var.cors_allowed_origins
          allowed_methods              = ["GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS"]
          allowed_headers              = ["Authorization", "Content-Type", "Accept", "Origin"]
          exposed_headers              = ["Content-Length", "Content-Type", "ETag", "Location", "Warning"]
          is_allow_credentials_enabled = true
          max_age_in_seconds           = 3600
        }
      }
    }

    routes {
      path    = "/"
      methods = ["GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS"]

      backend {
        type                       = "HTTP_BACKEND"
        url                        = "http://${local.nlb_private_ip}:8080/keycloak/"
        connect_timeout_in_seconds = 10
        read_timeout_in_seconds    = 300
        send_timeout_in_seconds    = 300
      }
    }

    routes {
      path    = "/{request_path*}"
      methods = ["GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS"]

      backend {
        type                       = "HTTP_BACKEND"
        url                        = "http://${local.nlb_private_ip}:8080/keycloak/$${request.path[request_path]}"
        connect_timeout_in_seconds = 10
        read_timeout_in_seconds    = 300
        send_timeout_in_seconds    = 300
      }
    }
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}
