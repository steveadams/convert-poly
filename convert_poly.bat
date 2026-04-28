@echo off
rem Drag-and-drop / double-click launcher for convert_poly.ps1.
rem
rem - Double-click this file -> a Windows file picker opens.
rem - Drag a .txt file onto this file -> it processes that file.
rem
rem In both cases the coordinates are auto-copied to the clipboard,
rem and the window stays open until you press a key so you can read
rem the output.

setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0convert_poly.ps1" %*

echo.
pause
