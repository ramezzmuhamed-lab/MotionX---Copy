@echo off
title FiveM Optimizer
:: Ask for admin rights if we do not have them yet
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0FiveM-Optimizer.ps1"
