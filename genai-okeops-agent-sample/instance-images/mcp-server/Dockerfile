# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
FROM container-registry.oracle.com/os/oraclelinux:9-slim AS kubectl-downloader

ARG TARGETARCH
ARG KUBECTL_VERSION=v1.38.0-alpha.0

RUN microdnf install -y ca-certificates curl \
    && curl --fail --location --silent --show-error \
        --output /kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
    && chmod 0755 /kubectl \
    && microdnf clean all

FROM container-registry.oracle.com/os/oraclelinux:9-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/tmp \
    OCI_CLI_AUTH=resource_principal \
    UV_PROJECT_ENVIRONMENT=/app/.venv \
    UV_PYTHON=python3.11 \
    PATH="/app/.venv/bin:$PATH"

WORKDIR /app

RUN microdnf install -y python3.11 ca-certificates shadow-utils \
    && rpm -e --nodeps python3.11-setuptools-wheel python3.11-pip-wheel \
    && rm -rf /usr/share/python3.11-wheels \
    && microdnf clean all \
    && rm -rf /var/cache/dnf /var/cache/yum

COPY --from=kubectl-downloader /kubectl /usr/local/bin/kubectl
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

COPY app.py __init__.py ./

RUN useradd --create-home --uid 1000 mcpuser \
    && chown -R mcpuser:mcpuser /app

USER mcpuser

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python3.11 -c "from urllib.request import urlopen; urlopen('http://127.0.0.1:8080/healthz', timeout=3).close()" || exit 1

CMD ["python3.11", "app.py"]