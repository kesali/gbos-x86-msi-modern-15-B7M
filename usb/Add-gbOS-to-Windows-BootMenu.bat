@echo off
:: Add-gbOS-to-Windows-BootMenu.bat
:: Automatically registers Googlebook OS (gbOS86) in the Windows Boot Manager menu.
:: Run this file as Administrator inside Windows after installing gbOS86.

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo ==========================================================
    echo  ERROR: Administrator privileges required!
    echo  Please right-click this file and select 'Run as administrator'
    echo ==========================================================
    echo.
    pause
    exit /b 1
)

echo.
echo ==========================================================
echo  Adding Googlebook OS (gbOS86) to Windows Boot Manager...
echo ==========================================================
echo.

for /f "tokens=2 delims={}" %%g in ('bcdedit /copy {bootmgr} /d "Googlebook OS (gbOS86)"') do (
    set ENTRY_GUID={%%g}
)

if "%ENTRY_GUID%"=="" (
    echo FAILED: Could not create boot entry in Windows BCD.
    pause
    exit /b 1
)

echo Created boot entry %ENTRY_GUID%
bcdedit /set %ENTRY_GUID% path \EFI\gbos86\BOOTX64.EFI
bcdedit /displayorder %ENTRY_GUID% /addlast
bcdedit /timeout 10

echo.
echo ==========================================================
echo  SUCCESS! Googlebook OS (gbOS86) was added to the boot menu.
echo  When you turn on or restart your laptop, you can choose
echo  between Windows and Googlebook OS.
echo ==========================================================
echo.
pause
