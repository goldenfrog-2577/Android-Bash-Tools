@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
color 0B
title OTG Rescue Toolkit

rem ================================================
rem OTG RESCUE TOOLKIT - Windows Batch conversion
rem Target: POCO devices (Snapdragon SoC) & Google Pixel (Tensor SoC)
rem Environment: Windows CMD, Android Platform Tools
rem ================================================

rem --- CONFIGURATION AND VERSION ---
set "MAJOR=1"
set "MINOR=5"
set "PATCH=0"
set "CHANNEL=dev"
set "VERSION=%MAJOR%.%MINOR%.%PATCH%-%CHANNEL%"
set "BUILD_DATE=%date%"
set "BUILD_ID=%date:~-4%%date:~3,2%%date:~0,2%%time:~0,2%%time:~3,2%"
set "ADB_BIN=D:\platform-tools\adb.exe"
set "FB_BIN=D:\platform-tools\fastboot.exe"
set "WORKDIR=D:\GoldenFrog\OTG_ToolKit\"
set "TEMPFILE=%TEMP%\otg_kit_%RANDOM%.tmp"

rem --- STATE ---
set "DEVICE_STATE=DISCONNECTED"
set "DEVICE_ID=N/A"
set "DEVICE_MODEL=Unknown"
set "DEVICE_TYPE=unknown"
set "MANUFACTURER="
set "BRAND="
set "VENDOR="
set "WARNING_SHOWN=0"

call :check_admin
call :check_bins
if errorlevel 1 goto :fatal

if not exist "%WORKDIR%" mkdir "%WORKDIR%" >nul 2>&1
if not exist "%WORKDIR%" (
    echo [ERROR] Cannot create %WORKDIR%
    goto :fatal
)

call :line
echo [*] Resetting ADB server...
"%ADB_BIN%" kill-server >nul 2>&1
"%ADB_BIN%" start-server >nul 2>&1
ping 127.0.0.1 -n 2 >nul

:main_loop
call :refresh_status
if /i "!WARNING_SHOWN!"=="0" if /i "!DEVICE_STATE!"=="ADB_SYSTEM" call :device_warning_gate
if /i "!WARNING_SHOWN!"=="0" if /i "!DEVICE_STATE!"=="ADB_RECOVERY" call :device_warning_gate
if errorlevel 1 goto :exit_script
call :header
if /i "%DEVICE_STATE%"=="FASTBOOT" goto :fastboot_menu
if /i "%DEVICE_STATE%"=="ADB_SYSTEM" goto :adb_menu
if /i "%DEVICE_STATE%"=="ADB_RECOVERY" goto :adb_menu
if /i "%DEVICE_STATE%"=="ADB_SIDELOAD" goto :sideload_menu

echo [ WAITING FOR DEVICE ]
echo.
echo  1. Refresh status
echo  2. Restart ADB server
echo  0. Exit
set "opt="
choice /c 120 /n /t 5 /d 1 /m "Choice (auto-refresh in 5 sec): "
if errorlevel 3 goto :exit_script
if errorlevel 2 (
    "%ADB_BIN%" kill-server >nul 2>&1
    echo ADB server restarted.
    ping 127.0.0.1 -n 2 >nul
)
goto :main_loop

:fastboot_menu
call :header
call :section "FASTBOOT MODE"
echo.
echo Firmware management:
echo  1. Device information [getvar all]
echo  2. Switch A/B slot [Active: %CURRENT_SLOT%]
echo  3. Flash image [boot / recovery / init_boot]
echo  4. Flash vbmeta [Disable Verity / Verification]
echo  5. Temporary boot image [fastboot boot]
echo.
echo Reboot:
echo  6. Recovery [TWRP / OrangeFox]
echo  7. FastbootD [partitions inside super.img]
echo  8. Rescue Mode [Pixel OTA recovery]
echo  9. System reboot
echo.
echo Dangerous operations:
echo 10. Format Data [userdata + metadata]
echo 11. Erase FRP [Factory Reset Protection]
echo 12. Bootloader management [Lock / Unlock]
echo 13. Flash logical image in FastbootD [system / system_ext / product / vendor]
echo  0. Exit
set "opt="
set /p "opt=Choice: "
if "%opt%"=="1" call :fb_get_info
if "%opt%"=="2" call :fb_switch_slot
if "%opt%"=="3" call :fb_flash_image
if "%opt%"=="4" call :fb_flash_vbmeta_safe
if "%opt%"=="5" call :fb_boot_temp_image
if "%opt%"=="6" call :fb_reboot_recovery
if "%opt%"=="7" call :fb_reboot_fastbootd
if "%opt%"=="8" call :fb_reboot_rescue
if "%opt%"=="9" "%FB_BIN%" reboot
if "%opt%"=="10" call :format_data
if "%opt%"=="11" call :erase_frp
if "%opt%"=="12" call :fb_bootloader_lock_menu
if "%opt%"=="13" call :fb_fastbootd_flash_image
if "%opt%"=="0" goto :exit_script
goto :main_loop

:adb_menu
call :header
call :section "ADB TOOLS"
echo.
echo Reboot:
echo  1. Bootloader [Fastboot]
echo  2. Recovery
echo  3. FastbootD
echo  4. Download Mode [Samsung / Odin]
echo  5. System reboot
echo.
echo Tools:
echo  6. Refresh status [Sideload]
echo  7. Remove Magisk modules [TWRP / OrangeFox]
echo  8. Dump partition [Active slot: %ADB_SLOT%]
echo  9. Logcat errors
echo 10. ADB Shell
echo  0. Exit
set "opt="
set /p "opt=Choice: "
if "%opt%"=="1" call :adb_reboot_bootloader
if "%opt%"=="2" call :adb_reboot_recovery
if "%opt%"=="3" call :adb_reboot_fastbootd
if "%opt%"=="4" call :adb_reboot_download_mode
if "%opt%"=="5" "%ADB_BIN%" reboot
if "%opt%"=="6" ping 127.0.0.1 -n 2 >nul
if "%opt%"=="7" call :adb_remove_magisk_modules
if "%opt%"=="8" call :adb_dump_partition
if "%opt%"=="9" call :adb_logcat_brief
if "%opt%"=="10" "%ADB_BIN%" shell
if "%opt%"=="0" goto :exit_script
goto :main_loop

:sideload_menu
call :header
call :section "ADB SIDELOAD"
echo 1. Flash ZIP archive
echo 2. Refresh status
echo 0. Exit
set "opt="
set /p "opt=Choice: "
if "%opt%"=="1" call :adb_sideload_zip
if "%opt%"=="2" ping 127.0.0.1 -n 2 >nul
if "%opt%"=="0" goto :exit_script
goto :main_loop

:check_admin
net session >nul 2>&1
if errorlevel 1 (
    echo [WARNING] This Batch file is not running as Administrator.
    echo Windows does not have Android-style root. Administrator rights may be needed for USB access.
    choice /c YN /n /m "Continue anyway? [Y/N]: "
    if errorlevel 2 exit /b 1
)
exit /b 0

:check_bins
if not exist "%ADB_BIN%" (
    echo [ERROR] adb.exe not found at "%ADB_BIN%".
    echo Check the PLATFORM TOOLS path near the top of this file.
    exit /b 1
)
if not exist "%FB_BIN%" (
    echo [ERROR] fastboot.exe not found at "%FB_BIN%".
    echo Check the PLATFORM TOOLS path near the top of this file.
    exit /b 1
)
exit /b 0

:refresh_status
set "DEVICE_STATE=DISCONNECTED"
set "DEVICE_ID=N/A"
set "DEVICE_MODEL=Unknown"
set "CURRENT_SLOT=N/A"
set "ADB_SLOT=N/A"
for /f "skip=1 tokens=1,2" %%A in ('"%ADB_BIN%" devices 2^>nul') do if not "%%A"=="" (
    set "DEVICE_ID=%%A"
    if /i "%%B"=="device" set "DEVICE_STATE=ADB_SYSTEM"
    if /i "%%B"=="recovery" set "DEVICE_STATE=ADB_RECOVERY"
    if /i "%%B"=="sideload" set "DEVICE_STATE=ADB_SIDELOAD"
    if /i "%%B"=="unauthorized" set "DEVICE_STATE=UNAUTHORIZED"
)
if /i not "!DEVICE_STATE!"=="DISCONNECTED" if /i not "!DEVICE_STATE!"=="UNAUTHORIZED" (
    for /f "delims=" %%A in ('%ADB_BIN% -s "!DEVICE_ID!" shell getprop ro.product.model 2^>nul') do set "DEVICE_MODEL=%%A"
    for /f "delims=" %%A in ('%ADB_BIN% -s "!DEVICE_ID!" shell getprop ro.boot.slot_suffix 2^>nul') do set "ADB_SLOT=%%A"
    goto :eof
)
for /f "tokens=1" %%A in ('"%FB_BIN%" devices 2^>nul') do if not "%%A"=="" (
    set "DEVICE_ID=%%A"
    set "DEVICE_STATE=FASTBOOT"
)
if /i "!DEVICE_STATE!"=="FASTBOOT" (
    for /f "tokens=2 delims=: " %%A in ('%FB_BIN% -s "!DEVICE_ID!" getvar product 2^>^&1 ^| findstr /i "product:"') do set "DEVICE_MODEL=%%A"
    for /f "tokens=2 delims=: " %%A in ('%FB_BIN% -s "!DEVICE_ID!" getvar current-slot 2^>^&1 ^| findstr /i "current-slot"') do set "CURRENT_SLOT=%%A"
)
exit /b 0

:header
cls
call :line
echo =================================================
echo          OTG RESCUE TOOLKIT v%VERSION%
echo          Build Date: %BUILD_DATE%
echo          Build ID:   %BUILD_ID%
echo          Target:     %DEVICE_MODEL%
echo =================================================
if /i "!DEVICE_STATE!"=="FASTBOOT" (
    echo Status: FASTBOOT ^| Slot: !CURRENT_SLOT!
    call :get_fb_var unlocked LOCK_STATUS
    call :get_fb_var version-bootloader BL_VERSION
    echo Bootloader: !LOCK_STATUS! ^| BL Ver: !BL_VERSION!
)
if /i "!DEVICE_STATE!"=="ADB_SYSTEM" echo Status: SYSTEM (ADB) ^| ID: !DEVICE_ID!
if /i "!DEVICE_STATE!"=="ADB_RECOVERY" echo Status: RECOVERY (ADB) ^| Model: !DEVICE_MODEL!
if /i "!DEVICE_STATE!"=="ADB_SIDELOAD" echo Status: SIDELOAD MODE
if /i "!DEVICE_STATE!"=="UNAUTHORIZED" echo Status: UNAUTHORIZED - confirm access on the phone
if /i "!DEVICE_STATE!"=="DISCONNECTED" echo Status: DISCONNECTED - waiting for OTG connection
if /i "!DEVICE_MODEL!" neq "Unknown" (
    echo Device: !DEVICE_MODEL!
)
call :line
exit /b 0

:detect_manufacturer
set "DEVICE_TYPE=unknown"
set "ADB_STATE="
for /f "delims=" %%A in ('"%ADB_BIN%" get-state 2^>nul') do set "ADB_STATE=%%A"
if /i not "!ADB_STATE!"=="device" exit /b 1
for /f "delims=" %%A in ('"%ADB_BIN%" shell getprop ro.product.manufacturer 2^>nul') do set "MANUFACTURER=%%A"
for /f "delims=" %%A in ('"%ADB_BIN%" shell getprop ro.product.brand 2^>nul') do set "BRAND=%%A"
for /f "delims=" %%A in ('"%ADB_BIN%" shell getprop ro.product.vendor.manufacturer 2^>nul') do set "VENDOR=%%A"
set "COMBINED=!MANUFACTURER! !BRAND! !VENDOR!"
for %%A in (xiaomi redmi poco) do echo !COMBINED!| findstr /i "%%A" >nul && set "DEVICE_TYPE=xiaomi"
echo !COMBINED!| findstr /i "google" >nul && set "DEVICE_TYPE=pixel"
echo !COMBINED!| findstr /i "samsung" >nul && set "DEVICE_TYPE=samsung"
exit /b 0

:show_device_warning
call :detect_manufacturer
if errorlevel 1 exit /b 1
if /i "%DEVICE_TYPE%"=="xiaomi" (
    call :show_warning_xiaomi
    if errorlevel 1 exit /b 1
)
if /i "%DEVICE_TYPE%"=="pixel" (
    call :show_warning_pixel
    if errorlevel 1 exit /b 1
)
if /i "%DEVICE_TYPE%"=="samsung" (
    call :show_warning_samsung
    if errorlevel 1 exit /b 1
)
if /i "%DEVICE_TYPE%"=="unknown" (
    echo Unknown device. All operations are at your own risk.
    call :confirm_continue
    if errorlevel 1 exit /b 1
)
exit /b 0

:device_warning_gate
call :show_device_warning
if errorlevel 1 exit /b 1
set "WARNING_SHOWN=1"
exit /b 0

:confirm_continue
set "CONFIRM="
set /p "CONFIRM=Type YES to continue: "
if not "!CONFIRM!"=="YES" (
    echo [ERROR] Confirmation failed. You must enter exactly YES.
    exit /b 1
)
exit /b 0

:show_warning_xiaomi
cls
echo XIAOMI / REDMI / POCO DEVICE DETECTED
echo.
echo 1. Bootloader must be unlocked.
echo 2. Never lock the bootloader on custom firmware.
echo 3. Check Anti-Rollback before firmware downgrade.
echo 4. Do not flash older tz, abl, xbl or similar firmware.
echo 5. Never use clean all and lock in MiFlash.
echo.
echo Violations may cause EDL 9008 state.
call :confirm_continue
if errorlevel 1 exit /b 1
exit /b 0

:show_warning_pixel
cls
echo GOOGLE PIXEL DEVICE DETECTED
echo.
echo 1. Pixel uses AVB 2.0 and Rollback Index.
echo 2. Downgrade may fail even with an unlocked bootloader.
echo 3. Never lock on incompatible firmware.
echo 4. Use official factory images only.
echo 5. fastboot flash may succeed while rollback protection prevents booting.
call :confirm_continue
if errorlevel 1 exit /b 1
exit /b 0

:show_warning_samsung
cls
echo SAMSUNG DEVICE DETECTED
echo.
echo 1. Samsung does not use Fastboot.
echo 2. Use Download Mode with Odin/Heimdall.
echo 3. Wrong CSC can cause a boot loop.
echo 4. Bootloader version cannot be downgraded.
echo 5. Never lock a modified system.
call :confirm_continue
if errorlevel 1 exit /b 1
exit /b 0

:adb_reboot_bootloader
"%ADB_BIN%" reboot bootloader
call :pause_screen
exit /b 0
:adb_reboot_recovery
"%ADB_BIN%" reboot recovery
call :pause_screen
exit /b 0
:adb_reboot_fastbootd
"%ADB_BIN%" reboot fastboot
call :pause_screen
exit /b 0
:adb_reboot_download_mode
"%ADB_BIN%" reboot download
call :pause_screen
exit /b 0

:adb_sideload_zip
set "ZIPFILE="
echo ZIP files in %WORKDIR%:
dir /b "%WORKDIR%\*.zip" 2>nul
set /p "ZIPFILE=Enter ZIP filename: "
if not exist "%WORKDIR%\%ZIPFILE%" (
    echo File not found.
    call :pause_screen
    exit /b 0
)
echo Starting sideload. Do not disconnect the cable.
"%ADB_BIN%" sideload "%WORKDIR%\%ZIPFILE%"
call :pause_screen
exit /b 0

:adb_remove_magisk_modules
"%ADB_BIN%" shell ls /data/adb/modules >nul 2>&1
if errorlevel 1 echo Cannot access /data. Encrypted or stock recovery.
if errorlevel 1 goto :adb_remove_done
set "MODNAME="
set /p "MODNAME=Module folder name, or all: "
if /i "%MODNAME%"=="all" ("%ADB_BIN%" shell rm -rf /data/adb/modules/*) else ("%ADB_BIN%" shell rm -rf /data/adb/modules/%MODNAME%)
:adb_remove_done
call :pause_screen
exit /b 0

:adb_logcat_brief
call :section "ERROR LOG"
echo Error-only log is displayed below.
echo Press Q inside the viewer to exit the log.
echo.
"%ADB_BIN%" logcat *:E -d | more +0
call :pause_screen
exit /b 0

:adb_dump_partition
set "PART="
set "SLOT="
set "PART_PATH="
set "FINAL_PART="
echo Available links under /dev/block/by-name/:
"%ADB_BIN%" shell ls -C /dev/block/by-name 2>nul
echo Enter a partition path manually if it is not visible above.
echo.
echo 1. Enter a direct path
echo 2. Enter partition name and slot
echo 0. Cancel
choice /c 120 /n /m "Dump mode: "
if errorlevel 3 exit /b 0
if errorlevel 2 goto :dump_partition_name

set /p "PART_PATH=Full path (/dev/block/by-name/boot_a): "
if not defined PART_PATH exit /b 0
goto :validate_dump_path

:dump_partition_name
set /p "PART=Partition name, for example boot: "
set /p "SLOT=Active slot (a / b): "
if /i not "!SLOT!"=="a" if /i not "!SLOT!"=="b" (
    echo Invalid slot. Use a or b.
    call :pause_screen
    exit /b 0
)
set "FINAL_PART=!PART!_!SLOT!"
set "PART_PATH=/dev/block/by-name/!FINAL_PART!"

:validate_dump_path
echo(!PART_PATH!| findstr /r /x /c:"/dev/block/by-name/[A-Za-z0-9_.-]*" >nul
if errorlevel 1 (
    echo Invalid path. Only /dev/block/by-name/ partition links are allowed.
    call :pause_screen
    exit /b 0
)
set "FINAL_PART=!PART_PATH:/dev/block/by-name/=!"
set "LOCAL_FILE=%WORKDIR%\!FINAL_PART!_dump.img"
set "DUMP_ROOT_MODE=none"
"%ADB_BIN%" shell id -u > "%TEMPFILE%" 2>nul
findstr /x /c:"0" "%TEMPFILE%" >nul && set "DUMP_ROOT_MODE=direct"
if /i "!DUMP_ROOT_MODE!"=="none" (
    "%ADB_BIN%" shell su -c id > "%TEMPFILE%" 2>nul
    findstr /b /c:"uid=0(" "%TEMPFILE%" >nul && set "DUMP_ROOT_MODE=su"
)
del /q "%TEMPFILE%" >nul 2>&1
if /i "!DUMP_ROOT_MODE!"=="none" (
    echo Root access is required to read block partitions from Android system.
    echo ADB shell is not root and su is unavailable or denied.
    echo Use a rooted device, root Recovery, or grant the ADB shell root access.
    call :pause_screen
    exit /b 0
)
if /i "!DUMP_ROOT_MODE!"=="su" "%ADB_BIN%" shell su -c test -e !PART_PATH! >nul 2>&1
if /i "!DUMP_ROOT_MODE!"=="direct" "%ADB_BIN%" shell test -e !PART_PATH! >nul 2>&1
if errorlevel 1 (
    echo Partition link is unavailable: !PART_PATH!
    echo Check that Recovery exposes the block device and that ADB has root access.
    call :pause_screen
    exit /b 0
)
set "TARGET_SIZE="
set "HOST_SIZE="
set "TARGET_MD5="
set "HOST_MD5="
if /i "!DUMP_ROOT_MODE!"=="su" for /f "delims=" %%A in ('"%ADB_BIN%" shell su -c blockdev --getsize64 !PART_PATH! 2^>nul') do set "TARGET_SIZE=%%A"
if /i "!DUMP_ROOT_MODE!"=="direct" for /f "delims=" %%A in ('"%ADB_BIN%" shell blockdev --getsize64 !PART_PATH! 2^>nul') do set "TARGET_SIZE=%%A"
if not defined TARGET_SIZE (
    echo Failed to get partition size for !PART_PATH!. Check target root and cable.
    call :pause_screen
    exit /b 0
)
echo Source: !PART_PATH!
echo Partition size: !TARGET_SIZE! bytes
if /i "!DUMP_ROOT_MODE!"=="su" "%ADB_BIN%" exec-out su -c cat !PART_PATH! > "%LOCAL_FILE%"
if /i "!DUMP_ROOT_MODE!"=="direct" "%ADB_BIN%" exec-out cat !PART_PATH! > "%LOCAL_FILE%"
for %%A in ("%LOCAL_FILE%") do set "HOST_SIZE=%%~zA"
echo Received: !HOST_SIZE! bytes
if "!TARGET_SIZE!"=="!HOST_SIZE!" (
    echo SUCCESS: sizes match byte for byte.
    set "TARGET_MD5="
    if /i "!DUMP_ROOT_MODE!"=="su" for /f "tokens=1" %%A in ('"%ADB_BIN%" shell su -c md5sum !PART_PATH! 2^>nul') do set "TARGET_MD5=%%A"
    if /i "!DUMP_ROOT_MODE!"=="direct" for /f "tokens=1" %%A in ('"%ADB_BIN%" shell md5sum !PART_PATH! 2^>nul') do set "TARGET_MD5=%%A"
    set "HOST_MD5="
    for /f "tokens=*" %%A in ('certutil -hashfile "%LOCAL_FILE%" MD5 2^>nul ^| findstr /r /i "^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]"') do if not defined HOST_MD5 set "HOST_MD5=%%A"
    set "HOST_MD5=!HOST_MD5: =!"
    if defined TARGET_MD5 if /i "!TARGET_MD5!"=="!HOST_MD5!" echo Hash matches: !HOST_MD5!
    if defined TARGET_MD5 if /i not "!TARGET_MD5!"=="!HOST_MD5!" (
        echo WARNING: MD5 hash differs; image may be corrupted.
        del /q "%LOCAL_FILE%" 2>nul
    )
)
if not "!TARGET_SIZE!"=="!HOST_SIZE!" (
    echo ERROR: image size differs from original.
    del /q "%LOCAL_FILE%" 2>nul
)
call :pause_screen
exit /b 0

:fb_get_info
"%FB_BIN%" -s "%DEVICE_ID%" getvar all 2>&1 | findstr /i "product slot secure unlocked version"
call :pause_screen
exit /b 0

:fb_switch_slot
call :get_fb_var current-slot CURRENT
if /i "!CURRENT!"=="a" "%FB_BIN%" -s "%DEVICE_ID%" --set-active=b
if /i "!CURRENT!"=="b" "%FB_BIN%" -s "%DEVICE_ID%" --set-active=a
if /i not "!CURRENT!"=="a" if /i not "!CURRENT!"=="b" echo Could not determine slot; device may be A-only.
call :pause_screen
exit /b 0

:fb_flash_image
set "PARTITION="
echo 1. Boot
echo 2. Init Boot
echo 3. Vendor Boot
echo 4. Recovery
echo 5. Enter partition manually
set /p "CHOICE=Choose partition: "
if "%CHOICE%"=="1" set "PARTITION=boot"
if "%CHOICE%"=="2" set "PARTITION=init_boot"
if "%CHOICE%"=="3" set "PARTITION=vendor_boot"
if "%CHOICE%"=="4" set "PARTITION=recovery"
if "%CHOICE%"=="5" set /p "PARTITION=Partition name: "
if not defined PARTITION exit /b 0
dir /b "%WORKDIR%\*.img" 2>nul
set "IMGNAME="
set /p "IMGNAME=Image filename: "
if not exist "%WORKDIR%\%IMGNAME%" (
    echo Image not found.
    call :pause_screen
    exit /b 0
)
for %%A in ("%WORKDIR%\%IMGNAME%") do set "IMAGE_SIZE=%%~zA"
if %IMAGE_SIZE% LSS 1024 (
    echo WARNING: image is very small: %IMAGE_SIZE% bytes.
    choice /c YN /n /m "Continue? [Y/N]: "
    if errorlevel 2 exit /b 0
)
call :afe_guard flash "%PARTITION%"
if errorlevel 1 exit /b 0
"%FB_BIN%" -s "%DEVICE_ID%" flash "%PARTITION%" "%WORKDIR%\%IMGNAME%"
call :pause_screen
exit /b 0

:fb_fastbootd_flash_image
set "USERSPACE="
call :get_fb_var is-userspace USERSPACE
if /i not "!USERSPACE!"=="yes" (
    echo [ERROR] The device is not in FastbootD userspace mode.
    echo Select FastbootD from the reboot menu first, then run this option again.
    call :pause_screen
    exit /b 1
)
echo.
echo Logical partitions:
echo 1. system
echo 2. system_ext
echo 3. product
echo 4. vendor
echo 5. odm
echo 6. system_dlkm
echo 7. vendor_dlkm
echo 8. super [complete super image]
echo 9. Enter partition manually
echo 0. Reboot to system
set "PARTITION="
set /p "CHOICE=Choose logical partition: "
if "!CHOICE!"=="1" set "PARTITION=system"
if "!CHOICE!"=="2" set "PARTITION=system_ext"
if "!CHOICE!"=="3" set "PARTITION=product"
if "!CHOICE!"=="4" set "PARTITION=vendor"
if "!CHOICE!"=="5" set "PARTITION=odm"
if "!CHOICE!"=="6" set "PARTITION=system_dlkm"
if "!CHOICE!"=="7" set "PARTITION=vendor_dlkm"
if "!CHOICE!"=="8" set "PARTITION=super"
if "!CHOICE!"=="9" set /p "PARTITION=Partition name: "
if "!CHOICE!"=="0" (
    "%FB_BIN%" -s "%DEVICE_ID%" reboot
    call :pause_screen
    exit /b 0
)
if not defined PARTITION exit /b 0
dir /b "%WORKDIR%\*.img" 2>nul
set "IMGNAME="
set /p "IMGNAME=Image filename: "
if not exist "%WORKDIR%\!IMGNAME!" (
    echo Image not found.
    call :pause_screen
    exit /b 0
)
for %%A in ("%WORKDIR%\!IMGNAME!") do set "IMAGE_SIZE=%%~zA"
if !IMAGE_SIZE! LSS 1024 (
    echo WARNING: image is very small: !IMAGE_SIZE! bytes.
    choice /c YN /n /m "Continue? [Y/N]: "
    if errorlevel 2 exit /b 0
)
call :afe_guard flash "!PARTITION!"
if errorlevel 1 exit /b 0
echo Flashing !IMGNAME! to !PARTITION! in FastbootD...
"%FB_BIN%" -s "%DEVICE_ID%" flash "!PARTITION!" "%WORKDIR%\!IMGNAME!"
call :pause_screen
exit /b 0

:afe_guard
set "AFE_OPERATION=%~1"
set "AFE_TARGET=%~2"
set "AFE_TARGET=%AFE_TARGET:/dev/block/by-name/=%"
set "AFE_TARGET=%AFE_TARGET:\=%"
set "AFE_TARGET=%AFE_TARGET:_a=%"
set "AFE_TARGET=%AFE_TARGET:_b=%"
if not defined AFE_TARGET (
    echo [AFE BLOCKED] Empty partition name.
    exit /b 1
)
for %%A in (abl xbl xbl_config pbl bl1 bl2 bl31 blenv tz tzsw hyp aop devcfg cdt ddr dram_train qupfw ldfw pvmfw dpm gsa gsa_bl1 gcf fips keymaster keystore secdata ssd storsec mdtp mdtpsecapp modem modemst1 modemst2 modem_userdata mdm1m9kefs1 mdm1m9kefs2 mdm1m9kefs3 mdm1m9kefsc fsg fsc efs efs_backup persist persistbak devinfo pinfo mfg_data trusty_persist) do if /i "!AFE_TARGET!"=="%%A" (
    if /i not "!AFE_OPERATION!"=="format" (
        echo [AFE BLOCKED] !AFE_OPERATION! of critical partition !AFE_TARGET! is prohibited.
        exit /b 1
    )
)
if /i "!AFE_TARGET!"=="super" if /i "!AFE_OPERATION!"=="erase" (
    echo [AFE BLOCKED] Erasing dangerous partition !AFE_TARGET! is prohibited.
    exit /b 1
)
for %%A in (userdata metadata vbmeta vbmeta_system vbmeta_vendor boot init_boot vendor_boot vendor_kernel_boot) do if /i "!AFE_TARGET!"=="%%A" if /i "!AFE_OPERATION!"=="erase" (
    echo [AFE BLOCKED] Erasing dangerous partition !AFE_TARGET! is prohibited.
    exit /b 1
)
if /i "!AFE_OPERATION!"=="format" if /i not "!AFE_TARGET!"=="userdata" if /i not "!AFE_TARGET!"=="metadata" (
    echo [AFE BLOCKED] Format is allowed only for userdata and metadata.
    exit /b 1
)
exit /b 0

:fb_boot_temp_image
set "IMGNAME="
dir /b "%WORKDIR%\*.img" 2>nul
set /p "IMGNAME=Image filename for temporary boot: "
if exist "%WORKDIR%\%IMGNAME%" "%FB_BIN%" -s "%DEVICE_ID%" boot "%WORKDIR%\%IMGNAME%"
call :pause_screen
exit /b 0

:fb_flash_vbmeta_safe
if not exist "%WORKDIR%\vbmeta.img" (
    echo vbmeta.img not found in %WORKDIR%.
    call :pause_screen
    exit /b 0
)
"%FB_BIN%" -s "%DEVICE_ID%" flash --disable-verity --disable-verification vbmeta "%WORKDIR%\vbmeta.img"
call :pause_screen
exit /b 0

:fb_reboot_recovery
"%FB_BIN%" -s "%DEVICE_ID%" reboot recovery
call :pause_screen
exit /b 0
:fb_reboot_fastbootd
"%FB_BIN%" -s "%DEVICE_ID%" reboot fastboot
call :pause_screen
exit /b 0
:fb_reboot_rescue
set "PRODUCT="
set "PIXEL_OK="
call :get_fb_var product PRODUCT
for %%A in (oriole raven bluejay panther cheetah lynx shiba husky akita tokay caiman komodo tegu) do if /i "!PRODUCT!"=="%%A" set "PIXEL_OK=1"
if defined PIXEL_OK ("%FB_BIN%" -s "%DEVICE_ID%" reboot rescue) else (
    echo Rescue Mode is officially supported only on Google Pixel.
    choice /c YN /n /m "Try anyway? [Y/N]: "
    if errorlevel 2 exit /b 0
    "%FB_BIN%" -s "%DEVICE_ID%" reboot rescue
)
call :pause_screen
exit /b 0

:format_data
choice /c YN /n /m "WARNING: erase userdata and metadata. Continue? [Y/N]: "
if errorlevel 2 exit /b 0
for %%A in (userdata metadata) do (
    call :afe_guard format "%%A"
    if not errorlevel 1 "%FB_BIN%" -s "%DEVICE_ID%" erase "%%A"
)
exit /b 0

:erase_frp
call :get_fb_var unlocked LOCK_STATUS
if /i not "%LOCK_STATUS%"=="yes" (
    echo Bootloader is locked or status is unknown. Operation unavailable.
    call :pause_screen
    exit /b 0
)
set "CONFIRM="
set /p "CONFIRM=Type ERASE_FRP to confirm: "
if /i not "%CONFIRM%"=="ERASE_FRP" exit /b 0
call :afe_guard erase frp
if not errorlevel 1 "%FB_BIN%" -s "%DEVICE_ID%" erase frp
call :pause_screen
exit /b 0

:fb_bootloader_lock_menu
 echo WARNING: bootloader operations cause a factory reset.
echo 1. Unlock
echo 2. Lock
echo 3. Unlock critical
echo 0. Back
set "BLOPT="
set /p "BLOPT=Choice: "
if "%BLOPT%"=="1" ("%FB_BIN%" -s "%DEVICE_ID%" flashing unlock || "%FB_BIN%" -s "%DEVICE_ID%" oem unlock)
if "%BLOPT%"=="2" (
    echo Ensure stock firmware is installed.
    choice /c YN /n /m "Lock bootloader? [Y/N]: "
    if errorlevel 2 exit /b 0
    "%FB_BIN%" -s "%DEVICE_ID%" flashing lock
)
if "%BLOPT%"=="3" "%FB_BIN%" -s "%DEVICE_ID%" flashing unlock_critical
call :pause_screen
exit /b 0

:get_fb_var
set "%~2="
    for /f "tokens=2,* delims=: " %%A in ('%FB_BIN% -s "%DEVICE_ID%" getvar %~1 2^>^&1 ^| findstr /i "%~1"') do set "%~2=%%A"
exit /b 0

:pause_screen
pause
exit /b 0

:line
echo -------------------------------------------------
exit /b 0

:section
echo.
echo =================================================
echo                 %~1
echo =================================================
exit /b 0

:fatal
call :line
echo OTG Rescue Toolkit stopped.
 pause
exit /b 1

:exit_script
if exist "%TEMPFILE%" del /q "%TEMPFILE%" >nul 2>&1
 echo Exiting OTG Rescue Toolkit...
endlocal
exit /b 0
