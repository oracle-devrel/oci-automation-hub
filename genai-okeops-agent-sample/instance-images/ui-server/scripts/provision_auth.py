# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import secrets
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

import oci
from dotenv import load_dotenv
from oci.certificates_management import CertificatesManagementClient
from oci.certificates_management.models import (
    CreateCertificateByImportingConfigDetails,
    CreateCertificateDetails,
)
from oci.identity_domains import IdentityDomainsClient
from oci.identity_domains.models import App, AppBasedOnTemplate


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CERT_DIR = ROOT / "certs"
DEFAULT_ENV_FILE = ROOT / ".env.generated"

load_dotenv(ROOT / ".env")


def _env(name: str, default: str = "") -> str:
    return os.getenv(name, default).strip()


def _hostname_from_base_url(base_url: str) -> str:
    parsed = urlparse(base_url)
    if not parsed.scheme or not parsed.netloc:
        raise ValueError("APP_BASE_URL must include a scheme and host, for example https://chat.example.com")
    return parsed.hostname or "localhost"


def _san_entries(hostname: str, extra_sans: list[str]) -> str:
    entries: list[str] = []
    if hostname.replace(".", "").isdigit():
        entries.append(f"IP:{hostname}")
    else:
        entries.append(f"DNS:{hostname}")
    for value in extra_sans:
        value = value.strip()
        if not value:
            continue
        if value.startswith(("DNS:", "IP:")):
            entries.append(value)
        elif value.replace(".", "").isdigit():
            entries.append(f"IP:{value}")
        else:
            entries.append(f"DNS:{value}")
    return ",".join(dict.fromkeys(entries))


def _safe_app_name(value: str) -> str:
    safe = "".join(char.lower() if char.isalnum() else "_" for char in value)
    safe = "_".join(item for item in safe.split("_") if item)
    return safe[:120] or "oci-enterprise-ai-chat"


def generate_self_signed_cert(
    cert_dir: Path,
    cert_basename: str,
    common_name: str,
    days: int,
    extra_sans: list[str],
    overwrite: bool,
) -> tuple[Path, Path]:
    cert_dir.mkdir(parents=True, exist_ok=True)
    cert_path = cert_dir / f"{cert_basename}.crt"
    key_path = cert_dir / f"{cert_basename}.key"

    if cert_path.exists() and key_path.exists() and not overwrite:
        print(f"Using existing certificate: {cert_path}")
        print(f"Using existing private key: {key_path}")
        return cert_path, key_path

    san = _san_entries(common_name, extra_sans)
    cmd = [
        "openssl",
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-sha256",
        "-days",
        str(days),
        "-nodes",
        "-keyout",
        str(key_path),
        "-out",
        str(cert_path),
        "-subj",
        f"/CN={common_name}",
        "-addext",
        f"subjectAltName={san}",
    ]
    subprocess.run(cmd, check=True)
    key_path.chmod(0o600)
    print(f"Generated self-signed certificate: {cert_path}")
    print(f"Generated private key: {key_path}")
    return cert_path, key_path


def _load_oci_config(profile: str, region: str) -> dict:
    config_file = os.getenv("OCI_CONFIG_FILE", os.path.expanduser("~/.oci/config"))
    config = dict(oci.config.from_file(config_file, profile))
    if region:
        config["region"] = region
    return config


def import_certificate_to_oci(
    config: dict,
    compartment_id: str,
    cert_name: str,
    cert_path: Path,
    key_path: Path,
    dry_run: bool,
) -> str:
    if dry_run:
        print(f"DRY RUN: would import {cert_path.name} into OCI Certificates as {cert_name}")
        return ""

    cert_pem = cert_path.read_text(encoding="utf-8")
    key_pem = key_path.read_text(encoding="utf-8")
    client = CertificatesManagementClient(config=config)
    details = CreateCertificateDetails(
        name=cert_name,
        compartment_id=compartment_id,
        description="Self-signed TLS certificate for the OCI Enterprise AI chat app.",
        certificate_config=CreateCertificateByImportingConfigDetails(
            certificate_pem=cert_pem,
            cert_chain_pem=cert_pem,
            private_key_pem=key_pem,
        ),
        freeform_tags={"managed_by": "oci-ai-chat-app"},
    )
    response = client.create_certificate(details)
    certificate_id = getattr(response.data, "id", "") or getattr(response.data, "certificate_id", "")
    print(f"Imported certificate into OCI Certificates: {certificate_id}")
    return str(certificate_id)


def create_oidc_app(
    config: dict,
    identity_domain_issuer: str,
    app_name: str,
    app_base_url: str,
    client_secret: str,
    dry_run: bool,
) -> tuple[str, str]:
    redirect_uri = f"{app_base_url.rstrip('/')}/auth/callback"
    post_logout_uri = f"{app_base_url.rstrip('/')}/"

    if dry_run:
        print(f"DRY RUN: would create OCI Identity Domain confidential OIDC app: {app_name}")
        print(f"DRY RUN: redirect URI: {redirect_uri}")
        return "", client_secret

    client = IdentityDomainsClient(config=config, service_endpoint=identity_domain_issuer.rstrip("/"))
    app = App(
        schemas=["urn:ietf:params:scim:schemas:oracle:idcs:App"],
        display_name=app_name,
        name=_safe_app_name(app_name),
        description="OIDC client for the OCI Enterprise AI chat app.",
        active=True,
        based_on_template=AppBasedOnTemplate(value="CustomWebAppTemplateId", well_known_id="CustomWebAppTemplateId"),
        login_mechanism="OIDC",
        client_type="confidential",
        is_o_auth_client=True,
        redirect_uris=[redirect_uri],
        post_logout_redirect_uris=[post_logout_uri],
        allowed_grants=["authorization_code", "refresh_token"],
        allow_offline=True,
        all_url_schemes_allowed=False,
        client_secret=client_secret,
    )
    response = client.create_app(
        app=app,
        attributes="id,ocid,name,displayName,clientSecret,hashedClientSecret,redirectUris,allowedGrants,active,clientType,isOAuthClient",
    )
    created = response.data
    client_id = getattr(created, "name", "") or getattr(created, "id", "")
    returned_secret = getattr(created, "client_secret", None) or client_secret
    print(f"Created OCI Identity Domain OIDC app: {client_id}")
    return str(client_id), str(returned_secret)


def write_env_file(
    env_file: Path,
    app_base_url: str,
    identity_domain_issuer: str,
    client_id: str,
    client_secret: str,
    certificate_id: str,
    cert_path: Path | None,
    key_path: Path | None,
) -> None:
    secure_cookie = "true" if app_base_url.startswith("https://") else "false"
    lines = [
        "# Generated by scripts/provision_auth.py",
        'AUTH_ENABLED="true"',
        f'APP_BASE_URL="{app_base_url}"',
        f'APP_SESSION_SECRET="{secrets.token_urlsafe(48)}"',
        f'AUTH_COOKIE_SECURE="{secure_cookie}"',
        f'OCI_IDENTITY_DOMAIN_ISSUER="{identity_domain_issuer.rstrip("/")}"',
        f'OCI_OIDC_CLIENT_ID="{client_id}"',
        f'OCI_OIDC_CLIENT_SECRET="{client_secret}"',
        f'OCI_OIDC_REDIRECT_URI="{app_base_url.rstrip("/")}/auth/callback"',
    ]
    if cert_path and key_path:
        lines.extend(
            [
                f'APP_TLS_CERT_FILE="{cert_path}"',
                f'APP_TLS_KEY_FILE="{key_path}"',
            ]
        )
    else:
        lines.extend(
            [
                'APP_TLS_CERT_FILE=""',
                'APP_TLS_KEY_FILE=""',
            ]
        )
    if certificate_id:
        lines.append(f'OCI_CERTIFICATE_ID="{certificate_id}"')
    env_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
    env_file.chmod(0o600)
    print(f"Wrote auth configuration: {env_file}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create OCI Identity Domain OIDC settings for the app. Local TLS and OCI certificate import are optional."
    )
    parser.add_argument("--apply", action="store_true", help="Create OCI resources. Without this, only local optional files and a dry run are performed.")
    parser.add_argument("--overwrite-cert", action="store_true", help="Replace the local generated certificate and key if they already exist.")
    parser.add_argument("--config-profile", default=_env("CONFIG_PROFILE", _env("OCI_CONFIG_PROFILE", "DEFAULT")))
    parser.add_argument("--region", default=_env("OCI_REGION", ""))
    parser.add_argument("--compartment-id", default=_env("COMPARTMENT_ID", ""))
    parser.add_argument("--identity-domain-issuer", default=_env("OCI_IDENTITY_DOMAIN_ISSUER", ""))
    parser.add_argument("--app-base-url", default=_env("APP_BASE_URL", "https://localhost:8000"))
    parser.add_argument("--oidc-app-name", default=_env("OCI_OIDC_APP_NAME", "OCI Enterprise AI Chat"))
    parser.add_argument("--oidc-client-secret", default=_env("OCI_OIDC_CLIENT_SECRET", secrets.token_urlsafe(48)))
    parser.add_argument("--certificate-name", default=_env("OCI_CERTIFICATE_NAME", "oci-enterprise-ai-chat-self-signed"))
    parser.add_argument("--certificate-id", default=_env("OCI_CERTIFICATE_ID", ""), help="Existing OCI certificate OCID to write to the env file and skip certificate import.")
    parser.add_argument("--generate-local-tls", action="store_true", help="Generate a self-signed cert and write APP_TLS_* paths. Usually only useful for local testing without a proxy.")
    parser.add_argument("--import-certificate", action="store_true", help="Import the generated self-signed certificate into OCI Certificates.")
    parser.add_argument("--skip-certificate-import", action="store_true", help="Deprecated alias for leaving certificate import disabled.")
    parser.add_argument("--cert-dir", default=str(DEFAULT_CERT_DIR))
    parser.add_argument("--cert-basename", default="app")
    parser.add_argument("--cert-days", type=int, default=int(_env("APP_CERT_DAYS", "365")))
    parser.add_argument("--subject-alt-name", action="append", default=["localhost", "127.0.0.1"], help="Extra SAN entry. May be repeated. Use DNS:name or IP:addr, or a raw host/IP.")
    parser.add_argument("--env-file", default=str(DEFAULT_ENV_FILE))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    app_base_url = args.app_base_url.rstrip("/")
    hostname = _hostname_from_base_url(app_base_url)

    should_import_certificate = bool(args.import_certificate and not args.skip_certificate_import and not args.certificate_id)
    should_generate_tls = bool(args.generate_local_tls or should_import_certificate)
    cert_path: Path | None = None
    key_path: Path | None = None

    if should_generate_tls:
        cert_path, key_path = generate_self_signed_cert(
            cert_dir=Path(args.cert_dir),
            cert_basename=args.cert_basename,
            common_name=hostname,
            days=args.cert_days,
            extra_sans=args.subject_alt_name,
            overwrite=args.overwrite_cert,
        )
    else:
        print("Skipping local TLS certificate generation. The container will serve HTTP by default.")

    missing = []
    if not args.compartment_id:
        missing.append("--compartment-id or COMPARTMENT_ID")
    if not args.identity_domain_issuer:
        missing.append("--identity-domain-issuer or OCI_IDENTITY_DOMAIN_ISSUER")

    dry_run = not args.apply
    if args.apply and missing:
        print("Cannot apply OCI changes because required values are missing:", file=sys.stderr)
        for item in missing:
            print(f"  - {item}", file=sys.stderr)
        return 2

    config = _load_oci_config(args.config_profile, args.region) if not missing or args.apply else {}
    certificate_id = ""
    client_id = ""
    client_secret = args.oidc_client_secret

    if not missing:
        if args.certificate_id:
            certificate_id = args.certificate_id
            print(f"Using existing OCI certificate: {certificate_id}")
        elif should_import_certificate:
            if not cert_path or not key_path:
                print("Cannot import certificate because local TLS certificate generation did not run.", file=sys.stderr)
                return 2
            certificate_id = import_certificate_to_oci(
                config=config,
                compartment_id=args.compartment_id,
                cert_name=args.certificate_name,
                cert_path=cert_path,
                key_path=key_path,
                dry_run=dry_run,
            )
        else:
            print("Skipping OCI certificate import. Use --import-certificate only when this script should manage the certificate.")
        client_id, client_secret = create_oidc_app(
            config=config,
            identity_domain_issuer=args.identity_domain_issuer,
            app_name=args.oidc_app_name,
            app_base_url=app_base_url,
            client_secret=client_secret,
            dry_run=dry_run,
        )
    else:
        print("Skipping OCI dry run because required values are missing:")
        for item in missing:
            print(f"  - {item}")

    if client_id or dry_run:
        write_env_file(
            env_file=Path(args.env_file),
            app_base_url=app_base_url,
            identity_domain_issuer=args.identity_domain_issuer,
            client_id=client_id or "<created-client-id>",
            client_secret=client_secret,
            certificate_id=certificate_id,
            cert_path=cert_path,
            key_path=key_path,
        )

    if dry_run:
        print("Run again with --apply after setting the missing OCI values to create OCI resources.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
