# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

import logging
import os
import secrets
from pathlib import Path

import oci
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s - %(message)s",
)
logger = logging.getLogger("oci_agent_mvp")

COMPARTMENT_ID = ""
OCI_GENAI_PROJECT_ID = ""
MODEL_ID = ""
PORT = int(os.getenv("PORT", "8000"))
APP_SESSION_SECRET = secrets.token_urlsafe(32)
APP_BASE_URL = os.getenv("APP_BASE_URL", "http://localhost:8080").rstrip("/")
OCI_GENAI_MEMORY_SUBJECT_ID = os.getenv("OCI_GENAI_MEMORY_SUBJECT_ID", "")
OCI_GENAI_MEMORY_ACCESS_POLICY = os.getenv("OCI_GENAI_MEMORY_ACCESS_POLICY", "recall_and_store")
OCI_GENAI_SHORT_TERM_MEMORY_OPTIMIZATION = os.getenv("OCI_GENAI_SHORT_TERM_MEMORY_OPTIMIZATION", "")

OCI_IDENTITY_DOMAIN_ISSUER = os.getenv("OCI_IDENTITY_DOMAIN_ISSUER", "").rstrip("/")
OCI_OIDC_CLIENT_ID = os.getenv("OCI_OIDC_CLIENT_ID", "")
OCI_OIDC_CLIENT_SECRET = os.getenv("OCI_OIDC_CLIENT_SECRET", "")
OCI_OIDC_REDIRECT_URI = f"{APP_BASE_URL}/auth/callback"
AUTH_COOKIE_NAME = "oci_ai_chat_session"
AUTH_ENABLED = True
AUTH_COOKIE_SECURE = APP_BASE_URL.lower().startswith("https://")
AUTH_ALLOWED_GROUPS: set[str] = set()
AUTH_GROUP_REGION_MAP: dict[str, list[str]] = {}
AUTH_GROUP_COMPARTMENT_MAP: dict[str, list[str]] = {}

def _load_oci_signer():
    try:
        return oci.auth.signers.get_resource_principals_signer()
    except Exception as exc:
        logger.warning("OCI resource principal signer is not available yet: %s", exc)
        return None


OCI_SIGNER = _load_oci_signer()


def _signer_value(*names: str) -> str:
    for name in names:
        value = getattr(OCI_SIGNER, name, "") if OCI_SIGNER is not None else ""
        if value:
            return str(value)
    return ""


def _load_oci_config() -> dict:
    region = (
        os.getenv("OCI_RESOURCE_PRINCIPAL_REGION", "")
        or _signer_value("region", "_region")
    )
    tenancy_id = _signer_value("tenancy_id", "tenant_id", "_tenancy_id")
    config = {"region": region}
    if tenancy_id:
        config["tenancy"] = tenancy_id
    return config


OCI_CONFIG = _load_oci_config()


def oci_client_kwargs(config: dict | None = None) -> dict:
    kwargs = {"config": config or OCI_CONFIG}
    if OCI_SIGNER is not None:
        kwargs["signer"] = OCI_SIGNER
    return kwargs

PROJECT_ROOT = Path(__file__).resolve().parents[1]
FRONTEND_DIR = PROJECT_ROOT / "frontend"
DATA_DIR = Path(os.getenv("APP_DATA_DIR", "/app/data"))
CONVERSATION_DB_PATH = DATA_DIR / "conversations.sqlite3"
