@echo off
rem ===========================================================================
rem Update Log Version Manager - open the web UI in your browser.
rem Double-click this file. It starts a hidden background server (once) and
rem opens http://127.0.0.1:8791 in your default browser.
rem Double-clicking again just re-opens the page (it reuses the running server).
rem ===========================================================================
cd /d "%~dp0"
node server.mjs
exit /b 0
