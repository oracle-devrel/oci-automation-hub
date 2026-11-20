# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
import time
from typing import Any, Dict, Optional
from urllib.parse import urlencode

import httpx
import jwt
from jwt import PyJWTError
from jwt.algorithms import RSAAlgorithm
from fastapi import HTTPException, Request
from fastapi.responses import RedirectResponse

from .config import (
    APP_BASE_URL,
    APP_SESSION_SECRET,
    AUTH_ALLOWED_GROUPS,
    AUTH_ENABLED,
    AUTH_GROUP_COMPARTMENT_MAP,
    AUTH_GROUP_REGION_MAP,
    AUTH_COOKIE_NAME,
    AUTH_COOKIE_SECURE,
    OCI_IDENTITY_DOMAIN_ISSUER,
    OCI_OIDC_CLIENT_ID,
    OCI_OIDC_CLIENT_SECRET,
    OCI_OIDC_REDIRECT_URI,
)

_SESSION_ID_TOKENS: Dict[str, str] = {}


def auth_configured() -> bool:
    return bool(OCI_IDENTITY_DOMAIN_ISSUER and OCI_OIDC_CLIENT_ID and OCI_OIDC_CLIENT_SECRET)


def auth_enabled() -> bool:
    return AUTH_ENABLED


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def _unb64(data: str) -> bytes:
    padding = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode(data + padding)


def _sign(payload: str) -> str:
    return _b64(hmac.new(APP_SESSION_SECRET.encode("utf-8"), payload.encode("utf-8"), hashlib.sha256).digest())


def encode_session(user: Dict[str, Any]) -> str:
    payload = _b64(json.dumps({"user": user, "iat": int(time.time())}, separators=(",", ":")).encode("utf-8"))
    return f"{payload}.{_sign(payload)}"


def decode_session(value: str) -> Optional[Dict[str, Any]]:
    try:
        payload, signature = value.split(".", 1)
        expected = _sign(payload)
        if not hmac.compare_digest(signature, expected):
            return None
        data = json.loads(_unb64(payload))
        user = data.get("user")
        return user if isinstance(user, dict) else None
    except Exception:
        return None


def current_user_from_request(request: Request) -> Dict[str, Any]:
    if not auth_enabled():
        return {
            "sub": request.client.host if request.client else "local",
            "display_name": "Local user",
            "email": "",
            "groups": [],
            "auth_mode": "disabled",
        }

    if not auth_configured():
        raise HTTPException(status_code=503, detail="OCI OIDC authentication is not configured")

    session = request.cookies.get(AUTH_COOKIE_NAME)
    user = decode_session(session or "")
    if not user:
        raise HTTPException(status_code=401, detail="Authentication required")

    if AUTH_ALLOWED_GROUPS:
        groups = set(str(group) for group in user.get("groups", []))
        if not groups.intersection(AUTH_ALLOWED_GROUPS):
            raise HTTPException(status_code=403, detail="User is not in an allowed OCI group")

    return user


def authenticated_user_from_request(request: Request) -> Optional[Dict[str, Any]]:
    if not auth_configured():
        return None
    session = request.cookies.get(AUTH_COOKIE_NAME)
    user = decode_session(session or "")
    return user if user else None


def public_user(user: Dict[str, Any]) -> Dict[str, Any]:
    return {key: value for key, value in user.items() if not key.startswith("_")}


def user_storage_key(user: Dict[str, Any]) -> str:
    return f"oci-user:{user.get('sub') or user.get('email') or 'unknown'}"


def _values_for_user_groups(user: Dict[str, Any], mapping: Dict[str, Any]) -> set[str]:
    groups = set(str(group) for group in user.get("groups", []))
    values: set[str] = set()
    for group in groups:
        raw = mapping.get(group) or []
        if isinstance(raw, str):
            values.add(raw)
        elif isinstance(raw, list):
            values.update(str(item) for item in raw if str(item).strip())
    return values


def allowed_regions_for_user(user: Dict[str, Any]) -> set[str]:
    return _values_for_user_groups(user, AUTH_GROUP_REGION_MAP)


def allowed_compartments_for_user(user: Dict[str, Any]) -> set[str]:
    return _values_for_user_groups(user, AUTH_GROUP_COMPARTMENT_MAP)


def discovery_url() -> str:
    return f"{OCI_IDENTITY_DOMAIN_ISSUER}/.well-known/openid-configuration"


def oidc_metadata() -> Dict[str, Any]:
    with httpx.Client(timeout=20.0) as client:
        res = client.get(discovery_url())
        res.raise_for_status()
        return res.json()


def signing_key_from_jwks(jwks_uri: str, id_token: str):
    token_header = jwt.get_unverified_header(id_token)
    key_id = token_header.get("kid")
    with httpx.Client(timeout=20.0) as client:
        res = client.get(jwks_uri)
        res.raise_for_status()
        jwks = res.json()

    for key in jwks.get("keys", []):
        if key.get("kid") == key_id:
            return RSAAlgorithm.from_jwk(json.dumps(key))

    raise HTTPException(status_code=401, detail="OCI ID token signing key was not found in JWKS")


def userinfo_claims(metadata: Dict[str, Any], access_token: str) -> Dict[str, Any]:
    endpoint = metadata.get("userinfo_endpoint") or metadata.get("secure_userinfo_endpoint")
    if not endpoint:
        raise HTTPException(status_code=401, detail="OCI userinfo endpoint is not available")

    with httpx.Client(timeout=20.0) as client:
        res = client.get(endpoint, headers={"Authorization": f"Bearer {access_token}"})
        if res.status_code >= 400:
            raise HTTPException(status_code=401, detail="OCI userinfo lookup failed")
        claims = res.json()
        return claims if isinstance(claims, dict) else {}


def login_redirect(request: Request) -> RedirectResponse:
    if not auth_enabled():
        return RedirectResponse("/")

    if not auth_configured():
        raise HTTPException(status_code=503, detail="OCI OIDC authentication is not configured")

    metadata = oidc_metadata()
    state = secrets.token_urlsafe(24)
    nonce = secrets.token_urlsafe(24)
    params = {
        "client_id": OCI_OIDC_CLIENT_ID,
        "response_type": "code",
        "scope": "openid profile email groups",
        "redirect_uri": OCI_OIDC_REDIRECT_URI,
        "state": state,
        "nonce": nonce,
    }
    response = RedirectResponse(f"{metadata['authorization_endpoint']}?{urlencode(params)}")
    response.set_cookie("oci_auth_state", state, httponly=True, secure=AUTH_COOKIE_SECURE, samesite="lax", max_age=600)
    response.set_cookie("oci_auth_nonce", nonce, httponly=True, secure=AUTH_COOKIE_SECURE, samesite="lax", max_age=600)
    return response


def _normalize_groups(claims: Dict[str, Any]) -> list[str]:
    groups = claims.get("groups") or claims.get("groupNames") or []
    if isinstance(groups, str):
        return [groups]
    if isinstance(groups, list):
        result = []
        for item in groups:
            if isinstance(item, str):
                result.append(item)
            elif isinstance(item, dict):
                value = item.get("name") or item.get("display") or item.get("value")
                if value:
                    result.append(str(value))
        return result
    return []


def callback_response(request: Request, code: str, state: str) -> RedirectResponse:
    if state != request.cookies.get("oci_auth_state"):
        raise HTTPException(status_code=400, detail="Invalid authentication state")

    metadata = oidc_metadata()
    client_auth = base64.b64encode(f"{OCI_OIDC_CLIENT_ID}:{OCI_OIDC_CLIENT_SECRET}".encode("utf-8")).decode("ascii")
    with httpx.Client(timeout=30.0) as client:
        token_res = client.post(
            metadata["token_endpoint"],
            data={
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": OCI_OIDC_REDIRECT_URI,
            },
            headers={
                "Authorization": f"Basic {client_auth}",
                "Content-Type": "application/x-www-form-urlencoded",
            },
        )
        if token_res.status_code >= 400:
            detail = "OCI token exchange failed"
            try:
                token_error = token_res.json()
                detail = token_error.get("error_description") or token_error.get("error") or detail
            except Exception:
                if token_res.text:
                    detail = token_res.text[:500]
            raise HTTPException(status_code=401, detail=detail)
        token_data = token_res.json()

    id_token = token_data.get("id_token")
    if not id_token:
        raise HTTPException(status_code=400, detail="OCI did not return an ID token")

    expected_issuer = metadata.get("issuer") or OCI_IDENTITY_DOMAIN_ISSUER
    unverified_claims: Dict[str, Any] = {}
    try:
        unverified_claims = jwt.decode(id_token, options={"verify_signature": False, "verify_aud": False})
    except PyJWTError:
        unverified_claims = {}

    try:
        signing_key = signing_key_from_jwks(metadata["jwks_uri"], id_token)
        claims = jwt.decode(
            id_token,
            signing_key,
            algorithms=["RS256"],
            audience=OCI_OIDC_CLIENT_ID,
            issuer=expected_issuer,
        )
    except (PyJWTError, httpx.HTTPError, HTTPException):
        access_token = token_data.get("access_token")
        claims = dict(unverified_claims)
        if access_token:
            try:
                claims = {**claims, **userinfo_claims(metadata, access_token)}
            except HTTPException:
                pass
        if not claims.get("sub"):
            raise HTTPException(status_code=401, detail="OCI token validation failed and no usable identity claims were returned")

    expected_nonce = request.cookies.get("oci_auth_nonce")
    token_nonce = claims.get("nonce") or unverified_claims.get("nonce")
    if expected_nonce and token_nonce != expected_nonce:
        raise HTTPException(status_code=400, detail="Invalid authentication nonce")

    session_id = secrets.token_urlsafe(24)
    _SESSION_ID_TOKENS[session_id] = id_token
    user = {
        "sub": claims.get("sub"),
        "display_name": claims.get("name") or claims.get("preferred_username") or claims.get("email") or "OCI user",
        "email": claims.get("email") or claims.get("preferred_username"),
        "groups": _normalize_groups(claims),
        "auth_mode": "oci-identity-domain",
        "_sid": session_id,
    }

    response = RedirectResponse("/")
    response.set_cookie(
        AUTH_COOKIE_NAME,
        encode_session(user),
        httponly=True,
        secure=AUTH_COOKIE_SECURE,
        samesite="lax",
        max_age=60 * 60 * 12,
    )
    clear_auth_cookies(response, include_session=False)
    return response


def clear_auth_cookies(response: RedirectResponse, include_session: bool = True) -> None:
    if include_session:
        response.delete_cookie(AUTH_COOKIE_NAME, path="/")
        response.set_cookie(AUTH_COOKIE_NAME, "", max_age=0, expires=0, path="/", httponly=True, secure=AUTH_COOKIE_SECURE, samesite="lax")
    for name in ("oci_auth_state", "oci_auth_nonce"):
        response.delete_cookie(name, path="/")
        response.set_cookie(name, "", max_age=0, expires=0, path="/", httponly=True, secure=AUTH_COOKIE_SECURE, samesite="lax")


def logout_response(request: Request) -> RedirectResponse:
    if not auth_enabled():
        return RedirectResponse("/")

    id_token = ""
    session = request.cookies.get(AUTH_COOKIE_NAME)
    user = decode_session(session or "")
    if user:
        session_id = str(user.get("_sid") or "")
        id_token = _SESSION_ID_TOKENS.pop(session_id, "") if session_id else ""

    redirect_url = "/auth/login"
    if auth_configured() and id_token:
        try:
            metadata = oidc_metadata()
            logout_endpoint = metadata.get("end_session_endpoint") or f"{OCI_IDENTITY_DOMAIN_ISSUER}/oauth2/v1/userlogout"
            params = {
                "post_logout_redirect_uri": f"{APP_BASE_URL.rstrip('/')}/",
                "state": secrets.token_urlsafe(16),
            }
            if id_token:
                params["id_token_hint"] = id_token
            redirect_url = f"{logout_endpoint}?{urlencode(params)}"
        except Exception:
            redirect_url = "/auth/login"

    response = RedirectResponse(redirect_url)
    clear_auth_cookies(response)
    return response
