# Public edge and WAF assessment

## Implemented path

Public clients reach OCI API Gateway over HTTPS. Gateway applies source-CIDR
network rules, rate limiting, CORS when configured, and access/execution
logging, then reaches a reserved-address private Network Load Balancer. The NLB
forwards only to the OKE gateway pods. Orthanc, Keycloak, their ClusterIP
services, the OKE API, PostgreSQL, and the NLB have no public listener.

The native Orthanc administrative UI and REST listener are therefore not
directly exposed to the internet. Requests traverse API Gateway and the OKE
reverse proxy and remain subject to OIDC/Orthanc authorization. The public API
path is still powerful for a global administrator; source CIDRs and privileged
role membership must be tightly controlled.

## Why this stack does not attach OCI WAF to the NLB

OCI Web Application Firewall policies do not support Network Load Balancer as
an enforcement point. A regional WAF policy can protect a Flexible Load
Balancer, while an edge WAF/WAAS deployment requires an owned web domain and
DNS/certificate choices. Those values cannot be correctly inferred by a
generic Terraform module, and pretending to attach WAF to this private NLB
would create a nonfunctional control.

API Gateway is the selected “load balancer/WAF/API layer” for the generic
deployment. If an organization requires OCI WAF rules, place an OCI Flexible
Load Balancer plus regional WAF in front of a private application backend, or
put edge WAF on an approved custom domain. Validate that design against the
API Gateway 20 MB body limit and avoid creating a second public path that
bypasses OIDC or source restrictions.

References:

- [OCI WAF policy prerequisites and supported enforcement points](https://docs.oracle.com/en-us/iaas/Content/WAF/Policies/getting_started_with_waf-policies.htm)
- [OCI regional WAF with Flexible Load Balancer](https://docs.oracle.com/en/learn/oci-waf-flex-lbaas/index.html)
