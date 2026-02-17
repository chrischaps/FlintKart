@echo off
cd /d "%~dp0"
engine\target\release\flint serve scenes\mountain_switchback.scene.toml --schemas engine\schemas --schemas schemas
