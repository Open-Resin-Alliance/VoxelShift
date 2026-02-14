@echo off
REM VoxelShift MSI Build - Quick wrapper
REM Double-click this file to build MSI

setlocal enabledelayedexpansion

echo.
echo Building VoxelShift MSI...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_msi.ps1"

if %ERRORLEVEL% neq 0 (
    echo.
    echo MSI build failed. Press any key to exit...
    pause >nul
    exit /b 1
) else (
    echo.
    echo MSI build successful!
    pause
)
