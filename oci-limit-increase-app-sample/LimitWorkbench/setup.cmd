REM Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
REM The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

@echo off
setlocal
if defined LIMIT_SETUP_PYTHON goto selected_python
where py >nul 2>nul
if errorlevel 1 goto fallback_python
py -3 "%~dp0scripts\setup_app.py" %*
exit /b %errorlevel%
:fallback_python
where python >nul 2>nul
if errorlevel 1 goto missing_python
python "%~dp0scripts\setup_app.py" %*
exit /b %errorlevel%
:selected_python
"%LIMIT_SETUP_PYTHON%" "%~dp0scripts\setup_app.py" %*
exit /b %errorlevel%
:missing_python
echo Python was not found. Install an approved Python 3.10+ and rerun setup.
exit /b 1
