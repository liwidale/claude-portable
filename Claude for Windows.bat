@echo off
title Claude Portable
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0system\claude-portable.ps1" %*
if errorlevel 1 pause
