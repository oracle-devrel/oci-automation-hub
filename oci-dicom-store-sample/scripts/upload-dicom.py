#!/usr/bin/env python3

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Upload a DICOM over HTTPS with interactive login and explicit certificate trust."""
import argparse
import getpass
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import urllib.parse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('file', nargs='?', type=Path, help='DICOM file to upload')
    parser.add_argument('--config', type=Path, default=Path(__file__).with_name('upload-config.json'))
    parser.add_argument('--synthetic', action='store_true', help='Generate and upload a 32 MiB synthetic image')
    parser.add_argument('--username', help='Override the username in the configuration')
    parser.add_argument('--delete-after-upload', action='store_true', help='Delete this uploaded instance after verification')
    args = parser.parse_args()
    if bool(args.file) == args.synthetic:
        parser.error('provide one DICOM file OR --synthetic')
    config = json.loads(args.config.read_text())
    endpoint = config['upload_endpoint'].rstrip('/')
    api = config['api_endpoint'].rstrip('/')
    token_url = config['token_url']
    for url in [endpoint, api, token_url]:
        if urllib.parse.urlparse(url).scheme != 'https':
            parser.error('all endpoints must use HTTPS')
    certificate = args.config.resolve().parent / config['certificate']
    if not certificate.is_file():
        parser.error(f'Trust certificate not found: {certificate}')
    if args.file and not args.file.is_file():
        parser.error(f'DICOM file not found: {args.file}')
    username = args.username or config.get('username') or input('Orthanc username: ').strip()
    password = getpass.getpass(f'Password for {username}: ')

    with tempfile.TemporaryDirectory(prefix='dicom-upload-') as directory:
        temp = Path(directory)

        def request(url, method='GET', token=None, body=None, content_type=None):
            response = temp / 'response.json'
            command = ['curl', '--silent', '--show-error', '--connect-timeout', '20',
                       '--max-time', '3600', '--request', method, '--output', str(response),
                       '--write-out', '%{http_code}', '--config', '-']
            if url.startswith(endpoint + '/'):
                command += ['--cacert', str(certificate)]
            # Send the token through stdin, not the process command line.
            curl_config = ('header = ' + json.dumps('Authorization: Bearer ' + token) + '\n') if token else ''
            if content_type:
                command += ['--header', 'Content-Type: ' + content_type]
            if body is not None:
                command += ['--data-binary', '@' + str(body)]
            result = subprocess.run(command + [url], input=curl_config, text=True, capture_output=True)
            if result.returncode:
                raise RuntimeError('Connection failed: ' + result.stderr.strip() +
                                   '\nConfirm your public IP is allowed and use the supplied certificate.')
            status = int(result.stdout)
            if not 200 <= status < 300:
                raise RuntimeError(f'HTTP {status} for {urllib.parse.urlparse(url).path}. '
                                   'Check credentials, upload permissions, and the endpoint.')
            return json.loads(response.read_text() or '{}')

        login = temp / 'login.form'
        login.write_text(urllib.parse.urlencode(dict(client_id='orthanc', grant_type='password',
                                                    username=username, password=password)))
        login.chmod(0o600)
        password = None
        try:
            token = request(token_url, 'POST', body=login,
                            content_type='application/x-www-form-urlencoded')['access_token']
        finally:
            login.unlink(missing_ok=True)
        print('Signed in. TLS certificate verification is enabled.', flush=True)

        file = args.file
        if args.synthetic:
            generator_path = Path(__file__).with_name('generate-test-dicom.py')
            spec = importlib.util.spec_from_file_location('dicom_generator', generator_path)
            generator = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(generator)
            payload, _ = generator.build_dicom(patient_id='SYNTHETIC-MANUAL-UPLOAD')
            for tag, value in [(0x0010, 4096), (0x0011, 8192)]:
                payload = payload.replace(generator.unsigned_short(0x0028, tag, 1),
                                          generator.unsigned_short(0x0028, tag, value), 1)
            old_pixel = generator.encode_element(0x7FE0, 0x0010, 'OB', b'\0\0')
            assert payload.endswith(old_pixel)
            pixels = bytes(range(256)) * (4096 * 8192 // 256)
            file = temp / 'synthetic-32MiB.dcm'
            file.write_bytes(payload[:-len(old_pixel)] + generator.encode_element(0x7FE0, 0x0010, 'OB', pixels))

        print(f'Uploading {file.name}: {file.stat().st_size:,} bytes to {endpoint}/instances', flush=True)
        uploaded = request(endpoint + '/instances', 'POST', token, file, 'application/dicom')
        identifier = uploaded['ID']
        print(f'Upload result: {uploaded["Status"]}\nInstance ID: {identifier}', flush=True)
        # The UI/management endpoint retains the same study authorization.
        verified = request(api + '/instances/' + identifier, token=token)
        assert verified['ID'] == identifier, 'Instance verification failed'
        print('Verified: Orthanc can find the uploaded instance.', flush=True)
        if args.delete_after_upload:
            if uploaded.get('Status') != 'Success':
                raise RuntimeError('Refusing to delete an instance that already existed before this upload.')
            request(api + '/instances/' + identifier, 'DELETE', token=token)
            print('Test instance deleted. Object Storage versions may remain.', flush=True)
        else:
            print(f'Image retained. View it at {api}/ui/app/', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, KeyError, ValueError) as error:
        raise SystemExit(str(error))
