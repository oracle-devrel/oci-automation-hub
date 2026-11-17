# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

locals {
  suffix = random_string.suffix.result

  resource_name = "${var.name}-${local.suffix}"
  bucket_name   = coalesce(var.object_storage_bucket_name, "${var.name}-images-${local.suffix}")

  orthanc_password = coalesce(var.orthanc_password, random_password.orthanc.result)
  postgres_password = coalesce(
    var.postgres_admin_password,
    random_password.postgres.result,
  )
  storage_user_matches = var.create_storage_customer_secret_key ? (
    data.oci_identity_users.storage_user[0].users
  ) : []
  storage_user_id = try(
    one(local.storage_user_matches).id,
    "ocid1.user.oc1..missing",
  )
  storage_user_can_use_customer_secret_keys = try(
    one(local.storage_user_matches).capabilities[0].can_use_customer_secret_keys,
    false,
  )
  storage_access_key = var.create_storage_customer_secret_key ? (
    oci_identity_customer_secret_key.orthanc[0].id
  ) : var.storage_access_key
  storage_secret_key = var.create_storage_customer_secret_key ? (
    oci_identity_customer_secret_key.orthanc[0].key
  ) : var.storage_secret_key
  keycloak_database_password = random_password.keycloak_database.result
  keycloak_admin_password    = coalesce(var.keycloak_admin_password, random_password.keycloak_admin.result)
  auth_service_password      = random_password.auth_service.result
  auth_service_secret        = random_password.auth_service_secret.result

  tenant_labels = {
    for tenant_key, tenant in var.orthanc_tenants :
    tenant_key => coalesce(tenant.label, "tenant-${tenant_key}")
  }
  tenant_role_names = flatten([
    for tenant_key, tenant in var.orthanc_tenants : [
      for permission in ["viewer", "uploader", "editor", "admin"] :
      "tenant-${tenant_key}-${permission}"
    ]
  ])
  tenant_sso_roles = merge([
    for tenant_key, tenant in var.orthanc_tenants : {
      for permission in ["viewer", "uploader", "editor", "admin"] :
      "tenant-${tenant_key}-${permission}" => "${tenant.display_name} - Orthanc ${title(permission)}s"
    }
  ]...)
  tenant_test_users = var.enable_tenant_test_users ? {
    for tenant_key, tenant in var.orthanc_tenants : tenant_key => {
      username = "synthetic-${tenant_key}"
      password = random_password.tenant_test_user[tenant_key].result
      role     = "tenant-${tenant_key}-editor"
      label    = local.tenant_labels[tenant_key]
    }
  } : {}

  public_base_url            = "https://${oci_apigateway_gateway.orthanc.hostname}"
  ohif_public_path           = "/orthanc/ohif/"
  s3_compatibility_endpoint  = "https://${data.oci_objectstorage_namespace.this.namespace}.compat.objectstorage.${var.region}.oci.customer-oci.com"
  nlb_private_ip             = oci_core_private_ip.orthanc_nlb.ip_address
  authorization_service_user = "orthanc-auth"

  # Orthanc Explorer 2 versions 1.14.1 and 1.15.0 pass malformed resource
  # arguments from their built-in instance preview/download buttons to the
  # authorization token helper. Hide the defective preview link; the built-in
  # download link is disabled below and both are replaced with token-aware
  # custom buttons.
  orthanc_explorer_css = <<-CSS
    .instance-button-group .custom-button-group > div:has(> a > i.bi-binoculars) {
      display: none !important;
    }
  CSS
  oke_node_arch        = length(regexall("\\.A[0-9]+\\.", var.oke_node_shape)) > 0 ? "AARCH64" : "X86_64"
  bastion_kubectl_arch = length(regexall("\\.A[0-9]+\\.", var.bastion_shape)) > 0 ? "arm64" : "amd64"
  oke_kubernetes_minor = join(".", slice(split(".", trimprefix(var.oke_kubernetes_version, "v")), 0, 2))
  calico_release_by_kubernetes_minor = {
    "1.33" = "3.30.0"
    "1.34" = "3.30.3"
    "1.35" = "3.31.5"
    "1.36" = "3.32.0"
  }
  calico_release = lookup(local.calico_release_by_kubernetes_minor, local.oke_kubernetes_minor, null)
  oke_node_sources = [
    for source in try(data.oci_containerengine_node_pool_option.sources.sources, []) : source
    if source.source_type == "IMAGE" && !strcontains(lower(source.source_name), "gpu")
  ]
  oke_node_image_id   = try(local.oke_node_sources[0].image_id, "")
  oke_node_image_name = try(local.oke_node_sources[0].source_name, "")

  tags = merge(
    {
      "managed-by" = "terraform"
      "project"    = "oci-cloud-native-dicom"
      "deployment" = local.resource_name
    },
    var.freeform_tags,
  )

  all_service_id = data.oci_core_services.all_services.services[0].id
  bastion_ssh_public_key = trimspace(
    file(pathexpand(var.ssh_public_key_path)),
  )
  bastion_ssh_cidrs = distinct(concat(
    length(var.bastion_allowed_ssh_cidrs) > 0 ? (
      var.bastion_allowed_ssh_cidrs
    ) : var.allowed_client_cidrs,
    var.enable_fastconnect ? var.fastconnect_on_premises_cidrs : [],
  ))

  orthanc_configuration = {
    Name                   = local.resource_name
    DicomAet               = var.orthanc_aet
    DicomServerEnabled     = false
    RemoteAccessAllowed    = true
    AuthenticationEnabled  = false
    StableAge              = 2
    StrictAetComparison    = true
    HttpCompressionEnabled = true
    MetricsEnabled         = true
    ExecuteLuaEnabled      = false

    DicomWeb = {
      Enable     = true
      Root       = "/dicom-web/"
      PublicRoot = "/orthanc/dicom-web/"
    }

    OHIF = {
      DataSource     = "dicom-web"
      RouterBasename = local.ohif_public_path
    }

    OrthancExplorer2 = {
      Enable        = true
      IsDefaultUI   = true
      CustomCssPath = "/etc/orthanc-explorer/custom.css"
      Keycloak = {
        Enable   = true
        Url      = "${local.public_base_url}/keycloak/"
        Realm    = "orthanc"
        ClientId = "orthanc"
      }
      UiOptions = {
        EnableShares               = false
        EnableUpload               = true
        EnableDeleteResources      = true
        EnableEditLabels           = true
        EnableAnonymization        = true
        EnableModification         = true
        EnableDownloadZip          = true
        EnableDownloadDicomFile    = false
        EnableOpenInStoneWebViewer = true
        EnableOpenInOhifViewer3    = true
        OhifViewer3PublicRoot      = "${local.public_base_url}${local.ohif_public_path}"
        CustomButtons = {
          instance = [
            {
              HttpMethod = "GET"
              Id         = "instance-preview"
              Tooltip    = "Preview DICOM instance"
              Target     = "_blank"
              Icon       = "bi bi-binoculars"
              Url        = "../../instances/{UUID}/preview?token={study-resource-token/download-instant-link}"
            },
            {
              HttpMethod = "GET"
              Id         = "instance-download"
              Tooltip    = "Download DICOM instance"
              Target     = "_self"
              Icon       = "bi bi-download"
              Url        = "../../instances/{UUID}/file?token={study-resource-token/download-instant-link}"
            },
          ]
        }
      }
    }

    Authorization = {
      WebServiceRootUrl  = "http://orthanc-auth-service:8000/"
      WebServiceUsername = local.authorization_service_user
      WebServicePassword = local.auth_service_password
      StandardConfigurations = [
        "orthanc-explorer-2",
        "stone-webviewer",
        "ohif",
      ]
      TokenHttpHeaders = ["Authorization"]
      CheckedLevel     = "studies"
      EnableAuditLogs  = true
    }

    PostgreSQL = {
      EnableIndex              = true
      EnableStorage            = false
      Host                     = oci_psql_db_system.orthanc.network_details[0].primary_db_endpoint_private_ip
      Port                     = 5432
      Database                 = "postgres"
      Username                 = var.postgres_admin_username
      Password                 = local.postgres_password
      EnableSsl                = true
      Lock                     = false
      MaximumConnectionRetries = 60
      ConnectionRetryInterval  = 5
      IndexConnectionsCount    = 20
      TransactionMode          = "ReadCommitted"
      ApplicationName          = local.resource_name
    }

    AwsS3Storage = {
      BucketName        = oci_objectstorage_bucket.dicom.name
      Region            = var.region
      Endpoint          = local.s3_compatibility_endpoint
      AccessKey         = local.storage_access_key
      SecretKey         = local.storage_secret_key
      ConnectionTimeout = 30
      RequestTimeout    = 1200
      MaxConnections    = 25
      MaxRetries        = 10
      StorageStructure  = "flat"
      VirtualAddressing = false
    }
  }

  orthanc_role_permissions = {
    roles = merge({
      "orthanc-viewer" = {
        "authorized-labels" = ["*"]
        permissions         = ["view", "download"]
      }
      "orthanc-uploader" = {
        "authorized-labels" = ["*"]
        permissions         = ["view", "download", "upload"]
      }
      "orthanc-editor" = {
        "authorized-labels" = ["*"]
        permissions = [
          "view",
          "download",
          "upload",
          "modify",
          "anonymize",
          "delete",
          "edit-labels",
          "send",
          "share",
        ]
      }
      "orthanc-admin" = {
        "authorized-labels" = ["*"]
        permissions = [
          "anonymize",
          "audit-logs",
          "delete",
          "download",
          "modify",
          "send",
          "share",
          "view",
          "worklists",
          "admin-permissions",
          "edit-labels",
          "q-r-remote-modalities",
          "settings",
          "upload",
        ]
      }
      }, merge([
        for tenant_key, tenant in var.orthanc_tenants : {
          "tenant-${tenant_key}-viewer" = {
            "authorized-labels" = [local.tenant_labels[tenant_key]]
            permissions         = ["view", "download"]
          }
          "tenant-${tenant_key}-uploader" = {
            "authorized-labels" = [local.tenant_labels[tenant_key]]
            permissions         = ["view", "download", "upload"]
          }
          "tenant-${tenant_key}-editor" = {
            "authorized-labels" = [local.tenant_labels[tenant_key]]
            permissions = [
              "view",
              "download",
              "upload",
              "modify",
              "anonymize",
              "delete",
              "send",
            ]
          }
          "tenant-${tenant_key}-admin" = {
            "authorized-labels" = [local.tenant_labels[tenant_key]]
            permissions = [
              "view",
              "download",
              "upload",
              "modify",
              "anonymize",
              "delete",
              "send",
              "audit-logs",
            ]
          }
        }
    ]...))
    "available-labels" = values(local.tenant_labels)
  }

  keycloak_realm = {
    realm                     = "orthanc"
    displayName               = "Orthanc"
    enabled                   = true
    sslRequired               = "external"
    registrationAllowed       = false
    resetPasswordAllowed      = true
    loginWithEmailAllowed     = true
    duplicateEmailsAllowed    = false
    bruteForceProtected       = true
    eventsEnabled             = true
    eventsExpiration          = 2592000
    enabledEventTypes         = ["LOGIN", "LOGIN_ERROR", "LOGOUT", "CODE_TO_TOKEN", "REFRESH_TOKEN", "REFRESH_TOKEN_ERROR"]
    adminEventsEnabled        = true
    adminEventsDetailsEnabled = true
    accessTokenLifespan       = 300
    ssoSessionIdleTimeout     = 1800
    ssoSessionMaxLifespan     = 36000
    roles = {
      realm = [
        for role in concat(
          ["orthanc-viewer", "orthanc-uploader", "orthanc-editor", "orthanc-admin"],
          local.tenant_role_names,
          ) : {
          name       = role
          composite  = false
          clientRole = false
        }
      ]
    }
    clients = [{
      clientId                  = "orthanc"
      name                      = "Orthanc Explorer"
      enabled                   = true
      protocol                  = "openid-connect"
      publicClient              = true
      standardFlowEnabled       = true
      directAccessGrantsEnabled = true
      redirectUris              = ["${local.public_base_url}/orthanc/*"]
      webOrigins                = [local.public_base_url]
      frontchannelLogout        = true
      fullScopeAllowed          = true
      attributes = {
        "post.logout.redirect.uris" = "${local.public_base_url}/orthanc/*"
      }
      protocolMappers = [{
        name            = "account audience"
        protocol        = "openid-connect"
        protocolMapper  = "oidc-audience-mapper"
        consentRequired = false
        config = {
          "included.client.audience" = "account"
          "id.token.claim"           = "false"
          "access.token.claim"       = "true"
        }
      }]
    }]
    users = concat([{
      username        = var.orthanc_username
      firstName       = "Orthanc"
      lastName        = "Administrator"
      email           = "${var.orthanc_username}@local.invalid"
      enabled         = true
      emailVerified   = true
      realmRoles      = ["orthanc-admin"]
      requiredActions = []
      credentials = [{
        type      = "password"
        value     = local.orthanc_password
        temporary = false
      }]
      }], [
      for tenant_key, tenant_user in local.tenant_test_users : {
        username        = tenant_user.username
        firstName       = "Synthetic"
        lastName        = var.orthanc_tenants[tenant_key].display_name
        email           = "${tenant_user.username}@local.invalid"
        enabled         = true
        emailVerified   = true
        realmRoles      = [tenant_user.role]
        requiredActions = []
        credentials = [{
          type      = "password"
          value     = tenant_user.password
          temporary = false
        }]
      }
    ])
    identityProviders = local.oci_sso_enabled ? [{
      alias                     = "oci"
      displayName               = "OCI IAM SSO"
      providerId                = "oidc"
      enabled                   = true
      trustEmail                = true
      storeToken                = false
      addReadTokenRoleOnCreate  = false
      authenticateByDefault     = false
      linkOnly                  = false
      firstBrokerLoginFlowAlias = "first broker login"
      config = {
        authorizationUrl = "${local.oci_sso_domain_url}/oauth2/v1/authorize"
        tokenUrl         = "${local.oci_sso_domain_url}/oauth2/v1/token"
        userInfoUrl      = "${local.oci_sso_domain_url}/oauth2/v1/userinfo"
        logoutUrl        = "${local.oci_sso_domain_url}/oauth2/v1/userlogout"
        jwksUrl          = "${local.oci_sso_domain_url}/admin/v1/SigningCert/jwk"
        issuer           = local.oci_sso_issuer
        clientId         = oci_identity_domains_app.orthanc_sso[0].name
        clientSecret     = oci_identity_domains_app.orthanc_sso[0].client_secret
        clientAuthMethod = "client_secret_post"
        # The stack-specific scope emits a flat string array through an OCI
        # custom claim. OCI's get_groups claim is an array of objects that the
        # stock Keycloak Claim-to-Role mapper cannot match.
        defaultScope      = "openid profile email ${one(oci_identity_domains_app.orthanc_sso[0].scopes).fqs}"
        syncMode          = "FORCE"
        validateSignature = "true"
        useJwksUrl        = "true"
        disableUserInfo   = "false"
        pkceEnabled       = "true"
        pkceMethod        = "S256"
      }
    }] : []
    identityProviderMappers = local.oci_sso_enabled ? [
      for role, group_name in local.oci_sso_roles : {
        name                   = "OCI ${role}"
        identityProviderAlias  = "oci"
        identityProviderMapper = "oidc-role-idp-mapper"
        config = {
          claim         = local.oci_sso_group_claim_name
          "claim.value" = group_name
          role          = role
          syncMode      = "FORCE"
        }
      }
    ] : []
  }

  nginx_configuration = <<-NGINX
    worker_processes auto;
    pid /tmp/nginx.pid;

    events {
      worker_connections 2048;
    }

    http {
      include /etc/nginx/mime.types;
      default_type application/octet-stream;
      access_log /dev/stdout;
      error_log /dev/stderr warn;
      client_max_body_size 0;
      proxy_request_buffering off;
      proxy_buffering off;
      proxy_read_timeout 1200s;
      proxy_send_timeout 1200s;
      client_body_temp_path /tmp/client_temp;
      proxy_temp_path /tmp/proxy_temp;
      fastcgi_temp_path /tmp/fastcgi_temp;
      uwsgi_temp_path /tmp/uwsgi_temp;
      scgi_temp_path /tmp/scgi_temp;

      server {
        listen 8080;
        %{if var.enable_fastconnect~}
        listen 8443 ssl;
        ssl_certificate /etc/nginx/tls/tls.crt;
        ssl_certificate_key /etc/nginx/tls/tls.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        %{endif~}

        location = /healthz {
          access_log off;
          return 200 "ok\n";
        }

        location = / {
          return 302 /orthanc/ui/app/;
        }

        location = /orthanc {
          return 308 /orthanc/;
        }

        location /orthanc/ {
          proxy_pass http://orthanc:8042/;
          proxy_http_version 1.1;
          proxy_set_header Host ${oci_apigateway_gateway.orthanc.hostname};
          proxy_set_header X-Forwarded-Host ${oci_apigateway_gateway.orthanc.hostname};
          proxy_set_header X-Forwarded-Proto https;
          proxy_set_header X-Forwarded-Port 443;
          proxy_set_header Forwarded "host=${oci_apigateway_gateway.orthanc.hostname};proto=https";
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header Authorization $http_authorization;
        }

        location = /keycloak {
          return 308 /keycloak/;
        }

        location /keycloak/ {
          proxy_pass http://keycloak:8080/keycloak/;
          proxy_http_version 1.1;
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-Host $host;
          proxy_set_header X-Forwarded-Proto https;
          proxy_set_header X-Forwarded-Port 443;
          proxy_set_header X-Forwarded-Prefix /keycloak;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }
      }
      %{if var.enable_large_upload_endpoint~}
      server {
        listen 9443 ssl;
        ssl_certificate /etc/nginx/large-upload-tls/tls.crt;
        ssl_certificate_key /etc/nginx/large-upload-tls/tls.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        client_body_timeout 1200s;

        location = /healthz {
          access_log off;
          return 200 "ok\n";
        }

        # Keep identity/UI/admin routes on the existing API Gateway endpoint.
        location / { return 404; }
        location ~ ^/orthanc/(dicom-web/|instances$) {
          rewrite ^/orthanc/(.*)$ /$1 break;
          proxy_pass http://orthanc:8042;
          proxy_http_version 1.1;
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-Host $host;
          proxy_set_header X-Forwarded-Proto https;
          proxy_set_header X-Forwarded-Port 443;
          proxy_set_header X-Forwarded-For $remote_addr;
          proxy_set_header Authorization $http_authorization;
        }
      }
      %{endif~}
    }
  NGINX

  oke_manifest = templatefile("${path.module}/templates/stack.yaml.tftpl", {
    namespace                   = local.resource_name
    orthanc_replicas            = var.orthanc_replicas
    keycloak_replicas           = var.keycloak_replicas
    orthanc_image               = var.orthanc_image
    orthanc_auth_service_image  = var.orthanc_auth_service_image
    keycloak_image              = var.keycloak_image
    nginx_image                 = var.nginx_image
    postgres_client_image       = var.postgres_client_image
    orthanc_config_b64          = base64encode(jsonencode(local.orthanc_configuration))
    orthanc_explorer_css_b64    = base64encode(local.orthanc_explorer_css)
    permissions_b64             = base64encode(jsonencode(local.orthanc_role_permissions))
    keycloak_realm_b64          = base64encode(jsonencode(local.keycloak_realm))
    nginx_config_b64            = base64encode(local.nginx_configuration)
    postgres_host               = oci_psql_db_system.orthanc.network_details[0].primary_db_endpoint_private_ip
    postgres_username_b64       = base64encode(var.postgres_admin_username)
    postgres_password_b64       = base64encode(local.postgres_password)
    keycloak_password_b64       = base64encode(local.keycloak_database_password)
    keycloak_admin_username_b64 = base64encode("keycloak-admin")
    keycloak_admin_password_b64 = base64encode(local.keycloak_admin_password)
    orthanc_auth_users_b64      = base64encode(jsonencode({ (local.authorization_service_user) = local.auth_service_password }))
    orthanc_auth_secret_b64     = base64encode(local.auth_service_secret)
    public_base_url             = local.public_base_url
    nlb_private_ip              = local.nlb_private_ip
    nlb_subnet_id               = oci_core_subnet.application.id
    nlb_nsg_id                  = local.nlb_nsg.id
    compartment_id              = var.compartment_id
    keycloak_trusted_proxy_cidr = var.oke_pods_subnet_cidr
    oke_nodes_subnet_cidr       = var.oke_nodes_subnet_cidr
    postgres_cidr               = "${oci_psql_db_system.orthanc.network_details[0].primary_db_endpoint_private_ip}/32"
    gateway_ingress_cidrs = distinct(concat([
      var.gateway_subnet_cidr,
      var.management_subnet_cidr,
      var.application_subnet_cidr,
      var.oke_nodes_subnet_cidr,
    ], var.enable_fastconnect ? var.fastconnect_on_premises_cidrs : []))
    orthanc_host_id              = tostring(parseint(substr(sha256(local.resource_name), 0, 7), 16))
    enable_large_upload_endpoint = var.enable_large_upload_endpoint
    large_upload_ip              = try(oci_core_public_ip.large_upload[0].ip_address, "")
    large_upload_subnet_id       = oci_core_subnet.gateway.id
    large_upload_nsg_id          = try(oci_core_network_security_group.large_upload[0].id, "")
    large_upload_cert_b64        = var.enable_large_upload_endpoint ? base64encode(tls_self_signed_cert.large_upload[0].cert_pem) : ""
    large_upload_key_b64         = var.enable_large_upload_endpoint ? base64encode(tls_private_key.large_upload[0].private_key_pem) : ""
    enable_fastconnect           = var.enable_fastconnect
    private_ingest_cert_b64      = var.enable_fastconnect ? base64encode(tls_self_signed_cert.private_ingest[0].cert_pem) : ""
    private_ingest_key_b64       = var.enable_fastconnect ? base64encode(tls_private_key.private_ingest[0].private_key_pem) : ""
    keycloak_bootstrap_id = substr(sha256(join(":", [
      local.keycloak_database_password,
      var.postgres_client_image,
      "schema-v2",
    ])), 0, 12)
    orthanc_config_hash = sha256(jsonencode({
      configuration = local.orthanc_configuration
      explorer_css  = local.orthanc_explorer_css
    }))
    auth_service_config_hash = sha256(jsonencode({
      permissions = local.orthanc_role_permissions
      password    = local.auth_service_password
      secret      = local.auth_service_secret
    }))
    keycloak_config_hash = sha256(jsonencode({
      database_password = local.keycloak_database_password
      admin_password    = local.keycloak_admin_password
      realm             = local.keycloak_realm
    }))
    nginx_config_hash = sha256(join("", [
      local.nginx_configuration,
      try(tls_self_signed_cert.private_ingest[0].cert_pem, ""),
      try(tls_self_signed_cert.large_upload[0].cert_pem, ""),
    ]))
  })
}

resource "random_string" "suffix" {
  length  = 8
  upper   = false
  lower   = true
  numeric = true
  special = false
}

resource "random_password" "orthanc" {
  length           = 32
  min_lower        = 4
  min_upper        = 4
  min_numeric      = 4
  min_special      = 4
  override_special = "!#%+-.:=?@_"
}

resource "random_password" "postgres" {
  length           = 32
  min_lower        = 4
  min_upper        = 4
  min_numeric      = 4
  min_special      = 4
  override_special = "!#%+-.:=?@_"
}

resource "random_password" "keycloak_database" {
  length      = 32
  min_lower   = 6
  min_upper   = 6
  min_numeric = 6
  special     = false
}

resource "random_password" "keycloak_admin" {
  length      = 32
  min_lower   = 6
  min_upper   = 6
  min_numeric = 6
  special     = false
}

resource "random_password" "auth_service" {
  length      = 32
  min_lower   = 6
  min_upper   = 6
  min_numeric = 6
  special     = false
}

resource "random_password" "auth_service_secret" {
  length      = 48
  min_lower   = 8
  min_upper   = 8
  min_numeric = 8
  special     = false
}

resource "random_password" "tenant_test_user" {
  for_each = var.enable_tenant_test_users ? var.orthanc_tenants : {}

  length      = 32
  min_lower   = 6
  min_upper   = 6
  min_numeric = 6
  special     = false
}

check "storage_credentials" {
  assert {
    condition = (
      (
        var.create_storage_customer_secret_key &&
        var.storage_user_email != null
      ) ||
      (
        !var.create_storage_customer_secret_key &&
        var.storage_access_key != null &&
        var.storage_secret_key != null
      )
    )
    error_message = "Set storage_user_email when create_storage_customer_secret_key is true, or set both storage_access_key and storage_secret_key when it is false."
  }
}

check "fastconnect_inputs" {
  assert {
    condition = !var.enable_fastconnect || (
      var.fastconnect_provider_service_id != null &&
      length(var.fastconnect_on_premises_cidrs) > 0
    )
    error_message = "When enable_fastconnect is true, set fastconnect_provider_service_id and at least one fastconnect_on_premises_cidrs entry."
  }
}
