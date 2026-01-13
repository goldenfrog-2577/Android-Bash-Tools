#!/data/data/com.termux/files/usr/bin/bash
# ^^^ ШЕБАНГ (Shebang). Указывает системе, какой интерпретатор использовать для запуска этого файла.
# В данном случае это bash внутри Termux.

# --- БАЗОВАЯ БЕЗОПАСНОСТЬ СКРИПТА ---
# set -u: (Unset) Скрипт немедленно остановится, если мы попытаемся использовать переменную,
# которая не была задана. Это спасает от опечаток.
set -u
# set -o pipefail: Если в цепочке команд (cmd1 | cmd2 | cmd3) хотя бы одна упадет с ошибкой,
# весь скрипт узнает об этом (вернет код ошибки), а не продолжит работу, как ни в чем не бывало.
set -o pipefail

# ====== НАСТРОЙКИ ПУТЕЙ И ФАЙЛОВ ======
# Переменная LOG хранит путь к текстовому файлу.
# Сюда мы будем дублировать все, что выводится на экран.
LOG="/data/media/0/.My Folder/logs/android_monitor_root.log"

# Временный файл. Он нужен, чтобы записать туда кусок системного лога (logcat),
# проанализировать его, а потом, возможно, перезаписать.
ERR_TEMP="/data/media/0/.My Folder/logs/last_errors.log"

# Функция show_help. Выводит инструкцию, если пользователь попросил помощи (-h).
# cat <<EOF ... EOF — это "Here Document". Позволяет выводить многострочный текст
# без кучи команд echo.
show_help() {
	cat <<EOF
=== ANDROID ROOT SYSTEM MONITOR ===

Usage:
  $(basename "$0") [options]
  # $(basename "$0") automatically expands to the script filename.

Options:
  -h, --help           Show this help message and exit
  -q, --quiet          Quiet mode: suppress terminal output (log file only)
  --no-logcat          Skip Logcat error scanning (faster execution)
  --loop <seconds>     Run monitor continuously with a delay of X seconds

Exit codes:
  0  OK (No issues detected)
  1  WARNING (Warnings detected)
  2  CRITICAL (Critical thresholds exceeded)
  3  INTERNAL ERROR (Script or argument error)

Examples:
  Run once with full output:
    $(basename "$0")

  Silent run (log only):
    $(basename "$0") --quiet

  Continuous monitoring every 30 seconds:
    $(basename "$0") --loop 30

  Skip system log analysis:
    $(basename "$0") --no-logcat

Threshold options (alert trigger levels):
  --disk-warn <percent>   Disk usage warning threshold (default: 80)
  --disk-crit <percent>   Disk usage critical threshold (default: 90)
  --ram-warn <percent>    RAM usage warning threshold (default: 80)
  --ram-crit <percent>    RAM usage critical threshold (default: 90)
  --gpu-warn <percent>    GPU load warning threshold (default: 80)
  --gpu-crit <percent>    GPU load critical threshold (default: 95)
EOF
}

# ====== EXIT CODES (КОДЫ ВОЗВРАТА) ======
# Мы даем числам понятные имена. Это хорошая практика.
# 0 обычно значит "успех", все что не 0 — ошибка или особое состояние.
EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2
EXIT_INTERNAL=3

# Переменная для хранения общего статуса "здоровья" системы.
# Изначально считаем, что все хорошо (0). Если найдем проблему, изменим это число.
SYSTEM_STATUS=$EXIT_OK

# ====== ФЛАГИ ПО УМОЛЧАНИЮ ======
# 0 — выключено, 1 — включено.
QUIET=0          # Показывать вывод на экран
NO_LOGCAT=0      # Читать логи системы
LOOP_INTERVAL=0  # 0 означает "запустить один раз и выйти"

# ====== ПОРОГИ (THRESHOLDS) ======
# Значения в процентах, при которых скрипт начнет ругаться желтым или красным.
DISK_WARN=80
DISK_CRIT=90

RAM_WARN=80
RAM_CRIT=90

# Для CPU мы используем мультипликатор. Если нагрузка выше (ядра * 1.5) — это Warning.
CPU_WARN_MULT=1.5
CPU_CRIT_MULT=2.0

GPU_WARN=80
GPU_CRIT=95

# ====== ЦВЕТА (ANSI Escape Codes) ======
# Проверяем: [ -t 1 ]. Это значит: "Запущен ли вывод (stdout) в интерактивный терминал?".
# Если да — включаем цвета. Если скрипт запущен через cron или в фоне — выключаем,
# чтобы в логах не было мусора вроде \033[0;31m.
if [ -t 1 ]; then
	RED='\033[0;31m'    # Красный
	GREEN='\033[0;32m'  # Зеленый
	YELLOW='\033[1;33m' # Желтый (жирный)
	NC='\033[0m'        # No Color (Сброс цвета на стандартный)
else
	RED='' ; GREEN='' ; YELLOW='' ; NC=''
fi

# Функция логирования. Она делает две вещи:
# 1. Выводит сообщение на экран (если не включен тихий режим).
# 2. Записывает сообщение в файл, предварительно вырезав цветовые коды.
log() {
	# date '+%H:%M:%S' — получает текущее время (Часы:Минуты:Секунды)
	ts="$(date '+%H:%M:%S')"

	# $1 — это первый аргумент, который передали функции (текст сообщения)
	if [ "$QUIET" -eq 0 ]; then
		# echo -e позволяет интерпретировать спецсимволы (цвета)
		echo -e "$ts - $1"
	fi

	# sed 's/\x1b\[[0-9;]*m//g' — это регулярное выражение, которое удаляет ANSI-коды цветов.
	# >> "$LOG" — добавляет строку в конец файла (не стирая старое).
	echo -e "$ts - $1" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG"
}

# Ротация логов: Проверяем размер файла лога.
# wc -l считает количество строк. Если их больше 1000 — стираем файл и пишем заголовок.
# Это нужно, чтобы файл не раздулся до гигабайтов.
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 1000 ]; then
	echo "--- Log rotated ---" > "$LOG" # Одинарная > перезаписывает файл с нуля
fi

# ====== ОБРАБОТКА АРГУМЕНТОВ (CLI OPTIONS) ======
# Цикл while работает, пока количество аргументов ($#) больше нуля.
while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help) # Если аргумент -h или --help
			show_help
			exit $EXIT_OK
			;;
		-q|--quiet)
			QUIET=1
			;;
		--no-logcat)
			NO_LOGCAT=1
			;;
		--loop)
			shift # Сдвигаем аргументы влево, чтобы $1 теперь указывал на ЧИСЛО после --loop
			# Проверка регулярным выражением: является ли $1 числом?
			if ! echo "$1" | grep -Eq '^[0-9]+$'; then
				echo "Invalid loop interval: $1"
				exit $EXIT_INTERNAL
			fi
			LOOP_INTERVAL="$1"
			;;
		# Обработка пользовательских порогов. Shift сдвигает очередь, чтобы забрать значение.
		--disk-warn) shift; DISK_WARN="$1"
			;;
		--disk-crit) shift; DISK_CRIT="$1"
			;;
		--ram-warn)  shift; RAM_WARN="$1"
			;;
		--ram-crit)  shift; RAM_CRIT="$1"
			;;
		--gpu-warn)  shift; GPU_WARN="$1"
			;;
		--gpu-crit)  shift; GPU_CRIT="$1"
			;;
		*) # Звездочка означает "все остальное", что не попало в фильтры выше
			echo "Unknown option: $1"
			exit $EXIT_INTERNAL
			;;
	esac
	shift # Переходим к следующему аргументу
done

# Очищаем экран терминала перед выводом (команда clear)
clear

# Главная функция мониторинга. В ней вся логика проверок.
run_monitor() {
	SYSTEM_STATUS=$EXIT_OK # Сбрасываем статус в ОК перед новой проверкой

# ====== ЗАГОЛОВОК ЛОГА ======
# Записываем разделители и дату в файл, чтобы визуально делить проверки.
echo "___________________________________________________" >> "$LOG"
echo "LOG SESSION START: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
echo "___________________________________________________" >> "$LOG"

# Создаем пустой файл ошибок, подавляя вывод ошибки, если не вышло (2>/dev/null)
touch "$ERR_TEMP" 2>/dev/null

echo "========================================"
echo "ANDROID ROOT SYSTEM MONITOR"
# getprop — команда Android для чтения системных свойств (модель, версия).
# uname -r — версия ядра Linux.
echo "Device: $(getprop ro.product.model)"
echo "Android: $(getprop ro.build.version.release)"
echo "Kernel: $(uname -r)"
echo "Time: $(date)"
echo "========================================"

# ====== 1. ХРАНИЛИЩЕ (/data) ======
echo
echo "=== STORAGE (/data) ==="
# df -h: показывает место на дисках в понятном формате (Gb, Mb).
# tail -1: берем последнюю строку вывода (где обычно /data).
# read ...: разбиваем строку на переменные.
df -h /data | tail -1 | while read -r fs size used avail percent mount; do
	use=${percent%\%} # Удаляем символ '%' из строки "85%", чтобы получить число 85

	log "Total: $size | Used: $used | Free: $avail"

	# Сравнение чисел: -ge (Greater or Equal / Больше или равно)
if [ "$use" -ge "$DISK_CRIT" ]; then
	log "${RED}CRITICAL: Usage ${percent}${NC}"
	SYSTEM_STATUS=$EXIT_CRITICAL
elif [ "$use" -ge "$DISK_WARN" ]; then
	log "${YELLOW}WARNING: Usage ${percent}${NC}"
	# Если текущий статус меньше WARNING (т.е. OK), поднимаем его до WARNING
	[ "$SYSTEM_STATUS" -lt $EXIT_WARNING ] && SYSTEM_STATUS=$EXIT_WARNING
else
	log "${GREEN}OK: Usage ${percent}${NC}"
fi
done

# ====== 2. ПАМЯТЬ (RAM) ======
echo
echo "=== MEMORY ==="
# Читаем напрямую из ядра Linux (/proc/meminfo).
# awk '{print $2}' — берет второе слово из строки (само число).
total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
# Bash не умеет в плавающую точку, но умеет в простую арифметику $((...))
used=$((total - avail))
percent=$((used * 100 / total)) # Считаем процент по школьной формуле
avail_mb=$((avail / 1024))      # Переводим КБ в МБ

if [ "$percent" -ge "$RAM_CRIT" ]; then
	log "${RED}CRITICAL: RAM ${percent}% (${avail_mb}MB free)${NC}"
	SYSTEM_STATUS=$EXIT_CRITICAL
elif [ "$percent" -ge "$RAM_WARN" ]; then
	log "${YELLOW}WARNING: RAM ${percent}% (${avail_mb}MB free)${NC}"
	[ "$SYSTEM_STATUS" -lt $EXIT_WARNING ] && SYSTEM_STATUS=$EXIT_WARNING
else
	log "${GREEN}OK: RAM ${percent}% (${avail_mb}MB free)${NC}"
fi

# ====== 3. ПРОЦЕССОР (CPU) ======
echo
echo "=== CPU ==="
# grep -c: считает количество строк (в данном случае количество ядер)
cores=$(grep -c processor /proc/cpuinfo)
# /proc/loadavg показывает среднюю нагрузку за 1, 5 и 15 минут. Берем первую ($1).
load=$(awk '{print $1}' /proc/loadavg)
log "Load: $load | Cores: $cores"

# --- АНАЛИЗ НАГРУЗКИ CPU ---
# Здесь сложность: loadavg — число дробное (напр. 2.54), а Bash понимает только целые.
# Используем awk для математического сравнения: (load > cores * multiplier).
# awk вернет 1 (истина) или 0 (ложь).
cpu_warn=$(awk -v l="$load" -v c="$cores" -v m="$CPU_WARN_MULT" 'BEGIN{print (l > c*m)}')
cpu_crit=$(awk -v l="$load" -v c="$cores" -v m="$CPU_CRIT_MULT" 'BEGIN{print (l > c*m)}')

if [ "$cpu_crit" -eq 1 ]; then
	log "${RED}CRITICAL: CPU Load ${load}${NC}"
	SYSTEM_STATUS=$EXIT_CRITICAL
elif [ "$cpu_warn" -eq 1 ]; then
	log "${YELLOW}WARNING: CPU Load ${load}${NC}"
	[ "$SYSTEM_STATUS" -lt $EXIT_WARNING ] && SYSTEM_STATUS=$EXIT_WARNING
else
	log "${GREEN}OK: CPU Load normal${NC}"
fi

# ====== 4. ТЕМПЕРАТУРА CPU ======
echo
echo "=== CPU TEMP ==="

max_temp=0

# В Android датчики температуры лежат в /sys/class/thermal/.
# Мы перебираем все зоны (thermal_zone0, thermal_zone1...)
for zone in /sys/class/thermal/thermal_zone*; do
	type=$(cat "$zone/type" 2>/dev/null) # Тип датчика (battery, cpu, gpu...)
	raw=$(cat "$zone/temp" 2>/dev/null)  # Сырое значение температуры

	# case — фильтруем только те датчики, в названии которых есть tsens или cpu
	case "$type" in
		tsens*|cpu*) ;;
		*) continue ;; # Если не подходит — пропускаем итерацию цикла
	esac

	[ -z "$raw" ] && continue # Если значение пустое — пропускаем
	temp=$((raw / 1000)) # Обычно температура хранится как 45000 (это 45 градусов)

	# Отсекаем глючные показания (меньше 15 или больше 120 градусов быть не может в норме)
	[ "$temp" -lt 15 ] || [ "$temp" -gt 120 ] && continue

	# Ищем максимум: если текущая темп. больше макс., то макс. = текущая
	if [ "$temp" -gt "$max_temp" ]; then
		max_temp="$temp"
	fi
done

# Если мы нашли хоть одну валидную температуру процессора
if [ "$max_temp" -gt 0 ]; then
	log "CPU Max Temp: ${max_temp}°C"
else
	# Если датчики процессора скрыты производителем, пытаемся взять температуру батареи
	log "CPU Temp: unavailable"
	skin=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
	if [ -n "$skin" ]; then
		skin_c=$((skin / 10)) # У батареи часто делитель 10, а не 1000
		log "SoC Temp (battery proxy): ${skin_c}°C"
	fi
fi

# ====== 5. ГРАФИЧЕСКИЙ ПРОЦЕССОР (GPU) ======
echo
echo "=== GPU MONITOR ==="
# Это самая сложная часть, так как у разных чипов (Snapdragon, MediaTek) пути разные.

# Проверяем, установлена ли утилита 'bc' (калькулятор), она нужна для точных расчетов.
BC_INSTALLED=$(command -v bc)

gpu_freq="N/A"
gpu_load="N/A"
gpu_gov="N/A"
gpu_model="Unknown"

# 1. ПОИСК ПУТЕЙ И СБОР ДАННЫХ
# Проверяем путь для Qualcomm Adreno
if [ -d /sys/class/kgsl/kgsl-3d0 ]; then
	gpu_model="Adreno (Qualcomm)"
	path="/sys/class/kgsl/kgsl-3d0"

	# Частота (делим на миллион, чтобы получить МГц)
	raw_freq=$(cat "$path/gpuclk" 2>/dev/null)
	[ -n "$raw_freq" ] && gpu_freq="$((raw_freq / 1000000)) MHz"

	# Загрузка GPU. В файле gpubusy два числа: загрузка и период. Делим одно на другое.
	gpu_load=$(cat "$path/gpubusy" 2>/dev/null | awk '{if($2>0) printf "%.1f%%", ($1/$2)*100; else print "0%"}')

	# Governor (регулятор частоты)
	gpu_gov=$(cat "$path/devfreq/governor" 2>/dev/null)

# Если Qualcomm не найден, ищем Mali (MediaTek, Exynos, Google Tensor)
elif [ -d /sys/module/mali_kbase ] || ls /sys/devices/platform/*.mali >/dev/null 2>&1; then
	# Mali может быть в разных местах, пытаемся найти путь динамически
	mali_p=$(ls -d /sys/devices/platform/*.mali 2>/dev/null | head -1)
	[ -z "$mali_p" ] && mali_p="/sys/class/misc/mali0/device" # Запасной вариант

	gpu_model="Mali (MTK/Exynos/Tensor)"

	# Перебираем возможные файлы с частотой (у разных ядер они называются по-разному)
	for f in "$mali_p/clock" "$mali_p/cur_freq" "/sys/kernel/debug/mali0/curr_freq"; do
		if [ -f "$f" ]; then
			raw_f=$(cat "$f" 2>/dev/null)
			[ -n "$raw_f" ] && [ "$raw_f" -gt 0 ] && gpu_freq="$((raw_f / 1000000)) MHz"
			break
		fi
	done

	# То же самое для загрузки (utilization)
	for f in "$mali_p/utilization" "/sys/module/mali_kbase/parameters/mali_gpu_utilization" "/sys/kernel/debug/mali0/utilization"; do
		if [ -f "$f" ]; then
			raw_l=$(cat "$f" 2>/dev/null)
			[ -n "$raw_l" ] && gpu_load="${raw_l}%"
			break
		fi
	done

	gpu_gov=$(cat "$mali_p/devfreq/governor" 2>/dev/null)
fi

# 2. ВЫВОД РЕЗУЛЬТАТОВ
if [ "$gpu_model" != "Unknown" ]; then
	log "Model:    $gpu_model"
	log "Freq:     $gpu_freq"
	log "Governor: $gpu_gov"

	# Убираем знак % для математики
	load_val=$(echo "$gpu_load" | tr -d '%')

	gpu_warn=0
	gpu_crit=0

	# Проверяем, что load_val — это число (защита от ошибок парсинга)
	if [[ "$load_val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		if [ -n "$BC_INSTALLED" ]; then
			# Если есть bc, используем его для сравнения дробей
			gpu_warn=$(echo "$load_val > $GPU_WARN" | bc)
			gpu_crit=$(echo "$load_val > $GPU_CRIT" | bc)
		else
			# Если bc нет, обрезаем дробную часть (${load_val%.*}) и сравниваем как целые
			[ "${load_val%.*}" -gt 80 ] && gpu_warn=1
			[ "${load_val%.*}" -gt 95 ] && gpu_crit=1
		fi
	fi

	if [ "$gpu_crit" -eq 1 ]; then
		log "${RED}CRITICAL: GPU Load $gpu_load${NC}"
		SYSTEM_STATUS=$EXIT_CRITICAL
	elif [ "$gpu_warn" -eq 1 ]; then
		log "${YELLOW}WARNING: GPU Load $gpu_load${NC}"
		[ "$SYSTEM_STATUS" -lt $EXIT_WARNING ] && SYSTEM_STATUS=$EXIT_WARNING
	else
		log "Load:     $gpu_load"
	fi
fi

# ====== 6. БАТАРЕЯ ======
echo
echo "=== BATTERY ==="
bat="/sys/class/power_supply/battery"
if [ -d "$bat" ]; then
	cap=$(cat "$bat/capacity") # Текущий % заряда
	status=$(cat "$bat/status") # Charging / Discharging / Full
	temp=$(( $(cat "$bat/temp") / 10 )) # Температура батареи
	# Напряжение в mV (милливольтах). Полезно для оценки здоровья батареи.
	volt=$(( $(cat "$bat/voltage_now") / 1000 ))

	log "Battery: ${cap}% | ${status} | ${temp}°C | ${volt}mV"
fi

# ====== 7. СЕТЬ ======
echo
echo "=== NETWORK ==="
# ping -c1: отправить только 1 пакет
# -W1: ждать ответа не больше 1 секунды
# 8.8.8.8: DNS Google (надежный адрес для проверки интернета)
# &>/dev/null: спрятать весь вывод команды (нам важен только код успеха/ошибки)
if ping -c1 -W1 8.8.8.8 &>/dev/null; then
	log "${GREEN}✓ Internet OK${NC}"
else
	log "${RED}✗ No Internet${NC}"
fi

# ====== 8. ОШИБКИ СИСТЕМЫ (LOGCAT) ======
echo
echo "=== LOGCAT ERRORS ==="
> "$ERR_TEMP" # Очищаем (обнуляем) временный файл

if [ "$NO_LOGCAT" -eq 1 ]; then
	log "Logcat: skipped (--no-logcat)"
else

# logcat -b ...: читаем буферы main, system и crash
# -d: вывалить текущее состояние и выйти (не ждать новых логов)
# *:E : фильтр, показывать только ошибки (Error) и фатальные сбои, игнорируя Debug/Info
# tail -n 500: берем последние 500 строк
logcat -b main,system,crash -d *:E | tail -n 500 > "$ERR_TEMP"
fi

# Если файл не пустой (-s)
if [ -s "$ERR_TEMP" ]; then
	count=$(wc -l < "$ERR_TEMP") # Считаем количество строк
	
if [ "$count" -gt 200 ]; then
	SYSTEM_STATUS=$EXIT_CRITICAL
elif [ "$count" -gt 50 ]; then
	[ "$SYSTEM_STATUS" -lt $EXIT_WARNING ] && SYSTEM_STATUS=$EXIT_WARNING
fi
	
	log "${YELLOW}⚠ Detected $count errors. Showing last 5:${NC}"
	echo "----------------------------------------"
	# awk добавляет красивую стрелочку ">" перед каждой строкой
	tail -n 5 "$ERR_TEMP" | awk '{print "  > " $0}'
	echo "----------------------------------------"
	log "Full history: cat $ERR_TEMP"
else
	log "${GREEN}No critical logcat errors detected${NC}"
fi

# ====== 9. ТОП ПРОЦЕССОВ ======
echo
echo "=== TOP PROCESSES ==="
# printf форматирует вывод колонок: %-6s (строка на 6 символов, выровнена влево)
printf "%-6s %-15s %-6s %-6s\n" "PID" "COMMAND" "%CPU" "%MEM"
echo "----------------------------------------"

# ps -Ao ...: выводит список процессов с выбранными полями.
# --sort=-%cpu: сортирует по убыванию нагрузки на CPU.
# head -n 6: берем заголовок + 5 процессов.
# tail -n +2: убираем заголовок команды ps, так как мы нарисовали свой выше.
ps -Ao pid,comm,%cpu,%mem --sort=-%cpu | head -n 6 | tail -n +2 | while read -r pid comm cpu mem; do
	# %.15s обрезает имя процесса до 15 символов, чтобы не ломать таблицу
	printf "%-6s %-15.15s %-6s %-6s\n" "$pid" "$comm" "$cpu" "$mem"
done

# ====== 10. ДИСКОВАЯ АКТИВНОСТЬ (I/O) ======
echo
echo "=== I/O ==="
# /proc/diskstats содержит сырые данные о чтениях/записях.
# Мы выдергиваем нужные столбцы (3-й название, 6-й чтения, 10-й записи).
if [ -f /proc/diskstats ]; then
	awk '{print "Disk:",$3,"Reads:",$6,"Writes:",$10}' /proc/diskstats | head -5
fi

# ====== 11. СИСТЕМНАЯ ИНФОРМАЦИЯ ======
echo
echo "=== SYSTEM INFO ==="
log "Uptime: $(uptime -p)" # Сколько времени работает телефон без перезагрузки

# Проверка Root прав. UID 0 — это всегда root (администратор).
if [ "$(id -u)" -eq 0 ]; then
	log "Root: ${GREEN}YES (UID: 0)${NC}"
else
	log "Root: ${RED}NO (Access Denied)${NC}"
fi

# SELinux: система принудительного контроля доступа. Enforcing - хорошо, Permissive - менее безопасно.
log "SELinux: $(getenforce 2>/dev/null)"
# ABI: архитектура процессора (arm64-v8a и т.д.)
log "ABI: $(getprop ro.product.cpu.abi)"

echo "========================================"
echo "Log file: $LOG"
echo "========================================"

log "Exit code: $SYSTEM_STATUS"
	return $SYSTEM_STATUS # Возвращаем код статуса из функции
}

# ====== БЛОК ЗАПУСКА ======
# Если интервал цикла задан (больше 0)
if [ "$LOOP_INTERVAL" -gt 0 ]; then
	while true; do # Бесконечный цикл
		clear # Очистка экрана
		run_monitor # Запуск основной функции
		sleep "$LOOP_INTERVAL" # Пауза перед следующим запуском
	done
else
	# Одиночный запуск
	run_monitor
	exit $? # Выходим из скрипта с кодом возврата функции run_monitor
fi
