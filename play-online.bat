@echo off
rem Join the shared Dried Sea server on GCP as yourself.
set "GODOT=%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7-stable_win64.exe"
start "" "%GODOT%" --path "%~dp0game" -- --connect=34.75.205.43 --name=%USERNAME%
