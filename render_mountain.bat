@echo off
setlocal

cd /d "%~dp0"

set FLINT=engine\target\release\flint
set SCENE=scenes\mountain_switchback.scene.toml
set SCHEMAS=--schemas engine\schemas --schemas schemas

echo Rendering mountain overhead view...
%FLINT% render %SCENE% %SCHEMAS% --output render_mountain_overhead.png --width 1280 --height 720 --no-grid --distance 280 --pitch 88 --target "10,14,-20"

echo Rendering mountain close-up...
%FLINT% render %SCENE% %SCHEMAS% --output render_mountain_closeup.png --width 1280 --height 720 --no-grid --distance 15 --pitch 25 --yaw 30 --target 0,1,5

echo Done. Output: render_mountain_overhead.png, render_mountain_closeup.png
