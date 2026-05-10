#!/system/bin/sh
#
# volte_vowifi_v2.sh
# Aggressive VoLTE/VoWiFi enabler (Pixel-focused, physical SIM oriented)
# v2 — более агрессивная перерегистрация IMS + roaming flags
#
# Требования: root, доступ к `resetprop` (если есть), `settings`, `cmd`, `service`, `dumpsys`
# Запуск: adb shell su -c "/data/local/tmp/volte_vowifi_v2.sh"
#

set -u

# --------------------------
# Конфигурация путей / логов
# --------------------------
WORKDIR="${WORKDIR:-/data/local/tmp/volte_vowifi}"
mkdir -p "$WORKDIR" 2>/dev/null || true
LOGFILE="$WORKDIR/volte_vowifi_v2_log_$(date +%Y%m%d_%H%M%S).txt"
BACKUP="$WORKDIR/volte_vowifi_v2_backup_$(date +%Y%m%d_%H%M%S).txt"

echo "[*] WORKDIR: $WORKDIR" | tee -a "$LOGFILE"
echo "[*] LOG: $LOGFILE" | tee -a "$LOGFILE"
echo "[*] BACKUP: $BACKUP" | tee -a "$LOGFILE"

# --------------------------
# Утилиты
# --------------------------
RESETPROP="$(command -v resetprop 2>/dev/null || true)"

run_resetprop() {
    # set persistent property (best-effort)
    k="$1"; v="$2"
    if [ -n "$RESETPROP" ]; then
        echo "[*] resetprop: $k -> $v" | tee -a "$LOGFILE"
        $RESETPROP "$k" "$v" 2>>"$LOGFILE" || echo "[!] resetprop failed for $k (ignored)" >>"$LOGFILE"
    else
        # fallback: runtime setprop (не персистентно) + лог
        echo "[*] setprop (runtime fallback): $k -> $v" | tee -a "$LOGFILE"
        setprop "$k" "$v" 2>>"$LOGFILE" || echo "[!] setprop failed for $k (ignored)" >>"$LOGFILE"
        echo "[!] NOTE: resetprop not available; value won't survive reboot" >>"$LOGFILE"
    fi
}

run_settings_put_global() {
    k="$1"; v="$2"
    echo "[*] settings put global $k $v" | tee -a "$LOGFILE"
    settings put global "$k" "$v" 2>>"$LOGFILE" || echo "[!] settings put global $k failed" >>"$LOGFILE"
}

run_settings_put_secure() {
    k="$1"; v="$2"
    echo "[*] settings put secure $k $v" | tee -a "$LOGFILE"
    settings put secure "$k" "$v" 2>>"$LOGFILE" || echo "[!] settings put secure $k failed" >>"$LOGFILE"
}

log_and_echo() {
    echo "$@" | tee -a "$LOGFILE"
}

# --------------------------
# 1) Бэкап текущих ключей (getprop + settings global)
# --------------------------
log_and_echo "[*] Снимаю бекап существующих getprop / settings..."
{
    echo "==== DATE ===="
    date
    echo
    echo "==== GETPROP (ims|volte|wfc|wcm) ===="
    getprop | egrep -i "ims|volte|wfc|wcm|ims_support|vendor.ims" || true
    echo
    echo "==== SETTINGS GLOBAL (relevant) ===="
    settings get global enhanced_4g_mode_enabled || true
    settings get global wifi_calling_enabled || true
    settings get global wfc_ims_mode || true
    settings get global wfc_ims_roaming_enabled || true
    settings get global wfc_ims_roaming_mode || true
    settings get global wfc_ims_roaming_available || true
    echo
} > "$BACKUP"

log_and_echo "[*] Бекап записан в $BACKUP"

# --------------------------
# 2) Список persist-ключей и settings (aggressive)
# --------------------------
# базовый набор (из v1) + дополнительные ключи для roaming/ims override
PERSIST_KEYS_LIST="
persist.dbg.volte_avail_ovr=1
persist.dbg.vt_avail_ovr=1
persist.dbg.wfc_avail_ovr=1
persist.dbg.wfc_ims_enabled=1
persist.dbg.volte_ims_enabled=1
persist.sys.ims_support=1
persist.vendor.ims.enabled=1
persist.dbg.wfc_roaming_enabled=1
persist.dbg.ims_roaming_override=1
persist.dbg.wfc_ims_roaming=1
"

# settings global values
SETTINGS_LIST="
enhanced_4g_mode_enabled=1
wifi_calling_enabled=1
wfc_ims_mode=1
wfc_ims_roaming_enabled=1
# добавляем roaming mode опционально (1 = WIFI_PREFFERED обычно)
wfc_ims_roaming_mode=1
"

log_and_echo "[*] Попытка задать persist свойства..."
# Проставляем persist-ключи
echo "$PERSIST_KEYS_LIST" | while IFS= read -r kv; do
    [ -z "$kv" ] && continue
    k="${kv%%=*}"; v="${kv#*=}"
    # если уже установлено такое же значение — пропускаем
    cur="$(getprop "$k" 2>/dev/null || true)"
    if [ "$cur" = "$v" ]; then
        log_and_echo "[*] Пропускаю $k (уже: $v)"
    else
        run_resetprop "$k" "$v"
    fi
done

# Проставляем системные настройки через settings
log_and_echo "[*] Применяю системные ключи через settings..."
echo "$SETTINGS_LIST" | while IFS= read -r kv; do
    [ -z "$kv" ] && continue
    # skip comments
    case "$kv" in \#*) continue ;; esac
    k="${kv%%=*}"; v="${kv#*=}"
    run_settings_put_global "$k" "$v"
done

# --------------------------
# 3) Soft reload радиоподсистемы — Airplane toggle (safe)
# --------------------------
log_and_echo "[*] Попытка soft-reload радиоподсистемы: toggle Airplane mode (safe)."
AM_MODE="$(settings get global airplane_mode_on 2>/dev/null || echo 0)"
log_and_echo "[*] Текущее значение airplane_mode_on = ${AM_MODE:-0}"

# Включим airplane, подождём, выключим — чтобы дать telephony перезапуститься
settings put global airplane_mode_on 1 2>/dev/null || true
am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true 2>/dev/null || true
sleep 3

settings put global airplane_mode_on 0 2>/dev/null || true
am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false 2>/dev/null || true
sleep 5

# --------------------------
# 4) Агрессивные шаги: Kill IMS / service calls / cmd phone ims attempts
# --------------------------
log_and_echo "[*] Агрессивная последовательность перерегистрации IMS (pkill/service/cmd attempts)."

# 4.1 kill Имс-процессов (best-effort)
log_and_echo "[*] Убиваем пользовательские IMS-процессы (pkill best-effort)."
pkill -f 'ims' 2>/dev/null || true
pkill -f 'Ims' 2>/dev/null || true
sleep 2

# 4.2 service call phone — common indexes (разные билды используют разные номера)
# Эти вызовы никак не ломают устройство — они best-effort.
log_and_echo "[*] Пробую service call phone reset/ims (несколько вариантов)..."
service call phone 83 2>/dev/null || true
service call phone 84 2>/dev/null || true
service call phone 52 2>/dev/null || true

# 4.3 cmd phone ims — попытки включения/перезагрузки IMS
log_and_echo "[*] Пробую cmd phone ims commands (если доступны)..."
cmd phone ims enable 2>/dev/null || true
cmd phone ims disable 2>/dev/null || true
cmd phone ims enable 2>/dev/null || true
cmd phone ims reset 2>/dev/null || true
cmd phone ims set-ims-service-enabled true 2>/dev/null || true

# 4.4 попытки через telephony manager ('service call' или 'am broadcast' вариантов)
# В некоторых билдах есть комманды "telephony.registry" — best-effort
am broadcast -a com.android.ims.ACTION_RESET 2>/dev/null || true
sleep 2

# 4.5 toggle мобильных данных (иногда помогает для физической SIM)
log_and_echo "[*] Короткий restart мобильных данных (svc data toggle)."
svc data disable 2>/dev/null || true
sleep 2
svc data enable 2>/dev/null || true
sleep 4

# --------------------------
# 5) Повторные attempts + проверка (3 попытки)
# --------------------------
MAX_TRIES=3
try=1
success=0

while [ "$try" -le "$MAX_TRIES" ]; do
    log_and_echo "[*] Попытка IMS-ре-регистрации: #$try/$MAX_TRIES"

    # короткий cycle: disable/enable ims via cmd if possible
    cmd phone ims disable 2>/dev/null || true
    sleep 1
    cmd phone ims enable 2>/dev/null || true
    sleep 3

    # ещё раз pkill для жёсткой перерегистрации
    pkill -f 'ims' 2>/dev/null || true
    sleep 2

    # Проверка dumpsys ims
    DUMP="$WORKDIR/dumpsys_ims_try${try}_$(date +%s).txt"
    echo "[*] Сохраняю dumpsys ims -> $DUMP" | tee -a "$LOGFILE"
    dumpsys ims > "$DUMP" 2>&1 || true

    # парсим для признаков успешной регистрации
    # ищем строки с Registered / WFC / VoLTE
    grep -E "Registered:|REG:|WFC|VoLTE|wfc|volte|IMS registration|Registered" "$DUMP" -i >/dev/null 2>&1 && found=1 || found=0

    # Более точная проверка: ищем "REGISTERED" блок
    if grep -qi "registered" "$DUMP" 2>/dev/null; then
        log_and_echo "[+] dumpsys ims показывает признаки регистрации (registered) — возможно успешно."
        success=1
        break
    fi

    # Также проверим status по wfc/volte
    if grep -Ei "WFC.*enabled|VoLTE.*enabled|wfc_ims_enabled|volte_ims_enabled" "$DUMP" >/dev/null 2>&1; then
        log_and_echo "[+] Найдены WFC/VoLTE-ключи в dumpsys (может работать) — проверяй UI/звонок."
        success=1
        break
    fi

    log_and_echo "[*] Попытка $try не выявила полной регистрации. Ждём и повторяем..."
    sleep 4
    try=$((try+1))
done

# --------------------------
# 6) Финальная валидация и подсказки
# --------------------------
log_and_echo "==== GETPROP AFTER CHANGES ====" >> "$LOGFILE"
getprop | egrep -i "ims|volte|wfc|ims_support|vendor.ims" >> "$LOGFILE" 2>&1 || true
log_and_echo "==== SETTINGS AFTER CHANGES (global) ====" >> "$LOGFILE"
{
    settings get global enhanced_4g_mode_enabled || true
    settings get global wifi_calling_enabled || true
    settings get global wfc_ims_mode || true
    settings get global wfc_ims_roaming_enabled || true
    settings get global wfc_ims_roaming_mode || true
} >> "$LOGFILE" 2>&1

# dumpsys final
FINAL_DUMP="$WORKDIR/dumpsys_ims_final_$(date +%s).txt"
dumpsys ims > "$FINAL_DUMP" 2>&1 || true

log_and_echo "[*] Скрипт завершил попытки включения VoLTE/VoWiFi (best-effort)."
log_and_echo "[*] Проверь состояние в Settings -> Network & Internet -> SIM -> (Mobile network) -> Advanced -> Wi-Fi Calling / VoLTE."
log_and_echo "[*] Если изменения не вступили — перезагрузи устройство (reboot) и проверь снова."

log_and_echo ""
log_and_echo "Бекап initial values: $BACKUP"
log_and_echo "Логи: $LOGFILE"
log_and_echo "dumpsys сохранён: $FINAL_DUMP"

# Откат (ручной) — подсказка пользователю
cat <<EOF >> "$LOGFILE"

Откат (ручной):
 - если использовался resetprop: для каждого ключа выполните "resetprop <key> <orig_value>" используя значения из $BACKUP
 - либо перезагрузите устройство, если вы применяли только setprop (runtime) — это восстановит прежние persist-значения
 - для settings: 'settings put global <key> <oldval>' по значениям из бекапа

Рекомендации:
 - Посмотри vendor лог: 'adb logcat -b all | egrep -i ims|telephony|wfc|volte'
 - Если IMS регистрируется, но не виден номер — попробуй вынуть/переустановить SIM (особенно для physical SIM).
 - Перезагрузка устройства часто решает остаточные gating'и: 'reboot'.
 - Если хочешь, могу помочь разобрать dumpsys_ims (приколи сюда файл), чтобы подобрать дополнительные persist keys для твоего оператора/прошивки.
EOF

# Вернемся с кодом 0 при успешной детекции регистрации, иначе 2
if [ "$success" -eq 1 ]; then
    log_and_echo "[+] Detected signs of IMS registration. Возвращаю 0."
    exit 0
else
    log_and_echo "[!] IMS registration not detected in best-effort attempts. Возвращаю 2."
    exit 2
fi
