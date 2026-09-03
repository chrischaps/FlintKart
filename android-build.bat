@echo off
setlocal

cd /d "%~dp0"

set GAME_DIR=%cd%
set ANDROID_DIR=%GAME_DIR%\engine\android
set APK=%ANDROID_DIR%\app\build\outputs\apk\debug\app-debug.apk

echo === Flint Android Build ===
echo Game:   %GAME_DIR%
echo Engine: %GAME_DIR%\engine
echo.

cd /d "%ANDROID_DIR%"

echo [1/2] Building APK...
call gradlew.bat assembleDebug -PgameDir="%GAME_DIR%"
if errorlevel 1 (
    echo ERROR: Gradle build failed.
    exit /b 1
)

if not exist "%APK%" (
    echo ERROR: APK not found at %APK%
    exit /b 1
)

echo [2/2] Installing on device...
adb install -r "%APK%"
if errorlevel 1 (
    echo ERROR: adb install failed. Is a device connected?
    exit /b 1
)

echo.
echo === Done! Launch the app on your device. ===
