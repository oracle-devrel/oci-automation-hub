# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

FROM python:3.12.14-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 HOME=/tmp
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --only-binary=:all: --require-hashes -r requirements.txt \
    && python -c "from switchyard.libsy import LlmClassifierConfig, TaskClassifierConfig, algorithms"
COPY app.py .
COPY static ./static
USER 10001:10001
EXPOSE 8080
CMD ["python", "app.py"]
