@echo off
:: ─────────────────────────────────────────────────────────────────────────────
:: SupArr Deploy — Windows double-click launcher
:: Finds Python 3.7+, installs it via winget if missing, launches the GUI.
:: ─────────────────────────────────────────────────────────────────────────────

setlocal EnableDelayedExpansion

:: ── Find Python ──────────────────────────────────────────────────────────────

call :find_python
if defined PYTHON goto :launch

:: ── Install Python ───────────────────────────────────────────────────────────

echo.
echo  Python 3.7+ not found. Installing...
echo.

:: Try winget first (ships with Windows 10 1709+ and Windows 11)
where winget >nul 2>&1
if %errorlevel% equ 0 (
    echo  Installing Python via winget...
    winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements --silent
    if !errorlevel! equ 0 (
        echo.
        echo  Python installed. Refreshing PATH...
        echo.
        :: Refresh PATH from registry so we pick up the new install
        for /f "tokens=2*" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v Path 2^>nul') do set "SYS_PATH=%%B"
        for /f "tokens=2*" %%A in ('reg query "HKCU\Environment" /v Path 2^>nul') do set "USR_PATH=%%B"
        set "PATH=!SYS_PATH!;!USR_PATH!"
        call :find_python
        if defined PYTHON goto :launch
    )
)

:: Fallback: check Microsoft Store stub (python3 command opens Store on Win10+)
echo.
echo  ERROR: Could not install Python automatically.
echo.
echo  Install manually from: https://www.python.org/downloads/
echo  Make sure "Add Python to PATH" is checked during install.
echo  Then double-click this file again.
echo.
pause
exit /b 1

:: ── Launch ───────────────────────────────────────────────────────────────────

:launch
%PYTHON% "%~dp0deploy.py"
if errorlevel 1 pause
goto :eof

:: ── Helper: find_python ──────────────────────────────────────────────────────

:find_python
set "PYTHON="

where python3 >nul 2>&1
if %errorlevel% equ 0 (
    python3 -c "import sys; exit(0 if sys.version_info >= (3,7) else 1)" 2>nul
    if !errorlevel! equ 0 (
        set "PYTHON=python3"
        goto :eof
    )
)

where python >nul 2>&1
if %errorlevel% equ 0 (
    python -c "import sys; exit(0 if sys.version_info >= (3,7) else 1)" 2>nul
    if !errorlevel! equ 0 (
        set "PYTHON=python"
        goto :eof
    )
)

where py >nul 2>&1
if %errorlevel% equ 0 (
    py -3 -c "import sys; exit(0 if sys.version_info >= (3,7) else 1)" 2>nul
    if !errorlevel! equ 0 (
        set "PYTHON=py -3"
        goto :eof
    )
)

goto :eof
