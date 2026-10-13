data "http" "oauth_token" {
  url    = "${trimsuffix(var.idcs_endpoint, "/")}/oauth2/v1/token"
  method = "POST"

  request_headers = {
    Accept        = "application/json"
    Content-Type  = "application/x-www-form-urlencoded"
    Authorization = "Basic ${base64encode("${var.client_id}:${var.client_secret}")}"
  }

  request_body = join("&", [
    "grant_type=client_credentials",
    "scope=${urlencode(join(" ", var.scope_fqs))}",
  ])
}

locals {
  token_response = jsondecode(data.http.oauth_token.response_body)
}
