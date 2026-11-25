@echo off
cd /d "%~dp0engine"
rem The engine's flint-player and flint, built with the packages flint.toml
rem lists and nothing else (Flint #1335); flint finds flint.toml above engine\.
rem Before the first build there is no flint that knows `build` (none at all,
rem or one from an older engine), so cargo makes one with no package and the
rem build options `flint build` keeps (audio, gamepad, dialogs): the flint
rem this game's list asks for, so `build` has only the player left to make.
rem Both run here in engine\, whose .cargo\config.toml cargo reads only from
rem here: from the game's root every crate would build a second time.
target\release\flint.exe build --help >nul 2>&1
if errorlevel 1 (
    cargo run --release -p flint-cli --no-default-features --features audio,gamepad,dialogs -- build --release
) else (
    target\release\flint.exe build --release
)
if errorlevel 1 (
    echo Build failed!
    exit /b 1
)
rem On PATH: the pair just built. `cargo install --path` would build them
rem again with every package, so they are copied instead.
set BIN=%USERPROFILE%\.cargo\bin
if defined CARGO_HOME set BIN=%CARGO_HOME%\bin
copy /y target\release\flint-player.exe "%BIN%\" >nul
if errorlevel 1 goto :install_failed
copy /y target\release\flint.exe "%BIN%\" >nul
if errorlevel 1 goto :install_failed
echo Build and install successful.
exit /b 0
:install_failed
echo Install to PATH failed!
exit /b 1
