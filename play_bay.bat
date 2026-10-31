@echo off
cd /d "%~dp0"
engine\target\release\flint-player.exe scenes\lighthouse_bay.scene.toml --schemas engine\schemas --schemas schemas
