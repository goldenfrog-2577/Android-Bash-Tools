#!/data/data/com.termux/files/usr/bin/bash
# ^ Это shebang. Он указывает системе, какой интерпретатор использовать для запуска скрипта. В данном случае это bash, находящийся в папке Termux.

# set -u: Заставляет скрипт завершаться с ошибкой, если мы пытаемся использовать переменную, которая не была задана. Это помогает избежать скрытых багов.
set -u
# set -o pipefail: Если в цепочке команд (pipeline, например cmd1 | cmd2) одна из команд упадет, то весь скрипт вернет ошибку, а не только последняя команда.
set -o pipefail

# Пути к файлам логов.
# LOG: основной лог мониторинга.
# ERR_LOG: временный файл для ошибок из системного журнала (logcat).
LOG="/data/media/0/.My Folder/logs/android_monitor.log"
ERR_LOG="/data/media/0/.My Folder/logs/last_errors.log"

# Коды выхода (Exit Codes). Это стандартизация того, как скрипт сообщает системе о результате работы.
# 0 - все хорошо, >0 - ошибки или предупреждения.
EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2
EXIT_INTERNAL=3

# Переменная текущего статуса системы. По умолчанию считаем, что все хорошо (0).
SYSTEM_STATUS=$EXIT_OK

# Настройки по умолчанию (флаги).
# 0 означает "выключено" или "нет", 1 будет означать "включено".
QUIET=0          # Тихий режим (без вывода в консоль)
NO_LOGCAT=0      # Не сканировать ошибки logcat (для ускорения)
LOOP_INTERVAL=0  # Интервал повторения скрипта (0 = запустить один раз)

# Пороговые значения (Thresholds) для срабатывания предупреждений.
# Если использование выше этих чисел, скрипт выдаст WARN или CRIT.
DISK_WARN=80     # Диск: предупреждение при 80%
DISK_CRIT=90     # Диск: критическое состояние при 90%
RAM_WARN=80      # ОЗУ: предупреждение при 80%
RAM_CRIT=90      # ОЗУ: критическое состояние при 90%
CPU_WARN_MULT=1.5 # Множитель нагрузки ЦП для предупреждения
CPU_CRIT_MULT=2.0 # Множитель нагрузки ЦП для критического состояния
GPU_WARN=80      # GPU: предупреждение при 80%
GPU_CRIT=95      # GPU: критическое состояние при 95%

# Проверяем, запущен ли скрипт в интерактивном терминале.
# [ -t 1 ] проверяет, открыт ли стандартный вывод (дескриптор 1) в терминале.
if [ -t 1 ]; then
	# Если да, задаем переменные для цветов текста (ANSI escape codes).
	RED='\033[0;31m'    # Красный
	GREEN='\033[0;32m'  # Зеленый
	YELLOW='\033[0;33m' # Желтый
	NC='\033[0m'        # No Color (сброс цвета)
else
	# Если скрипт запущен, например, через cron или перенаправлен в файл, отключаем цвета, чтобы в файле не было "мусора" из спецсимволов.
	RED='' ; GREEN='' ; YELLOW='' ; NC=''
fi

# Функция для вывода текста на экран.
# Используется вместо обычного echo/printf, чтобы учитывать настройку QUIET.
out_printf() {
	# [ "$QUIET" -eq 0 ] - если тихий режим ВЫКЛЮЧЕН (равен 0),
	# && (тогда) выполняем команду printf. "$@" означает "все переданные аргументы".
	[ "$QUIET" -eq 0 ] && printf "$@"
}

# Функция логирования. Пишет и на экран, и в файл.
log() {
	# Получаем текущее время в формате ЧЧ:ММ:СС.
	ts="$(date '+%H:%M:%S')"
	# Если не тихий режим, выводим на экран с временем.
	[ "$QUIET" -eq 0 ] && echo -e "$ts - $1"  
	# Пишем в файл лога ($LOG).
	# sed 's/\x1b\[[0-9;]*m//g' удаляет цветовые коды, чтобы лог был чистым текстом.
	# >> означает "дописать в конец файла", а не перезаписать его.
	echo -e "$ts - $1" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG"
}

# Функция помощи (Help).
# cat <<EOF ... EOF - это Here Document, позволяет вывести многострочный текст.
show_help() {
	cat <<EOF
=== ANDROID ROOT SYSTEM MONITOR ===

Usage:
  Usage:
  $(basename "$0") [options]
  # $(basename "$0") automatically expands to the script filename

Options:
  -h, --help              Show this help message and exit
  -q, --quiet             Quiet mode: suppress terminal output (log file only)
  -n, --no-logcat         Skip Logcat error scanning (faster execution)
  -l, --loop <seconds>    Run monitor continuously with a delay of X seconds
  -c, --clear-log         Clear the content of the log file without deleting it
    

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

# Функция ротации логов.
# Чтобы файл лога не стал бесконечно огромным, мы его очищаем, если он слишком длинный.
rotate_log() {
	# Если файл существует (-f) И количество строк (wc -l) больше 1000...
	if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 1000 ]; then
		# ...то перезаписываем файл (>) одной строкой.
		echo "--- Log rotated ---" > "$LOG"
	fi
}

# Вывод шапки с информацией об устройстве.
print_header() {
	local slot
	# getprop - команда Android для получения системных свойств.
	# Здесь узнаем активный слот загрузки (A или B).
	slot="$(getprop ro.boot.slot_suffix)"
	# Если слот пустой (-z), пишем "unknown".
	[ -z "$slot" ] && slot="unknown"
	
	# Получаем кодовое имя устройства (например, alioth)
	codename="$(getprop ro.product.device)"
	[ -z "$codename" ] && codename="unknown"

	echo "========================================"
	echo "ANDROID ROOT SYSTEM MONITOR"
	echo "Device: $(getprop ro.product.model) ($codename)"       # Модель телефона
	echo "Android: $(getprop ro.build.version.release)" # Версия Android
	echo "Kernel: $(uname -r)"                        # Версия ядра Linux
	echo "Active slot: $slot"
	echo "Time: $(date)"
	echo "========================================"
}

# Подсказка для тихого режима.
quiet_hint() {
	# Если включен тихий режим, напоминаем пользователю проверить лог-файл.
	[ "$QUIET" -eq 1 ] && echo "Check details in log file: $LOG" && echo
}

# Проверка места на накопителе (/data).
check_storage() {
    local use size used avail percent _
	echo
	echo "=== STORAGE (/data) ==="
	quiet_hint

	# Читаем вывод df.
	df -h /data | tail -1 | while read -r _ size used avail percent _; do
		use=${percent%\%} 
		
		# Красивое форматирование: заменяем 'G' на ' GB', чтобы было "106 GB" вместо "106G"
		# Используем Bash-замену: ${переменная//что/на_что}
		local f_size=${size//G/ GB}
		local f_used=${used//G/ GB}
		local f_avail=${avail//G/ GB}

		log "Total: $f_size | Used: $f_used | Free: $f_avail"

		if [ "$use" -ge "$DISK_CRIT" ]; then
			log "${RED}CRITICAL: Usage ${percent}${NC}"
			SYSTEM_STATUS=$EXIT_CRITICAL
		elif [ "$use" -ge "$DISK_WARN" ]; then
			log "${YELLOW}WARNING: Usage ${percent}${NC}"
			[ "$SYSTEM_STATUS" -lt $EXIT_WARNING ] && SYSTEM_STATUS=$EXIT_WARNING
		else
			log "${GREEN}OK: Usage ${percent}${NC}"
		fi
	done
}

# Проверка оперативной памяти (RAM).
check_memory() {
    local total avail used percent avail_mb total_gb
    local z_total z_free z_used
	echo
	echo "=== MEMORY ==="
	quiet_hint

	# Читаем данные из системного файла /proc/meminfo
	total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
	avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
	
	# Вычисляем общий объем в ГБ (с одной цифрой после запятой через awk для красоты)
	total_gb=$(awk "BEGIN {printf \"%.1f\", $total / 1024 / 1024}")
	
	# Выводим общую информацию
	log "Total RAM: ${total_gb} GB"
	
    # Zram & Swap
	z_total=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
	z_free=$(awk '/SwapFree/ {print $2}' /proc/meminfo)
	
	if [ "$z_total" -gt 0 ]; then
		z_used=$(( (z_total - z_free) / 1024 ))
		z_total_mb=$(( z_total / 1024 ))
		log "ZRAM: ${z_used} MB used / ${z_total_mb} MB total"
	fi

	# Математические вычисления
	used=$((total - avail))
	percent=$((used * 100 / total)) 
	avail_mb=$((avail / 1024))      

	# Логика проверки порогов
	if [ "$percent" -ge "$RAM_CRIT" ]; then
		log "${RED}CRITICAL: RAM ${percent}% (${avail_mb}MB free)${NC}"
		SYSTEM_STATUS=$EXIT_CRITICAL
	elif [ "$percent" -ge "$RAM_WARN" ]; then
		log "${YELLOW}WARNING: RAM ${percent}% (${avail_mb}MB free)${NC}"
		[ "$SYSTEM_STATUS" -lt $EXIT_WARNING ] && SYSTEM_STATUS=$EXIT_WARNING
	else
		log "${GREEN}OK: RAM ${percent}% (${avail_mb}MB free)${NC}"
	fi
}

# Проверка загрузки процессора (CPU).
check_cpu() {
    local cores load warn crit
	echo
	echo "=== CPU ==="
	quiet_hint
	
	# Получаем имя процессора из свойств системы
	cpu_name=$(getprop ro.soc.model)
	[ -z "$cpu_name" ] && cpu_name=$(getprop ro.board.platform)
	
	cores=$(grep -c processor /proc/cpuinfo)
	load=$(awk '{print $1}' /proc/loadavg)

	# Считаем количество ядер процессора. grep -c считает строки.
	cores=$(grep -c processor /proc/cpuinfo)
	# Читаем среднюю загрузку (Load Average) за последнюю минуту из /proc/loadavg.
	load=$(awk '{print $1}' /proc/loadavg)
	log "Model: $cpu_name"
	log "Load: $load | Cores: $cores"

	# Bash не умеет сравнивать дробные числа (float), поэтому используем awk.
	# Если load > cores * multiplier, возвращаем 1, иначе 0.
	warn=$(awk -v l="$load" -v c="$cores" -v m="$CPU_WARN_MULT" 'BEGIN{print (l > c*m)}')
	crit=$(awk -v l="$load" -v c="$cores" -v m="$CPU_CRIT_MULT" 'BEGIN{print (l > c*m)}')

	if [ "$crit" -eq 1 ]; then
		log "${RED}CRITICAL: CPU Load $load${NC}"
		SYSTEM_STATUS=$EXIT_CRITICAL
	elif [ "$warn" -eq 1 ]; then
		log "${YELLOW}WARNING: CPU Load $load${NC}"
		[ "$SYSTEM_STATUS" -lt $EXIT_WARNING ] && SYSTEM_STATUS=$EXIT_WARNING
	else
		log "${GREEN}OK: CPU Load normal${NC}"
	fi
}

# Проверка температуры процессора.
check_cpu_temp() {
    local max=0 z type raw t b
	echo
	echo "=== CPU TEMP ==="
	quiet_hint

	max=0
	# Перебираем все термальные зоны в системе.
	for z in /sys/class/thermal/thermal_zone*; do
		# 2>/dev/null подавляет ошибки, если файл не читается.
		type=$(cat "$z/type" 2>/dev/null)
		raw=$(cat "$z/temp" 2>/dev/null)
		
		# Фильтруем только зоны, связанные с CPU или tsens.
		# case ... esac - это аналог switch.
		case "$type" in tsens*|cpu*) ;; *) continue ;; esac
		
		# Если данных нет, пропускаем шаг цикла.
		[ -z "$raw" ] && continue
		
		# Обычно температура хранится в тысячных долях (45000 = 45C). Делим на 1000.
		t=$((raw / 1000))
		
		# Отсеиваем нереалистичные значения (глюки датчиков): меньше 15 или больше 120 градусов.
		[ "$t" -lt 15 ] || [ "$t" -gt 120 ] && continue
		
		# Ищем максимальную температуру среди всех ядер.
		[ "$t" -gt "$max" ] && max="$t"
	done

	if [ "$max" -gt 0 ]; then
		log "CPU Max Temp: ${max}°C"
	else
		# Если не нашли температуру CPU, пробуем взять температуру батареи как прокси.
		log "CPU Temp: unavailable"
		b=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
		# Температура батареи часто хранится в десятых долях (350 = 35.0C). Делим на 10.
		[ -n "$b" ] && log "SoC Temp (battery proxy): $((b/10))°C"
	fi
}

# Проверка видеоядра (GPU). Самая сложная часть, так как пути зависят от производителя (Qualcomm vs MediaTek и др.).
check_gpu() {
	echo
	echo "=== GPU MONITOR ==="
	quiet_hint

	local BC_INSTALLED gpu_model gpu_freq gpu_load gpu_gov
	# Проверяем, установлена ли утилита 'bc' (калькулятор), нужна для точных вычислений.
	BC_INSTALLED=$(command -v bc 2>/dev/null)

	gpu_model="Unknown"
	gpu_freq="N/A"
	gpu_load="N/A"
	gpu_gov="N/A"

	# --- Ветка для Adreno (процессоры Qualcomm Snapdragon) ---
	if [ -d /sys/class/kgsl/kgsl-3d0 ]; then
		gpu_model="Adreno (Qualcomm)"
		local path="/sys/class/kgsl/kgsl-3d0"

		local raw_freq
		raw_freq=$(cat "$path/gpuclk" 2>/dev/null)
		# Конвертируем Гц в МГц.
		[ -n "$raw_freq" ] && gpu_freq="$((raw_freq / 1000000)) MHz"

		# Вычисляем нагрузку через файл gpubusy (время работы / общее время).
		gpu_load=$(awk '{if($2>0) printf "%.1f%%", ($1/$2)*100; else print "0%"}' "$path/gpubusy" 2>/dev/null)
		gpu_gov=$(cat "$path/devfreq/governor" 2>/dev/null)

	# --- Ветка для Mali (процессоры MediaTek, Exynos, Google Tensor) ---
	elif ls /sys/devices/platform/*mali* >/dev/null 2>&1 || [ -d /sys/module/mali_kbase ]; then
		gpu_model="Mali (MediaTek / Exynos / Tensor)"

		local mali_path
		# Пытаемся найти папку драйвера Mali.
		mali_path=$(ls -d /sys/devices/platform/*mali* 2>/dev/null | head -1)
		[ -z "$mali_path" ] && mali_path="/sys/class/misc/mali0/device"

		# Ищем файл с частотой (перебираем возможные варианты путей).
		for f in \
			"$mali_path/cur_freq" \
			"$mali_path/clock" \
			"/sys/kernel/debug/mali0/curr_freq"
		do
			if [ -f "$f" ]; then
				local raw_f
				raw_f=$(cat "$f" 2>/dev/null)
				[ -n "$raw_f" ] && [ "$raw_f" -gt 0 ] && gpu_freq="$((raw_f / 1000000)) MHz"
				break
			fi
		done

		# Ищем файл с загрузкой (utilization).
		for f in \
			"$mali_path/utilization" \
			"/sys/module/mali_kbase/parameters/mali_gpu_utilization" \
			"/sys/kernel/debug/mali0/utilization"
		do
			if [ -f "$f" ]; then
				local raw_l
				raw_l=$(cat "$f" 2>/dev/null)
				[ -n "$raw_l" ] && gpu_load="${raw_l}%"
				break
			fi
		done

		gpu_gov=$(cat "$mali_path/devfreq/governor" 2>/dev/null)
	fi

	# Если модель не определена, выходим из функции.
	[ "$gpu_model" = "Unknown" ] && { log "GPU: unavailable"; return; }

	log "Model:    $gpu_model"
	log "Freq:     $gpu_freq"
	log "Governor: $gpu_gov"

	# Обработка порогов нагрузки GPU.
	local load_val gpu_warn gpu_crit
	load_val=$(echo "$gpu_load" | tr -d '%') # Убираем знак %
	gpu_warn=0
	gpu_crit=0

	# Проверяем, является ли значение числом (включая дробные).
	if [[ "$load_val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		if [ -n "$BC_INSTALLED" ]; then
			# Если есть bc, сравниваем дробные числа.
			gpu_warn=$(echo "$load_val > $GPU_WARN" | bc)
			gpu_crit=$(echo "$load_val > $GPU_CRIT" | bc)
		else
			# Иначе сравниваем целую часть (отбрасываем дробь через ${var%.*}).
			[ "${load_val%.*}" -gt "$GPU_WARN" ] && gpu_warn=1
			[ "${load_val%.*}" -gt "$GPU_CRIT" ] && gpu_crit=1
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
}

# Проверка батареи.
check_battery() {
	echo
	echo "=== BATTERY & HEALTH ==="
	quiet_hint

	# Объявляем локальные переменные для безопасности
	local b="/sys/class/power_supply/battery"
	local cap status temp volt health cycles health_pct

	# Если папка не существует, выходим
	[ ! -d "$b" ] && log "Battery data: unavailable" && return

	# Собираем базовые данные
	cap=$(cat "$b/capacity" 2>/dev/null)
	status=$(cat "$b/status" 2>/dev/null)
	temp=$(( $(cat "$b/temp" 2>/dev/null) / 10 ))
	volt=$(( $(cat "$b/voltage_now" 2>/dev/null) / 1000 ))
	
	# Собираем данные об износе
	health=$(cat "$b/health" 2>/dev/null)
	cycles=$(cat "$b/cycle_count" 2>/dev/null)
	[ -z "$cycles" ] && cycles="N/A"

	# Пытаемся рассчитать состояние в % (если система отдает данные о емкости)
	# charge_full (текущая макс. емкость) / charge_full_design (заводская емкость)
	local full=$(cat "$b/charge_full" 2>/dev/null)
	local design=$(cat "$b/charge_full_design" 2>/dev/null)
	
	if [ -n "$full" ] && [ -n "$design" ] && [ "$design" -gt 0 ]; then
		health_pct=$(( full * 100 / design ))
		health="$health ($health_pct%)"
	fi

	# Вывод информации
	log "Status:   $status ($cap%)"
	log "Health:   $health"
	log "Cycles:   $cycles"
	log "Temp:     ${temp}°C"
	log "Voltage:  ${volt}mV"

	# Проверка на критический перегрев батареи
	if [ "$temp" -gt 45 ]; then
		log "${RED}WARNING: Battery overheating! (${temp}°C)${NC}"
		[ "$SYSTEM_STATUS" -lt $EXIT_WARNING ] && SYSTEM_STATUS=$EXIT_WARNING
	fi
}

# Проверка интернета.
check_network() {
	echo
	echo "=== NETWORK ==="
	quiet_hint

	# Пингуем Google DNS (8.8.8.8).
	# -c1: один пакет. -W1: ждать ответа максимум 1 секунду.
	# &>/dev/null: скрываем весь вывод команды ping.
	if ping -c1 -W1 8.8.8.8 &>/dev/null; then
		log "${GREEN}✓ Internet OK${NC}"
	else
		log "${RED}✗ No Internet${NC}"
	fi
}

# Анализ ошибок в системном журнале Android (logcat).
check_logcat() {
    local c s
	echo
	echo "=== LOGCAT ERRORS ==="
	> "$ERR_LOG" # Очищаем файл ошибок перед записью.

	# Если включен флаг пропуска (-n), выходим.
	[ "$NO_LOGCAT" -eq 1 ] && log "Logcat: skipped (--no-logcat)" && return

	# logcat -d: дамп (вывод текущего состояния и выход).
	# *:E означает "все теги с приоритетом Error или выше".
	# tail -n 500: берем последние 500 ошибок.
	logcat -b main,system,crash -d *:E | tail -n 500 > "$ERR_LOG"

	# Если файл пустой (-s проверяет, что размер > 0), значит ошибок нет.
	[ ! -s "$ERR_LOG" ] && log "${GREEN}No critical logcat errors detected${NC}" && return

	# Считаем количество строк ошибок.
	c=$(wc -l < "$ERR_LOG")
	# Если ошибок очень много (>200), ставим статус Critical.
	[ "$c" -gt 200 ] && SYSTEM_STATUS=$EXIT_CRITICAL
	[ "$c" -gt 50 ] && [ "$SYSTEM_STATUS" -lt $EXIT_WARNING ] && SYSTEM_STATUS=$EXIT_WARNING
	
	# Определяем, сколько строк показать в превью (максимум 5 или сколько есть, если меньше).
	s=5; [ "$c" -lt 5 ] && s="$c"

	log "${YELLOW}⚠ Detected $c errors. Showing last $s:${NC}"
	echo "----------------------------------------"
	# Показываем последние s строк, добавляя "> " в начало каждой для красоты.
	tail -n "$s" "$ERR_LOG" | while read -r line; do
        log "  > $line"
    done
	echo "----------------------------------------"
	log "Full history: cat $ERR_LOG"
}

# Вывод топ процессов по потреблению CPU.
print_top() {
    local p c cpu m
	echo
	echo "=== TOP PROCESSES ==="
	quiet_hint

	# Форматированный вывод заголовка таблицы.
	out_printf "%-6s %-15s %-6s %-6s\n" "PID" "COMMAND" "%CPU" "%MEM"
	echo "----------------------------------------"
	# ps: команда для списка процессов.
	# -Ao ...: задаем нужные колонки.
	# --sort=-%cpu: сортируем по убыванию CPU.
	# head -n 6: берем топ 6 (1 заголовок + 5 процессов).
	# tail -n +2: пропускаем первую строку (заголовок ps), так как мы напечатали свой.
	ps -Ao pid,comm,%cpu,%mem --sort=-%cpu | head -n 6 | tail -n +2 |
	while read -r p c cpu m; do
		# Печатаем каждую строку красиво выровненной.
		out_printf "%-6s %-15.15s %-6s %-6s\n" "$p" "$c" "$cpu" "$m"
	done
}

# Статистика ввода/вывода (I/O).
print_io() {
	echo
	echo "=== I/O (Storage Usage) ==="
	quiet_hint

	# Проверяем, существует ли файл статистики дисков ядра.
	if [ ! -f /proc/diskstats ]; then
		log "Error: /proc/diskstats not found"
		return
	fi

	# Печатаем красивую шапку таблицы.
	# %-10s означает "выделить 10 символов и выровнять по левому краю".
	out_printf "%-10s %-12s %-12s\n" "DEVICE" "READ (MB)" "WRITE (MB)"
	echo "----------------------------------------"

	# Запускаем awk для обработки файла.
	awk '
	{
		# $3 - это имя устройства (например, mmcblk0, loop1, dm-0).
		
		# Фильтрация (RegEx):
		# ^(mmcblk[0-9]+ : Ищет основные чипы памяти (внутренняя память).
		# |sd[a-z]+      : Ищет SCSI/UFS диски (иногда внутренняя память или OTG флешки).
		# |dm-[0-9]+)    : Ищет Device Mapper (зашифрованные разделы Android, например Userdata).
		# Мы специально НЕ ищем "p[0-9]", чтобы не выводить каждый мелкий раздел, а только диск целиком.
		if ($3 ~ /^(mmcblk[0-9]+|sd[a-z]+|dm-[0-9]+)$/) {
			
			# $6 - количество прочитанных секторов.
			# $10 - количество записанных секторов.
			# Сектор обычно равен 512 байтам.
			# Формула: (Секторы * 512) / 1024 / 1024 = Мегабайты.
			# Упрощенно: Секторы / 2048 = Мегабайты.
			
			read_mb = $6 / 2048
			write_mb = $10 / 2048
			
			# Печатаем данные. %.1f означает "число с одной цифрой после запятой".
			printf "%-10s %-12.1f %-12.1f\n", $3, read_mb, write_mb
		}
	}
	' /proc/diskstats
}


# Вспомогательная функция для получения "бэкенда" (реального устройства) точки монтирования.
get_backend_from_mountinfo() {
	local mp="$1"

	# Парсим /proc/self/mountinfo, чтобы найти, какое физическое устройство смонтировано в эту папку.
	awk -v m="$mp" '
		$5 == m {
			for (i = 1; i <= NF; i++) {
				if ($i == "-") {
					print $(i+2) # Поле после "-" и типа ФС содержит источник.
					exit
				}
			}
		}
	' /proc/self/mountinfo
}

# Функция поиска реальной точки монтирования для имени раздела (например, system).
find_mountpoint() {
	local part="$1"

	# Сначала ищем простое совпадение (например /data).
	mp=$(awk -v p="/$part" '$5 == p {print $5}' /proc/self/mountinfo | head -1)
	[ -n "$mp" ] && echo "$mp" && return

	# Если это раздел system, тут все сложнее из-за system-as-root в новых Android.
	if [ "$part" = "system" ]; then
		mp=$(awk '
			$5 ~ /system_root/ {
				for (i = 1; i <= NF; i++) {
					if ($i == "-" && $(i+2) ~ /dm-/) {
						print $5
						exit
					}
				}
			}
		' /proc/self/mountinfo)
		[ -n "$mp" ] && echo "$mp" && return
	fi

	return 1
}

# Детальная проверка разделов системы.
check_partitions() {
	echo
	echo "=== SYSTEM PARTITIONS ==="
	quiet_hint

	out_printf "%-12s %-28s %8s %8s %8s\n" "PARTITION" "MOUNT POINT" "SIZE" "USED" "FREE"
	out_printf "%-12s %-28s %8s %8s %8s\n" "----------" "----------------------------" "--------" "--------" "--------"

	# Список разделов для проверки.
	local parts=(
		system
		system_ext
		product
		vendor
		odm
		cache
		data
		metadata
		apex
		persist
	)

	for part in "${parts[@]}"; do
	local mp df_line size used free backend

	# Ищем, куда смонтирован раздел.
	mp=$(find_mountpoint "$part")
	[ -z "$mp" ] && continue # Если не нашли, пропускаем.

	# Получаем данные df (disk free) для этой точки.
	df_line=$(df -h "$mp" 2>/dev/null | awk 'NR==2')
	[ -z "$df_line" ] && continue

	size=$(echo "$df_line" | awk '{print $2}')
	used=$(echo "$df_line" | awk '{print $3}')
	free=$(echo "$df_line" | awk '{print $4}')

	# Получаем техническое имя устройства.
	backend="$(get_backend_from_mountinfo "$mp")"
	[ -z "$backend" ] && backend="unknown"

	# Выводим в таблицу.
	out_printf "%-12s %-28s %8s %8s %8s\n" \
		"$part" "$mp" "$size" "$used" "$free"

	# Пишем в лог.
	log "Mounted at $mp -> $backend | Size: $size | Used: $used | Free: $free"
	done
}

# Определение метода Root-прав.
detect_root_method() {
	# Проверяем наличие команды magisk.
	if command -v magisk >/dev/null 2>&1; then
		echo "Magisk"
		return
	fi

	# Проверяем стандартные папки Magisk.
	if [ -d /sbin/.magisk ] || [ -d /data/adb/magisk ]; then
		echo "Magisk"
		return
	fi

	# Проверяем признаки KernelSU (файлы устройств или версия ядра).
	if [ -e /dev/kernelsu ] || \
		[ -e /sys/kernel/kernelsu ] || \
		grep -q kernelsu /proc/version 2>/dev/null; then
		echo "KernelSU"
		return
	fi

	# Если ничего не нашли, но uid=0 (суперпользователь), значит рут есть, но неизвестный.
	[ "$(id -u)" -eq 0 ] && echo "Root (unknown)" || echo "No Root"
}

# Получение версии Magisk.
get_magisk_version() {
	if command -v magisk >/dev/null 2>&1; then
		magisk -v 2>/dev/null | cut -d':' -f1
		return
	fi

	if [ -f /data/adb/magisk/magisk_version ]; then
		cat /data/adb/magisk/magisk_version 2>/dev/null
		return
	fi

	echo "unknown"
}

# Проверка статуса Zygisk (модуль Magisk для инъекции кода в процессы).
get_zygisk_status() {
	if [ "$(getprop persist.magisk.zygisk 2>/dev/null)" = "1" ]; then
		echo "Enabled"
	elif [ -d /data/adb/zygisk ]; then
		echo "Enabled"
	else
		echo "Disabled"
	fi
}

# Вывод общей информации о системе.
print_system() {
	echo
	echo "=== SYSTEM INFO ==="
	quiet_hint

	log "Uptime: $(uptime -p)" # Время работы без перезагрузки.

	# Если скрипт запущен от рута (id 0).
	if [ "$(id -u)" -eq 0 ]; then
		root_method="$(detect_root_method)"
		log "Root: ${GREEN}YES${NC}"
		log "System Access Level: $(detect_root_method) $(get_magisk_version)"
		log "Zygisk: $(get_zygisk_status)"
	else
		log "Root: ${RED}NO${NC}"
	fi

	log "SELinux: $(getenforce 2>/dev/null)" # Статус безопасности SELinux (Enforcing/Permissive).
	log "ABI: $(getprop ro.product.cpu.abi)" # Архитектура процессора (например, arm64-v8a).
}

check_pixel_security() {
	# Объявляем локальную переменную для вендора
	local vendor
	# Получаем производителя и переводим в нижний регистр для надежного сравнения
	vendor=$(getprop ro.product.manufacturer | tr '[:upper:]' '[:lower:]')
	
	# Если в имени производителя нет "google", тихо выходим из функции
	[[ "$vendor" != *"google"* ]] && return

	echo
	echo "=== GOOGLE TITAN SECURITY ==="
	quiet_hint

	# Объявляем локальные переменные для работы внутри функции
	local titan_status hardware_level
	
	# Проверяем уровень аппаратной защиты Keymaster
	hardware_level=$(getprop ro.hardware.keystore_impl 2>/dev/null)
	[ -z "$hardware_level" ] && hardware_level="unknown"

	# Проверка StrongBox через системный лог (признак активности Titan M/M2)
	if logcat -d | grep -qi "StrongBox" ; then
		titan_status="${GREEN}Active (StrongBox detected)${NC}"
	else
		titan_status="${YELLOW}Standby / Not detected${NC}"
	fi

	log "Titan Chip:      $titan_status"
	log "Keystore Impl:   $hardware_level"
	
	# Проверяем состояние Verified Boot (green/yellow/orange/red)
	log "Verified Boot:   $(getprop ro.boot.verifiedbootstate 2>/dev/null)"
}

# Главная функция (точка входа в логику).
main() {
    local root_method
	SYSTEM_STATUS=$EXIT_OK
	rotate_log
	touch "$ERR_LOG" 2>/dev/null # Создаем пустой файл ошибок, если нет.

	# Пишем разделитель начала сессии в лог.
	echo "___________________________________________________" >> "$LOG"
	echo "LOG SESSION START: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
	echo "___________________________________________________" >> "$LOG"

	# Запускаем все проверки по очереди.
	print_header
	check_storage
	check_memory
	check_cpu
	check_cpu_temp
	check_gpu
	check_battery
	check_network
	check_logcat
	print_top
	print_io
	check_partitions
	check_pixel_security
	print_system

	echo "========================================"
	echo "Log file: $LOG"
	echo "========================================"

	log "Exit code: $SYSTEM_STATUS"
	return "$SYSTEM_STATUS"
}

# Обработка аргументов командной строки.
# $# - количество переданных аргументов. Пока их больше 0, крутим цикл.
while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help) show_help; exit 0 ;;
		-q|--quiet) QUIET=1 ;; # Включаем тихий режим.
		-n|--no-logcat) NO_LOGCAT=1 ;; # Отключаем сканирование logcat.
		-l|--loop) shift; LOOP_INTERVAL="$1" ;; # Забираем следующее значение как интервал.
		-c|--clear-log)
			if [ -f "$LOG" ]; then
				: > "$LOG"  # Магия Bash: очищает файл, не удаляя его
				echo "Log file cleared: $LOG"
			else
				echo "Log file not found, nothing to clear."
			fi
			exit 0 ;; # Выходим, так как мы только чистили лог
		
		# Считываем кастомные пороги (флаг + следующее значение).
		--disk-warn) shift; DISK_WARN="$1" ;;
		--disk-crit) shift; DISK_CRIT="$1" ;;
		--ram-warn) shift; RAM_WARN="$1" ;;
		--ram-crit) shift; RAM_CRIT="$1" ;;
		--gpu-warn) shift; GPU_WARN="$1" ;;
		--gpu-crit) shift; GPU_CRIT="$1" ;;
		
		# Если аргумент неизвестен, выводим ошибку и выходим.
		*) echo "Unknown option: $1"; exit $EXIT_INTERNAL ;;
	esac
	shift # Сдвигаем список аргументов влево (удаляем обработанный $1).
done

# Если не тихий режим, очищаем экран консоли перед выводом.
[ "$QUIET" -eq 0 ] && clear

# Логика цикла. Если задан интервал (--loop).
if [ "$LOOP_INTERVAL" -gt 0 ]; then
	while true; do # Бесконечный цикл.
		clear
		main # Запускаем главную функцию.
		sleep "$LOOP_INTERVAL" # Ждем указанное время.
	done
else
	# Запуск один раз.
	main
	exit $? # Выходим с кодом возврата функции main.
fi
