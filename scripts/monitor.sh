#!/data/data/com.termux/files/usr/bin/bash

# ====== НАСТРОЙКИ ======
# Указываем путь к файлу, куда будут записываться все отчеты
LOG="$HOME/android_monitor_root.log"
# Временный файл для хранения последних ошибок системы
ERR_TEMP="$HOME/last_errors.log"

# ====== ЦВЕТА ======
# Если скрипт запущен в терминале, включаем цветной текст для красоты
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m' # Сброс цвета
else
    # Если запуск в фоне, отключаем цвета, чтобы не засорять лог кодами
    RED='' ; GREEN='' ; YELLOW='' ; NC=''
fi

# Функция для вывода текста на экран и одновременной записи в файл лога
log() {
    echo -e "$(date '+%H:%M:%S') - $1" | tee -a "$LOG"
}

# Очищаем экран терминала перед выводом
clear

# Создаем файл для ошибок, если его еще не существует
touch "$ERR_TEMP" 2>/dev/null

echo "========================================"
echo "ANDROID ROOT SYSTEM MONITOR"
# Получаем данные о модели, версии Android и ядре через системные команды
echo "Device: $(getprop ro.product.model)"
echo "Android: $(getprop ro.build.version.release)"
echo "Kernel: $(uname -r)"
echo "Time: $(date)"
echo "========================================"

# ====== 1. ХРАНИЛИЩЕ ======
echo
echo "=== STORAGE (/data) ==="
# Команда df проверяет место на диске. Читаем строку с разделом /data
df -h /data | tail -1 | while read -r fs size used avail percent mount; do
    use=${percent%\%} # Убираем знак % для сравнения чисел
    
    # Показываем общую статистику: Всего | Занято | Свободно
    log "Total: $size | Used: $used | Free: $avail"
    
    # Если место почти кончилось (больше 80% или 90%), выводим предупреждение
    if [ "$use" -gt 90 ]; then
        log "${RED}CRITICAL: Usage ${percent}${NC}"
    elif [ "$use" -gt 80 ]; then
        log "${YELLOW}WARNING: Usage ${percent}${NC}"
    else
        log "${GREEN}OK: Usage ${percent}${NC}"
    fi
done

# ====== 2. ПАМЯТЬ (RAM) ======
echo
echo "=== MEMORY ==="
# Берем данные о памяти из системного файла /proc/meminfo
total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
used=$((total - avail))
percent=$((used * 100 / total)) # Считаем процент занятой памяти
avail_mb=$((avail / 1024))      # Переводим свободные килобайты в мегабайты

# Если свободно меньше 10%, подсвечиваем красным
if [ "$percent" -gt 90 ]; then
    log "${RED}CRITICAL: RAM ${percent}% (${avail_mb}MB free)${NC}"
else
    log "${GREEN}OK: RAM ${percent}% (${avail_mb}MB free)${NC}"
fi

# ====== 3. ПРОЦЕССОР (CPU) ======
echo
echo "=== CPU ==="
# Считаем количество ядер и среднюю нагрузку на систему
cores=$(grep -c processor /proc/cpuinfo)
load=$(awk '{print $1}' /proc/loadavg)
log "Load: $load | Cores: $cores"

# ====== 4. ТЕМПЕРАТУРА CPU ======
echo
echo "=== CPU TEMP (SM8250) ==="

max_temp=0

# Проходим циклом по всем датчикам температуры в системе
for zone in /sys/class/thermal/thermal_zone*; do
    type=$(cat "$zone/type" 2>/dev/null)
    raw=$(cat "$zone/temp" 2>/dev/null)

    # Ищем только те, что относятся к процессору (tsens или cpu)
    case "$type" in
        tsens*|cpu*) ;;
        *) continue ;;
    esac

    [ -z "$raw" ] && continue
    temp=$((raw / 1000)) # Переводим из миллиградусов в обычные градусы

    # Игнорируем ошибочные данные (слишком холодные или горячие)
    [ "$temp" -lt 15 ] || [ "$temp" -gt 120 ] && continue

    # Запоминаем самую высокую температуру среди всех ядер
    if [ "$temp" -gt "$max_temp" ]; then
        max_temp="$temp"
    fi
done

# Если датчики процессора недоступны, берем температуру батареи как запасной вариант
if [ "$max_temp" -gt 0 ]; then
    log "CPU Max Temp: ${max_temp}°C"
else
    log "CPU Temp: unavailable"
    skin=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
    if [ -n "$skin" ]; then
        skin_c=$((skin / 10))
        log "SoC Temp (battery proxy): ${skin_c}°C"
    fi
fi

# ====== 5. БАТАРЕЯ ======
echo
echo "=== BATTERY ==="
bat="/sys/class/power_supply/battery"
if [ -d "$bat" ]; then
    cap=$(cat "$bat/capacity") # Процент заряда
    status=$(cat "$bat/status") # Статус (заряжается/разряжается)
    temp=$(( $(cat "$bat/temp") / 10 )) # Температура аккумулятора
    # Считываем реальное напряжение в милливольтах (помогает при износе АКБ)
    volt=$(( $(cat "$bat/voltage_now") / 1000 ))
    
    log "Battery: ${cap}% | ${status} | ${temp}°C | ${volt}mV"
fi

# ====== 6. СЕТЬ ======
echo
echo "=== NETWORK ==="
# Проверяем связь с интернетом, отправляя один пакет на сервер Google
if ping -c1 -W1 8.8.8.8 &>/dev/null; then
    log "${GREEN}✓ Internet OK${NC}"
else
    log "${RED}✗ No Internet${NC}"
fi

# ====== 7. ОШИБКИ СИСТЕМЫ (LOGCAT) ======
echo
echo "=== LOGCAT ERRORS ==="
> "$ERR_TEMP" # Очищаем файл перед новой записью

# Собираем последние 500 критических ошибок (Level: Error) из системного лога
logcat -b main,system,crash -d *:E | tail -n 500 > "$ERR_TEMP"

if [ -s "$ERR_TEMP" ]; then
    count=$(wc -l < "$ERR_TEMP") # Считаем, сколько строк с ошибками найдено
    log "${YELLOW}⚠ Detected $count errors. Showing last 5:${NC}"
    echo "----------------------------------------"
    # Показываем последние 5 строк, чтобы не забивать экран
    tail -n 5 "$ERR_TEMP" | awk '{print "  > " $0}'
    echo "----------------------------------------"
    log "Full history: cat $ERR_TEMP"
else
    log "${GREEN}No critical logcat errors detected${NC}"
fi

# ====== 8. ТОП ПРОЦЕССОВ ======
echo
echo "=== TOP PROCESSES ==="
# Рисуем красивую шапку таблицы (выравнивание по колонкам)
printf "%-7s %-15s %-6s %-6s\n" "PID" "COMMAND" "%CPU" "%MEM"
echo "----------------------------------------"

# Выводим 5 самых «тяжелых» процессов по потреблению процессора
ps -Ao pid,comm,%cpu,%mem --sort=-%cpu | head -n 6 | tail -n +2 | while read -r pid comm cpu mem; do
    printf "%-7s %-15.15s %-6s %-6s\n" "$pid" "$comm" "$cpu" "$mem"
done

# ====== 9. ДИСКОВАЯ АКТИВНОСТЬ (I/O) ======
echo
echo "=== I/O ==="
# Читаем статистику чтений и записей на диск из ядра
if [ -f /proc/diskstats ]; then
    awk '{print "Disk:",$3,"Reads:",$6,"Writes:",$10}' /proc/diskstats | head -5
fi

# ====== 10. СИСТЕМНАЯ ИНФОРМАЦИЯ ======
echo
echo "=== SYSTEM INFO ==="
log "Uptime: $(uptime -p)" # Время работы с момента включения

# Честная проверка Root: проверяем, равен ли ID пользователя нулю
if [ "$(id -u)" -eq 0 ]; then
    log "Root: ${GREEN}YES (UID: 0)${NC}"
else
    log "Root: ${RED}NO (Access Denied)${NC}"
fi

# Показываем статус безопасности SELinux и архитектуру процессора
log "SELinux: $(getenforce 2>/dev/null)"
log "ABI: $(getprop ro.product.cpu.abi)"

echo "========================================"
echo "Log file: $LOG"
echo "========================================"
