resource "oci_health_checks_http_monitor" "this" {
  compartment_id      = var.compartment_id
  display_name        = "${var.display_name}-health-check"
  interval_in_seconds = 10
  protocol            = "HTTPS"
  port                = 443
  method              = "GET"
  path                = "/ic/api/integration/v2/flows/rest/project/ORCL-R-REST_ECHO_REQUEST/ORCL-R-SAMPLE_ECHO/1.0/metadata/openapi"
  timeout_in_seconds  = 10
  targets             = [var.primary_load_balancer_ip, var.secondary_load_balancer_ip]

  headers = {
    Host = var.hostname
  }
  defined_tags  = var.defined_tags
  freeform_tags = var.freeform_tags
}

resource "oci_dns_steering_policy" "this" {
  compartment_id          = var.compartment_id
  display_name            = var.display_name
  template                = "FAILOVER"
  health_check_monitor_id = oci_health_checks_http_monitor.this.id
  ttl                     = var.ttl

  answers {
    name  = "primary"
    pool  = "primary"
    rtype = "A"
    rdata = var.primary_load_balancer_ip
  }

  answers {
    name  = "secondary"
    pool  = "secondary"
    rtype = "A"
    rdata = var.secondary_load_balancer_ip
  }

  # The FAILOVER template requires this sequence: FILTER, HEALTH, PRIORITY, LIMIT.
  rules {
    rule_type = "FILTER"

    default_answer_data {
      answer_condition = "answer.isDisabled != true"
      should_keep      = true
    }
  }

  rules {
    rule_type = "HEALTH"
  }

  rules {
    rule_type = "PRIORITY"

    default_answer_data {
      answer_condition = "answer.pool == 'primary'"
      value            = 0
    }

    default_answer_data {
      answer_condition = "answer.pool == 'secondary'"
      value            = 1
    }
  }

  rules {
    rule_type     = "LIMIT"
    default_count = 1
  }

  defined_tags  = var.defined_tags
  freeform_tags = var.freeform_tags
}

resource "oci_dns_rrset" "primary_load_balancer" {
  zone_name_or_id = var.dns_zone_id
  domain          = var.hostname
  rtype           = "A"

  items {
    domain = var.hostname
    rtype  = "A"
    rdata  = var.primary_load_balancer_ip
    ttl    = var.ttl
  }
}

resource "oci_dns_steering_policy_attachment" "this" {
  display_name = "${var.display_name}-oic"
  # Keep the zone apex A record pinned to primary and expose failover through
  # a dedicated hostname within the managed zone.
  domain_name        = var.hostname
  steering_policy_id = oci_dns_steering_policy.this.id
  zone_id            = var.dns_zone_id
}
