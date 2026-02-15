@echo off
setlocal

cd /d "%~dp0"

set FLINT=engine\target\release\flint
set SCENE=scenes\oval_plus.scene.toml
set SCHEMAS=--schemas engine\schemas --schemas schemas

echo Rendering overhead view...
%FLINT% render %SCENE% %SCHEMAS% --output render_overhead.png --width 1280 --height 720 --no-grid --shadows --distance 80 --pitch 70 --target 0,0,0

echo Rendering kart close-up...
%FLINT% render %SCENE% %SCHEMAS% --output render_kart.png --width 1280 --height 720 --no-grid --shadows --distance 12 --pitch 25 --yaw 30 --target 0,1,5

echo Done. Output: render_overhead.png, render_kart.png
