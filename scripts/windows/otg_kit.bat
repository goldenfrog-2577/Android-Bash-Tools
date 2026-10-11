@echo off
rem ============================================================================
rem  OTG RESCUE TOOLKIT v2 (Windows) - spasenie Android-ustroistv cherez USB
rem  Avtor: GoldenFrog
rem  Pervye stroki - tolko ASCII: do chcp 65001 kirillica chitaetsya krivo.
rem ============================================================================
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
rem Znaki "!" nado zadat DO vklyucheniya DelayedExpansion, inache oni ischezayut
set "TAG_WARN=[!]"
set "TAG_ERR=[x]"
setlocal EnableDelayedExpansion
title OTG Rescue Toolkit

rem ── Версия ─────────────────────────────────────────────────────────────────
set "VERSION=2.0.0"
set "BUILD_DATE=11.10.2026"

rem ── Цвета ANSI (Windows 10+). NO_COLOR=1 — без цветов ──────────────────────
set "C_RED=" & set "C_GRN=" & set "C_YEL=" & set "C_BLU=" & set "C_CYN=" & set "C_BLD=" & set "C_DIM=" & set "C_NC="
if not defined NO_COLOR (
    for /f %%a in ('echo prompt $E^| cmd') do set "ESC=%%a"
    if defined ESC (
        set "C_RED=!ESC![91m" & set "C_GRN=!ESC![92m" & set "C_YEL=!ESC![93m"
        set "C_BLU=!ESC![94m" & set "C_CYN=!ESC![96m" & set "C_BLD=!ESC![1m"
        set "C_DIM=!ESC![90m" & set "C_NC=!ESC![0m"
    )
)
set "LINE=─────────────────────────────────────────────────"
set "DLINE=═════════════════════════════════════════════════"

rem ── Пути по умолчанию (переопределяются otg_kit.cfg и OTG_* переменными) ─────
set "SCRIPT_DIR=%~dp0"
set "CFG_FILE=%SCRIPT_DIR%otg_kit.cfg"
set "ADB_BIN=D:\platform-tools\adb.exe"
set "FB_BIN=D:\platform-tools\fastboot.exe"
set "WORKDIR=D:\GoldenFrog\OTG_ToolKit\"
set "LOGDIR="
set "ALLOW_NET=0"
set "TMPF=%TEMP%\otg_kit_%RANDOM%%RANDOM%.tmp"
set "TMPF2=%TEMP%\otg_kit_%RANDOM%%RANDOM%_2.tmp"

call :load_config
call :check_env
if errorlevel 1 goto :fatal

call :now STAMP
set "LOGFILE=%LOGDIR%otg_kit_%STAMP%.log"
call :log "START v%VERSION% ADB=%ADB_BIN% FB=%FB_BIN% WORKDIR=%WORKDIR%"

call :info "Запуск ADB-сервера…"
"%ADB_BIN%" start-server >nul 2>&1

rem ── Состояние ──────────────────────────────────────────────────────────────
set "SERIAL="
set "STATE=NONE"
set "PREV_KEY="
set "QUIT=0"
set "USB_CHECKED=0"

:main_loop
call :refresh_status
call :header
if "!STATE!"=="MULTI" call :pick_device
if "!STATE!"=="SYSTEM" call :menu_system
if "!STATE!"=="RECOVERY" call :menu_system
if "!STATE!"=="SIDELOAD" call :menu_sideload
if "!STATE!"=="RESCUE" call :menu_rescue
if "!STATE!"=="BOOTLOADER" call :menu_fastboot
if "!STATE!"=="FASTBOOTD" call :menu_fastboot
if "!STATE!"=="NONE" call :menu_waiting
if "!STATE!"=="UNAUTHORIZED" call :menu_waiting
if "!STATE!"=="OFFLINE" call :menu_waiting
if "!QUIT!"=="1" goto :exit_script
goto :main_loop

rem ============================================================================
rem  НАСТРОЙКА И ОКРУЖЕНИЕ
rem ============================================================================

:load_config
if exist "%CFG_FILE%" (
    for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%CFG_FILE%") do (
        set "_k=%%A"
        set "_v=%%B"
        if /i "!_k!"=="ADB_BIN" set "ADB_BIN=!_v!"
        if /i "!_k!"=="FB_BIN" set "FB_BIN=!_v!"
        if /i "!_k!"=="WORKDIR" set "WORKDIR=!_v!"
        if /i "!_k!"=="LOGDIR" set "LOGDIR=!_v!"
        if /i "!_k!"=="ALLOW_NET" set "ALLOW_NET=!_v!"
    )
)
if defined OTG_ADB_BIN set "ADB_BIN=%OTG_ADB_BIN%"
if defined OTG_FB_BIN set "FB_BIN=%OTG_FB_BIN%"
if defined OTG_WORKDIR set "WORKDIR=%OTG_WORKDIR%"
if defined OTG_LOGDIR set "LOGDIR=%OTG_LOGDIR%"
if defined OTG_ALLOW_NET set "ALLOW_NET=%OTG_ALLOW_NET%"
if not "!WORKDIR:~-1!"=="\" set "WORKDIR=!WORKDIR!\"
if not defined LOGDIR set "LOGDIR=!WORKDIR!logs\"
if not "!LOGDIR:~-1!"=="\" set "LOGDIR=!LOGDIR!\"
exit /b 0

:check_env
rem Нет по указанному пути — ищем в PATH
if not exist "!ADB_BIN!" for %%X in (adb.exe) do if not "%%~$PATH:X"=="" set "ADB_BIN=%%~$PATH:X"
if not exist "!FB_BIN!" for %%X in (fastboot.exe) do if not "%%~$PATH:X"=="" set "FB_BIN=%%~$PATH:X"
set "_miss="
if not exist "!ADB_BIN!" set "_miss=adb.exe"
if not exist "!FB_BIN!" set "_miss=!_miss! fastboot.exe"
if defined _miss (
    call :err "Не найдено: !_miss!"
    call :note "Укажите путь в otg_kit.cfg (ADB_BIN / FB_BIN) или добавьте platform-tools в PATH."
    exit /b 1
)
if not exist "!WORKDIR!" mkdir "!WORKDIR!" >nul 2>&1
if not exist "!WORKDIR!" (
    call :err "Не удалось создать папку !WORKDIR!"
    exit /b 1
)
if not exist "!LOGDIR!" mkdir "!LOGDIR!" >nul 2>&1
exit /b 0

rem :now ПЕРЕМЕННАЯ — метка времени yyyyMMdd-HHmmss без зависимости от локали
:now
set "%~1="
for /f "usebackq delims=" %%T in (`powershell -NoProfile -NonInteractive -Command "Get-Date -Format yyyyMMdd-HHmmss"`) do set "%~1=%%T"
if not defined %~1 set "%~1=%RANDOM%%RANDOM%"
exit /b 0

rem ============================================================================
rem  ВЫВОД: единые элементы интерфейса
rem ============================================================================

:info
set "_m=%~1"
echo %C_BLU%[*]%C_NC% !_m!
exit /b 0
:ok
set "_m=%~1"
echo %C_GRN%[+]%C_NC% !_m!
exit /b 0
:warn
set "_m=%~1"
echo %C_YEL%!TAG_WARN!%C_NC% !_m!
exit /b 0
:err
set "_m=%~1"
echo %C_RED%!TAG_ERR!%C_NC% !_m!
exit /b 0
:note
set "_m=%~1"
echo     %C_DIM%!_m!%C_NC%
exit /b 0

:title
set "_m=%~1"
echo.
echo %C_CYN%!LINE!%C_NC%
echo  %C_BLD%!_m!%C_NC%
echo %C_CYN%!LINE!%C_NC%
exit /b 0

:section
set "_m=%~1"
set "_c=%~2"
if not defined _c set "_c=%C_CYN%"
echo.
echo  !_c!!_m!%C_NC%
exit /b 0

rem :item НОМЕР "Название" ["подсказка"]
:item
set "_n=  %~1"
set "_n=!_n:~-2!"
set "_t=%~2"
set "_h=%~3"
if defined _h goto :item_hint
echo   %C_BLD%!_n!%C_NC%  !_t!
exit /b 0
:item_hint
echo   %C_BLD%!_n!%C_NC%  !_t!  %C_DIM%· !_h!%C_NC%
exit /b 0

:pause_screen
echo.
echo %C_DIM%Нажмите любую клавишу, чтобы вернуться в меню…%C_NC%
pause >nul
exit /b 0

rem :ask "Вопрос" → ANSWER (пустой ввод = пусто, а не старое значение)
:ask
set "ANSWER="
set /p "ANSWER=%C_CYN%?%C_NC% %~1 "
exit /b 0

rem :confirm_yn "Вопрос" → errorlevel 0 = да
:confirm_yn
choice /c YN /n /m "%~1 [Y/N]: "
if errorlevel 2 exit /b 1
exit /b 0

rem :confirm_word СЛОВО "что произойдёт" → errorlevel 0 = подтверждено
:confirm_word
echo %C_RED%%~2%C_NC%
call :ask "Для подтверждения введите %~1:"
if "!ANSWER!"=="%~1" exit /b 0
call :info "Отменено."
exit /b 1

:log
set "_lm=%~1"
>> "%LOGFILE%" echo [%date% %time%] [!SERIAL!] !_lm!
exit /b 0

rem :run КОМАНДА... — показать, выполнить, залогировать, сообщить итог
:run
set "_cmdline=%*"
echo %C_DIM%  ^> !_cmdline!%C_NC%
>> "%LOGFILE%" echo [%date% %time%] [!SERIAL!] RUN !_cmdline!
%*
set "_rc=!errorlevel!"
call :log "RC=!_rc!"
if "!_rc!"=="0" (call :ok "Выполнено.") else (call :err "Команда завершилась с кодом !_rc!.")
exit /b !_rc!

rem ============================================================================
rem  УСТРОЙСТВА
rem ============================================================================

:refresh_status
set "DEV_N=0"
"%ADB_BIN%" devices >"%TMPF%" 2>nul
for /f "usebackq skip=1 tokens=1,2" %%A in ("%TMPF%") do call :add_dev "%%A" "%%B" adb
"%FB_BIN%" devices >"%TMPF%" 2>nul
for /f "usebackq tokens=1,2" %%A in ("%TMPF%") do call :add_dev "%%A" "%%B" fastboot

if "!DEV_N!"=="0" (
    set "SERIAL=" & set "STATE=NONE" & set "PREV_KEY="
    call :clear_info
    exit /b 0
)
set "_found="
if defined SERIAL for /l %%i in (1,1,!DEV_N!) do if "!DEV_S_%%i!"=="!SERIAL!" set "_found=%%i"
if not defined _found (
    if "!DEV_N!"=="1" (set "_found=1") else (
        set "SERIAL=" & set "STATE=MULTI" & set "PREV_KEY="
        call :clear_info
        exit /b 0
    )
)
set "SERIAL=!DEV_S_%_found%!"
set "STATE=!DEV_ST_%_found%!"
if "!STATE!"=="FASTBOOT" (
    call :fb_var is-userspace _us
    if /i "!_us!"=="yes" (set "STATE=FASTBOOTD") else (set "STATE=BOOTLOADER")
)
rem Сведения перечитываем только при смене устройства или режима
if not "!PREV_KEY!"=="!SERIAL!/!STATE!" (
    set "PREV_KEY=!SERIAL!/!STATE!"
    set "T_ROOT="
    call :load_info
)
exit /b 0

rem :add_dev серийник состояние транспорт
:add_dev
set "_s=%~1"
set "_t=%~2"
if not defined _s exit /b 0
if "!_s:~0,1!"=="*" exit /b 0
rem Сетевые подключения (Wi-Fi отладка) пропускаем: работаем только по кабелю
if not "!ALLOW_NET!"=="1" (
    if not "!_s::=!"=="!_s!" exit /b 0
    if not "!_s:._adb-tls=!"=="!_s!" exit /b 0
)
set "_st=OFFLINE"
if "%~3"=="fastboot" (set "_st=FASTBOOT") else (
    if /i "!_t!"=="device" set "_st=SYSTEM"
    if /i "!_t!"=="recovery" set "_st=RECOVERY"
    if /i "!_t!"=="sideload" set "_st=SIDELOAD"
    if /i "!_t!"=="rescue" set "_st=RESCUE"
    if /i "!_t!"=="unauthorized" set "_st=UNAUTHORIZED"
)
set /a DEV_N+=1
set "DEV_S_!DEV_N!=!_s!"
set "DEV_ST_!DEV_N!=!_st!"
exit /b 0

:pick_device
call :title "НАЙДЕНО НЕСКОЛЬКО УСТРОЙСТВ"
for /l %%i in (1,1,!DEV_N!) do call :item %%i "!DEV_S_%%i!" "!DEV_ST_%%i!"
call :item 0 "Выход"
echo.
call :ask "Выберите устройство:"
if "!ANSWER!"=="0" (set "QUIT=1" & exit /b 0)
call :is_number "!ANSWER!" || exit /b 0
if !ANSWER! GEQ 1 if !ANSWER! LEQ !DEV_N! (
    set "SERIAL=!DEV_S_%ANSWER%!"
    set "PREV_KEY="
)
exit /b 0

:is_number
set "_x=%~1"
if not defined _x exit /b 1
echo(!_x!| findstr /r /x "[0-9][0-9]*" >nul
exit /b %errorlevel%

rem :fb_var ИМЯ ПЕРЕМЕННАЯ — значение fastboot getvar без мусора
:fb_var
set "%~2="
"%FB_BIN%" -s "!SERIAL!" getvar %~1 >"%TMPF2%" 2>&1
for /f "usebackq tokens=1,* delims=:" %%A in ("%TMPF2%") do (
    set "_k=%%A"
    set "_k=!_k:(bootloader) =!"
    if /i "!_k!"=="%~1" (
        set "_v=%%B"
        if defined _v if "!_v:~0,1!"==" " set "_v=!_v:~1!"
        set "%~2=!_v!"
    )
)
exit /b 0

:clear_info
for %%V in (D_MODEL D_CODENAME D_MAKER D_SOC D_SLOT D_ANDROID D_UNLOCKED D_BLVER) do set "%%V="
set "DEVICE_TYPE=unknown"
exit /b 0

:load_info
call :clear_info
if "!STATE!"=="SYSTEM" goto :load_info_adb
if "!STATE!"=="RECOVERY" goto :load_info_adb
if "!STATE!"=="BOOTLOADER" goto :load_info_fb
if "!STATE!"=="FASTBOOTD" goto :load_info_fb
if "!STATE!"=="RESCUE" (
    "%ADB_BIN%" -s "!SERIAL!" rescue getprop ro.product.device >"%TMPF%" 2>nul
    for /f "usebackq delims=" %%A in ("%TMPF%") do set "D_CODENAME=%%A"
    set "DEVICE_TYPE=pixel"
)
exit /b 0

:load_info_adb
rem Все свойства одним вызовом; формат «ключ=значение» (пустые строки for /f пропускает)
for %%P in (ro.product.model ro.product.device ro.product.manufacturer ro.product.brand ro.soc.manufacturer ro.soc.model ro.boot.slot_suffix ro.build.version.release) do set "P_%%P="
"%ADB_BIN%" -s "!SERIAL!" shell "for p in ro.product.model ro.product.device ro.product.manufacturer ro.product.brand ro.soc.manufacturer ro.soc.model ro.boot.slot_suffix ro.build.version.release; do echo $p=$(getprop $p); done" >"%TMPF%" 2>nul
for /f "usebackq tokens=1,* delims==" %%A in ("%TMPF%") do set "P_%%A=%%B"
set "D_MODEL=!P_ro.product.model!"
set "D_CODENAME=!P_ro.product.device!"
set "D_SOC=!P_ro.soc.manufacturer! !P_ro.soc.model!"
if "!D_SOC!"==" " set "D_SOC="
set "D_SLOT=!P_ro.boot.slot_suffix!"
if defined D_SLOT set "D_SLOT=!D_SLOT:_=!"
set "D_ANDROID=!P_ro.build.version.release!"
set "D_MAKER=!P_ro.product.manufacturer! !P_ro.product.brand!"
echo(!D_MAKER!| findstr /i "xiaomi redmi poco" >nul && set "DEVICE_TYPE=xiaomi"
echo(!D_MAKER!| findstr /i "google" >nul && set "DEVICE_TYPE=pixel"
echo(!D_MAKER!| findstr /i "samsung" >nul && set "DEVICE_TYPE=samsung"
set "KT_!SERIAL!=!DEVICE_TYPE!"
call :log "INFO !D_MODEL! (!D_CODENAME!) type=!DEVICE_TYPE!"
exit /b 0

:load_info_fb
call :fb_var product D_CODENAME
call :fb_var current-slot D_SLOT
call :fb_var unlocked D_UNLOCKED
if "!STATE!"=="BOOTLOADER" call :fb_var version-bootloader D_BLVER
rem Производитель в fastboot не виден — берём из прошлого подключения по ADB
if defined KT_!SERIAL! for %%K in ("!SERIAL!") do set "DEVICE_TYPE=!KT_%%~K!"
call :is_pixel "!D_CODENAME!" && set "DEVICE_TYPE=pixel"
call :soc_by_codename "!D_CODENAME!"
exit /b 0

:is_pixel
for %%C in (oriole raven bluejay panther cheetah lynx tangorpro felix shiba husky akita tokay caiman komodo comet tegu frankel blazer mustang rango) do if /i "%~1"=="%%C" exit /b 0
exit /b 1

:soc_by_codename
for %%C in (oriole raven bluejay) do if /i "%~1"=="%%C" set "D_SOC=Google Tensor"
for %%C in (panther cheetah lynx tangorpro felix) do if /i "%~1"=="%%C" set "D_SOC=Google Tensor G2"
for %%C in (shiba husky akita) do if /i "%~1"=="%%C" set "D_SOC=Google Tensor G3"
for %%C in (tokay caiman komodo comet tegu) do if /i "%~1"=="%%C" set "D_SOC=Google Tensor G4"
for %%C in (frankel blazer mustang rango) do if /i "%~1"=="%%C" set "D_SOC=Google Tensor G5"
for %%C in (alioth apollo lmi cmi umi cas thyme munch) do if /i "%~1"=="%%C" set "D_SOC=Snapdragon 8xx"
exit /b 0

rem ============================================================================
rem  ШАПКА
rem ============================================================================

:header
cls
echo %C_BLU%!DLINE!%C_NC%
echo  %C_BLD%OTG RESCUE TOOLKIT%C_NC%  v%VERSION%  %C_DIM%%BUILD_DATE% · Windows%C_NC%
echo %C_BLU%!DLINE!%C_NC%
set "_lbl=%C_RED%НЕ ПОДКЛЮЧЕНО%C_NC%"
if "!STATE!"=="SYSTEM" set "_lbl=%C_GRN%SYSTEM%C_NC% (ADB)"
if "!STATE!"=="RECOVERY" set "_lbl=%C_YEL%RECOVERY%C_NC% (ADB)"
if "!STATE!"=="SIDELOAD" set "_lbl=%C_YEL%SIDELOAD%C_NC% (recovery)"
if "!STATE!"=="RESCUE" set "_lbl=%C_YEL%RESCUE%C_NC% (Pixel)"
if "!STATE!"=="BOOTLOADER" set "_lbl=%C_CYN%FASTBOOT%C_NC% (bootloader)"
if "!STATE!"=="FASTBOOTD" set "_lbl=%C_CYN%FASTBOOTD%C_NC% (userspace)"
if "!STATE!"=="UNAUTHORIZED" set "_lbl=%C_RED%UNAUTHORIZED%C_NC%"
if "!STATE!"=="OFFLINE" set "_lbl=%C_RED%OFFLINE%C_NC%"
if "!STATE!"=="MULTI" set "_lbl=%C_YEL%НЕСКОЛЬКО УСТРОЙСТВ%C_NC%"
echo  Режим      : !_lbl!
set "_name=!D_MODEL!"
if defined D_CODENAME (
    if defined _name (set "_name=!_name! (!D_CODENAME!)") else (set "_name=(!D_CODENAME!)")
)
if defined _name echo  Устройство : %C_GRN%!_name!%C_NC%
if defined D_SOC echo  Чипсет     : !D_SOC!
if defined SERIAL echo  Серийник   : !SERIAL!
if defined D_ANDROID echo  Android    : !D_ANDROID!
if defined D_SLOT echo  Слот       : %C_YEL%!D_SLOT!%C_NC%
if defined D_UNLOCKED (
    if /i "!D_UNLOCKED!"=="yes" (set "_bl=%C_GRN%UNLOCKED%C_NC%") else (set "_bl=%C_RED%LOCKED%C_NC%")
    echo  Загрузчик  : !_bl!  %C_DIM%!D_BLVER!%C_NC%
)
echo %C_BLU%!LINE!%C_NC%
exit /b 0

rem ============================================================================
rem  ПРЕДУПРЕЖДЕНИЯ (раз на устройство, перед первой опасной операцией)
rem ============================================================================

:ensure_warned
if defined WARNED_!SERIAL! exit /b 0
call :title "ПЕРЕД ОПАСНЫМИ ОПЕРАЦИЯМИ"
if "!DEVICE_TYPE!"=="xiaomi" (
    echo  Xiaomi / Redmi / POCO:
    echo   1. Нужен разблокированный загрузчик.
    echo   2. Никогда не блокируйте загрузчик на кастомной прошивке.
    echo   3. Проверьте Anti-Rollback ^(ARB^) перед понижением прошивки.
    echo   4. Не прошивайте более старые xbl, abl, tz и т.п.
    echo   5. Не используйте «clean all and lock» в MiFlash.
    call :warn "Нарушение этих правил может привести к EDL (9008)."
)
if "!DEVICE_TYPE!"=="pixel" (
    echo  Google Pixel:
    echo   1. AVB 2.0 и Rollback Index: даунгрейд может не загрузиться
    echo      даже на разблокированном загрузчике.
    echo   2. Никогда не блокируйте загрузчик на несовместимой прошивке.
    echo   3. Используйте только официальные factory/OTA образы.
    echo   4. Pixel 6+: после bootloader с anti-rollback откат невозможен.
)
if "!DEVICE_TYPE!"=="samsung" (
    echo  Samsung:
    echo   1. Fastboot не используется — прошивка через Download Mode ^(Odin/Heimdall^).
    echo   2. Неправильный CSC может вызвать bootloop.
    echo   3. Версию загрузчика ^(BL^) понизить нельзя.
)
if "!DEVICE_TYPE!"=="unknown" (
    echo  Производитель не определён ^(в fastboot его не видно —
    echo  подключите устройство в системе хотя бы раз за сеанс^).
)
echo.
call :confirm_word YES "Все действия — на ваш страх и риск." || exit /b 1
set "WARNED_!SERIAL!=1"
call :log "WARNING acknowledged type=!DEVICE_TYPE!"
exit /b 0

rem ============================================================================
rem  AFE — Anti Flash and Erase: критичные разделы
rem ============================================================================

rem :afe_guard flash|erase РАЗДЕЛ
:afe_guard
set "_op=%~1"
set "_t=%~2"
if not defined _t (call :err "[AFE] Пустое имя раздела." & exit /b 1)
if /i "!_t:~-2!"=="_a" set "_t=!_t:~0,-2!"
if /i "!_t:~-2!"=="_b" set "_t=!_t:~0,-2!"
if /i "!_op!"=="erase" if /i "!_t!"=="super" (
    call :err "[AFE] Стирание super запрещено — это soft-brick (не будет fastbootd)."
    exit /b 1
)
for %%A in (abl xbl xbl_config xbl_ramdump pbl bl1 bl2 bl31 blenv tz tzsw hyp aop aop_config devcfg cdt ddr dram_train qupfw ldfw pvmfw dpm uefi uefisecapp imagefv shrm cpucp featenabler multiimgoem bootloader gsa gsa_bl1 gcf fips keymaster keystore secdata ssd storsec mdtp mdtpsecapp modem radio modemst1 modemst2 modem_userdata mdm1m9kefs1 mdm1m9kefs2 mdm1m9kefs3 mdm1m9kefsc fsg fsc efs efs_backup persist persistbak devinfo pinfo mfg_data trusty_persist) do (
    if /i "!_t!"=="%%A" (
        call :err "[AFE] Операция «!_op!» над разделом «!_t!» запрещена — риск hard-brick."
        if /i "!_t!"=="bootloader" call :note "bootloader/radio прошивайте только через flash-all.bat / Android Flash Tool."
        if /i "!_t!"=="radio" call :note "bootloader/radio прошивайте только через flash-all.bat / Android Flash Tool."
        exit /b 1
    )
)
exit /b 0

rem ============================================================================
rem  ФАЙЛЫ В WORKDIR
rem ============================================================================

rem :pick_file "Описание" расширение → PICKED (полный путь) или errorlevel 1
:pick_file
set "PICKED="
set "_pf_n=0"
set "_wd=!WORKDIR:'=''!"
powershell -NoProfile -NonInteractive -Command "Get-ChildItem -LiteralPath '!_wd!' -File -Filter '*.%~2' | Sort-Object Name | ForEach-Object { $b = $_.Length; $s = if ($b -ge 1GB) { '{0:N2} ГБ' -f ($b/1GB) } elseif ($b -ge 1MB) { '{0:N1} МБ' -f ($b/1MB) } else { '{0:N1} КБ' -f ($b/1KB) }; '{0}|{1}' -f $_.Name, $s }" >"%TMPF%" 2>nul
for /f "usebackq tokens=1,* delims=|" %%A in ("%TMPF%") do (
    set /a _pf_n+=1
    set "PF_!_pf_n!=%%A"
    set "PZ_!_pf_n!=%%B"
)
if "!_pf_n!"=="0" (
    call :err "В !WORKDIR! нет файлов *.%~2"
    call :note "Положите %~1 в эту папку и повторите."
    exit /b 1
)
echo  %~1 в !WORKDIR!:
for /l %%i in (1,1,!_pf_n!) do call :item %%i "!PF_%%i!" "!PZ_%%i!"
call :item 0 "Отмена"
call :ask "Номер файла:"
if not defined ANSWER (call :info "Отменено." & exit /b 1)
if "!ANSWER!"=="0" (call :info "Отменено." & exit /b 1)
call :is_number "!ANSWER!" || (call :err "Нужен номер из списка." & exit /b 1)
if !ANSWER! GTR !_pf_n! (call :err "Нет такого номера." & exit /b 1)
set "PICKED=!WORKDIR!!PF_%ANSWER%!"
exit /b 0

rem :hsize БАЙТЫ ПЕРЕМЕННАЯ — работает и для файлов больше 2 ГБ
:hsize
set "%~2="
for /f "usebackq delims=" %%S in (`powershell -NoProfile -NonInteractive -Command "$b=[double]'%~1'; if($b -ge 1GB){'{0:N2} ГБ' -f ($b/1GB)}elseif($b -ge 1MB){'{0:N1} МБ' -f ($b/1MB)}elseif($b -ge 1KB){'{0:N1} КБ' -f ($b/1KB)}else{'{0} Б' -f $b}"`) do set "%~2=%%S"
exit /b 0

rem :img_kind ФАЙЛ → IMG_KIND: boot / vendor_boot / vbmeta / sparse / dtbo / zip / unknown
:img_kind
set "IMG_KIND=unknown"
set "_p=%~1"
set "_p=!_p:'=''!"
set "_hex="
for /f "usebackq delims=" %%H in (`powershell -NoProfile -NonInteractive -Command "$f=[IO.File]::OpenRead('!_p!'); $b=New-Object byte[] 8; [void]$f.Read($b,0,8); $f.Close(); ($b | ForEach-Object { '{0:x2}' -f $_ }) -join ''"`) do set "_hex=%%H"
if "!_hex:~0,16!"=="414e44524f494421" set "IMG_KIND=boot"
if "!_hex:~0,16!"=="564e4452424f4f54" set "IMG_KIND=vendor_boot"
if "!_hex:~0,8!"=="41564230" set "IMG_KIND=vbmeta"
if "!_hex:~0,8!"=="ed26ff3a" set "IMG_KIND=sparse"
if "!_hex:~0,8!"=="d7b7ab1e" set "IMG_KIND=dtbo"
if "!_hex:~0,8!"=="504b0304" set "IMG_KIND=zip"
exit /b 0

rem :check_image ФАЙЛ РАЗДЕЛ — сигнатура против ожидаемого типа
:check_image
set "_want="
set "_cp=%~2"
if /i "!_cp:~0,4!"=="boot" set "_want=boot"
if /i "!_cp:~0,9!"=="init_boot" set "_want=boot"
if /i "!_cp:~0,8!"=="recovery" set "_want=boot"
if /i "!_cp:~0,11!"=="vendor_boot" set "_want=vendor_boot"
if /i "!_cp:~0,6!"=="vbmeta" set "_want=vbmeta"
if /i "!_cp:~0,4!"=="dtbo" set "_want=dtbo"
call :img_kind "%~1"
for %%F in ("%~1") do (
    set "_size=%%~zF"
    call :hsize %%~zF _hs
    call :info "Файл: %%~nxF (!_hs!), тип: !IMG_KIND!"
)
if "!IMG_KIND!"=="zip" (
    call :err "Это ZIP-архив, а не образ. Распакуйте нужный .img (или используйте sideload)."
    exit /b 1
)
call :is_small "!_size!" && (call :err "Файл слишком маленький для образа раздела." & exit /b 1)
if defined _want if not "!IMG_KIND!"=="!_want!" if not "!IMG_KIND!"=="sparse" (
    call :warn "Ожидался образ типа «!_want!» для раздела «%~2», а файл — «!IMG_KIND!»."
    call :confirm_word FLASH "Прошивка неподходящего образа может окирпичить устройство." || exit /b 1
)
exit /b 0

:is_small
rem размер меньше 4096 байт (строка короче 4 символов или число < 4096)
set "_z=%~1"
if "!_z:~3,1!"=="" exit /b 0
if "!_z:~4,1!"=="" if !_z! LSS 4096 exit /b 0
exit /b 1

rem ============================================================================
rem  ROOT НА ЦЕЛЕВОМ УСТРОЙСТВЕ
rem ============================================================================

:detect_target_root
if defined T_ROOT exit /b 0
set "T_ROOT=none"
"%ADB_BIN%" -s "!SERIAL!" shell id -u >"%TMPF%" 2>nul
findstr /x "0" "%TMPF%" >nul && (set "T_ROOT=direct" & exit /b 0)
call :info "Запрашиваю root на целевом устройстве — подтвердите запрос на его экране."
"%ADB_BIN%" -s "!SERIAL!" shell "su -c 'id -u'" >"%TMPF%" 2>nul
findstr /x "0" "%TMPF%" >nul && set "T_ROOT=su"
exit /b 0

:need_target_root
call :detect_target_root
if "!T_ROOT!"=="none" (
    call :err "Нет root на целевом устройстве."
    call :note "Нужен TWRP/OrangeFox или Magisk/KernelSU с выданным доступом для Shell."
    exit /b 1
)
exit /b 0

rem :tsh "команда" [файл-вывода] — выполнить на цели от root
rem Команда передаётся в одинарных кавычках su -c — внутри неё одинарных кавычек быть не должно.
:tsh
set "_out=%~2"
if not defined _out set "_out=%TMPF%"
if "!T_ROOT!"=="direct" "%ADB_BIN%" -s "!SERIAL!" shell "%~1" >"!_out!" 2>&1
if "!T_ROOT!"=="su" "%ADB_BIN%" -s "!SERIAL!" shell "su -c '%~1'" >"!_out!" 2>&1
exit /b 0

rem ============================================================================
rem  ОПЕРАЦИИ: ADB
rem ============================================================================

rem :adb_reboot ЦЕЛЬ "подпись" (ЦЕЛЬ = - для обычной перезагрузки)
:adb_reboot
call :info "Перезагрузка: %~2…"
if "%~1"=="-" (call :run "%ADB_BIN%" -s "!SERIAL!" reboot) else (call :run "%ADB_BIN%" -s "!SERIAL!" reboot %~1)
timeout /t 2 /nobreak >nul
exit /b 0

:op_adb_shell
call :title "ADB SHELL"
call :note "Выход из оболочки: exit"
"%ADB_BIN%" -s "!SERIAL!" shell
call :pause_screen
exit /b 0

:op_logcat_errors
call :title "LOGCAT: последние ошибки"
"%ADB_BIN%" -s "!SERIAL!" logcat -d "*:E" >"%TMPF%" 2>nul
powershell -NoProfile -NonInteractive -Command "Get-Content -LiteralPath '%TMPF%' -Tail 50 -Encoding UTF8"
call :pause_screen
exit /b 0

:op_collect_logs
call :title "СБОР ДИАГНОСТИКИ"
call :now _ts
set "_cn=!D_CODENAME!"
if not defined _cn set "_cn=dev"
set "_dir=!WORKDIR!diag_!_cn!_!_ts!"
mkdir "!_dir!" >nul 2>&1
if not exist "!_dir!" (call :err "Не удалось создать !_dir!" & call :pause_screen & exit /b 0)
if "!STATE!"=="BOOTLOADER" goto :collect_fb
if "!STATE!"=="FASTBOOTD" goto :collect_fb
call :info "getprop, logcat…"
"%ADB_BIN%" -s "!SERIAL!" shell getprop >"!_dir!\getprop.txt" 2>&1
"%ADB_BIN%" -s "!SERIAL!" logcat -d -b all >"!_dir!\logcat.txt" 2>&1
"%ADB_BIN%" -s "!SERIAL!" logcat -d -b crash >"!_dir!\logcat_crash.txt" 2>nul
call :confirm_yn "Собрать dmesg и логи прошлой загрузки (нужен root на цели)?"
if errorlevel 1 goto :collect_done
call :need_target_root || goto :collect_done
call :info "dmesg, pstore/ramoops, last_kmsg…"
call :tsh "dmesg" "!_dir!\dmesg.txt"
call :tsh "cat /sys/fs/pstore/* /proc/last_kmsg 2>/dev/null" "!_dir!\last_boot.txt"
goto :collect_done
:collect_fb
"%FB_BIN%" -s "!SERIAL!" getvar all >"!_dir!\getvar_all.txt" 2>&1
:collect_done
for %%F in ("!_dir!\*") do if %%~zF==0 del /q "%%F" >nul 2>&1
call :ok "Сохранено в: !_dir!"
dir /b "!_dir!"
call :log "DIAG !_dir!"
call :pause_screen
exit /b 0

:op_dump_partition
call :title "ДАМП РАЗДЕЛА"
call :need_target_root || (call :pause_screen & exit /b 0)
call :note "Активный слот цели: !D_SLOT!. Список разделов — введите ?"
call :ask "Имя раздела (например, boot, init_boot, vendor_boot):"
if "!ANSWER!"=="?" (
    call :tsh "ls /dev/block/by-name 2>/dev/null || ls /dev/block/bootdevice/by-name"
    powershell -NoProfile -NonInteractive -Command "(Get-Content -LiteralPath '%TMPF%') -join '  '"
    call :ask "Имя раздела:"
)
set "_part=!ANSWER!"
echo(!_part!| findstr /r /x "[A-Za-z0-9_][A-Za-z0-9_]*" >nul || (
    call :err "Недопустимое имя раздела (только латиница, цифры и _)."
    call :pause_screen & exit /b 0
)
set "_sl=!D_SLOT!"
if not defined _sl set "_sl=x"
rem Ищем блочное устройство: сначала с суффиксом слота, потом без
call :tsh "for d in /dev/block/by-name /dev/block/bootdevice/by-name; do for n in !_part!_!_sl! !_part!; do [ -e $d/$n ] && echo $d/$n && exit 0; done; done"
set "_path="
for /f "usebackq delims=" %%A in ("%TMPF%") do if not defined _path set "_path=%%A"
if not defined _path (call :err "Раздел «!_part!» не найден на устройстве." & call :pause_screen & exit /b 0)
call :tsh "blockdev --getsize64 !_path!"
set "_size="
for /f "usebackq delims=" %%A in ("%TMPF%") do if not defined _size set "_size=%%A"
call :is_number "!_size!" || (call :err "Не удалось получить размер !_path!." & call :pause_screen & exit /b 0)
call :hsize !_size! _hs
call :info "Раздел: !_path! (!_hs!)"

rem Хватит ли места на диске ПК (+64 МБ запаса); арифметика cmd 32-битная — считаем в PowerShell
set "_space="
for /f "usebackq delims=" %%A in (`powershell -NoProfile -NonInteractive -Command "$d=(Get-Item -LiteralPath '!WORKDIR!').PSDrive; if($d.Free -gt ([int64]'!_size!' + 64MB)){'ok'}else{'no'}"`) do set "_space=%%A"
if "!_space!"=="no" (call :err "Мало места на диске ПК для дампа !_hs!." & call :pause_screen & exit /b 0)

call :now _ts
set "_pn=!_path:*by-name/=!"
set "_out=!WORKDIR!!_pn!_!_ts!.img"
call :info "Копирование… (не отключайте кабель)"
if "!T_ROOT!"=="direct" "%ADB_BIN%" -s "!SERIAL!" exec-out "cat !_path!" >"!_out!"
if "!T_ROOT!"=="su" "%ADB_BIN%" -s "!SERIAL!" exec-out "su -c 'cat !_path!'" >"!_out!"
set "_got=0"
for %%F in ("!_out!") do set "_got=%%~zF"
if not "!_got!"=="!_size!" (
    call :err "Размер не совпал: получено !_got! из !_size! байт. Дамп удалён."
    call :note "Попробуйте другой кабель или порт USB."
    del /q "!_out!" >nul 2>&1
    call :log "DUMP FAIL !_path!"
    call :pause_screen & exit /b 0
)
call :ok "Размер совпадает: !_got! байт."
call :info "Сверка MD5…"
call :tsh "md5sum !_path!"
set "_tm="
for /f "usebackq tokens=1" %%A in ("%TMPF%") do if not defined _tm set "_tm=%%A"
set "_hm="
for /f "usebackq delims=" %%A in (`powershell -NoProfile -NonInteractive -Command "(Get-FileHash -Algorithm MD5 -LiteralPath '!_out!').Hash.ToLower()"`) do set "_hm=%%A"
if defined _tm if /i "!_tm!"=="!_hm!" (
    call :ok "MD5 совпадает: !_hm!"
    call :ok "Дамп: !_out!"
    call :log "DUMP OK !_path! md5=!_hm!"
    call :pause_screen & exit /b 0
)
call :err "MD5 не совпал (цель: !_tm!, ПК: !_hm!). Дамп удалён."
del /q "!_out!" >nul 2>&1
call :log "DUMP MD5 FAIL !_path!"
call :pause_screen
exit /b 0

:op_magisk_modules
call :title "МОДУЛИ MAGISK / KERNELSU"
call :need_target_root || (call :pause_screen & exit /b 0)
call :tsh "cd /data/adb/modules 2>/dev/null || exit 3; for m in *; do [ -d $m ] || continue; st=on; [ -f $m/disable ] && st=off; [ -f $m/remove ] && st=del; nm=$(grep -m1 name= $m/module.prop 2>/dev/null | cut -d= -f2-); echo $m/$st/$nm; done"
set "_mn=0"
for /f "usebackq tokens=1,2,* delims=/" %%A in ("%TMPF%") do (
    set /a _mn+=1
    set "MOD_ID_!_mn!=%%A"
    set "MOD_ST_!_mn!=%%B"
    set "MOD_NM_!_mn!=%%C"
)
if "!_mn!"=="0" (
    call :warn "Модули не найдены (или /data зашифрован / нет доступа)."
    call :pause_screen & exit /b 0
)
for /l %%i in (1,1,!_mn!) do (
    set "_st=%C_GRN%вкл%C_NC%"
    if "!MOD_ST_%%i!"=="off" set "_st=%C_YEL%выкл%C_NC%"
    if "!MOD_ST_%%i!"=="del" set "_st=%C_RED%удалится%C_NC%"
    set "_nn=  %%i"
    echo   %C_BLD%!_nn:~-2!%C_NC%  [!_st!] !MOD_ID_%%i!  %C_DIM%!MOD_NM_%%i!%C_NC%
)
call :section "Действия"
call :item d "Отключить модуль" "файл disable, обратимо"
call :item e "Включить модуль"
call :item r "Удалить модуль" "файл remove, удалится при загрузке"
call :item D "Отключить ВСЕ" "главное средство от bootloop"
call :item 0 "Назад"
call :ask "Выбор:"
set "_act=!ANSWER!"
if "!_act!"=="D" (
    call :tsh "for m in /data/adb/modules/*/; do touch $m/disable; done; echo done"
    findstr /x "done" "%TMPF%" >nul && (call :ok "Все модули отключены. Перезагрузите устройство.") || call :err "Не удалось."
    call :log "MODULES disable all"
    call :pause_screen & exit /b 0
)
if not "!_act!"=="d" if not "!_act!"=="e" if not "!_act!"=="r" exit /b 0
call :ask "Номер модуля:"
call :is_number "!ANSWER!" || (call :info "Отменено." & call :pause_screen & exit /b 0)
if !ANSWER! LSS 1 (call :err "Нет такого номера." & call :pause_screen & exit /b 0)
if !ANSWER! GTR !_mn! (call :err "Нет такого номера." & call :pause_screen & exit /b 0)
set "_mid=!MOD_ID_%ANSWER%!"
rem id приходит с устройства — проверяем, прежде чем вставлять в команду
echo(!_mid!| findstr /r /x "[A-Za-z0-9._-][A-Za-z0-9._-]*" >nul || (call :err "Подозрительное имя модуля." & call :pause_screen & exit /b 0)
if "!_mid!"=="." (call :err "Подозрительное имя модуля." & call :pause_screen & exit /b 0)
if "!_mid!"==".." (call :err "Подозрительное имя модуля." & call :pause_screen & exit /b 0)
if "!_act!"=="d" call :tsh "touch /data/adb/modules/!_mid!/disable && echo done"
if "!_act!"=="e" call :tsh "rm -f /data/adb/modules/!_mid!/disable /data/adb/modules/!_mid!/remove && echo done"
if "!_act!"=="r" call :tsh "touch /data/adb/modules/!_mid!/remove && echo done"
findstr /x "done" "%TMPF%" >nul && (call :ok "Готово: !_mid!.") || call :err "Не удалось."
call :log "MODULE !_act! !_mid!"
call :pause_screen
exit /b 0

:op_magisk_remove_all
call :title "MAGISK: УДАЛИТЬ ВСЕ МОДУЛИ"
call :note "Команда: adb wait-for-device shell magisk --remove-modules"
call :note "Удалит все модули и перезагрузит устройство. Работает даже в бутлупе,"
call :note "если adb успевает подняться."
call :confirm_yn "Выполнить?" || exit /b 0
call :run "%ADB_BIN%" -s "!SERIAL!" wait-for-device shell magisk --remove-modules
call :pause_screen
exit /b 0

rem ============================================================================
rem  ОПЕРАЦИИ: SIDELOAD / RESCUE
rem ============================================================================

:op_sideload
call :title "ADB SIDELOAD"
call :pick_file "Прошивки/OTA (.zip)" zip || (call :pause_screen & exit /b 0)
call :warn "НЕ ОТКЛЮЧАЙТЕ КАБЕЛЬ до окончания."
call :run "%ADB_BIN%" -s "!SERIAL!" sideload "!PICKED!"
call :note "Итог смотрите на экране устройства (код 1 при «xfer: 1.00x» — это норма)."
call :pause_screen
exit /b 0

:op_rescue_install
call :title "PIXEL RESCUE: УСТАНОВКА OTA"
call :note "Нужен полный OTA-пакет Google для этого устройства (не factory image)."
call :pick_file "OTA-пакеты (.zip)" zip || (call :pause_screen & exit /b 0)
call :warn "НЕ ОТКЛЮЧАЙТЕ КАБЕЛЬ до окончания."
call :run "%ADB_BIN%" -s "!SERIAL!" rescue install "!PICKED!"
call :pause_screen
exit /b 0

:op_rescue_info
call :title "PIXEL RESCUE: СВЕДЕНИЯ"
for %%P in (ro.product.device ro.build.fingerprint ro.build.date.utc) do (
    set "_v="
    "%ADB_BIN%" -s "!SERIAL!" rescue getprop %%P >"%TMPF%" 2>nul
    for /f "usebackq delims=" %%A in ("%TMPF%") do set "_v=%%A"
    echo  %%P = !_v!
)
call :pause_screen
exit /b 0

rem ============================================================================
rem  ОПЕРАЦИИ: FASTBOOT
rem ============================================================================

:fb_reboot
if "%~1"=="-" (call :run "%FB_BIN%" -s "!SERIAL!" reboot) else (call :run "%FB_BIN%" -s "!SERIAL!" reboot %~1)
timeout /t 2 /nobreak >nul
exit /b 0

:op_fb_info
call :title "ИНФОРМАЦИЯ (getvar all)"
set "_cn=!D_CODENAME!"
if not defined _cn set "_cn=dev"
set "_f=!WORKDIR!getvar_!_cn!.txt"
"%FB_BIN%" -s "!SERIAL!" getvar all >"!_f!" 2>&1
findstr /i /r /c:"product" /c:"current-slot" /c:"slot-count" /c:"unlocked" /c:"secure" /c:"version" /c:"is-userspace" /c:"anti" /c:"battery" "!_f!" | findstr /v /i "partition"
echo.
call :note "Полный вывод сохранён: !_f!"
call :pause_screen
exit /b 0

:op_fb_switch_slot
call :title "ПЕРЕКЛЮЧЕНИЕ A/B СЛОТА"
set "_next="
if /i "!D_SLOT!"=="a" set "_next=b"
if /i "!D_SLOT!"=="b" set "_next=a"
if not defined _next (call :err "Слот не определён — устройство A-only?" & call :pause_screen & exit /b 0)
call :info "Текущий слот: !D_SLOT! → будет: !_next!"
call :note "Во втором слоте должна быть рабочая система (обычно — предыдущая версия после OTA)."
call :confirm_yn "Переключить на слот !_next!?" || exit /b 0
call :run "%FB_BIN%" -s "!SERIAL!" --set-active=!_next! && set "D_SLOT=!_next!"
call :pause_screen
exit /b 0

:op_fb_flash
call :title "ПРОШИВКА ОБРАЗА В РАЗДЕЛ"
call :ensure_warned || (call :pause_screen & exit /b 0)
if "!STATE!"=="FASTBOOTD" (
    call :item 1 "system"
    call :item 2 "system_ext"
    call :item 3 "product"
    call :item 4 "vendor"
    call :item 5 "odm"
    call :item 7 "Ввести вручную"
) else (
    call :item 1 "boot"
    call :item 2 "init_boot" "Pixel 7+ и др. с Android 13+ (Magisk патчит его)"
    call :item 3 "vendor_boot" "Pixel 6+"
    call :item 4 "recovery"
    call :item 5 "dtbo"
    call :item 7 "Ввести вручную"
)
call :item 0 "Отмена"
call :ask "Раздел:"
set "_part="
if "!STATE!"=="FASTBOOTD" (
    if "!ANSWER!"=="1" set "_part=system"
    if "!ANSWER!"=="2" set "_part=system_ext"
    if "!ANSWER!"=="3" set "_part=product"
    if "!ANSWER!"=="4" set "_part=vendor"
    if "!ANSWER!"=="5" set "_part=odm"
) else (
    if "!ANSWER!"=="1" set "_part=boot"
    if "!ANSWER!"=="2" set "_part=init_boot"
    if "!ANSWER!"=="3" set "_part=vendor_boot"
    if "!ANSWER!"=="4" set "_part=recovery"
    if "!ANSWER!"=="5" set "_part=dtbo"
)
if "!ANSWER!"=="7" (
    call :ask "Имя раздела:"
    set "_part=!ANSWER!"
)
if not defined _part exit /b 0
echo(!_part!| findstr /r /x "[A-Za-z0-9_][A-Za-z0-9_]*" >nul || (call :err "Недопустимое имя раздела." & call :pause_screen & exit /b 0)
call :afe_guard flash "!_part!" || (call :pause_screen & exit /b 0)
if "!STATE!"=="BOOTLOADER" if /i not "!D_UNLOCKED!"=="yes" call :warn "Загрузчик заблокирован — прошивка почти наверняка будет отклонена."
echo.
call :pick_file "Образы (.img)" img || (call :pause_screen & exit /b 0)
call :check_image "!PICKED!" "!_part!" || (call :pause_screen & exit /b 0)
set "_slotopt="
set "_suf=!_part:~-2!"
if defined D_SLOT if /i not "!_suf!"=="_a" if /i not "!_suf!"=="_b" (
    call :confirm_yn "Прошить в оба слота (a и b)? Нет — только в текущий (!D_SLOT!)" && set "_slotopt=--slot=all"
)
echo.
call :info "Раздел: !_part! !_slotopt!   Файл: !PICKED!"
call :confirm_yn "Прошить?" || exit /b 0
call :run "%FB_BIN%" -s "!SERIAL!" !_slotopt! flash "!_part!" "!PICKED!"
call :pause_screen
exit /b 0

:op_fb_vbmeta
call :title "VBMETA: ОТКЛЮЧЕНИЕ VERITY / VERIFICATION"
call :ensure_warned || (call :pause_screen & exit /b 0)
call :note "Нужно для кастомных ядер/GSI. На Pixel и многих других устройствах после"
call :note "первого отключения проверок требуется Format Data, иначе система не загрузится."
call :pick_file "vbmeta-образы (.img)" img || (call :pause_screen & exit /b 0)
call :check_image "!PICKED!" vbmeta || (call :pause_screen & exit /b 0)
call :confirm_yn "Прошить в vbmeta с --disable-verity --disable-verification?" || exit /b 0
call :run "%FB_BIN%" -s "!SERIAL!" --disable-verity --disable-verification flash vbmeta "!PICKED!"
call :pause_screen
exit /b 0

:op_fb_boot_temp
call :title "ВРЕМЕННАЯ ЗАГРУЗКА ОБРАЗА (fastboot boot)"
call :note "Образ загружается в RAM без прошивки — для проверки ядер/recovery."
call :note "На Pixel 7+ грузится boot.img с ядром, init_boot так не грузится."
call :pick_file "Образы (.img)" img || (call :pause_screen & exit /b 0)
call :check_image "!PICKED!" boot || (call :pause_screen & exit /b 0)
call :run "%FB_BIN%" -s "!SERIAL!" boot "!PICKED!"
call :pause_screen
exit /b 0

:op_fb_format_data
call :title "FORMAT DATA"
call :ensure_warned || (call :pause_screen & exit /b 0)
call :note "fastboot -w: стирание и форматирование userdata, cache и metadata."
call :confirm_word WIPE "ВСЕ ДАННЫЕ ПОЛЬЗОВАТЕЛЯ БУДУТ УДАЛЕНЫ." || (call :pause_screen & exit /b 0)
call :run "%FB_BIN%" -s "!SERIAL!" -w
call :pause_screen
exit /b 0

:op_fb_erase_frp
call :title "СТИРАНИЕ FRP"
if /i not "!D_UNLOCKED!"=="yes" (call :err "Загрузчик заблокирован — операция невозможна." & call :pause_screen & exit /b 0)
call :ensure_warned || (call :pause_screen & exit /b 0)
call :note "Многие загрузчики (в т.ч. Pixel) откажут в erase frp — это нормально."
call :confirm_word ERASE_FRP "Будет очищен раздел Factory Reset Protection." || (call :pause_screen & exit /b 0)
call :afe_guard erase frp && call :run "%FB_BIN%" -s "!SERIAL!" erase frp
call :pause_screen
exit /b 0

:op_fb_bootloader
call :title "УПРАВЛЕНИЕ ЗАГРУЗЧИКОМ"
if /i "!D_UNLOCKED!"=="yes" (echo  Текущий статус: %C_GRN%UNLOCKED%C_NC%) else (echo  Текущий статус: %C_RED%LOCKED%C_NC%)
call :fb_var unlock_ability _ab
if defined _ab call :note "unlock_ability: !_ab! (1 — разблокировка разрешена в настройках)"
call :warn "Любая смена статуса = полный сброс данных (Factory Reset)."
echo.
call :item 1 "Разблокировать" "flashing unlock"
call :item 2 "Заблокировать" "flashing lock — только на стоковой прошивке"
call :item 3 "Разблокировать критические разделы" "flashing unlock_critical"
call :item 0 "Назад"
call :ask "Выбор:"
if "!ANSWER!"=="1" goto :bl_unlock
if "!ANSWER!"=="2" goto :bl_lock
if "!ANSWER!"=="3" goto :bl_critical
exit /b 0
:bl_unlock
if /i "!D_UNLOCKED!"=="yes" (call :info "Уже разблокирован." & call :pause_screen & exit /b 0)
if "!DEVICE_TYPE!"=="xiaomi" call :note "Xiaomi/POCO разблокируются только через Mi Unlock Tool — fastboot откажет."
call :confirm_word UNLOCK "Данные будут стёрты. Подтвердите на экране устройства кнопками громкости." || (call :pause_screen & exit /b 0)
call :run "%FB_BIN%" -s "!SERIAL!" flashing unlock || call :run "%FB_BIN%" -s "!SERIAL!" oem unlock
goto :bl_done
:bl_lock
if /i not "!D_UNLOCKED!"=="yes" (call :info "Загрузчик уже заблокирован." & call :pause_screen & exit /b 0)
call :ensure_warned || (call :pause_screen & exit /b 0)
echo.
call :err "Блокировка на кастомной прошивке, с Magisk или изменённым vbmeta = КИРПИЧ."
call :note "Блокируйте только после полной прошивки официального factory image."
call :confirm_word LOCK "Устройство будет заблокировано и сброшено." || (call :pause_screen & exit /b 0)
call :run "%FB_BIN%" -s "!SERIAL!" flashing lock
goto :bl_done
:bl_critical
call :note "Нужно для прошивки bootloader/radio некоторыми инструментами."
call :confirm_word UNLOCK_CRITICAL "Данные будут стёрты." || (call :pause_screen & exit /b 0)
call :run "%FB_BIN%" -s "!SERIAL!" flashing unlock_critical
:bl_done
set "PREV_KEY="
call :pause_screen
exit /b 0

rem ============================================================================
rem  USB: проверка физического подключения (диспетчер устройств Windows)
rem ============================================================================
rem Get-PnpDevice видит телефон, даже когда adb/fastboot его не видят:
rem нет драйвера, EDL 9008, Samsung Download. Режим определяем по VID:PID и имени.

:usb_scan
set "USB_N=0"
set "USB_MODE="
set "USB_NODRV=0"
powershell -NoProfile -NonInteractive -Command "Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match '^USB\\VID_(18D1|2717|05C6|04E8|22B8|2A70|12D1|22D9|2D95|0E8D|0BB4|1004)&PID_' } | ForEach-Object { $m = [regex]::Match($_.InstanceId, 'VID_([0-9A-F]{4})&PID_([0-9A-F]{4})'); '{0}:{1}|{2}|{3}' -f $m.Groups[1].Value, $m.Groups[2].Value, $_.Status, $_.FriendlyName }" >"%TMPF%" 2>nul
for /f "usebackq tokens=1,2,* delims=|" %%A in ("%TMPF%") do call :usb_add "%%A" "%%B" "%%C"
exit /b 0

:usb_add
set "_id=%~1"
set "_mode=other"
set "_fn=%~3"
if /i "!_id!"=="05C6:9008" set "_mode=edl"
if /i "!_id!"=="04E8:685D" set "_mode=download"
if /i "!_id!"=="0E8D:0003" set "_mode=brom"
if "!_mode!"=="other" (
    echo(!_fn!| findstr /i "bootloader fastboot" >nul && set "_mode=fastboot"
    echo(!_fn!| findstr /i "ADB" >nul && set "_mode=adb"
)
rem Fastboot-интерфейсы Google/Xiaomi без драйвера: 18D1:4EE0, 18D1:D00D
if "!_mode!"=="other" if /i "!_id!"=="18D1:4EE0" set "_mode=fastboot"
if "!_mode!"=="other" if /i "!_id!"=="18D1:D00D" set "_mode=fastboot"
set /a USB_N+=1
set "USB_ID_!USB_N!=!_id!"
set "USB_ST_!USB_N!=%~2"
set "USB_FN_!USB_N!=!_fn!"
set "USB_MD_!USB_N!=!_mode!"
if /i not "%~2"=="OK" set "USB_NODRV=1"
if not defined USB_MODE if not "!_mode!"=="other" set "USB_MODE=!_mode!"
exit /b 0

:usb_hint
if "!USB_MODE!"=="edl" (
    call :err "Устройство в EDL (Qualcomm 9008) — аварийный режим загрузчика."
    call :note "adb/fastboot тут бессильны: нужен MiFlash/QFIL и авторизованный аккаунт."
    call :note "Иногда помогает выход: зажать Power + Vol- на 15–20 с."
    exit /b 0
)
if "!USB_MODE!"=="download" (
    call :warn "Samsung в режиме Download (Odin) — используйте Odin/Heimdall."
    exit /b 0
)
if "!USB_MODE!"=="brom" (
    call :err "MediaTek в режиме BROM — нужен SP Flash Tool / mtkclient."
    exit /b 0
)
if "!USB_NODRV!"=="1" (
    call :warn "Телефон виден в Windows, но драйвер не установлен или с ошибкой."
    call :note "Установите Google USB Driver (Android SDK) или драйвер производителя,"
    call :note "затем в Диспетчере устройств: Обновить драйвер → Android Bootloader / ADB Interface."
    exit /b 0
)
if "!USB_MODE!"=="adb" (
    call :warn "Windows видит ADB-интерфейс, но adb не видит устройство."
    call :note "Перезапустите ADB-сервер (пункт 2) и проверьте окно разрешения отладки на телефоне."
    exit /b 0
)
if "!USB_MODE!"=="fastboot" (
    call :warn "Windows видит fastboot-интерфейс, но fastboot не видит устройство."
    call :note "Обычно это драйвер: Диспетчер устройств → Android Bootloader Interface."
    exit /b 0
)
if not "!USB_N!"=="0" (
    call :warn "Телефон подключён по USB, но без отладки."
    call :note "Включите «Отладка по USB» и выберите режим USB «Передача файлов»."
    exit /b 0
)
call :info "Ожидание подключения по USB…"
call :note "Нужен кабель с передачей данных (не только зарядный) и включённая отладка по USB."
exit /b 0

:op_usb_diag
call :title "ДИАГНОСТИКА USB"
call :usb_scan
if "!USB_N!"=="0" (
    echo  Телефонов в диспетчере устройств Windows не найдено.
) else (
    for /l %%i in (1,1,!USB_N!) do (
        echo   %C_BLD%!USB_ID_%%i!%C_NC%  !USB_FN_%%i!
        call :note "режим: !USB_MD_%%i!   драйвер: !USB_ST_%%i!"
    )
)
echo.
echo  adb devices:
"%ADB_BIN%" devices 2>nul | more +1
echo  fastboot devices:
"%FB_BIN%" devices 2>nul
echo.
call :usb_hint
call :pause_screen
exit /b 0

rem ============================================================================
rem  МЕНЮ ПО СОСТОЯНИЯМ
rem ============================================================================

:read_choice
echo.
set "CHOICE_IN="
set /p "CHOICE_IN=%C_CYN%›%C_NC% "
exit /b 0

:menu_system
set "_rec=0"
if "!STATE!"=="RECOVERY" set "_rec=1"
call :section "Перезагрузка" "%C_YEL%"
call :item 1 "В bootloader" "fastboot"
call :item 2 "В recovery"
call :item 3 "В fastbootd" "прошивка разделов внутри super"
call :item 4 "В систему"
if "!DEVICE_TYPE!"=="samsung" call :item 5 "В Download Mode" "Odin / Heimdall"
if "!_rec!"=="1" if "!DEVICE_TYPE!"=="pixel" call :item 6 "В Rescue Mode" "Pixel: установка OTA"
call :section "Инструменты"
call :item 7 "Модули Magisk / KernelSU" "отключить / удалить"
if "!_rec!"=="0" call :item 8 "Сброс модулей при бутлупе" "magisk --remove-modules"
call :item 9 "Дамп раздела" "размер + MD5"
call :item 10 "Логи: последние ошибки" "logcat *:E"
call :item 11 "Сохранить диагностику" "logcat, dmesg, ramoops"
call :item 12 "ADB Shell"
call :item 13 "Диагностика USB"
echo.
call :item 0 "Выход"
call :read_choice
set "c=!CHOICE_IN!"
if "!c!"=="1" call :adb_reboot bootloader "в bootloader"
if "!c!"=="2" call :adb_reboot recovery "в recovery"
if "!c!"=="3" call :adb_reboot fastboot "в fastbootd"
if "!c!"=="4" call :adb_reboot - "в систему"
if "!c!"=="5" if "!DEVICE_TYPE!"=="samsung" call :adb_reboot download "в Download Mode"
if "!c!"=="6" if "!_rec!"=="1" call :adb_reboot rescue "в Rescue Mode"
if "!c!"=="7" call :op_magisk_modules
if "!c!"=="8" if "!_rec!"=="0" call :op_magisk_remove_all
if "!c!"=="9" call :op_dump_partition
if "!c!"=="10" call :op_logcat_errors
if "!c!"=="11" call :op_collect_logs
if "!c!"=="12" call :op_adb_shell
if "!c!"=="13" call :op_usb_diag
if "!c!"=="0" set "QUIT=1"
exit /b 0

:menu_sideload
call :section "Прошивка"
call :item 1 "ADB Sideload" "zip / OTA"
call :section "Перезагрузка" "%C_YEL%"
call :item 2 "В систему"
call :item 3 "В bootloader"
if not "!DEVICE_TYPE!"=="samsung" call :item 4 "В Rescue Mode" "Pixel"
echo.
call :item 0 "Выход"
call :read_choice
set "c=!CHOICE_IN!"
if "!c!"=="1" call :op_sideload
if "!c!"=="2" call :adb_reboot - "в систему"
if "!c!"=="3" call :adb_reboot bootloader "в bootloader"
if "!c!"=="4" call :adb_reboot rescue "в Rescue Mode"
if "!c!"=="0" set "QUIT=1"
exit /b 0

:menu_rescue
call :section "Pixel Rescue"
call :item 1 "Сведения об устройстве" "adb rescue getprop"
call :item 2 "Установить OTA" "adb rescue install"
call :section "Перезагрузка" "%C_YEL%"
call :item 3 "В систему"
call :item 4 "В bootloader"
echo.
call :item 0 "Выход"
call :read_choice
set "c=!CHOICE_IN!"
if "!c!"=="1" call :op_rescue_info
if "!c!"=="2" call :op_rescue_install
if "!c!"=="3" call :adb_reboot - "в систему"
if "!c!"=="4" call :adb_reboot bootloader "в bootloader"
if "!c!"=="0" set "QUIT=1"
exit /b 0

:menu_fastboot
set "_bl=0"
if "!STATE!"=="BOOTLOADER" set "_bl=1"
call :section "Прошивка"
call :item 1 "Информация" "getvar all"
call :item 2 "Переключить A/B слот" "сейчас: !D_SLOT!"
if "!_bl!"=="1" (call :item 3 "Прошить образ" "boot / init_boot / vendor_boot / …") else (call :item 3 "Прошить логический раздел" "system / vendor / product / …")
call :item 4 "Прошить vbmeta" "disable verity / verification"
if "!_bl!"=="1" call :item 5 "Загрузить образ без прошивки" "fastboot boot"
call :section "Перезагрузка" "%C_YEL%"
if "!_bl!"=="1" (call :item 6 "В fastbootd" "разделы внутри super") else (call :item 6 "В bootloader")
call :item 7 "В recovery"
call :item 8 "В систему"
call :section "Опасные операции" "%C_RED%"
call :item 9 "Format Data" "userdata + metadata"
call :item 10 "Стереть FRP"
if "!_bl!"=="1" call :item 11 "Загрузчик" "lock / unlock"
call :item 12 "Сохранить getvar all"
call :item 13 "Диагностика USB"
echo.
call :item 0 "Выход"
call :read_choice
set "c=!CHOICE_IN!"
if "!c!"=="1" call :op_fb_info
if "!c!"=="2" call :op_fb_switch_slot
if "!c!"=="3" call :op_fb_flash
if "!c!"=="4" call :op_fb_vbmeta
if "!c!"=="5" if "!_bl!"=="1" call :op_fb_boot_temp
if "!c!"=="6" if "!_bl!"=="1" call :fb_reboot fastboot
if "!c!"=="6" if "!_bl!"=="0" call :fb_reboot bootloader
if "!c!"=="7" call :fb_reboot recovery
if "!c!"=="8" call :fb_reboot -
if "!c!"=="9" call :op_fb_format_data
if "!c!"=="10" call :op_fb_erase_frp
if "!c!"=="11" if "!_bl!"=="1" call :op_fb_bootloader
if "!c!"=="12" call :op_collect_logs
if "!c!"=="13" call :op_usb_diag
if "!c!"=="0" set "QUIT=1"
exit /b 0

:menu_waiting
if "!STATE!"=="UNAUTHORIZED" call :warn "Разрешите отладку на экране телефона (галочка «Всегда разрешать»)."
if "!STATE!"=="OFFLINE" call :warn "Устройство offline: переподключите кабель или перезапустите ADB-сервер."
if "!STATE!"=="NONE" (
    rem Диспетчер устройств опрашиваем один раз за ожидание — PowerShell не быстрый
    if "!USB_CHECKED!"=="0" (call :usb_scan & set "USB_CHECKED=1")
    call :usb_hint
)
call :section "Действия"
call :item 1 "Обновить"
call :item 2 "Перезапустить ADB-сервер"
call :item 3 "Диагностика USB"
echo.
call :item 0 "Выход"
echo.
choice /c 1230 /n /t 5 /d 1 /m "%C_CYN%›%C_NC% %C_DIM%(автообновление через 5 с)%C_NC% "
set "_e=!errorlevel!"
if "!_e!"=="1" set "USB_CHECKED=0"
if "!_e!"=="2" (
    "%ADB_BIN%" kill-server >nul 2>&1
    "%ADB_BIN%" start-server >nul 2>&1
    call :ok "ADB-сервер перезапущен."
    set "USB_CHECKED=0"
    timeout /t 1 /nobreak >nul
)
if "!_e!"=="3" call :op_usb_diag
if "!_e!"=="4" set "QUIT=1"
exit /b 0

rem ============================================================================
rem  ВЫХОД
rem ============================================================================

:fatal
echo.
echo OTG Rescue Toolkit остановлен.
pause
goto :cleanup_exit

:exit_script
echo.
echo %C_YEL%Выход из OTG Rescue ToolKit.%C_NC%
call :log "EXIT"

:cleanup_exit
if exist "%TMPF%" del /q "%TMPF%" >nul 2>&1
if exist "%TMPF2%" del /q "%TMPF2%" >nul 2>&1
endlocal & endlocal
exit /b 0

