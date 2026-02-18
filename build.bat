@echo off
cd /d "%~dp0engine"
cargo build --release --bin flint-player --bin flint
if errorlevel 1 (
    echo Build failed!
    exit /b 1
)
cargo install --path crates/flint-player --force
cargo install --path crates/flint-cli --force
if errorlevel 1 (
    echo Install to PATH failed!
    exit /b 1
)
echo Build and install successful.
