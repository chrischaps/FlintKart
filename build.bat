@echo off
cd /d "%~dp0engine"
cargo build --release --bin flint-player
if errorlevel 1 (
    echo Build failed!
    exit /b 1
)
echo Build successful.
