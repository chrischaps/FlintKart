@echo off
cd /d "%~dp0"
engine\target\release\flint-player.exe scenes\mountain_switchback_chris.scene.toml --schemas engine\schemas --schemas schemas
