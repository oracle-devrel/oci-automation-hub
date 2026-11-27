# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

param([string]$PythonPath = '')
$ErrorActionPreference = 'Stop'
if (-not $PythonPath) { $PythonPath = $env:LIMIT_SETUP_PYTHON }
if ($PythonPath) {
    & $PythonPath "$PSScriptRoot\scripts\setup_app.py"
} elseif (Get-Command py -ErrorAction SilentlyContinue) {
    & py -3 "$PSScriptRoot\scripts\setup_app.py"
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    & python "$PSScriptRoot\scripts\setup_app.py"
} else {
    Write-Error 'Python was not found. Install an approved Python 3.10+ and rerun setup.'
    exit 1
}
exit $LASTEXITCODE
