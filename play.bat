@echo off
rem Launch The Dried Sea (windowed). WASD move, E harvest, C craft, B build.
set "GODOT=%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7-stable_win64.exe"
"%GODOT%" --path "%~dp0game"
