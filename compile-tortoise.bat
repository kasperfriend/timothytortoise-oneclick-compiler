@echo off
:: =====================================================================
::  Turtle WoW (T-imothy/tortoise-wow, mantech-turtle) - ONE CLICK SETUP
::  Double-click this file. Everything is installed INSIDE this folder.
:: =====================================================================
setlocal
title Turtle WoW - One Click Setup
cd /d "%~dp0"

where powershell >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Windows PowerShell was not found. It ships with Windows 10/11 - please repair your Windows installation.
    pause
    exit /b 1
)

if not exist "%~dp0oneclick-setup.ps1" (
    echo [ERROR] oneclick-setup.ps1 is missing next to setup.bat
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0oneclick-setup.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo  ======================================================
    echo   SETUP FINISHED SUCCESSFULLY.  See README-FIRST.txt
    echo  ======================================================
) else (
    echo  ======================================================
    echo   SETUP FAILED with code %RC%.  Read the messages above
    echo   and setup.log. Fix the cause and double-click setup.bat
    echo   again - it resumes where it stopped.
    echo  ======================================================
)
echo.
pause
exit /b %RC%
