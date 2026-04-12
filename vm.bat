@echo off
:: Windsurf VM Manager — wrapper for vm.ps1
:: Add this folder to PATH to use "vm" from anywhere.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vm.ps1" %*
