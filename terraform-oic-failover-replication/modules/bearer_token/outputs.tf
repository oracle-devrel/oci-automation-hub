output "access_token" {
  description = "OAuth 2.0 bearer access token for the matching OIC region."
  value       = local.token_response.access_token
  sensitive   = true
}

output "token_type" {
  description = "Token type returned by Identity Domains, normally Bearer."
  value       = local.token_response.token_type
}

output "expires_in" {
  description = "Access-token lifetime in seconds."
  value       = local.token_response.expires_in
}
