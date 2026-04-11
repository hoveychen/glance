@echo off
setlocal enabledelayedexpansion

echo ==> Building Glance (Release)...
cargo build --release
if %ERRORLEVEL% neq 0 (
    echo ERROR: Cargo build failed
    exit /b 1
)

echo ==> Packaging MSI...
wix build -o Glance.msi -arch x64 -bindpath target\release installer\Package.wxs
if %ERRORLEVEL% neq 0 (
    echo ERROR: WiX build failed
    exit /b 1
)

echo ==> Done!
echo     MSI: Glance.msi
echo.
echo Prerequisites:
echo     dotnet tool install --global wix --version 5.0.2
