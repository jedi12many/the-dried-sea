@echo off
rem Full verification: content validator, economy bands, sim unit suite, playable smoke.
setlocal
set "GODOT=%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7-stable_win64_console.exe"
cd /d "%~dp0"
echo === content validator ===
node tools\validate.mjs || goto :fail
echo === economy model ===
node tools\economy-model.mjs || goto :fail
echo === sim unit suite ===
"%GODOT%" --headless --path game --script res://tests/run_tests.gd || goto :fail
echo === playable smoke ===
"%GODOT%" --headless --path game res://tests/smoke.tscn || goto :fail
echo.
echo ALL GREEN
exit /b 0
:fail
echo.
echo FAILED — see output above
exit /b 1
