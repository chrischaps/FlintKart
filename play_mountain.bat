@echo off
cd /d "%~dp0"
engine\target\release\flint-player.exe scenes\mountain_switchback.scene.toml --schemas engine\schemas --schemas schemas
