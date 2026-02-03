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
	# Убираем 'local' для lock_file, чтобы trap видел её при выходе из скрипта
	lock_file="/tmp/${script_name}.lock"
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

	# trap устанавливается один раз на весь жизненный цикл скрипта
	trap 'rm -f "$lock_file"; exit' EXIT INT TERM
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
# - NO_FILE_LOG: если 1 — разрешить запись логов в файл $LOG
# - ENABLE_NET_TEST: если 1 — разрешить выполнение функци check_iperf3_speed
SYSTEM_STATUS=$EXIT_OK

NO_LOGCAT=0
NO_FILE_LOG=0
BRIEF_MODE=0
EXTENDED=0
DRY_RUN=0
QUIET=0
LOOP_INTERVAL=0
ENABLE_NET_TEST=0

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
GPU_CRIT=90

# Цвета: включаем escape-последовательности только если stdout — интерактивный терминал
# Проверка [ -t 1 ] — true, если дескриптор 1 (stdout) привязан к терминалу.
if [ -t 1 ]; then
	RED='\033[1;31m'
	GREEN='\033[1;32m'
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
#  - записывает строчку в файл $LOG (если NO_FILE_LOG=0), удаляя цвета.
log() {
	local ts
	ts="$(date '+%H:%M:%S')"

	# 1. Вывод в терминал (если не включен тихий режим)
	[ "$QUIET" -eq 0 ] && echo -e "$ts - $1"

	# 2. Запись в файл (только если запись разрешена)
	if [ "$NO_FILE_LOG" -eq 0 ]; then
		# sed удаляет ANSI escape-коды перед записью в файл
		echo -e "$ts - $1" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG"
	fi
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
  -f, --no-file           Disable writing output to the .log file (Terminal only)
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

===================================
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
	echo
	echo "Device: $(getprop ro.product.model) ($codename)"
	echo "Android: $(getprop ro.build.version.release)"
	echo "Kernel: $(uname -r)"
	echo "Active slot: $slot"
	echo "Time: $(date)"
	echo
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

	# Читаем значения в килобайтах
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
# Опрашивает каждое ядро: выводит текущую и максимальную частоты (cur/max).
# Помогает отследить архитектуру Big.LITTLE и понять лимиты каждого ядра.
get_cpu_freqs_detailed() {
	local cpu_dir="/sys/devices/system/cpu"
	local f_cur f_max i online_status core_info

	log "CPU Frequencies (Current/Max):"

	for i in {0..7}; do
		# Проверяем статус ядра (0 - offline, 1 - online)
		if [ -f "$cpu_dir/cpu$i/online" ]; then
			online_status=$(cat "$cpu_dir/cpu$i/online" 2>/dev/null)
		else
			online_status=1
		fi

		if [ "$online_status" -eq 1 ]; then
			f_cur=$(cat "$cpu_dir/cpu$i/cpufreq/scaling_cur_freq" 2>/dev/null)
			f_max=$(cat "$cpu_dir/cpu$i/cpufreq/scaling_max_freq" 2>/dev/null)
			
			if [ -n "$f_cur" ] && [ -n "$f_max" ]; then
				# Форматируем как "1804/2419 MHz"
				# %4d гарантирует, что числа не "поплывут", если частота станет трехзначной
				core_info=$(printf "Core %d: %4d / %4d MHz" "$i" "$((f_cur/1000))" "$((f_max/1000))")
				log "              $core_info"
			else
				log "              Core $i: DATA_ERR"
			fi
		else
			log "              Core $i: ${RED}OFFLINE${NC}"
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

	# Сравниваем дробные значения с помощью awk (bash не поддерживает float)
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
	local zones=0 denied=0 valid=0

	echo
	echo "[ CPU TEMP ]"
	quiet_hint

	# Расширенный список ключевых слов для поиска процессорных зон
	# tsens, cpu, soc, msm_therm, core - покрывает 99% Android устройств
	for z in /sys/class/thermal/thermal_zone*; do
		[ -f "$z/type" ] || continue

		type=$(cat "$z/type" 2>/dev/null) || { denied=1; continue; }
		type=$(echo "$type" | tr '[:upper:]' '[:lower:]')

		# Фильтр типов зон
		case "$type" in
			*tsens*|*cpu*|*soc*|*core*|*msm_therm*) ;;
			*) continue ;;
		esac

		zones=$((zones + 1))
		# Авто-определение формата: 45000 (ms) или 45 (градусы)
		raw=$(cat "$z/temp" 2>/dev/null) || { denied=1; continue; }
		[ -z "$raw" ] || [ "$raw" -le 0 ] && continue

		if [ "$raw" -gt 1000 ]; then
			t=$((raw / 1000))
		else
			t=$raw
		fi
		# Валидация: 15°C (минимум) до 115°C (порог троттлинга)
		if [ "$t" -ge 15 ] && [ "$t" -le 115 ]; then
			valid=1
			[ "$t" -gt "$max" ] && max="$t"
		fi
	done

	# Добавляем цветовой индикатор (желтый если > 60, красный если > 80)
	if [ "$max" -gt 0 ]; then
		local color=$NC
		[ "$max" -gt 60 ] && color=$YELLOW
		[ "$max" -gt 80 ] && color=$RED
		log "CPU Max Temp: ${color}${max}°C${NC}"
		return
	fi

	# Пояснительная секция, если определение температуры CPU по какой-то причине недоступно
	if [ "$zones" -eq 0 ]; then
		log "CPU Temp: ${RED}unavailable${NC} (no thermal zones)"
	elif [ "$denied" -eq 1 ]; then
		log "CPU Temp: ${RED}unavailable${NC} (permission denied)"
	elif [ "$valid" -eq 0 ]; then
		log "CPU Temp: ${RED}unavailable${NC} (invalid sensor data)"
	else
		log "CPU Temp: ${RED}unavailable${NC}"
	fi

	# План Б: Если датчики CPU молчат, берем батарею
	b=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
	if [ -n "$b" ]; then
		# У батарей делитель обычно 10 (например 365 -> 36.5C)
		log "SoC Temp (battery proxy): $((b/10))°C"
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

	# Добавляем в блок [ GPU MONITOR ]
	local fps_data

	# Получаем текущий FPS через SurfaceFlinger
	# Мы берем задержку между кадрами и пересчитываем в FPS
	fps_data=$(dumpsys SurfaceFlinger --latency | head -1 | awk '{if($1>0) printf "%.0f", 1000000000/$1}')

	if [ "$fps_data" -lt 40 ]; then
		log "FPS:      ${RED}${fps_data}${NC} (Lagging)"
	elif [ "$fps_data" -lt 90 ]; then
		log "FPS:      ${YELLOW}${fps_data}${NC}"
	else
		log "FPS:      ${GREEN}${fps_data}${NC}"
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
	# 1. Пытаемся взять стандартный prop
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

# first_csv_value
# Назначение:
#   Возвращает первое "валидное" значение из CSV-строки.
#
# Контекст:
#   Многие Android getprop возвращают значения в формате:
#     "Operator1,Operator2" или "Unknown,Unknown"
#   Эта функция позволяет корректно извлечь первое осмысленное значение.
#
# Логика:
#   - Разбивает входную строку по запятым
#   - Последовательно проверяет каждый элемент
#   - Возвращает первый элемент, который:
#       * не равен "Unknown"
#       * не является пустой строкой
#   - После первого совпадения завершает выполнение
#
# Аргументы:
#   $1 — строка в формате CSV
#
# Возврат:
#   stdout — первое валидное значение или пусто, если ничего не найдено
first_csv_value() {
	echo "$1" | awk -F',' '{for(i=1;i<=NF;i++) if($i!="Unknown" && $i!="") {print $i; exit}}'
}

# get_mobile_info
# Назначение:
#   Определяет информацию о мобильной сети:
#     - имя оператора (Carrier)
#     - тип радиосети (RAT: LTE, NR, HSPA и т.д.)
#
# Контекст:
#   Android может возвращать несколько значений для SIM:
#     - Dual SIM
#     - виртуальные / inactive SIM
#     - значения в формате CSV
#
#   Поэтому:
#     - делаются fallback-запросы
#     - используется фильтрация через first_csv_value
#
# Используемые getprop:
#   gsm.operator.alpha        — имя оператора
#   gsm.sim.operator.alpha    — fallback для имени оператора
#   gsm.network.type          — тип сети (RAT)
#   gsm.network.type.1        — fallback для второй SIM
#
# Возврат:
#   stdout — строка формата:
#     "<carrier>|<rat>"
get_mobile_info() {
	local carrier_raw rat_raw carrier rat

	# Получаем "сырое" имя оператора
	carrier_raw=$(getprop gsm.operator.alpha)

	# Fallback, если значение отсутствует
	[ -z "$carrier_raw" ] && carrier_raw=$(getprop gsm.sim.operator.alpha)

	# Получаем "сырой" тип сети (RAT)
	rat_raw=$(getprop gsm.network.type)

	# Fallback для dual-SIM или альтернативных слотов
	[ -z "$rat_raw" ] && rat_raw=$(getprop gsm.network.type.1)

	# Извлекаем первое валидное значение из CSV
	carrier=$(first_csv_value "$carrier_raw")
	rat=$(first_csv_value "$rat_raw")

	# Гарантируем ненулевой вывод
	[ -z "$carrier" ] && carrier="Unknown"
	[ -z "$rat" ] && rat="Unknown"

	# Вывод в формате, удобном для read / IFS
	echo "$carrier|$rat"
}

# measure_latency
# Назначение:
#   Измеряет:
#     - среднюю задержку (latency)
#     - вариацию задержки (jitter)
#   до указанного хоста.
#
# Контекст:
#   Используется ICMP ping как наиболее универсальный способ
#   измерения сетевых характеристик на Android.
#
# Аргументы:
#   $1 — целевой хост (IP или DNS-имя)
#
# Возврат:
#   stdout — две числовые величины:
#     "<avg_latency_ms> <jitter_ms>"
#
#   return 1 — если измерения не удалось выполнить
measure_latency() {
	local host="$1"
	local times

	# Выполняем 5 ping-запросов с таймаутом 2 секунды
	# Из вывода извлекаем значения времени отклика (time=XX ms)
	times=$(ping -c5 -W2 "$host" 2>/dev/null | \
		awk -F'time=' '/time=/{print $2}' | awk '{print $1}')

	# Если нет ни одного значения — измерение не удалось
	[ -z "$times" ] && return 1

	# Инициализация статистических переменных
	local min=999999 max=0 sum=0 count=0 t

	# Перебор всех значений задержки
	for t in $times; do
		# Отбрасываем дробную часть (работаем в целых ms)
		t=${t%.*}

		# Минимальное значение
		[ "$t" -lt "$min" ] && min="$t"

		# Максимальное значение
		[ "$t" -gt "$max" ] && max="$t"

		# Сумма и счётчик
		sum=$((sum + t))
		count=$((count + 1))
	done

	# Среднее значение задержки
	local avg=$((sum / count))

	# Jitter как разница max - min
	local jitter=$((max - min))

	# Вывод результата
	echo "$avg $jitter"
}

# check_iperf3_speed
# Тестирование пропускной способности сети (iperf3).
# - Игнорируется в BRIEF_MODE и если не передан флаг ENABLE_NET_TEST.
# - Обходит список серверов, используя быстрый TCP-чек порта 5201.
check_iperf3_speed() {
	# 1. Жесткое условие: не тормозим систему в кратком режиме
	[ "$BRIEF_MODE" = "1" ] && return

	# 2. Опциональность: запускаем только если пользователь этого хочет
	# Либо добавь проверку счетчика циклов, чтобы не спамить тестами
	if [ "$ENABLE_NET_TEST" != "1" ]; then
		# Можно просто вывести статус готовности, если iperf3 есть
		command -v iperf3 >/dev/null 2>&1 && log "iPerf3:     Ready (use --net-speed to test)"
		return
	fi

	if ! command -v iperf3 >/dev/null 2>&1; then
		log "iPerf3:     Not installed"
		return
	fi

	echo
	echo "[ NETWORK SPEED ] (iperf3)"
	log "Status:     Testing speed (please wait...)"

	local servers=("iperf.he.net" "ping.online.net" "bouygues.iperf.fr" "speedtest.uztelecom.uz" "speedtest.serverius.net")
	local timeout_sec=10 
	local server ok=0

	for server in "${servers[@]}"; do
		# Проверка порта (2 секунды таймаут — это максимум, что мы можем позволить)
		if ! timeout 2 sh -c "echo >/dev/tcp/$server/5201" 2>/dev/null; then
			continue
		fi

		# Тест Download
		local down
		down=$(timeout "$timeout_sec" iperf3 -c "$server" -R 2>/dev/null | awk '/receiver/{print $(NF-2),$(NF-1)}')

		if [ -n "$down" ] && [ "$down" != "0 " ]; then
			ok=1
			log "Server:     $server"
			log "Download:   $down"

			# Тест Upload (только если Download удался)
			local up
			up=$(timeout "$timeout_sec" iperf3 -c "$server" 2>/dev/null | awk '/receiver/{print $(NF-2),$(NF-1)}')

			# Если upload не удался (как было в твоем логе), пишем "Failed/Blocked"
			[ -n "$up" ] && [ "$up" != "0 " ] && log "Upload:     $up" || log "Upload:     Blocked/Failed"
			break
		fi
	done

	[ "$ok" -eq 0 ] && log "iPerf3:     ${RED}All servers unreachable${NC}"
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

	local route_info
	route_info=$(timeout 2 ip route get 8.8.8.8 2>/dev/null)

	# Пытаемся определить активный интерфейс (wlan0 = Wi-Fi, rmnet* = Mobile)  
	conn_type=$(echo "$route_info" | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
	local_ip=$(echo "$route_info" | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')

	if [ -n "$conn_type" ]; then
		case "$conn_type" in
			wlan*)
				log "Connection: ${GREEN}Wi-Fi${NC} ($conn_type)"
			;;
			rmnet*|ccmni*)
				log "Connection: ${GREEN}Mobile Data${NC} ($conn_type)"
				IFS="|" read -r carrier rat <<< "$(get_mobile_info)"
				log "Carrier:    $carrier"
				log "RAT:        $rat"
			;;
			rndis*|usb*)
				log "Connection: ${GREEN}USB Tethering${NC} ($conn_type)"
			;;
			tun*|wg*)
				log "Connection: ${GREEN}VPN${NC} ($conn_type)"
			;;
			*) 
				log "Connection: $conn_type"
			;;
		esac
		log "Local IP:   $local_ip"
	fi
	
	# DNS resolvers
	local dns_servers=()
	local d
	for p in net.dns1 net.dns2 net.dns3 net.dns4; do
		d=$(getprop "$p")
		[ -n "$d" ] && dns_servers+=("$d")
	done
	[ "${#dns_servers[@]}" -gt 0 ] && log "DNS:        ${dns_servers[*]}"

	local hosts=("8.8.8.8" "1.1.1.1" "google.com")
	local success=0

	for host in "${hosts[@]}"; do
		if ping -c1 -W2 "$host" >/dev/null 2>&1; then
	success=1
		log "${GREEN}✓ Internet connectivity: OK ($host)${NC}"

		if latency=$(measure_latency "$host"); then
			set -- $latency
			log "Latency:    ${1} ms"
			log "Jitter:     ${2} ms"
		fi
		break
	fi
	done

	# HTTP fallback
	if [ "$success" -eq 0 ] && command -v curl >/dev/null; then
		if curl -s --connect-timeout 3 http://clients3.google.com/generate_204 >/dev/null; then
			success=1
			log "${GREEN}✓ Internet connectivity: OK (HTTP probe)${NC}"
		fi
	fi

	if [ "$success" -eq 0 ]; then
		log "${RED}✗ No Internet connectivity${NC}"

		if [ "$(id -u)" -eq 0 ]; then
			log "Active interfaces:"
			ip -br addr show | sed 's/^/  /'
		fi
	fi
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
	quiet_hint

	[ "$NO_LOGCAT" -eq 1 ] && log "Logcat: skipped (--no-logcat)" && return

	logcat -b main,system,crash -d *:E \
	| grep -v "^--------- beginning of" \
	| tail -n 500 > "$ERR_LOG"

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
# Выводит список топ-5 процессов в стиле Card UI.
# - Автоматически декодирует имена пакетов Android.
# - Динамически подстраивается под BRIEF_MODE.
print_top() {
	local p c cpu m real_name
	local separator="----------------------------------------"

	# Берем топ-5 процессов по потреблению CPU
	local top_data
	top_data=$(ps -Ao pid,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | head -n 6 | tail -n +2)
	[ -z "$top_data" ] && return

	# Логика BRIEF_MODE
	if [ "$BRIEF_MODE" = "1" ]; then
		local top_cpu
		top_cpu=$(echo "$top_data" | awk '{print int($3); exit}')
		[ "$top_cpu" -lt 20 ] && return
		log "${YELLOW}Warning: High CPU usage detected (${top_cpu}%)${NC}"
	fi

	echo
	echo "[ TOP PROCESSES ]"
	[ "$BRIEF_MODE" = "1" ] && echo "(!) High load detected:"
	quiet_hint
	
	echo "$separator"

	echo "$top_data" | while read -r p c cpu m; do
		# Продвинутое определение имени (оставляем твою логику, она крутая)
		if [[ "$c" == "app_process"* ]] || [[ "$c" == "base" ]] || [[ "$c" == "sh" ]]; then
			if [ -f "/proc/$p/cmdline" ]; then
				real_name=$(tr '\0' '\n' < "/proc/$p/cmdline" | head -n 1)
				real_name=${real_name##*/}
				c=${real_name##*.}
			fi
		fi
		[ -z "$c" ] && c="unknown"

		# Вывод в стиле карточки
		out_printf "Process:   %s\n" "$c"
		out_printf "Details:   PID: %-8s | CPU: %-6s | MEM: %s\n" "$p" "$cpu%" "$m%"
		
		# Логируем в файл одной строкой
		log "TOP: PID=$p | CMD=$c | CPU=$cpu% | MEM=$m%"

		echo "$separator"
	done
}

# print_io
# Анализ активности ввода-вывода (I/O) для блочных устройств.
# - Выводит полные пути монтирования без обрезки.
# - Использует "карточный" стиль для удобства чтения на мобильных экранах.
# - Фильтрует устройства с активностью менее 0.1 MB.
print_io() {
	echo
	echo "[ I/O ] (Active Storage)"
	quiet_hint

	if [ ! -f /proc/diskstats ]; then
		log "Error: /proc/diskstats not found"
		return
	fi

	local tmp_mnt="/tmp/mnt_map"
	# Собираем актуальную карту монтирований
	mount | awk '{print $1, $3}' > "$tmp_mnt"

	# Обрабатываем diskstats и сопоставляем с точками монтирования
	local io_raw
	io_raw=$(awk -v m_file="$tmp_mnt" '
	BEGIN {
		while ((getline < m_file) > 0) mnt_map[$1] = $2
		close(m_file)
	}
	{
		# Фильтр основных блочных устройств (mmc, sd, dm)
		if ($3 ~ /^(mmcblk[0-9]+|sd[a-z]+|dm-[0-9]+)$/) {
			read_mb = $6 / 2048
			write_mb = $10 / 2048

			# Порог активности 0.1 MB
			if (read_mb > 0.1 || write_mb > 0.1) {
				dev_path = "/dev/block/" $3
				mnt = "unmapped/other"

				if (dev_path in mnt_map) {
					mnt = mnt_map[dev_path]
				} else {
					for (d in mnt_map) {
						if (d ~ "/" $3 "$") { mnt = mnt_map[d]; break }
					}
				}
				# Выводим сырые данные для последующей обработки циклом
				printf "%s|%s|%.1f|%.1f\n", $3, mnt, read_mb, write_mb
			}
		}
	}
	' /proc/diskstats)

	if [ -n "$io_raw" ]; then
		echo "----------------------------------------"
		while IFS="|" read -r dev mnt r_mb w_mb; do
			# Вывод в консоль: Устройство и его полный путь
			out_printf "Device:    %-10s\n" "$dev"
			out_printf "Mount:     %s\n" "$mnt"
			out_printf "Activity:  READ: %s MB | WRITE: %s MB\n" "$r_mb" "$w_mb"
			
			# Дублируем подробности в лог
			log "I/O: Dev=$dev | Mount=$mnt | R=${r_mb}MB | W=${w_mb}MB"
			
			echo "----------------------------------------"
		done <<< "$io_raw"
	else
		log "No active I/O detected (>0.1MB)"
		echo "----------------------------------------"
	fi

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
# Анализирует разделы системы в формате списка (Card UI).
# - Показывает тип ФС, точку монтирования, объем и источник (блочное устройство).
# - Единый стиль с блоками I/O и TOP PROCESSES.
check_partitions() {
	echo
	echo "[ SYSTEM PARTITIONS ]"
	quiet_hint

	local parts=(system system_ext product vendor odm cache data metadata apex persist)
	local separator="----------------------------------------"

	echo "$separator"

	for part in "${parts[@]}"; do
		local mp info size used free fstype backend
		
		mp=$(find_mountpoint "$part")
		[ -z "$mp" ] && continue

		# Получаем данные о размере
		info=$(df -h "$mp" 2>/dev/null | awk 'NR==2 {print $2,$3,$4}')
		[ -z "$info" ] && continue
		read -r size used free <<< "$info"

		# Определяем тип ФС
		fstype=$(awk -v m="$mp" '$2==m {print $3}' /proc/mounts | head -n1)
		[ -z "$fstype" ] && fstype="unknown"

		# Определяем источник (backend)
		backend="$(get_backend_from_mountinfo "$mp")"
		[ -z "$backend" ] && backend="unknown"

		# Вывод в стиле "карточки"
		out_printf "Partition: %-12s [%s]\n" "$part" "$fstype"
		out_printf "Mount:     %s\n" "$mp"
		out_printf "Device:    %s\n" "$backend"
		out_printf "Storage:   Total: %s | Used: %s | Free: %s\n" "$size" "$used" "$free"

		# Логируем всё одной строкой для истории
		log "[$part] Type: $fstype | Mount: $mp | Source: $backend | Size: $size | Used: $used | Free: $free"

		echo "$separator"
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
		[ -n "$version" ] && printf "           Version:      %s\n" "$version"
		[ -n "$desc" ]    && printf "           Description:  %s\n" "$desc"
		printf "           Status:       %s\n\n" "$state"
	done

	[ "$found" -eq 0 ] && echo "$(date +%H:%M:%S) - No Magisk modules installed"
}

# get_deep_sleep_stats
# Рассчитывает время глубокого сна (Deep Sleep) процессора.
get_deep_sleep_stats() {
	local uptime_ms=0 sleep_ms=0 deep_sleep_pct=0
	local total_idle_us=0 i=0 s_val=0
	local last_state_idx=0 cpu_count=0

	# 1. Находим индекс самого глубокого состояния сна (макс. число в названии папки)
	# Это универсально для всех ядер: от 3.18 до 6.x
	last_state_idx=$(ls -1 /sys/devices/system/cpu/cpu0/cpuidle/ 2>/dev/null | grep "state" | sed 's/state//' | sort -rn | head -n 1)

	# Если ничего не нашли, выходим
	if [ -z "$last_state_idx" ]; then
		log "Deep Sleep: unavailable (No cpuidle states)"
		return
	fi

	# 2. Получаем аптайм системы
	uptime_ms=$(awk '{print int($1 * 1000)}' /proc/uptime)
	
	# 3. Получаем количество ядер
	cpu_count=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | wc -l)
	[ "$cpu_count" -eq 0 ] && cpu_count=1

	# 4. Суммируем время этого "самого глубокого" состояния по всем ядрам
	for i in $(seq 0 $((cpu_count - 1))); do
		local target_path="/sys/devices/system/cpu/cpu$i/cpuidle/state${last_state_idx}/time"
		if [ -f "$target_path" ]; then
			s_val=$(cat "$target_path" 2>/dev/null)
			total_idle_us=$((total_idle_us + ${s_val:-0}))
		fi
	done

	# 5. Расчеты
	# Делим на количество ядер (обычно 8) и переводим из мкс в мс
	sleep_ms=$((total_idle_us / cpu_count / 1000))

	if [ "$sleep_ms" -gt 0 ] && [ "$uptime_ms" -gt 0 ]; then
		deep_sleep_pct=$(( sleep_ms * 100 / uptime_ms ))
		[ "$deep_sleep_pct" -gt 100 ] && deep_sleep_pct=100

		local sleep_min=$((sleep_ms / 1000 / 60))
		log "Deep Sleep: $deep_sleep_pct% (${sleep_min} min total)"
	else
		log "Deep Sleep: 0% (Device always active)"
	fi
}

# print_system
# Выводит базовую информацию о системе:
#  - uptime
#  - root: YES/NO
#  - system access level + версия Magisk (если есть)
#  - статус Zygisk
#  - статус SELinux и ABI
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

	# Показ времени активного использования и статуса deep_sleep
	log "Uptime: $(uptime -p)"
	get_deep_sleep_stats

	# Вывод языка, ROM и firmware частей прошивки
	log "Locale: $(get_system_locale)"
	log "Build: $(get_build_description)"
	log "Firmware: $(get_firmware_description)"

	# Проверка версии графического API
	log "Vulkan Driver: $(bootstrap.sh getprop ro.hardware.vulkan 2>/dev/null || echo "default")"
	log "OpenGL Vendor: $(getprop ro.hardware.egl 2>/dev/null || echo "default")"

	log "Screen Resolution: $(get_screen_resolution)"

	# Проверка на root, уровень системного доступа, версию Magisk и статус Zygisk
	if [ "$(id -u)" -eq 0 ]; then
		log "Root: ${GREEN}YES${NC}"
		log "System Access Level: $(detect_root_method) $(get_magisk_version)"
		log "Zygisk: $(get_zygisk_status)"
	else
		log "Root: ${RED}NO${NC}"
	fi

	# Проверка безопасности: статус SELinux и архитектуры процессора
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

	# Режим быстрой проверки без полного цикла
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "[ DRY RUN MODE ] — Only showing system info"
		echo
		print_header
		print_system
		log "DRY RUN completed successfully"
		return $EXIT_OK
	fi

	SYSTEM_STATUS=$EXIT_OK

	# Логика работы с файлом лога
	if [ "$NO_FILE_LOG" -eq 0 ]; then
		rotate_log
		touch "$LOG" 2>/dev/null
		# Записываем технический заголовок только в файл
		{
			echo "___________________________________________________"
			echo "LOG SESSION START: $(date '+%Y-%m-%d %H:%M:%S')"
			echo "___________________________________________________"
		} >> "$LOG"
	fi

	# Основной цикл вывода информации
	print_header
	check_storage
	check_memory
	check_cpu
	check_cpu_temp
	check_thermal_status
	check_gpu
	check_battery
	check_network
	check_iperf3_speed
	check_logcat
	print_top
	print_io
	check_partitions
	check_pixel_security

	# Блок расширенной информации
	if [ "$EXTENDED" -eq 1 ]; then
		print_magisk_modules
		print_system_extended
	else
		print_system
	fi

	# Финальный статус
	if [ "$NO_FILE_LOG" -eq 0 ]; then
		echo "========================================"
		echo "Log file: $LOG"
		echo "========================================"
	else
		echo "========================================"
		echo "     [ LOGGING TO FILE DISABLED ] "
		echo "========================================"
	fi

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
		-f|--no-file) NO_FILE_LOG=1;;
		--net-speed) ENABLE_NET_TEST=1;;
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
	# Проверка на запущенную копию (убедись, что функция объявлена выше)
	check_already_running || exit $?

	while true; do
		# 1. Засекаем начало ДО выполнения монитора
		start_time=$(date +%s)

		clear
		run_monitor

		# 2. Засекаем конец ПОСЛЕ выполнения
		end_time=$(date +%s)
		elapsed=$((end_time - start_time))

		if [ "$elapsed" -lt "$LOOP_INTERVAL" ]; then
			# Спим остаток времени
			sleep_time=$((LOOP_INTERVAL - elapsed))
			echo -e "\nWaiting ${sleep_time}s for next cycle... Ctrl + C to exit"
			sleep "$sleep_time"
		else
			# Если выполнение заняло дольше, чем указанный интервал
			echo -e "\n${YELLOW}WARNING: Execution time (${elapsed}s) exceeded loop interval ($LOOP_INTERVAL s)${NC}" >&2
			# Спим минимальный интервал, чтобы не "жарить" процессор в бесконечном цикле без пауз
			sleep 2
		fi
	done
else
	# Одиночный запуск: выполняем монитор и выходим с кодом результата.
	run_monitor
	exit $?
fi
