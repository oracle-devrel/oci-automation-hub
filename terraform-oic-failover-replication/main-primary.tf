data "oci_identity_domain" "this" {
  domain_id = var.identity_domain_id
}

resource "oci_dns_zone" "public" {
  # Keep the global DNS control plane independent of either OIC workload
  # region. This provider must target the tenancy home region.
  provider = oci.home

  compartment_id = var.compartment_id
  name           = var.domain_hostname
  scope          = var.dns_zone_scope
  zone_type      = var.dns_zone_type

  defined_tags  = var.oic_defined_tags
  freeform_tags = var.oic_freeform_tags
}

locals {
  primary_normalized_client_allowed_scope_fqs = [
    for scope in var.client_allowed_scope_fqs :
    can(regex("^https?://", scope))
    ? scope
    : "${trimsuffix(module.primary_oic_instance.primary_audience_url, "/")}/${scope}"
  ]
}

# Read the Identity Domains application generated for this OIC instance so the
# matching OAuth client can request every resource scope the instance exposes.
data "oci_identity_domains_app" "primary_oic_resource" {
  provider = oci.primary

  idcs_endpoint = data.oci_identity_domain.this.url
  app_id        = module.primary_oic_instance.idcs_app_id
}

locals {
  primary_oic_resource_scope_fqs = [
    for scope in data.oci_identity_domains_app.primary_oic_resource.scopes :
    scope.fqs
  ]
}

module "primary_oic_instance" {
  depends_on = [oci_dns_zone.public]
  source     = "./modules/oic_instance"

  providers = {
    oci = oci.primary
  }

  compartment_id            = var.compartment_id
  domain_id                 = var.identity_domain_id
  display_name              = var.primary_oic_display_name
  integration_instance_type = var.oic_integration_instance_type
  shape                     = var.oic_shape
  is_byol                   = var.oic_is_byol
  message_packs             = var.oic_message_packs
  defined_tags              = var.oic_defined_tags
  freeform_tags             = var.oic_freeform_tags
}

# Read the certificate chain the regional OIC endpoint presents once the
# instance is available. The URL reference defers this data read until apply
# when the OIC URL is first created.
data "tls_certificate" "primary_oic_backend" {
  depends_on = [module.primary_oic_instance]
  url        = module.primary_oic_instance.instance_url
}

locals {
  primary_oic_backend_server_certificate_pem = one([
    for certificate in data.tls_certificate.primary_oic_backend.certificates : certificate.cert_pem
    if !certificate.is_ca
  ])
  primary_oic_backend_ca_certificate_pem = join("\n", [
    for certificate in data.tls_certificate.primary_oic_backend.certificates : certificate.cert_pem
    if certificate.is_ca
  ])
}

data "external" "primary_oic_dns" {
  # Waiting for the OIC resource ensures that the endpoint exists before DNS is queried.
  depends_on = [module.primary_oic_instance]

  program = [
    "sh",
    "-c",
    <<-EOT
      ipv4=$(dig +short A "$1" | awk 'NR == 2 { print; exit }')
      printf '{"ipv4":"%s"}\n' "$ipv4"
    EOT
    ,
    "dig-oic-host",
    regex("^https?://([^/:]+)", module.primary_oic_instance.instance_url)[0],
  ]
}

module "primary_network" {
  depends_on = [module.primary_oic_instance]
  source     = "./modules/network"

  providers = {
    oci = oci.primary
  }

  compartment_id          = var.compartment_id
  name_prefix             = var.primary_oic_display_name
  vcn_cidr                = var.vcn_cidr
  public_subnet_cidr      = var.public_subnet_cidr
  functions_subnet_cidr   = var.functions_subnet_cidr
  create_functions_subnet = var.primary_create_functions_subnet
  oic_host_ipv4           = data.external.primary_oic_dns.result.ipv4
}

module "primary_oic_load_balancer" {
  source = "./modules/oic_load_balancer"

  providers = {
    oci = oci.primary
  }

  compartment_id                 = var.compartment_id
  subnet_id                      = module.primary_network.public_subnet_id
  vcn_id                         = module.primary_network.vcn_id
  backend_ip_address             = data.external.primary_oic_dns.result.ipv4
  name_prefix                    = var.primary_oic_display_name
  listener_certificate_id        = module.primary_oic_certificates.certificate_id
  backend_server_certificate_pem = local.primary_oic_backend_server_certificate_pem
  backend_ca_certificate_pem     = local.primary_oic_backend_ca_certificate_pem
  defined_tags                   = var.oic_defined_tags
  freeform_tags                  = var.oic_freeform_tags
}

module "primary_oic_certificates" {
  source = "./modules/oic_certificates"

  providers = {
    oci = oci.primary
  }

  compartment_id               = var.compartment_id
  name_prefix                  = var.primary_oic_display_name
  ssl_certificate_file_path    = var.ssl_certificate_file_path
  ssl_ca_certificate_file_path = var.ssl_ca_certificate_file_path
  ssl_private_key_file_path    = var.ssl_private_key_file_path
  defined_tags                 = var.oic_defined_tags
  freeform_tags                = var.oic_freeform_tags
}

module "primary_oic_client_app" {
  depends_on = [module.primary_oic_instance]
  source     = "./modules/oic_client_app"

  providers = {
    oci = oci.primary
  }

  idcs_endpoint = data.oci_identity_domain.this.url
  display_name  = var.primary_client_app_display_name
  description   = var.client_app_description
  allowed_scope_fqs = distinct(concat(
    local.primary_oic_resource_scope_fqs,
    local.primary_normalized_client_allowed_scope_fqs,
  ))
  access_token_expiry  = var.client_access_token_expiry
  refresh_token_expiry = var.client_refresh_token_expiry
  bypass_consent       = var.client_bypass_consent
  trust_scope          = var.client_trust_scope
  active               = var.client_active
}

# The OIC instance creates its own Identity Domains application. Grant that
# application's ServiceAdministrator role to the OAuth client created for the
# same primary instance.
data "oci_identity_domains_app_roles" "primary_service_administrator" {
  provider = oci.primary

  idcs_endpoint   = data.oci_identity_domain.this.url
  app_role_filter = "displayName eq \"ServiceAdministrator\" and app.value eq \"${module.primary_oic_instance.idcs_app_id}\""
}

resource "oci_identity_domains_grant" "primary_service_administrator" {
  provider = oci.primary

  idcs_endpoint   = data.oci_identity_domain.this.url
  schemas         = ["urn:ietf:params:scim:schemas:oracle:idcs:Grant"]
  grant_mechanism = "ADMINISTRATOR_TO_APP"

  # The OIC-generated application is the server application whose AppRole is
  # being granted.
  app {
    value = module.primary_oic_instance.idcs_app_id
  }

  entitlement {
    attribute_name  = "appRoles"
    attribute_value = one(data.oci_identity_domains_app_roles.primary_service_administrator.app_roles).id
  }

  # The OAuth client for this OIC instance is the consuming application.
  grantee {
    type  = "App"
    value = module.primary_oic_client_app.id
  }

  lifecycle {
    precondition {
      condition     = length(data.oci_identity_domains_app_roles.primary_service_administrator.app_roles) == 1
      error_message = "Expected exactly one ServiceAdministrator AppRole for the primary OIC-generated application."
    }
  }
}

# Exchange the primary region's client credentials only after its OIC role
# grant exists, so the returned token can authorize that instance's REST APIs.
module "primary_oic_bearer_token" {
  depends_on = [oci_identity_domains_grant.primary_service_administrator]
  source     = "./modules/bearer_token"

  idcs_endpoint = data.oci_identity_domain.this.url
  client_id     = module.primary_oic_client_app.name
  client_secret = module.primary_oic_client_app.client_secret
  scope_fqs = distinct(concat(
    local.primary_oic_resource_scope_fqs,
    local.primary_normalized_client_allowed_scope_fqs,
  ))
}
