#!/data/user/0/bin.mt.plus/files/term/bin/bash
# ^ Это shebang. Он указывает системе, какой интерпретатор использовать для запуска скрипта. В данном случае это bash, находящийся в папке MT Manager.

# set -u: Заставляет скрипт завершаться с ошибкой, если мы пытаемся использовать переменную, которая не была задана. Это помогает избежать скрытых багов.
set -u
# set -o pipefail: Если в цепочке команд (pipeline, например cmd1 | cmd2) одна из команд упадет, то весь скрипт вернет ошибку, а не только последняя команда.
set -o pipefail

# Путь к основному файлу лога и временно используемому файлу для ошибок (logcat)
#  - LOG: основной лог-файл, в который дублируется всё, что выводится.
#  - ERR_LOG: временный файл, куда записываются ошибки из logcat.
LOG="/data/media/0/.My Folder/logs/android_monitor.log"
ERR_LOG="/data/media/0/.My Folder/logs/last_errors.log"

# exit_code_label
# Функция: преобразует числовой код возврата в удобочитаемую метку.
# Аргументы:
#   $1 - числовой код возврата (0/1/2/3/...)
# Выводит на stdout цветную метку (если терминал поддерживает цвета).
# Не меняет переменные окружения.
exit_code_label() {
	case "$1" in

		$EXIT_OK)
			echo "${GREEN}OK${NC}"
			;;
		
		$EXIT_WARNING)
			echo "${YELLOW}WARNING${NC}"
			;;
		
		$EXIT_CRITICAL)
			echo "${RED}CRITICAL${NC}"
			;;
		
		$EXIT_INTERNAL)
			echo "${RED}INTERNAL ERROR${NC}"
			;;
		
		*)
			echo "UNKNOWN"
			;;
	esac
}

# check_dependencies
# Функция: проверяет, установлены ли необходимые системные утилиты.
# Возвращаемые коды:
#   0 - все зависимости присутствуют
#   EXIT_INTERNAL - обнаружены отсутствующие критические зависимости
# Печатает рекомендации по установке в stderr, если чего-то не хватает.
check_dependencies() {
	local missing=()

	# Критические утилиты, без которых скрипт не сможет корректно выполнять отдельные части логики (парсинг, вывод, получение списка процессов).
	local critical_deps=("awk" "grep" "sed" "df" "ps")
	for dep in "${critical_deps[@]}"; do
		# command -v проверяет, доступна ли команда в PATH
		if ! command -v "$dep" >/dev/null 2>&1; then
			missing+=("$dep")
		fi
	done

	# Если есть отсутствующие утилиты — сообщаем пользователю и прерываем.
	if [ ${#missing[@]} -gt 0 ]; then
		# Пишем в stderr (показательно для cron / автоматизации).
		echo "ERROR: Missing required utilities: ${missing[*]}" >&2
		# Подсказываем пакетный менеджер Termux (pkg). Пользователь на Android.
		echo "Install them via: pkg install coreutils procps" >&2
		return $EXIT_INTERNAL
	fi

	# 'bc' — не критичен, но удобен для сравнения дробных чисел (GPU проценты).
	if ! command -v bc >/dev/null 2>&1; then
		# NOTE выводим в stderr, но работа продолжается в integer-mode.
		echo "NOTE: 'bc' calculator not found. GPU percentage checks will use integer math." >&2
	fi
	return $EXIT_OK
}

# check_already_running
# Функция: предотвращает запуск двух экземпляров скрипта одновременно.
# Логика:
#   - размещает lock-файл /tmp/<scriptname>.lock с PID текущего процесса
#   - если lock-файл существует и процесс жив — возвращает ошибку
#   - при завершении (trap EXIT) lock-файл удаляется автоматически
# Возвращает EXIT_OK либо EXIT_INTERNAL в случае уже запущенного экземпляра.
check_already_running() {
	local script_name=$(basename "$0")
	local lock_file="/tmp/${script_name}.lock"
	local pid

	if [ -f "$lock_file" ]; then
		pid=$(cat "$lock_file" 2>/dev/null)
		# kill -0 проверяет, существует ли процесс с PID
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
			echo "ERROR: Script is already running with PID $pid" >&2
			echo "If this is wrong, delete: $lock_file" >&2
			return $EXIT_INTERNAL
		else
			# stale lock — удаляем
			rm -f "$lock_file"
		fi
	fi

	# записываем текущий PID в lock
	echo $$ > "$lock_file"

	# гарантированно удалить lock при выходе любого типа
	trap 'rm -f "$lock_file"' EXIT
	return $EXIT_OK
}

# EXIT CODES — понятные имена для числовых кодов возврата
EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2
EXIT_INTERNAL=3

# Глобальные переменные состояния и флаги
# - SYSTEM_STATUS: агрегированный статус после всех проверок
# - QUIET: если 1 — не печатать в терминал, только писать в лог
# - NO_LOGCAT: если 1 — пропустить длительный анализ logcat
# - LOOP_INTERVAL: если >0 — запускать монитор в цикле каждые N секунд
# - DRY_RUN: если 1 — проверить зависимости и вывести только заголовок
# - BRIEF_MODE: если 1 — показывать только важные сообщения (WARNING/CRITICAL)
# - EXTENDED: если 1 — в конце вывести расширенную информацию о системе
SYSTEM_STATUS=$EXIT_OK

QUIET=0
NO_LOGCAT=0
LOOP_INTERVAL=0
DRY_RUN=0
BRIEF_MODE=0
EXTENDED=0

# Thresholds: параметры, при превышении которых срабатывают WARNING/CRITICAL
# - DISK_WARN / DISK_CRIT: в процентах для дисковых разделов (/data)
# - RAM_WARN / RAM_CRIT: в процентах для RAM
# - CPU_WARN_MULT / CPU_CRIT_MULT: множители по отношению к числу ядер
# - GPU_WARN / GPU_CRIT: проценты загрузки GPU
DISK_WARN=80
DISK_CRIT=90
RAM_WARN=80
RAM_CRIT=90
CPU_WARN_MULT=1.5
CPU_CRIT_MULT=2.0
GPU_WARN=80
GPU_CRIT=95

# Цвета: включаем escape-последовательности только если stdout — интерактивный терминал
# Проверка [ -t 1 ] — true, если дескриптор 1 (stdout) привязан к терминалу.
if [ -t 1 ]; then
	RED='\033[0;31m'
	GREEN='\033[0;32m'
	YELLOW='\033[1;33m'
	NC='\033[0m'
else
	# В неинтерактивном режиме (cron/лог-файл) не добавляем мусор в лог
	RED='' ; GREEN='' ; YELLOW='' ; NC=''
fi

# out_printf
# Удобная обёртка вокруг printf, учитывающая QUIET и BRIEF_MODE.
# Если BRIEF_MODE включен — функция фильтрует обычные информационные строки, оставляя только сообщения, содержащие "CRITICAL", "WARNING" или "ERROR".
out_printf() {
	if [ "$BRIEF_MODE" -eq 1 ]; then
		# Простейшая фильтрация по ключевым словам — подходит для быстрого режима.
		if [[ "$*" != *"CRITICAL"* ]] && [[ "$*" != *"WARNING"* ]] && [[ "$*" != *"ERROR"* ]]; then
			return
		fi
	fi
	[ "$QUIET" -eq 0 ] && printf "$@"
}

# log
# Универсальная функция логирования:
#  - выводит строку в терминал (если QUIET=0),
#  - записывает ту же строчку в файл $LOG (без управляющих цветовых кодов).
# Формат строки: "HH:MM:SS - сообщение"
log() {
	ts="$(date '+%H:%M:%S')"
	[ "$QUIET" -eq 0 ] && echo -e "$ts - $1"
	# sed удаляет ANSI escape-коды перед записью в файл
	echo -e "$ts - $1" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG"
}

# show_help
# Многострочная справка, показываемая при запуске с -h/--help.
# Объясняет опции и примеры использования.
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
  -b, --brief             Brief mode: show only warnings and errors (good for quick checks)
  -d, --dry-run           Test mode: verify dependencies and show basic info without full checks
  -e, --extended          Show extended system information
  -c, --clear-log         Clear content of log file without deleting it

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

# rotate_log
# Простая ротация лога: если в файле больше 1000 строк — перезаписать его одной строкой.
# Такой подход минимален и подходит для устройств с ограниченным дисковым пространством.
rotate_log() {
	if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 1000 ]; then
		echo "--- Log rotated ---" > "$LOG"
	fi
}

# print_header
# Выводит заголовок монитора: модель устройства, версия Android, ядро, активный слот, текущая дата/время. Использует свойства getprop — стандартный метод на Android.
print_header() {
	local slot
	slot="$(getprop ro.boot.slot_suffix)"
	[ -z "$slot" ] && slot="unknown"
	  
	codename="$(getprop ro.product.device)"
	[ -z "$codename" ] && codename="unknown"

	echo "========================================"
	echo "ANDROID ROOT SYSTEM MONITOR"
	echo "Device: $(getprop ro.product.model) ($codename)"
	echo "Android: $(getprop ro.build.version.release)"
	echo "Kernel: $(uname -r)"
	echo "Active slot: $slot"
	echo "Time: $(date)"
	echo "========================================"
}

# quiet_hint
# Если включён quiet-режим, печатает подсказку о том, где смотреть лог.
# Используемая в разделах перед выдачей подробной информации.
quiet_hint() {
	[ "$QUIET" -eq 1 ] && echo "Check details in log file: $LOG" && echo
}

# check_storage
# Проверяет использование хранилища на /data:
#  - читает df -h /data
#  - парсит процент использования и сравнивает с порогами
#  - логирует общий размер, использовано, свободно
# Примечание: мы используем tail -1 и ожидаем, что последняя строка — это /data.
check_storage() {
	local use size used avail percent _
	echo
	echo "[ STORAGE ] (/data)"
	quiet_hint

	df -h /data | tail -1 | while read -r _ size used avail percent _; do
		use=${percent%\%}

		# Небольшая "косметика" — заменяем 'G' на ' GB' для читабельности
		local f_size=${size//G/ GB}
		local f_used=${used//G/ GB}
		local f_avail=${avail//G/ GB}

		log "Total: $f_size | Used: $f_used | Free: $f_avail"

		# Сравнение с порогами: сначала CRITICAL, затем WARNING
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

# check_memory
# Считывает /proc/meminfo, рассчитывает использованную память и проценты, проверяет наличие swap / zram и логирует информацию о ZRAM.
check_memory() {
	local total avail used percent avail_mb total_gb
	local z_total z_free z_used
	echo
	echo "[ MEMORY ] (RAM)"
	quiet_hint

	# читаем значения в килобайтах
	total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
	avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)

	# prettify: показать общий объём в GB с одной цифрой
	total_gb=$(awk "BEGIN {printf \"%.1f\", $total / 1024 / 1024}")

	log "Total RAM: ${total_gb} GB"

	# Swap / ZRAM информация — читаем, если есть
	z_total=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
	z_free=$(awk '/SwapFree/ {print $2}' /proc/meminfo)
	  
	if [ "$z_total" -gt 0 ]; then
		z_used=$(( (z_total - z_free) / 1024 ))
		z_total_mb=$(( z_total / 1024 ))
		log "ZRAM: ${z_used} MB used / ${z_total_mb} MB total"
	fi

	# Считаем проценты занятости
	used=$((total - avail))
	percent=$((used * 100 / total))
	avail_mb=$((avail / 1024))

	# Проверка порогов и выставление глобального статуса
	if [ "$percent" -ge "$RAM_CRIT" ]; then
		log "${RED}CRITICAL: RAM ${percent}% (${avail_mb} MB free)${NC}"
		SYSTEM_STATUS=$EXIT_CRITICAL
	elif [ "$percent" -ge "$RAM_WARN" ]; then
		log "${YELLOW}WARNING: RAM ${percent}% (${avail_mb} MB free)${NC}"
		[ "$SYSTEM_STATUS" -lt $EXIT_WARNING ] && SYSTEM_STATUS=$EXIT_WARNING
	else
		log "${GREEN}OK: RAM ${percent}% (${avail_mb} MB free)${NC}"
	fi
}

# get_cpu_freqs_detailed
# Опрашивает каждое из 8 ядер процессора и выводит текущую частоту для каждого.
# Если ядро отключено системой энергосбережения (Hotplug), выводит статус OFFLINE.
# Использует форматирование %4s/%4d для сохранения идеальной структуры колонок.
# Полезно для архитектур Big.LITTLE (как Snapdragon 870), где частоты кластеров различаются.
get_cpu_freqs_detailed() {
    local cpu_dir="/sys/devices/system/cpu"
    local f i online_status
    
    log "CPU Frequencies:"

    for i in {0..7}; do
        # Проверяем, активно ли ядро (1 - online, 0 - offline)
        # Ядро 0 обычно всегда online, поэтому файла может не быть — считаем его активным по умолчанию.
        if [ -f "$cpu_dir/cpu$i/online" ]; then
            online_status=$(cat "$cpu_dir/cpu$i/online" 2>/dev/null)
        else
            online_status=1
        fi

        if [ "$online_status" -eq 1 ]; then
            f=$(cat "$cpu_dir/cpu$i/cpufreq/scaling_cur_freq" 2>/dev/null)
            if [ -n "$f" ]; then
                out_printf "              Core $i: %4d MHz\n" "$((f/1000))"
            else
                out_printf "              Core $i: %4s\n" "DATA_ERR"
            fi
        else
            # Выделяем OFFLINE цветом, чтобы сразу бросалось в глаза
            out_printf "              Core $i: ${RED}%4s${NC}\n" "OFFLINE"
        fi
    done
}

# check_cpu
# Собирает информацию о CPU: модель, количество ядер, loadavg, governor и частоты.
# - Использует вспомогательные функции get_board_name, get_cpu_governor, get_cpu_freqs
# - Сравнивает среднюю нагрузку (loadavg) с порогами, используя множитель на число ядер
check_cpu() {
	local cores load warn crit
	echo
	echo "[ CPU ]"
	quiet_hint

	cpu_name=$(getprop ro.soc.model)
	[ -z "$cpu_name" ] && cpu_name=$(getprop ro.board.platform)
	cores=$(grep -c processor /proc/cpuinfo)
	load=$(awk '{print $1}' /proc/loadavg)

	log "Model: $cpu_name"
	log "Board: $(get_board_name)"
	log "Load: $load | Cores: $cores"
	log "CPU Governor: $(get_cpu_governor)"
	get_cpu_freqs_detailed
	
	# Сравнение текущей макс. частоты с заводской макс. частотой
    local cur_max_f factory_max_f base="/sys/devices/system/cpu/cpu0/cpufreq"
    cur_max_f=$(cat "$base/scaling_max_freq" 2>/dev/null)
    factory_max_f=$(cat "$base/cpuinfo_max_freq" 2>/dev/null)

    if [ -n "$cur_max_f" ] && [ -n "$factory_max_f" ]; then
        if [ "$cur_max_f" -lt "$factory_max_f" ]; then
            log "CPU Throttling: ${RED}ACTIVE${NC} (Limited to $((cur_max_f/1000)) MHz)"
        else
            log "CPU Throttling: ${GREEN}Inactive${NC}"
        fi
    fi

	# сравниваем дробные значения с помощью awk (bash не поддерживает float)
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

# check_cpu_temp
# Поиск и выбор максимальной валидной температуры среди датчиков thermal_zone*.
# Если нет подходящих датчиков — пытаемся взять температуру батареи как прокси.
check_cpu_temp() {
	local max=0 z type raw t b
	echo
	echo "[ CPU TEMP ]"
	quiet_hint

	max=0

	for z in /sys/class/thermal/thermal_zone*; do

		type=$(cat "$z/type" 2>/dev/null)
		raw=$(cat "$z/temp" 2>/dev/null)

		# Отбираем датчики по имени (tsens* или cpu*)
		case "$type" in tsens*|cpu*) ;; *) continue ;; esac

		[ -z "$raw" ] && continue

		# Обычно датчики дают тысячные градусы (например 47000 -> 47C)
		t=$((raw / 1000))

		# Отсеиваем глючные значения
		[ "$t" -lt 15 ] || [ "$t" -gt 120 ] && continue

		[ "$t" -gt "$max" ] && max="$t"
	done

	if [ "$max" -gt 0 ]; then
		log "CPU Max Temp: ${max}°C"
	else
		log "CPU Temp: unavailable"
		b=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
		[ -n "$b" ] && log "SoC Temp (battery proxy): $((b/10))°C"
	fi
}

# check_gpu
# Поддерживает Qualcomm (Adreno) и Mali (MediaTek / Exynos / Tensor).
# Собирает модель, частоту, governor и загрузку GPU; сравнивает с порогами.
# Примечание: чтение путей /sys может отличаться между устройствами, поэтому здесь предусмотрено несколько вариантов файлов.
check_gpu() {
	echo
	echo "[ GPU MONITOR ]"
	quiet_hint

	local BC_INSTALLED gpu_model gpu_freq gpu_load gpu_gov
	BC_INSTALLED=$(command -v bc 2>/dev/null)

	gpu_model="Unknown"
	gpu_freq="N/A"
	gpu_load="N/A"
	gpu_gov="N/A"

	# Adreno (Qualcomm)
	if [ -d /sys/class/kgsl/kgsl-3d0 ]; then
		gpu_model="Adreno (Qualcomm)"
		local path="/sys/class/kgsl/kgsl-3d0"

		local raw_freq
		raw_freq=$(cat "$path/gpuclk" 2>/dev/null)
		[ -n "$raw_freq" ] && gpu_freq="$((raw_freq / 1000000)) MHz"

		# gpubusy обычно содержит busy и total — вычисляем процент
		gpu_load=$(awk '{if($2>0) printf "%.1f%%", ($1/$2)*100; else print "0%"}' "$path/gpubusy" 2>/dev/null)
		gpu_gov=$(cat "$path/devfreq/governor" 2>/dev/null)

	# Mali (MediaTek / Exynos / Google Tensor)
	elif ls /sys/devices/platform/*mali* >/dev/null 2>&1 || [ -d /sys/module/mali_kbase ]; then
		gpu_model="Mali (MediaTek / Exynos / Tensor)"

		local mali_path
		mali_path=$(ls -d /sys/devices/platform/*mali* 2>/dev/null | head -1)
		[ -z "$mali_path" ] && mali_path="/sys/class/misc/mali0/device"

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

	# Если не определили модель — считаем GPU недоступным
	[ "$gpu_model" = "Unknown" ] && { log "GPU: unavailable"; return; }

	log "Model:    $gpu_model"
	log "Freq:     $gpu_freq"
	log "Governor: $gpu_gov"

	local load_val gpu_warn gpu_crit
	load_val=$(echo "$gpu_load" | tr -d '%')
	gpu_warn=0
	gpu_crit=0

	# Проверяем, является ли load_val числом (включая дробные)
	if [[ "$load_val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		if [ -n "$BC_INSTALLED" ]; then
			# Используем bc для сравнения дробных чисел
			gpu_warn=$(echo "$load_val > $GPU_WARN" | bc)
			gpu_crit=$(echo "$load_val > $GPU_CRIT" | bc)
		else
			# fallback: сравниваем целую часть
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

# check_battery
# Читает свойства батареи в /sys/class/power_supply/battery и выводит:
#  - статус (Charging/Discharging)
#  - health (Good/Unknown)
#  - cycles (если доступны)
#  - температуру в градусах Цельсия
#  - напряжение в mV
# Также вычисляет процент износа, если доступны charge_full и charge_full_design.
check_battery() {
    echo
    echo "[ BATTERY & HEALTH ]"
    quiet_hint

    local b="/sys/class/power_supply/battery"
    local cap status temp volt health cycles health_pct current_now power_w

    [ ! -d "$b" ] && log "Battery data: unavailable" && return

    # Основные параметры
    cap=$(cat "$b/capacity" 2>/dev/null)
    status=$(cat "$b/status" 2>/dev/null)
    temp=$(( $(cat "$b/temp" 2>/dev/null) / 10 ))
    volt=$(( $(cat "$b/voltage_now" 2>/dev/null) / 1000 ))
    
    # Расчет мгновенной мощности
    current_now=$(cat "$b/current_now" 2>/dev/null) # обычно в микроамперах
    if [ -n "$current_now" ] && [ "$volt" -gt 0 ]; then
        # Ток в мА (с сохранением знака)
        local i_ma=$((current_now / 1000))
        # Мощность в Ваттах через awk (v в мВ, i в мА)
        power_w=$(awk -v v=$volt -v i=$i_ma 'BEGIN { printf "%.2f", (v * i) / 1000000 }')
        # Для отображения в логе убираем минус, так как статус (Charging/Discharging) и так понятен
        display_power="${power_w#-}W"
        display_current="${i_ma#-}mA"
    else
        display_power="N/A"
        display_current="N/A"
    fi

    # Здоровье и циклы
    health=$(cat "$b/health" 2>/dev/null)
    cycles=$(cat "$b/cycle_count" 2>/dev/null)
    [ -z "$cycles" ] && cycles="N/A"

    local full=$(cat "$b/charge_full" 2>/dev/null)
    local design=$(cat "$b/charge_full_design" 2>/dev/null)
    
    if [ -n "$full" ] && [ -n "$design" ] && [ "$design" -gt 0 ]; then
        health_pct=$(( full * 100 / design ))
        # Ограничиваем 100%, если калибровка сбита
        [ "$health_pct" -gt 100 ] && health_pct=100
        health="$health ($health_pct%)"
    fi

    log "Status:   $status ($cap%)"
    log "Health:   $health"
    log "Cycles:   $cycles"
    log "Temp:     ${temp}°C"
    log "Current:  $display_current"
    log "Power:    $display_power"
    log "Voltage:  ${volt}mV"

    # Предупреждения
    if [ "$temp" -gt 45 ]; then
        log "${RED}WARNING: Battery overheating! (${temp}°C)${NC}"
        [ "$SYSTEM_STATUS" -lt $EXIT_WARNING ] && SYSTEM_STATUS=$EXIT_WARNING
    fi
}

# check_thermal_status
# Проверяет системный статус троттлинга (Android 10+)
check_thermal_status() {
    local status temp
    # 1. Пытаемся взять стандартный проп
    status=$(getprop sys.thermal.status 2>/dev/null)
    
    # 2. Если пусто, пробуем найти критические зоны в ядре
    if [ -z "$status" ]; then
        # Ищем зону с типом 'skin' или 'cpu-thermal'
        for z in /sys/class/thermal/thermal_zone*; do
            type=$(cat "$z/type" 2>/dev/null)
            if [[ "$type" == *"skin"* ]] || [[ "$type" == *"cpu"* ]]; then
                temp=$(cat "$z/temp" 2>/dev/null)
                # Если температура выше 45 градусов, помечаем как Moderate
                if [ "$temp" -gt 55000 ]; then status=3; 
                elif [ "$temp" -gt 45000 ]; then status=2; 
                else status=0; fi
                break
            fi
        done
    fi

    [ -z "$status" ] && return

    case "$status" in
        0) log "Thermal Status: ${GREEN}NONE (Cool)${NC}" ;;
        1) log "Thermal Status: ${GREEN}LIGHT${NC}" ;;
        2) log "Thermal Status: ${YELLOW}MODERATE${NC}" ;;
        3) log "Thermal Status: ${YELLOW}SEVERE (Throttling)${NC}" ;;
        4|5) log "Thermal Status: ${RED}CRITICAL/EMERGENCY${NC}" ;;
    esac
}

# check_network
# Попытка подключения к нескольким проверочным хостам.
# - Перечисляем hosts; если хоть один reachable — считаем интернет доступным.
# - Если нет и исполняемся от root, печатаем сетевые интерфейсы для диагностики.
check_network() {
    echo
    echo "[ NETWORK ]"
    quiet_hint

    local conn_type local_ip
    # Пытаемся определить активный интерфейс (wlan0 = Wi-Fi, rmnet* = Mobile)
    conn_type=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5}')
    local_ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7}')

    if [ -n "$conn_type" ]; then
        case "$conn_type" in
            wlan*) log "Connection: ${GREEN}Wi-Fi${NC} ($conn_type)" ;;
            rmnet*|ccmni*) log "Connection: ${GREEN}Mobile Data${NC} ($conn_type)" ;;
            *) log "Connection: $conn_type" ;;
        esac
        log "Local IP:   $local_ip"
    fi

    # Дальше твоя стандартная проверка пингом
    local hosts=("8.8.8.8" "google.com")
    local success=0
    for host in "${hosts[@]}"; do
        if ping -c1 -W2 "$host" >/dev/null 2>&1; then
            success=1
            log "${GREEN}✓ Internet connectivity: OK ($host)${NC}"
            break
        fi
    done

    [ "$success" -eq 0 ] && log "${RED}✗ No Internet connectivity${NC}"
}

# check_logcat
# Снимает дамп ошибок (Error и выше) из буферов main, system, crash:
# - сохраняет последние 500 строк в ERR_LOG
# - выводит превью (до 5 последних строк)
# - выставляет SYSTEM_STATUS при большом числе ошибок
check_logcat() {
	local c s
	echo
	echo "[ LOGCAT ERRORS ]"
	> "$ERR_LOG"

	[ "$NO_LOGCAT" -eq 1 ] && log "Logcat: skipped (--no-logcat)" && return

	logcat -b main,system,crash -d *:E | tail -n 500 > "$ERR_LOG"

	[ ! -s "$ERR_LOG" ] && log "${GREEN}No critical logcat errors detected${NC}" && return

	c=$(wc -l < "$ERR_LOG")
	[ "$c" -gt 200 ] && SYSTEM_STATUS=$EXIT_CRITICAL
	[ "$c" -gt 50 ] && [ "$SYSTEM_STATUS" -lt $EXIT_WARNING ] && SYSTEM_STATUS=$EXIT_WARNING

	s=5; [ "$c" -lt 5 ] && s="$c"

	log "${YELLOW}⚠ Detected $c errors. Showing last $s:${NC}"
	echo "----------------------------------------"
	tail -n "$s" "$ERR_LOG" | while read -r line; do
		log "  > $line"
	done
	echo "----------------------------------------"
	log "Full history: cat $ERR_LOG"
}

# print_top
# Выводит топ-процессов по использованию CPU (заголовок + 5 процессов)
# Если команда — стандартный app_process, пытается вытащить имя пакета из /proc/PID/cmdline.
# Форматирование колонок делаем через printf/out_printf.
print_top() {
	local p c cpu m real_name
	echo
	echo "[ TOP PROCESSES ]"
	quiet_hint

	out_printf "%-6s %-20s %-6s %-6s\n" "PID" "COMMAND/PACKAGE" "%CPU" "%MEM"
	echo "------------------------------------------------"
	
	# Получаем топ 5 процессов по CPU
	ps -Ao pid,comm,%cpu,%mem --sort=-%cpu | head -n 6 | tail -n +2 |
	while read -r p c cpu m; do
		# Если процесс - стандартная обертка Android, лезем глубже
		if [[ "$c" == "app_process"* ]] || [[ "$c" == "base" ]]; then
			if [ -f "/proc/$p/cmdline" ]; then
				# Читаем cmdline, заменяя нулевые байты на пробелы
				real_name=$(tr '\0' ' ' < "/proc/$p/cmdline" | awk '{print $1}')
				# Оставляем только последнюю часть пакета для краткости (напр. com.android.vending -> vending)
				# Если хочешь полное имя, удали часть с 'sed' ниже
				c=$(echo "$real_name" | sed 's/.*\.//')
			fi
		fi
		
		# Печатаем строку (увеличили ширину колонки имени до 20 символов)
		out_printf "%-6s %-20.20s %-6s %-6s\n" "$p" "$c" "$cpu" "$m"
	done
}


# print_io
# Обрабатывает /proc/diskstats и печатает прочитанные/записанные мегабайты для основных устройств (mmcblk*, sd*, dm-*). Сектора -> МБ через деление на 2048.
print_io() {
    echo
    echo "[ I/O ] (Active Storage)"
    quiet_hint

    if [ ! -f /proc/diskstats ]; then
        log "Error: /proc/diskstats not found"
        return
    fi

    out_printf "%-10s %-18s %-10s %-10s\n" "DEVICE" "MOUNT" "READ(MB)" "WRITE(MB)"
    echo "------------------------------------------------------------"

    # Создаем временный файл со списком монтирований для AWK
    local tmp_mnt="/tmp/mnt_map"
    mount | awk '{print $1, $3}' > "$tmp_mnt"

    awk -v m_file="$tmp_mnt" '
    BEGIN {
        # Сначала загружаем карту монтирований в память AWK из файла
        while ((getline < m_file) > 0) {
            mnt_map[$1] = $2
        }
        close(m_file)
    }
    {
        if ($3 ~ /^(mmcblk[0-9]+|sd[a-z]+|dm-[0-9]+)$/) {
            read_mb = $6 / 2048
            write_mb = $10 / 2048
            
            if (read_mb > 0.1 || write_mb > 0.1) {
                dev_path = "/dev/block/" $3
                mnt = "system/other"
                
                # Ищем точное совпадение или по имени устройства
                if (dev_path in mnt_map) {
                    mnt = mnt_map[dev_path]
                } else {
                    for (d in mnt_map) {
                        if (d ~ "/" $3 "$") {
                            mnt = mnt_map[d]
                            break
                        }
                    }
                }

                # Сокращаем длинные пути для читабельности
                sub(/^\/mnt\/vendor\//, "v:", mnt)
                sub(/^\/data\/media\/0/, "storage", mnt)
                sub(/^\/apex\/.*/, "apex", mnt)

                printf "%-10s %-18.18s %-10.1f %-10.1f\n", $3, mnt, read_mb, write_mb
            }
        }
    }
    ' /proc/diskstats

    # Удаляем временный файл
    rm -f "$tmp_mnt"
}

# get_backend_from_mountinfo
# Парсит /proc/self/mountinfo, чтобы определить реальный источник (device) для заданной точки монтирования. Возвращает строку-идентификатор, например '/dev/block/dm-2' или '/dev/block/by-name/userdata'.
get_backend_from_mountinfo() {
	local mp="$1"
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

# find_mountpoint
# По имени раздела (например "system") пытается найти его точку монтирования в /proc/self/mountinfo. Учитывает нынешние Android-особенности, такие как "system-as-root" (system_root). Возвращает путь монтирования или 1 (ошибка) — как обычный Unix-паттерн.
find_mountpoint() {
	local part="$1"
	mp=$(awk -v p="/$part" '$5 == p {print $5}' /proc/self/mountinfo | head -1)
	[ -n "$mp" ] && echo "$mp" && return

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

# check_partitions
# Формирует табличный вывод часто используемых разделов:
#   system, system_ext, product, vendor, odm, cache, data, metadata, apex, persist
# Для каждого:
#   - находит точку монтирования (find_mountpoint)
#   - берет строку df -h и парсит size/used/free
#   - определяет "backend" (реальное блочное устройство) через mountinfo
check_partitions() {
	echo
	echo "[ SYSTEM PARTITIONS ]"
	quiet_hint

	out_printf "%-12s %-28s %8s %8s %8s\n" "PARTITION" "MOUNT POINT" "SIZE" "USED" "FREE"
	out_printf "%-12s %-28s %8s %8s %8s\n" "----------" "----------------------------" "--------" "--------" "--------"

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

	mp=$(find_mountpoint "$part")
	[ -z "$mp" ] && continue

	df_line=$(df -h "$mp" 2>/dev/null | awk 'NR==2')
	[ -z "$df_line" ] && continue

	size=$(echo "$df_line" | awk '{print $2}')
	used=$(echo "$df_line" | awk '{print $3}')
	free=$(echo "$df_line" | awk '{print $4}')

	backend="$(get_backend_from_mountinfo "$mp")"
	[ -z "$backend" ] && backend="unknown"

	out_printf "%-12s %-28s %8s %8s %8s\n" \
		"$part" "$mp" "$size" "$used" "$free"

	log "Mounted at $mp -> $backend | Size: $size | Used: $used | Free: $free"
	done
}

# check_pixel_security
# Специфична для устройств Google Pixel.
# Пытается определить наличие Titan/StrongBox и состояние Verified Boot.
check_pixel_security() {
	local vendor
	vendor=$(getprop ro.product.manufacturer | tr '[:upper:]' '[:lower:]')

	# Если устройство не от Google — пропускаем функцию без шума
	[[ "$vendor" != *"google"* ]] && return

	echo
	echo "[ GOOGLE TITAN SECURITY ]"
	quiet_hint

	local titan_status hardware_level

	hardware_level=$(getprop ro.hardware.keystore_impl 2>/dev/null)
	[ -z "$hardware_level" ] && hardware_level="unknown"

	if logcat -d | grep -qi "StrongBox" ; then
		titan_status="${GREEN}Active (StrongBox detected)${NC}"
	else
		titan_status="${YELLOW}Standby / Not detected${NC}"
	fi

	log "Titan Chip:      $titan_status"
	log "Keystore Impl:   $hardware_level"
	log "Verified Boot:   $(getprop ro.boot.verifiedbootstate 2>/dev/null)"
}

# detect_root_method
# Определяет метод получения root:
#   - Magisk (проверки команд и каталогов)
#   - KernelSU (файлы/символы)
#   - Root (unknown) — если uid=0, но явных признаков Magisk/Kernelsu нет
# Результат печатается в stdout (например, "Magisk").
detect_root_method() {
	if command -v magisk >/dev/null 2>&1; then
		echo "Magisk"
		return
	fi

	if [ -d /sbin/.magisk ] || [ -d /data/adb/magisk ]; then
		echo "Magisk"
		return
	fi

	if [ -e /dev/kernelsu ] || \
		[ -e /sys/kernel/kernelsu ] || \
		grep -q kernelsu /proc/version 2>/dev/null; then
		echo "KernelSU"
		return
	fi

	[ "$(id -u)" -eq 0 ] && echo "Root (unknown)" || echo "No Root"
}

# get_magisk_version
# Пытается получить версию Magisk:
#   - через утилиту magisk (если доступна)
#   - через файл /data/adb/magisk/magisk_version (если есть)
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

# get_zygisk_status
# Проверяет, включён ли Zygisk:
#  - смотрит свойство persist.magisk.zygisk
#  - ищет сокеты в /dev/socket/, связанные с zygisk
# Возвращает "Enabled", "Enabled (Reboot Required)" или "Disabled".
get_zygisk_status() {
    local prop_status socket_exists env_check magisk_ver zygote_check
    
    # 1. Проверка через свойства Magisk
    prop_status=$(getprop persist.magisk.zygisk 2>/dev/null)
    
    # 2. Проверка активных сокетов (динамический показатель)
    socket_exists=$(ls /dev/socket/ 2>/dev/null | grep -c "zygisk")
    
    # 3. Проверка через переменные окружения Zygote (самый точный метод)
    # Zygisk внедряет свои переменные в процесс zygote
    zygote_check=$(grep -E "zygisk|magisk" /proc/$(pidof zygote | awk '{print $1}')/environ 2>/dev/null)
    
    # 4. Проверка через наличие внедренной библиотеки в памяти
    # Если в картах памяти zygote есть zygisk.so — он 100% активен
    local mem_check=0
    if [ -f "/proc/$(pidof zygote | awk '{print $1}')/maps" ]; then
        if grep -q "zygisk" "/proc/$(pidof zygote | awk '{print $1}')/maps" 2>/dev/null; then
            mem_check=1
        fi
    fi

    if [ "$mem_check" -eq 1 ] || [ -n "$zygote_check" ]; then
        echo -e "${GREEN}Enabled (Active)${NC}"
    elif [ "$socket_exists" -gt 0 ]; then
        echo -e "${YELLOW}Enabled (Standby/Socket detected)${NC}"
    elif [ "$prop_status" = "1" ]; then
        echo -e "${YELLOW}Enabled (Reboot Required)${NC}"
    else
        echo -e "${RED}Disabled${NC}"
    fi
}

# get_system_locale
# Возвращает системную локаль — сначала persist.sys.locale, затем ro.product.locale
get_system_locale() {
	getprop persist.sys.locale \ || getprop ro.product.locale
}

# get_build_description
# Возвращает строку ROM части прошивки (ro.build.display.id)
get_build_description() {
	getprop ro.build.display.id
}

# get_firmware_description
# Возвращает строку firmware части прошивки (ro.build.description)
get_firmware_description() {
	getprop ro.build.description
}

# get_board_name
# Возвращает кодовое имя платы (ro.product.board)
get_board_name() {
	getprop ro.product.board
}

# get_cpu_governor
# Возвращает текущий governor для cpu0 (scaling_governor)
get_cpu_governor() {
	local gov
	gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
	[ -n "$gov" ] && echo "$gov"
}

# get_screen_resolution
# Использует утилиту wm (window manager) для получения размеров экрана
# Формат результата: "WIDTHxHEIGHT" (например "1080x2400")
get_screen_resolution() {
	wm size 2>/dev/null | awk -F': ' 'NR==1 {print $2}'
}

# print_magisk_modules
# Возвращает список установленных модулей Magisk.
# Проверяет наличие каталога /data/adb/modules и выводит имена модулей, исключая служебный каталог lost+found.
# Используется для формирования расширенного (EXTENDED) вывода.
print_magisk_modules() {
	local modules_dir="/data/adb/modules"
	[ -d "$modules_dir" ] || return

	echo
	echo "[ MAGISK MODULES ]"

	local found=0

	for m in "$modules_dir"/*; do
		[ -d "$m" ] || continue
		[ "$(basename "$m")" = "lost+found" ] && continue

		found=1

		local name version desc state

		# Имя модуля
		if [ -f "$m/module.prop" ]; then
			name=$(grep -m1 '^name=' "$m/module.prop" | cut -d= -f2)
			version=$(grep -m1 '^version=' "$m/module.prop" | cut -d= -f2)
			desc=$(grep -m1 '^description=' "$m/module.prop" | cut -d= -f2)
		fi

		# Статус модуля
		if [ -f "$m/disable" ]; then
			state="Disabled"
		else
			state="Enabled"
		fi

		printf "%s - %s\n" "$(date +%H:%M:%S)" "${name:-$(basename "$m")}"
		[ -n "$version" ] && printf "           Version: %s\n" "$version"
		[ -n "$desc" ]    && printf "           Desc:    %s\n" "$desc"
		printf "           Status:  %s\n\n" "$state"
	done

	[ "$found" -eq 0 ] && echo "$(date +%H:%M:%S) - No Magisk modules installed"
}

# print_system
# Выводит базовую информацию о системе:
#  - uptime
#  - root: YES/NO
#  - system access level + версия Magisk (если есть)
#  - Zygisk статус
#  - SELinux state и ABI
print_system() {
	echo
	echo "[ SYSTEM INFO ]"
	quiet_hint

	log "Uptime: $(uptime -p)"

	if [ "$(id -u)" -eq 0 ]; then
		log "Root: ${GREEN}YES${NC}"
		log "System Access Level: $(detect_root_method) $(get_magisk_version)"
		log "Zygisk: $(get_zygisk_status)"
	else
		log "Root: ${RED}NO${NC}"
	fi

	log "SELinux: $(getenforce 2>/dev/null)"
	log "ABI: $(getprop ro.product.cpu.abi)"
}

# print_system_extended
# Расширенный блок system info — содержит язык, описание прошивки и разрешение экрана, помимо стандартной информации из print_system.
print_system_extended() {
	echo
	echo "[ SYSTEM INFO ] (EXTENDED)"
	quiet_hint

	log "Uptime: $(uptime -p)"
	log "Locale: $(get_system_locale)"
	log "Build: $(get_build_description)"
	log "Firmware: $(get_firmware_description)"

	# Проверка версии графического API
    log "Vulkan Driver: $(bootstrap.sh getprop ro.hardware.vulkan 2>/dev/null || echo "default")"
    log "OpenGL Vendor: $(getprop ro.hardware.egl 2>/dev/null || echo "default")"

    log "Screen Resolution: $(get_screen_resolution)"

	if [ "$(id -u)" -eq 0 ]; then
		log "Root: ${GREEN}YES${NC}"
		log "System Access Level: $(detect_root_method) $(get_magisk_version)"
		log "Zygisk: $(get_zygisk_status)"
	else
		log "Root: ${RED}NO${NC}"
	fi

	log "SELinux: $(getenforce 2>/dev/null)"
	log "ABI: $(getprop ro.product.cpu.abi)"
}

# run_monitor
# Основная последовательность запуска:
#  - проверка зависимостей
#  - dry-run режим (только инфо) при DRY_RUN=1
#  - подготовка логов (rotate_log, touch ERR_LOG)
#  - запуск всех блоков проверки по очереди
#  - вывод standard/extended system info в зависимости от флага EXTENDED
#  - запись финального exit code в лог
run_monitor() {
	check_dependencies || return $?

	if [ "$DRY_RUN" -eq 1 ]; then
		echo "[ DRY RUN MODE ] — Only showing system info"
		echo
		print_header
		print_system
		log "DRY RUN completed successfully"
		return $EXIT_OK
	fi

	SYSTEM_STATUS=$EXIT_OK
	rotate_log
	touch "$ERR_LOG" 2>/dev/null

	echo "___________________________________________________" >> "$LOG"
	echo "LOG SESSION START: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
	echo "___________________________________________________" >> "$LOG"

	print_header
	check_storage
	check_memory
	check_cpu
	check_cpu_temp
	check_thermal_status
	check_gpu
	check_battery
	check_network
	check_logcat
	print_top
	print_io
	check_partitions
	check_pixel_security

	if [ "$EXTENDED" -eq 1 ]; then
		print_system_extended
	else
		print_system
	fi
	
	if [ "$EXTENDED" -eq 1 ]; then
	    print_magisk_modules
	fi

	echo "========================================"
	echo "Log file: $LOG"
	echo "========================================"

	log "Exit code: $SYSTEM_STATUS ($(exit_code_label "$SYSTEM_STATUS"))"
	return "$SYSTEM_STATUS"
}

# Обработка аргументов командной строки (CLI).
# Поддерживаются опции, описанные в show_help. После обработки — сдвигаем аргументы с помощью shift, чтобы перейти к следующему.
while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help) show_help; exit 0 ;;
		-q|--quiet) QUIET=1 ;;
		-n|--no-logcat) NO_LOGCAT=1 ;;
		-l|--loop) shift; LOOP_INTERVAL="$1" ;;
		-d|--dry-run) DRY_RUN=1 ;;
		-b|--brief) BRIEF_MODE=1 ;;
		-e|--extended) EXTENDED=1 ;;
		-c|--clear-log)
			if [ -f "$LOG" ]; then
				: > "$LOG"
				echo "Log file cleared: $LOG"
			else
				echo "Log file not found, nothing to clear"
			fi
			exit 0 ;;

		--disk-warn) shift; DISK_WARN="$1" ;;
		--disk-crit) shift; DISK_CRIT="$1" ;;
		--ram-warn) shift; RAM_WARN="$1" ;;
		--ram-crit) shift; RAM_CRIT="$1" ;;
		--gpu-warn) shift; GPU_WARN="$1" ;;
		--gpu-crit) shift; GPU_CRIT="$1" ;;

		*) echo "Unknown option: $1"; exit $EXIT_INTERNAL ;;
	esac
	shift
done

# Перед началом вывода очищаем экран (если не quiet), чтобы лог выглядел аккуратно.
[ "$QUIET" -eq 0 ] && clear

# Главная логика цикла.
# Если задан LOOP_INTERVAL (>0), запускаем run_monitor в бесконечном цикле, защищаясь от повторных запусков через check_already_running (lock-file).
# В цикле считаем время выполнения и при необходимости ждём остаток интервала.
if [ "$LOOP_INTERVAL" -gt 0 ]; then
	check_already_running || exit $?

	while true; do
		clear
		run_monitor

		local start_time=$(date +%s)
		local end_time=$(date +%s)
		local elapsed=$((end_time - start_time))

		if [ "$elapsed" -lt "$LOOP_INTERVAL" ]; then
			sleep $((LOOP_INTERVAL - elapsed))
		else
			# Если выполнение заняло дольше, чем указанный интервал — предупреждение.
			echo "WARNING: Execution time ($elapsed s) exceeded loop interval ($LOOP_INTERVAL s)" >&2
			sleep "$LOOP_INTERVAL"
		fi
	done
else
	# Одиночный запуск: выполняем монитор и выходим с кодом результата.
	run_monitor
	exit $?
fi
