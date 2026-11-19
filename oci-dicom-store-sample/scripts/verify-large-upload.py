#!/usr/bin/env python3

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Exercise the HTTPS NLB with a 32 MiB synthetic DICOM, then delete the study.
Requires the existing Terraform state and curl; never prints credentials.
"""
import email.parser
import email.policy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.parse
import uuid

ROOT = Path(__file__).resolve().parent.parent

def output(name, raw=True):
    return subprocess.check_output(['terraform', f'-chdir={ROOT / "terraform"}', 'output', '-raw' if raw else '-json', name], text=True).strip()

with tempfile.TemporaryDirectory(prefix='dicom-large-upload-') as tmp:
    temp = Path(tmp)
    cert = temp / 'ca.pem'
    cert.write_text(output('large_upload_certificate'))
    base = output('large_upload_endpoint')
    api = output('api_endpoint')
    keycloak = output('keycloak_endpoint')
    counter = 0

    def request(url, method='GET', body=None, token=None, content_type=None, accept=None):
        global counter
        counter += 1
        dest, headers = temp / f'response-{counter}', temp / f'headers-{counter}'
        args = ['curl', '--silent', '--show-error', '--connect-timeout', '20', '--max-time', '600', '--request', method, '--output', str(dest), '--dump-header', str(headers), '--write-out', '%{http_code}', '--config', '-']
        if url.startswith(base):
            args += ['--cacert', str(cert)]
        config = ''
        if token:
            config += 'header = ' + json.dumps('Authorization: Bearer ' + token) + '\n'
        for name, value in [('Content-Type', content_type), ('Accept', accept)]:
            if value:
                args += ['--header', name + ': ' + value]
        if body is not None:
            datafile = temp / f'body-{counter}'
            datafile.write_bytes(body)
            datafile.chmod(0o600)
            args += ['--data-binary', '@' + str(datafile)]
        result = subprocess.run(args + [url], input=config, text=True, capture_output=True, check=True)
        return int(result.stdout), dest.read_bytes(), headers.read_bytes()

    def get_token(username, password):
        body = urllib.parse.urlencode(dict(client_id='orthanc', grant_type='password', username=username, password=password)).encode()
        status, data, _ = request(keycloak + '/realms/orthanc/protocol/openid-connect/token', 'POST', body, content_type='application/x-www-form-urlencoded')
        assert status == 200, f'Login failed: HTTP {status}'
        return json.loads(data)['access_token']

    admin = get_token(output('orthanc_username'), output('orthanc_password'))
    for token in [None, 'invalid-token']:
        status, _, _ = request(base + '/dicom-web/studies', token=token)
        assert status in (401, 403), f'Unauthenticated request accepted: {status}'
    for path in ['/ui/app/', '/tools/find', '/../keycloak/', '/system']:
        status, _, _ = request(base + path, token=admin)
        assert status == 404, f'Non-imaging route exposed: {path} HTTP {status}'
    print('OK  TLS certificate verified; anonymous/invalid tokens denied; UI/admin routes excluded', flush=True)

    spec = importlib.util.spec_from_file_location('generator', ROOT / 'scripts/generate-test-dicom.py')
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    payload, meta = generator.build_dicom(patient_id='SYNTHETIC-LARGE-UPLOAD')
    for tag, value in [(0x0010, 4096), (0x0011, 8192)]:
        payload = payload.replace(generator.unsigned_short(0x0028, tag, 1), generator.unsigned_short(0x0028, tag, value), 1)
    pixels = bytes(range(256)) * (4096 * 8192 // 256)
    old = generator.encode_element(0x7FE0, 0x0010, 'OB', b'\0\0')
    assert payload.endswith(old)
    payload = payload[:-len(old)] + generator.encode_element(0x7FE0, 0x0010, 'OB', pixels)
    boundary = 'dicom-' + uuid.uuid4().hex
    multipart = (f'--{boundary}\r\nContent-Type: application/dicom\r\n\r\n'.encode() + payload + f'\r\n--{boundary}--\r\n'.encode())
    study_id = None
    try:
        status, _, _ = request(api + '/dicom-web/studies', 'POST', multipart, admin, f'multipart/related; type="application/dicom"; boundary={boundary}')
        assert status == 413, f'Expected API Gateway size rejection; received HTTP {status}'
        print('OK  API Gateway rejects the same oversized request with HTTP 413', flush=True)
        status, _, _ = request(base + '/dicom-web/studies', 'POST', multipart, admin, f'multipart/related; type="application/dicom"; boundary={boundary}')
        assert status in (200, 202), f'Large STOW failed: HTTP {status}'
        query = json.dumps({'Level': 'Study', 'Query': {'StudyInstanceUID': meta['StudyInstanceUID']}}).encode()
        status, data, _ = request(api + '/tools/find', 'POST', query, admin, 'application/json')
        assert status == 200 and len(json.loads(data)) == 1, 'Uploaded study not found'
        study_id = json.loads(data)[0]
        print(f'OK  STOW-RS upload: {len(payload)} DICOM bytes ({len(multipart)} request bytes)', flush=True)
        status, data, _ = request(base + '/dicom-web/studies?StudyInstanceUID=' + meta['StudyInstanceUID'], token=admin, accept='application/dicom+json')
        assert status == 200 and len(json.loads(data)) == 1, f'QIDO failed: {status}'
        wado = base + '/dicom-web/studies/' + meta['StudyInstanceUID'] + '/series/' + meta['SeriesInstanceUID'] + '/instances/' + meta['SOPInstanceUID']
        status, data, headers = request(wado, token=admin, accept='multipart/related; type="application/dicom"; transfer-syntax=*')
        assert status == 200, f'WADO failed: {status}'
        content = next(line for line in headers.decode().splitlines() if line.lower().startswith('content-type:'))
        message = email.parser.BytesParser(policy=email.policy.default).parsebytes(content.encode() + b'\r\nMIME-Version: 1.0\r\n\r\n' + data)
        parts = list(message.iter_parts())
        assert len(parts) == 1 and parts[0].get_payload(decode=True) == payload, 'WADO bytes differ from upload'
        print('OK  QIDO search and byte-identical WADO retrieval through NLB', flush=True)
        tenants = json.loads(output('tenant_test_credentials', False))
        if len(tenants) >= 2:
            tenant_keys = sorted(tenants)[:2]
            tokens = [get_token(tenants[k]['username'], tenants[k]['password']) for k in tenant_keys]
            status, _, _ = request(wado, token=tokens[0])
            assert status in (401, 403, 404), f'Unclassified study leaked: {status}'
            auth = json.loads(output('tenant_authorization', False))
            label = auth['tenants'][tenant_keys[0]]['label']
            status, _, _ = request(api + '/studies/' + study_id + '/labels/' + urllib.parse.quote(label), 'PUT', b'', admin)
            assert status == 200, f'Classification failed: {status}'
            # Classification changes can take time to reach authorization caches.
            for attempt in range(45):
                status, data, _ = request(base + '/dicom-web/studies?StudyInstanceUID=' + meta['StudyInstanceUID'], token=tokens[0], accept='application/dicom+json')
                if status == 200 and len(json.loads(data)) == 1:
                    break
                time.sleep(2)
            else:
                raise AssertionError('Authorized tenant cannot discover its classified study')
            viewer_request = json.dumps({'Type': 'viewer-instant-link', 'ValidityDuration': 300, 'Resources': [{'OrthancId': study_id, 'DicomUid': meta['StudyInstanceUID'], 'Level': 'study'}]}).encode()
            status, data, _ = request(api + '/auth/tokens/viewer-instant-link', 'PUT', viewer_request, tokens[0], 'application/json')
            assert status == 200, f'Authorized tenant viewer token denied: {status}'
            viewer = json.loads(data)['Token']
            status, _, _ = request(wado, token=viewer, accept='multipart/related; type="application/dicom"')
            assert status == 200, f'Authorized study token denied: {status}'
            status, _, _ = request(wado, token=tokens[1])
            assert status in (401, 403, 404), f'Cross-tenant access allowed: {status}'
            print('OK  Quarantine, tenant QIDO, study-token retrieval, and cross-tenant denial through NLB', flush=True)
        else:
            print('SKIP Tenant tests: enable_tenant_test_users requires two tenants', flush=True)
    finally:
        if study_id is None:
            query = json.dumps({'Level': 'Study', 'Query': {'StudyInstanceUID': meta['StudyInstanceUID']}}).encode()
            status, data, _ = request(api + '/tools/find', 'POST', query, admin, 'application/json')
            if status == 200 and len(json.loads(data)) == 1:
                study_id = json.loads(data)[0]
        if study_id:
            status, _, _ = request(api + '/studies/' + study_id, 'DELETE', token=admin)
            assert status == 200, f'Synthetic cleanup failed: {status}'
            print('OK  Synthetic study deleted (bucket versions may remain)', flush=True)
