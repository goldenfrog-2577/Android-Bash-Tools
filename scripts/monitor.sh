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
	local fail=0

	# 1. Список жизненно важных утилит
	local critical_deps=(
		"awk" "grep" "sed" "df" "ps"
		"dumpsys" "getprop" "logcat"
		"find" "cat" "sleep"
	)

	# Тихая проверка наличия команд
	for dep in "${critical_deps[@]}"; do
		if ! command -v "$dep" >/dev/null 2>&1; then
			missing+=("$dep")
			fail=1
		fi
	done

	# 2. Проверка прав (Root) — только фатальная ошибка в stderr
	if [ "$(id -u)" -ne 0 ]; then
		echo -e "${RED}FATAL: This script MUST be run as ROOT (su)${NC}" >&2
		return $EXIT_INTERNAL
	fi

	# 3. Сообщение об отсутствующих утилитах
	if [ "$fail" -eq 1 ]; then
		echo -e "${RED}ERROR: Missing critical system utilities: ${missing[*]}${NC}" >&2
		echo "Please install them or ensure they are in your PATH" >&2
		return $EXIT_INTERNAL
	fi

	# 4. Проверка 'bc' — пишем только в основной лог, без вывода на экран
	if ! command -v bc >/dev/null 2>&1; then
		# Используем твою функцию log, которая пишет в файл/переменную, но не засоряет stdout при инициализации
		log "Note: 'bc' missing. Using Integer mode for math"
	fi

	# Возвращаем успех без лишнего шума в консоли
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
	lock_file="/data/local/tmp/${script_name}.lock"
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

# quiet_hint
# Если включён quiet-режим, печатает подсказку о том, где смотреть лог.
# Используемая в разделах перед выдачей подробной информации.
quiet_hint() {
	[ "$QUIET" -eq 1 ] && echo "Check details in log file: $LOG" && echo
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

# rotate_log
# Простая ротация лога: если в файле больше 1000 строк — перезаписать его одной строкой.
# Такой подход минимален и подходит для устройств с ограниченным дисковым пространством.
rotate_log() {
	if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 1000 ]; then
		echo "--- Log rotated ---" > "$LOG"
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
	echo "Bootloader: $(get_bootloader_status)"
	echo "Time: $(date)"
	echo
	echo "========================================"
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

	local storage_info="Unknown"
	local health_info=""
	local ufs_ver="UFS"

	# 1. Определяем тип, вендор и модель
	if [ -d "/sys/class/block/sda" ]; then
		local vendor=$(cat /sys/class/block/sda/device/vendor 2>/dev/null | xargs)
		local model=$(cat /sys/class/block/sda/device/model 2>/dev/null | xargs)

		# Определяем версию: Alioth (SM8250) это всегда 3.1
		# Но для универсальности проверим пропсы
		local prop_ver=$(getprop sys.storage.ufs_version)
		if [ -n "$prop_ver" ]; then
			ufs_ver="UFS $prop_ver"
		elif [[ "$(getprop ro.board.platform)" == "kona" ]]; then
			ufs_ver="UFS 3.1"
		fi

		storage_info="$ufs_ver ($vendor $model)"

		# 2. Поиск здоровья (Life Time)
		# Путь 1: Прямой поиск файла health_descriptor
		local h_file=$(find /sys/devices/platform/soc -name "health_descriptor" 2>/dev/null | head -n 1)

		# Путь 2: Если первый пуст, ищем в узлах контроллера (часто на Xiaomi)
		[ -z "$h_file" ] && h_file=$(find /sys/class/ufs-bsg -name "health_descriptor" 2>/dev/null | head -n 1)

		if [ -f "$h_file" ]; then
			# Читаем 3-й и 4-й байты (Estimation A и B)
			# Обычно это HEX значения. 0x01 = 0-10% износа.
			local life_a=$(grep "Device Life Time Estimation A" "$h_file" | awk '{print $NF}' | tr -d '[]')
			if [ -n "$life_a" ]; then
				# Конвертируем HEX в DEC для расчета
				local life_dec=$((life_a))
				# Если 0x01 -> 10%, 0x02 -> 20%...
				local pct=$(( (life_dec - 1) * 10 ))
				[ "$pct" -lt 0 ] && pct=0

				local h_color=$GREEN
				[ "$pct" -gt 50 ] && h_color=$YELLOW
				[ "$pct" -gt 80 ] && h_color=$RED
				health_info="${h_color}${pct}% used${NC}"
			fi
		fi
	elif [ -d "/sys/block/mmcblk0" ]; then
		storage_info="eMMC"
		local life_time=$(cat /sys/block/mmcblk0/device/life_time 2>/dev/null | xargs)
		[ -n "$life_time" ] && health_info="$life_time used"
	fi

	log "Type:   $storage_info"
	[ -n "$health_info" ] && log "Health: $health_info"

	# 3. Информация о разделах
	df -h /data | tail -1 | while read -r _ size used avail percent _; do
		use=${percent%\%}
		log "Total:  ${size//G/ GB} | Used: ${used//G/ GB} | Free: ${avail//G/ GB}"

		local s_color=$GREEN
		[ "$use" -ge "$DISK_WARN" ] && s_color=$YELLOW
		[ "$use" -ge "$DISK_CRIT" ] && s_color=$RED
		log "Status: ${s_color}OK (${percent} used)${NC}"
	done
}

# check_memory
# Анализирует состояние оперативной памяти и ZRAM, выводит вердикт в строке Status.
check_memory() {
	local total avail used percent avail_mb total_gb
	local z_total z_free z_used z_total_mb
	echo
	echo "[ MEMORY ] (RAM)"
	quiet_hint

	# 1. Читаем MemInfo
	total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
	avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)

	# 2. Форматируем общий объем
	total_gb=$(awk "BEGIN {printf \"%.1f\", $total / 1024 / 1024}")
	log "Total:  ${total_gb} GB"

	# 3. Обработка ZRAM
	z_total=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
	z_free=$(awk '/SwapFree/ {print $2}' /proc/meminfo)

	if [ "$z_total" -gt 0 ]; then
		z_used=$(( (z_total - z_free) / 1024 ))
		z_total_mb=$(( z_total / 1024 ))
		log "ZRAM:   ${z_used} MB used / ${z_total_mb} MB total"
	fi

	# 4. Расчет нагрузки
	used=$((total - avail))
	percent=$((used * 100 / total))
	avail_mb=$((avail / 1024))

	# 5. Выставление статуса согласно новой концепции
	local s_color=$GREEN
	local s_label="OK"

	if [ "$percent" -ge "$RAM_CRIT" ]; then
		s_color=$RED
		s_label="CRITICAL"
		SYSTEM_STATUS=$EXIT_CRITICAL
	elif [ "$percent" -ge "$RAM_WARN" ]; then
		s_color=$YELLOW
		s_label="WARNING"
		[ "$SYSTEM_STATUS" -lt $EXIT_WARNING ] && SYSTEM_STATUS=$EXIT_WARNING
	fi

	log "Status: ${s_color}${s_label} (${percent}% used, ${avail_mb} MB free)${NC}"
}

# get_cpu_freqs_detailed
# Опрашивает каждое ядро: выводит текущую и максимальную частоты (cur/max).
# Помогает отследить архитектуру Big.LITTLE и понять лимиты каждого ядра.
get_cpu_freqs_detailed() {
	local cpu_dir="/sys/devices/system/cpu"
	local f_cur f_max i online_status core_info

	log "CPU Frequencies (Current / Max):"

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
# Анализирует нагрузку CPU и выводит вердикт в едином стиле Status.
check_cpu() {
	local cores load_pct cpu_name
	echo
	echo "[ CPU ]"
	quiet_hint

	# 1. Снимаем первый замер
	local stat1=$(grep '^cpu ' /proc/stat)
	local user1=$(echo $stat1 | awk '{print $2}')
	local nice1=$(echo $stat1 | awk '{print $3}')
	local syst1=$(echo $stat1 | awk '{print $4}')
	local idle1=$(echo $stat1 | awk '{print $5}')
	local iow1=$(echo $stat1 | awk '{print $6}')
	local irq1=$(echo $stat1 | awk '{print $7}')
	local sir1=$(echo $stat1 | awk '{print $8}')

	sleep 0.5

	# 2. Снимаем второй замер
	local stat2=$(grep '^cpu ' /proc/stat)
	local user2=$(echo $stat2 | awk '{print $2}')
	local nice2=$(echo $stat2 | awk '{print $3}')
	local syst2=$(echo $stat2 | awk '{print $4}')
	local idle2=$(echo $stat2 | awk '{print $5}')
	local iow2=$(echo $stat2 | awk '{print $6}')
	local irq2=$(echo $stat2 | awk '{print $7}')
	local sir2=$(echo $stat2 | awk '{print $8}')

	# 3. Считаем дельту (Shell Arithmetic)
	local PrevIdle=$((idle1 + iow1))
	local Idle=$((idle2 + iow2))
	local PrevNonIdle=$((user1 + nice1 + syst1 + irq1 + sir1))
	local NonIdle=$((user2 + nice2 + syst2 + irq2 + sir2))
	local PrevTotal=$((PrevIdle + PrevNonIdle))
	local Total=$((Idle + NonIdle))

	local total_d=$((Total - PrevTotal))
	local idle_d=$((Idle - PrevIdle))

	if [ "$total_d" -gt 0 ]; then
		load_pct=$(( (total_d - idle_d) * 100 / total_d ))
	else
		load_pct=0
	fi

	# 4. Информация о железе
	cpu_name=$(getprop ro.soc.model)
	[ -z "$cpu_name" ] && cpu_name=$(getprop ro.board.platform)
	cores=$(grep -c processor /proc/cpuinfo)

	# 5. Цвета для процентов нагрузки
	local load_color=$GREEN
	[ "$load_pct" -gt 60 ] && load_color=$YELLOW
	[ "$load_pct" -gt 85 ] && load_color=$RED

	log "Model:  $cpu_name"
	log "Board:  $(get_board_name)"
	log "Usage:  ${load_color}${load_pct}%${NC} | Cores: $cores active"
	log "Governor: $(get_cpu_governor)"

	get_cpu_freqs_detailed

	# 6. Проверка троттлинга
	local cur_max_f factory_max_f base="/sys/devices/system/cpu/cpu0/cpufreq"
	cur_max_f=$(cat "$base/scaling_max_freq" 2>/dev/null)
	factory_max_f=$(cat "$base/cpuinfo_max_freq" 2>/dev/null)

	if [ -n "$cur_max_f" ] && [ -n "$factory_max_f" ]; then
		if [ "$cur_max_f" -lt "$factory_max_f" ]; then
			log "Throttling: ${RED}ACTIVE${NC} ($((cur_max_f/1000)) MHz limit)"
		else
			log "Throttling: ${GREEN}Inactive${NC}"
		fi
	fi

	# 7. Унифицированный статус
	local s_color=$GREEN
	local s_label="OK"
	local s_msg="CPU load normal"

	if [ "$load_pct" -gt 90 ]; then
		s_color=$RED
		s_label="CRITICAL"
		s_msg="CPU Overload!"
		SYSTEM_STATUS=$EXIT_CRITICAL
	elif [ "$load_pct" -gt 70 ]; then
		s_color=$YELLOW
		s_label="WARNING"
		s_msg="High CPU load"
		[ "$SYSTEM_STATUS" -lt $EXIT_WARNING ] && SYSTEM_STATUS=$EXIT_WARNING
	fi

	log "Status: ${s_color}${s_label} (${s_msg})${NC}"
}


# check_cpu_temp
# Опрашивает тепловые датчики каждого ядра. При отсутствии данных по ядрам 
# использует температуру батареи в качестве ориентира SoC.
check_cpu_temp() {
	local max=0 z type raw t i
	local cores_ok=0

	echo
	echo "[ CPU TEMP ]"
	quiet_hint

	log "Core Temperatures:"

	# Собираем карту путей thermal_zone один раз для ускорения работы
	local tz_map
	tz_map=$(grep -r "" /sys/class/thermal/thermal_zone*/type 2>/dev/null)

	for i in {0..7}; do
		local sensor_name=""
		case $i in
			0) sensor_name="cpu-0-0-usr" ;;
			1) sensor_name="cpu-0-1-usr" ;;
			2) sensor_name="cpu-0-2-usr" ;;
			3) sensor_name="cpu-0-3-usr" ;;
			4) sensor_name="cpu-1-4-usr" ;;
			5) sensor_name="cpu-1-5-usr" ;;
			6) sensor_name="cpu-1-6-usr" ;;
			7) sensor_name="cpu-1-7-usr" ;;
		esac

		local core_t="N/A"
		# Находим путь к файлу температуры для конкретного датчика
		local t_path=$(echo "$tz_map" | grep "$sensor_name" | cut -d: -f1 | sed 's/type/temp/')

		if [ -n "$t_path" ] && [ -f "$t_path" ]; then
			raw=$(cat "$t_path" 2>/dev/null)
			if [ -n "$raw" ] && [ "$raw" -gt 0 ]; then
				# Конвертируем из микроградусов в градусы
				t=$((raw > 1000 ? raw / 1000 : raw))
				core_t="${t}°C"
				[ "$t" -gt "$max" ] && max="$t"
				cores_ok=$((cores_ok + 1))
			fi
		fi

		# Логика цвета
		local c_color=$NC
		local t_val=${core_t%°C}
		if [[ "$t_val" =~ ^[0-9]+$ ]]; then
			[ "$t_val" -gt 55 ] && c_color=$YELLOW
			[ "$t_val" -gt 75 ] && c_color=$RED
		fi

		# Формируем строку заранее, чтобы printf не конфликтовал с функцией log
		local core_display
		core_display=$(printf "${c_color}%4s${NC}" "$core_t")
		log "              Core $i: $core_display"
	done

	# Итоговый расчет SoC
	local final_t=0
	local label="SoC Max Temp"

	if [ "$cores_ok" -gt 0 ]; then
		final_t=$max
	else
		# План Б: Температура батареи
		raw=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
		if [ -n "$raw" ]; then
			final_t=$((raw / 10))
			label="SoC Temp (battery proxy)"
		fi
	fi

	# Светофор для итоговой температуры
	local status_color=$GREEN
	[ "$final_t" -gt 60 ] && status_color=$YELLOW
	[ "$final_t" -gt 80 ] && status_color=$RED

	if [ "$final_t" -gt 0 ]; then
		log "$label: ${status_color}${final_t}°C ${NC}"
	else
		log "$label: ${RED}Unavailable${NC}"
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

	local BC_INSTALLED gpu_model gpu_freq gpu_load gpu_gov gpu_temp
	BC_INSTALLED=$(command -v bc 2>/dev/null)

	gpu_model="Unknown"
	gpu_freq="N/A"
	gpu_load="N/A"
	gpu_gov="N/A"
	gpu_temp="N/A"

		# 1. Поиск температуры (Адаптивный)
		for f in /sys/class/thermal/thermal_zone*/type; do
		local type=$(cat "$f" 2>/dev/null)
		if [[ "$type" == "gpuss-0-usr" || "$type" == "gpu-usr" || "$type" == "gpu" ]]; then
			local t_path="${f%type}temp"
			t_raw=$(cat "$t_path" 2>/dev/null)
			if [ -n "$t_raw" ] && [ "$t_raw" -gt 0 ]; then
				t_val=$((t_raw > 1000 ? t_raw / 1000 : t_raw))
				gpu_temp="${t_val}°C"
				break
			fi
		fi
	done

	# 2. Определение модели и метрик (Adreno)
	if [ -d /sys/class/kgsl/kgsl-3d0 ]; then
		gpu_model="Adreno (Qualcomm)"
		local path="/sys/class/kgsl/kgsl-3d0"

		# Частота: если gpuclk дает 0, пробуем cur_freq (бывает в некоторых ядрах)
		local raw_freq=$(cat "$path/gpuclk" 2>/dev/null)
		if [ -z "$raw_freq" ] || [ "$raw_freq" -eq 0 ]; then
			raw_freq=$(cat "$path/devfreq/cur_freq" 2>/dev/null)
		fi
		[ -n "$raw_freq" ] && gpu_freq="$((raw_freq / 1000000)) MHz"

		gpu_load=$(awk '{if($2>0) printf "%.1f%%", ($1/$2)*100; else print "0%"}' "$path/gpubusy" 2>/dev/null)
		gpu_gov=$(cat "$path/devfreq/governor" 2>/dev/null)

	# 3. Определение модели и метрик (Mali)
	elif ls /sys/devices/platform/*mali* >/dev/null 2>&1 || [ -d /sys/module/mali_kbase ]; then
		gpu_model="Mali (MediaTek/Exynos/Tensor)"
		local mali_path
		mali_path=$(ls -d /sys/devices/platform/*mali* 2>/dev/null | head -1)
		[ -z "$mali_path" ] && mali_path="/sys/class/misc/mali0/device"

		# Частота Mali
		for f in "$mali_path/cur_freq" "$mali_path/clock" "/sys/kernel/debug/mali0/curr_freq"; do
			if [ -f "$f" ]; then
				local raw_f=$(cat "$f" 2>/dev/null)
				[ -n "$raw_f" ] && [ "$raw_f" -gt 0 ] && gpu_freq="$((raw_f / 1000000)) MHz"; break
			fi
		done
		# Нагрузка Mali
		for f in "$mali_path/utilization" "/sys/module/mali_kbase/parameters/mali_gpu_utilization"; do
			if [ -f "$f" ]; then
				local raw_l=$(cat "$f" 2>/dev/null)
				[ -n "$raw_l" ] && gpu_load="${raw_l}%"; break
			fi
		done
		gpu_gov=$(cat "$mali_path/devfreq/governor" 2>/dev/null)
	fi

	[ "$gpu_model" = "Unknown" ] && { log "GPU: unavailable"; return; }

	# 4. Цветовая индикация температуры
	local t_color=$NC
	if [[ "$gpu_temp" =~ ^[0-9]+ ]]; then
		local t_num=${gpu_temp%°C}
		[ "$t_num" -gt 55 ] && t_color=$YELLOW
		[ "$t_num" -gt 75 ] && t_color=$RED
	fi

	# 5. Вывод основных данных
	log "Model:       $gpu_model"
	log "Frequency:   $gpu_freq"
	log "Governor:    $gpu_gov"
	log "Temperature: ${t_color}${gpu_temp}${NC}"

	# 6. Анализ нагрузки и логирование статуса
	local load_val=$(echo "$gpu_load" | tr -d '%')
	local gpu_warn=0 gpu_crit=0

	if [[ "$load_val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		if [ -n "$BC_INSTALLED" ]; then
			gpu_warn=$(echo "$load_val > ${GPU_WARN:-70}" | bc)
			gpu_crit=$(echo "$load_val > ${GPU_CRIT:-90}" | bc)
		else
			[ "${load_val%.*}" -gt "${GPU_WARN:-70}" ] && gpu_warn=1
			[ "${load_val%.*}" -gt "${GPU_CRIT:-90}" ] && gpu_crit=1
		fi
	fi

	if [ "$gpu_crit" -eq 1 ]; then
		log "Load:       ${RED}${gpu_load} (CRITICAL)${NC}"
		SYSTEM_STATUS=$EXIT_CRITICAL
	elif [ "$gpu_warn" -eq 1 ]; then
		log "Load:       ${YELLOW}${gpu_load} (HIGH)${NC}"
		[ "$SYSTEM_STATUS" -lt $EXIT_WARNING ] && SYSTEM_STATUS=$EXIT_WARNING
	else
		log "Load:        $gpu_load"
	fi

	# 7. Refresh Rate
	local fps_data
	fps_data=$(dumpsys SurfaceFlinger --latency | head -1 | awk '{if($1>0) printf "%.0f", 1000000000/$1}')
	[ -z "$fps_data" ] && fps_data="N/A"

	local f_color=$GREEN
	[ "$fps_data" != "N/A" ] && {
		[ "$fps_data" -lt 40 ] && f_color=$RED
		[ "$fps_data" -lt 90 ] && [ "$fps_data" -ge 40 ] && f_color=$YELLOW
	}
	log "Refresh Rate: ${f_color}${fps_data}${NC} HZ"
}

# check_battery
# Мониторинг АКБ: уровень, здоровье, мощность и детальный тип зарядки.
check_battery() {
	echo
	echo "[ BATTERY & HEALTH ]"
	quiet_hint

	local b="/sys/class/power_supply/battery"
	local w="/sys/class/power_supply/wireless"
	local cap status temp volt health cycles health_pct current_now power_w charge_type wireless_temp reverse_status

	[ ! -d "$b" ] && { log "Battery data: unavailable"; return; }

	# 1. Основные параметры
	cap=$(cat "$b/capacity" 2>/dev/null)
	status=$(cat "$b/status" 2>/dev/null)
	temp=$(( $(cat "$b/temp" 2>/dev/null) / 10 ))
	volt=$(( $(cat "$b/voltage_now" 2>/dev/null) / 1000 ))

		# 2. Проверка реверсивной зарядки
	reverse_status="Off"
	for r_node in "$w/reverse_chg_mode" "$w/wireless_out" "/sys/class/google_battery/reverse_chg_mode"; do
		if [ -f "$r_node" ] && [ "$(cat "$r_node" 2>/dev/null)" = "1" ]; then
			reverse_status="${MAGENTA}Active (Battery Share)${NC}"
			charge_type="Wireless Out (Donor)"
			break
		fi
	done

	# 3. Определение типа зарядки
	if [ "$reverse_status" = "Off" ]; then
		if [ "$status" = "Charging" ] || [ "$status" = "Full" ]; then
			if [ -d "$w" ] && [ "$(cat "$w/online" 2>/dev/null)" = "1" ]; then
				charge_type="Wireless"
			elif [ -d "/sys/class/power_supply/usb" ]; then
				local usb_type=$(cat /sys/class/power_supply/usb/type 2>/dev/null)
				local usb_voltage=$(( $(cat /sys/class/power_supply/usb/voltage_now 2>/dev/null) / 1000 ))

				if [ "$usb_voltage" -gt 6000 ]; then
					charge_type="Fast Charging (PD/QC)"
				elif [[ "$usb_type" == *"PD"* ]]; then
					charge_type="Fast Charging (USB-PD)"
				elif [ "$usb_voltage" -gt 0 ]; then
					charge_type="Standard (USB)"
				else
					charge_type="Slow (USB/PC)"
				fi
			else
				charge_type="Plugged (Unknown)"
			fi
		else
			# Вместо дублирования Discharging
			charge_type="Battery (Internal)"
		fi
	fi

	# 4. Датчик беспроводной катушки (мониторим и при входе, и при выходе энергии)
	local w_raw=$(grep -l "wireless_therm" /sys/class/thermal/thermal_zone*/type 2>/dev/null | sed 's/type/temp/' | xargs cat 2>/dev/null)
	if [ -n "$w_raw" ]; then
		wireless_temp=$(( w_raw / 1000 ))
		# Добавляем инфо о катушке, если она теплая или активна беспроводка
		if [[ "$charge_type" =~ "Wireless" ]]; then
			charge_type="$charge_type (Coil: ${wireless_temp}°C)"
		fi
	fi

	# 5. Расчет мгновенной мощности
	current_now=$(cat "$b/current_now" 2>/dev/null)
	if [ -n "$current_now" ] && [ "$volt" -gt 0 ]; then
		local i_ma=$((current_now / 1000))
		power_w=$(awk -v v=$volt -v i=$i_ma 'BEGIN { printf "%.2f", (v * i) / 1000000 }')
		display_power="${power_w#-}W"
		display_current="${i_ma#-}mA"
	else
		display_power="N/A"
		display_current="N/A"
	fi

	# 6. Здоровье и циклы
	health=$(cat "$b/health" 2>/dev/null)
	cycles=$(cat "$b/cycle_count" 2>/dev/null)
	[ -z "$cycles" ] && cycles="N/A"

	local full=$(cat "$b/charge_full" 2>/dev/null)
	local design=$(cat "$b/charge_full_design" 2>/dev/null)
	if [ -n "$full" ] && [ -n "$design" ] && [ "$design" -gt 0 ]; then
		health_pct=$(( full * 100 / design ))
		[ "$health_pct" -gt 100 ] && health_pct=100
		health="$health ($health_pct%)"
	fi

	# 7. Вывод
	local s_color=$NC
	[ "$status" = "Charging" ] && s_color=$GREEN
	[ "$status" = "Discharging" ] && [ "$cap" -lt 20 ] && s_color=$RED

	log "Status:      ${s_color}${status}${NC} ($cap%)"
	log "Type:        $charge_type"
	[ "$reverse_status" != "Off" ] && log "Reverse:     $reverse_status"
	log "Health:      $health"
	log "Cycles:      $cycles"
	log "Temperature: ${temp}°C"
	log "Current:     $display_current"
	log "Power:       $display_power"
	log "Voltage:     ${volt}mV"

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
		command -v iperf3 >/dev/null 2>&1 && log "iPerf3:     Ready (use --net-speed or -s to test)"
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
# Выводит список топ-5 процессов. Память выводится в MB/GB для лучшей читаемости.
print_top() {
	local p c cpu rss real_name mem_formatted
	local separator="----------------------------------------"

	# Берем топ-5 процессов. rss — это память в KB.
	local top_data
	top_data=$(ps -Ao pid,comm,%cpu,rss --sort=-%cpu 2>/dev/null | head -n 6 | tail -n +2)
	[ -z "$top_data" ] && return

	# Логика BRIEF_MODE (по CPU)
	if [ "$BRIEF_MODE" = "1" ]; then
		local top_cpu=$(echo "$top_data" | awk '{print int($3); exit}')
		[ "$top_cpu" -lt 20 ] && return
		log "${YELLOW}Warning: High CPU usage detected (${top_cpu}%)${NC}"
	fi

	echo
	echo "[ TOP PROCESSES ]"
	[ "$BRIEF_MODE" = "1" ] && echo "(!) High load detected:"
	quiet_hint

	echo "$separator"

	echo "$top_data" | while read -r p c cpu rss; do
		# Имя процесса (твоя логика декодирования cmdline)
		if [[ "$c" == "app_process"* ]] || [[ "$c" == "base" ]] || [[ "$c" == "sh" ]]; then
			if [ -f "/proc/$p/cmdline" ]; then
				real_name=$(tr '\0' '\n' < "/proc/$p/cmdline" | head -n 1)
				real_name=${real_name##*/}
				# Убираем лишние точки в именах пакетов для компактности
				c=${real_name##*.}
			fi
		fi
		[ -z "$c" ] && c="unknown"

		# Конвертация RSS (KB) в MB или GB
		# 1048576 KB = 1024 MB = 1 GB
		if [ "$rss" -ge 1048576 ]; then
			mem_formatted=$(awk -v r="$rss" 'BEGIN {printf "%.2f GB", r/1024/1024}')
		else
			mem_formatted=$(awk -v r="$rss" 'BEGIN {printf "%d MB", r/1024}')
		fi

		# Пример логики для индикации (внутри твоего цикла)
		local mem_color=$NC
		if [ "$rss" -ge 1048576 ]; then # Больше 1 GB
			mem_color=$RED
		elif [ "$rss" -ge 524288 ]; then # Больше 512 MB
			mem_color=$YELLOW
		fi

		# Вывод
		out_printf "Process:   %s\n" "$c"
		out_printf "Details:   PID: %-8s | CPU: %-6s | MEM: ${mem_color}%s${NC}\n" "$p" "$cpu%" "$mem_formatted"

		log "TOP: PID=$p | CMD=$c | CPU=$cpu% | MEM=$mem_formatted"
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
			log "I/O: Device=$dev | Mount=$mnt | R=${r_mb}MB | W=${w_mb}MB"
			
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
# Сканирует основные разделы системы, определяет тип файловой системы, режим доступа (Read-Only/Read-Write) и отображает статистику занятого места.
check_partitions() {
	echo
	echo "[ SYSTEM PARTITIONS ]"
	quiet_hint

	local parts=(system system_ext product vendor odm cache data metadata apex persist)
	local separator="----------------------------------------"

	echo "$separator"

	for part in "${parts[@]}"; do
		local mp info size used free fstype backend opts access

		mp=$(find_mountpoint "$part")
		[ -z "$mp" ] && continue

		# Получаем данные о размере
		info=$(df -h "$mp" 2>/dev/null | awk 'NR==2 {print $2,$3,$4}')
		[ -z "$info" ] && continue
		read -r size used free <<< "$info"

		# Определяем тип ФС и опции монтирования
		# Извлекаем 3-ю (тип) и 4-ю (опции) колонки из /proc/mounts
		read -r fstype opts <<< "$(awk -v m="$mp" '$2==m {print $3, $4}' /proc/mounts | head -n1)"
		[ -z "$fstype" ] && fstype="unknown"

		# Определяем режим доступа: ищем 'ro' или 'rw' в начале строки опций или после запятой
		if [[ ",$opts," == *",ro,"* ]]; then
			access="-ro"
		elif [[ ",$opts," == *",rw,"* ]]; then
			access="-rw"
		else
			access="-??"
		fi

		# Определяем источник (backend)
		backend="$(get_backend_from_mountinfo "$mp")"
		if [ -z "$backend" ] || [ "$backend" = "unknown" ]; then
			[ "$fstype" = "tmpfs" ] && backend="RAM (tmpfs)" || backend="virtual"
		fi

		# Вывод в стиле "карточки" с новым форматом заголовка
		out_printf "Partition: %s [%s] [%s]\n" "$part" "$fstype" "$access"
		out_printf "Mount:     %s\n" "$mp"
		out_printf "Device:    %s\n" "$backend"
		out_printf "Storage:   Total: %s | Used: %s | Free: %s\n" "$size" "$used" "$free"

		# Логируем всё одной строкой для истории
		log "[$part] Type: $fstype ($access) | Mount: $mp | Source: $backend | Size: $size | Used: $used | Free: $free"

		echo "$separator"
	done
}

# check_pixel_security
# Глубокий анализ безопасности и состояния чипов Google Tensor (6-10 серии).
# Для старых моделей Pixel (1-5) выводит сообщение об отсутствии чипа Tensor.
check_pixel_security() {
	local soc_name vendor product_model
	soc_name=$(getprop ro.soc.model)
	vendor=$(getprop ro.product.manufacturer | tr '[:upper:]' '[:lower:]')
	product_model=$(getprop ro.product.model)

	# 1. Проверка вендора. Если не Google — выходим молча.
	if [[ "$vendor" != *"google"* ]]; then
		return
	fi

	echo
	echo "[ GOOGLE PIXEL STATS ]"
	quiet_hint

	# 2. Проверка на наличие Tensor (gs, zuma, laguna)
	if [[ ! "$soc_name" =~ ^(gs|zuma|laguna) ]]; then
		log "Model:          $product_model"
		log "Status:         ${YELLOW}Feature Unavailable${NC}"
		log "Reason:         Google Tensor SoC not detected"
		return
	fi

	# 3. Определение поколения Tensor
	local tensor_gen="Tensor (Generic)"
	case "$soc_name" in
		"gs101")   tensor_gen="Tensor G1 (Pixel 6)" ;;
		"gs201")   tensor_gen="Tensor G2 (Pixel 7)" ;;
		"gs301")   tensor_gen="Tensor G3 (Pixel 8)" ;;
		"zuma"*)   tensor_gen="Tensor G4 (Pixel 9)" ;;
		"laguna"*) tensor_gen="Tensor G5 (Pixel 10)" ;;
	esac
	log "Platform:       $tensor_gen ($soc_name)"

	# 4. Анализ TPU (NPU) — ищем универсальный путь для всех поколений
	local tpu_path=""
	# Проверяем типовые пути для разных поколений
	for path in "/sys/class/accel/accel0" "/sys/devices/platform/10000000.tpu" "/sys/devices/platform/edgetpu"; do
		if [ -d "$path" ]; then
			tpu_path="$path"
			break
		fi
	done

	if [ -n "$tpu_path" ]; then
		log "TPU Engine:     ${GREEN}Detected${NC} (Google AI Core)"
	else
		log "TPU Engine:     ${YELLOW}Hidden/Protected${NC}"
	fi

	# 5. Titan M2 / StrongBox
	local strongbox
	if [ -d "/sys/class/misc/strongbox" ] || [ -d "/dev/strongbox" ]; then
		strongbox="${GREEN}Hardware (Titan M2)${NC}"
	else
		strongbox="${YELLOW}Software/Emulated${NC}"
	fi
	log "Security Chip:  $strongbox"

	# 6. Состояние Verified Boot и AVB
	local avb_state=$(getprop ro.boot.vbmeta.device_state)
	local vboot=$(getprop ro.boot.verifiedbootstate)
	log "AVB State:      ${avb_state:-unknown} ($vboot)"

	# 7. AOC (Always On Computer)
	if [ -d "/sys/devices/platform/aoc" ]; then
		local aoc_status=$(cat /sys/devices/platform/aoc/status 2>/dev/null || echo "Active")
		log "AOC Subsystem:  $aoc_status"
	fi

	# 8. Модем
	local modem_ver=$(getprop gsm.version.baseband | cut -d',' -f1)
	[ -n "$modem_ver" ] && log "Modem Baseband: $modem_ver"

	# 9. Загрузчик
	local bootloader_state=$(getprop ro.boot.flash.locked)
	if [ "$bootloader_state" = "1" ]; then
		log "Bootloader:     ${GREEN}Locked${NC}"
	else
		log "Bootloader:     ${RED}Unlocked (Risk)${NC}"
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

# check_wakelocks
# Анализирует активные вейклоки (Partial Wake Locks) через dumpsys power.
# Извлекает Tag (имя) и Owner (пакет/UID), определяет статус удержания.
# Ограничивает вывод до 5 наиболее актуальных записей для чистоты лога.
check_wakelocks() {
	echo
	echo "[ WAKELOCKS ] (PowerManager Analysis)"
	quiet_hint

	local raw_data
	raw_data=$(dumpsys power | sed -n '/Wake Locks: size=/,/^[[:space:]]*$/p' | grep "PARTIAL_WAKE_LOCK")

	if [ -n "$raw_data" ]; then
		echo "----------------------------------------------------"
		echo "$raw_data" | head -n 5 | while read -r line; do
			# Извлекаем тег (теперь ищем любые кавычки)
			local tag=$(echo "$line" | grep -oE "['\"][^'\"]+['\"]" | head -n 1 | tr -d "'\"")

			# Извлекаем владельца (UID или имя пакета)
			local owner=$(echo "$line" | grep -oE '\((uid=)?[0-9a-zA-Z._-]+\)' | tr -d '() uid=')
			[ -z "$owner" ] && owner=$(echo "$line" | grep -oE '[0-9]{4,}' | head -n 1)

			[ -z "$tag" ] && tag="System/Kernel"
			[ -z "$owner" ] && owner="Unknown"

			local clean_tag=$(echo "$tag" | cut -c1-30)

			# Определяем статус для лога (с цветом) и для экрана (текстом)
			local is_active="Active"
			local log_status="${GREEN}Active${NC}"
			if echo "$line" | grep -qE "disabled|released"; then
				is_active="Inactive"
				log_status="${YELLOW}Inactive${NC}"
			fi

			# Чистый вывод в колонки без управляющих символов
			printf "Tag:    %-30s\n" "$clean_tag"
			printf "Owner:  %-30s\n" "$owner"
			printf "Status: %s\n" "$is_active"

			# А вот здесь, в основной строке лога, цвета будут работать корректно
			log "Wakelock: $tag ($owner) -> $log_status"
			echo "----------------------------------------------------"
		done
	else
		log "Status: ${GREEN}OK${NC} (No active partial wake locks)"
	fi
}

# check_integrity_status
# Пытается определить уровень доверия Google Play Integrity.
check_integrity_status() {
	local integrity="None"
	local color=$RED
	local g_integrity s_integrity basic vboot

	# 1. Проверка через системные пропсы
	g_integrity=$(getprop sys.usb.config.meta 2>/dev/null)
	s_integrity=$(getprop ro.com.google.clientidbase.ms 2>/dev/null)

	# 2. Базовые флаги
	basic=$(getprop ro.boot.flash.locked)
	vboot=$(getprop ro.boot.verifiedbootstate)

	# Проверка на базовую целостность
	local bl_check
	# Очищаем вывод от ANSI-цветов с помощью sed напрямую
	bl_check=$(get_bootloader_status_hard 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')

	if [[ "$vboot" == "green" ]] && [[ "$basic" == "1" ]]; then
		integrity="MEETS_BASIC_INTEGRITY"
		color=$YELLOW
	fi

	# 3. Логика для Strong/Device
	if [[ "$bl_check" == *"Locked (Official)"* ]]; then
		integrity="MEETS_STRONG_INTEGRITY"
		color=$GREEN
	elif [[ "$bl_check" == *"Fake Locked"* ]]; then
		integrity="MEETS_DEVICE_INTEGRITY (Spoofed)"
		color=$YELLOW
	fi

	echo -e "${color}${integrity}${NC}"
}

# get_bootloader_status
# Жёсткая проверка: ищем признаки разблокировки, которые пытаются скрыть.
get_bootloader_status() {
	local lock_prop verified_prop secure_boot lk_state

	# 1. Стандартные пропсы
	lock_prop=$(getprop ro.boot.flash.locked)
	verified_prop=$(getprop ro.boot.verifiedbootstate)

	# 2. Поиск в cmdline (там часто остается реальное состояние)
	# Ищем упоминания "orange" (разблокирован) или флаги безопасности
	local cmdline=$(cat /proc/cmdline)

	# 3. Эвристика для Xiaomi (иногда реальный статус в ro.boot.status)
	lk_state=$(getprop ro.boot.status) # Бывает 'locked' или 'unlocked'

	local final_status="Unknown"
	local color=$NC

	# Логика определения "правды"
	if [[ "$cmdline" == *"orange"* ]] || [[ "$cmdline" == *"verifiedbootstate=orange"* ]] || [[ "$lk_state" == "unlocked" ]]; then
		final_status="Unlocked (Fake Locked Detected)"
		color=$RED
	elif [ "$lock_prop" = "0" ]; then
		final_status="Unlocked"
		color=$RED
	elif [ "$lock_prop" = "1" ] && [ "$verified_prop" = "green" ]; then
		# Если пропсы говорят "Locked", проверяем, не подсунул ли их Magisk
		# Обычно на кастомных ядрах с разблокированным лоадером 'orange' подменяется на 'green'
		final_status="Locked (Official/Spoofed)"
		color=$GREEN
	fi

	echo -e "${color}${final_status}${NC}"
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
	log "Play Integrity: $(check_integrity_status)"
	log "ABI: $(getprop ro.product.cpu.abi)"
}

# print_system_extended
# Расширенный блок system info — содержит язык, описание прошивки и разрешение экрана, помимо стандартной информации из print_system.
print_system_extended() {
	echo
	echo "[ SYSTEM INFO ] (EXTENDED)"
	quiet_hint

	# Вывод языка системы и времени активного использования
	log "Locale: $(get_system_locale)"
	log "Uptime: $(uptime -p)"

	# Вывод ROM и firmware частей прошивки
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

	# Проверка безопасности: статус SELinux, Play Integrity и архитектуры процессора
	log "SELinux: $(getenforce 2>/dev/null)"
	log "Play Integrity: $(check_integrity_status)"
	log "ABI: $(getprop ro.product.cpu.abi)"
}

# check_io_schedulers
# Проверяет настройки планировщика для основных блочных устройств (UFS/eMMC).
#  - scheduler: текущий алгоритм (mq-deadline, kyber, none)
#  - read_ahead: размер упреждающего чтения
check_io_schedulers() {
	echo
	echo "[ I/O ] (Schedulers)"
	quiet_hint

	local dev_list=("sda" "sdb" "mmcblk0")
	local separator="----------------------------------------"

	echo "$separator"
	for dev in "${dev_list[@]}"; do
		[ ! -d "/sys/block/$dev" ] && continue

		local sched read_ahead
		# Извлекаем активный планировщик из скобок [none]
		sched=$(cat "/sys/block/$dev/queue/scheduler" 2>/dev/null | awk -F'[' '{print $2}' | cut -d']' -f1)
		[ -z "$sched" ] && sched="N/A"
		
		read_ahead=$(cat "/sys/block/$dev/queue/read_ahead_kb" 2>/dev/null)

		out_printf "Device:    %s\n" "$dev"
		out_printf "Scheduler: %s\n" "$sched"
		out_printf "ReadAhead: %s KB\n" "${read_ahead:-0}"
		
		log "I/O Scheduler: Device=$dev | Schedule=$sched | RA=${read_ahead}KB"
		echo "$separator"
	done
}

# print_kernel_extended
# Выводит детализированную информацию о ядре: компилятор, сеть, энтропию и системные таймеры.
print_kernel_extended() {
	echo
	echo "[ KERNEL INFO ] (EXTENDED)"
	quiet_hint

	# 1. Версия и компилятор
	local full_ver=$(cat /proc/version)
	local compiler=$(echo "$full_ver" | grep -oE "(clang|gcc) version [0-9.]+")
	log "Full Version:    $full_ver"
	[ -n "$compiler" ] && log "Compiler:        $compiler"

	# 2. Сетевой стек (TCP & VPN)
	local tcp_algo=$(sysctl -n net.ipv4.tcp_congestion_control)
	local tcp_avail=$(sysctl -n net.ipv4.tcp_available_congestion_control)
	log "TCP Congestion:  $tcp_algo (Available: $tcp_avail)"

	if [ -d "/sys/module/wireguard" ]; then
		local wg_ver=$(cat /sys/module/wireguard/version)
		log "WireGuard:       v$wg_ver (Kernel Module)"
	fi

	# 3. Системные ресурсы и таймеры (HZ и Энтропия)
	local hz="Unknown"

	if [ -f "/proc/config.gz" ]; then
		# Используем zcat или gzip -dc, которые точно есть в toybox/busybox
		hz=$(zcat /proc/config.gz 2>/dev/null | grep "CONFIG_HZ=" | head -1 | cut -d= -f2)
		# Если zcat не сработал, пробуем альтернативу
		[ -z "$hz" ] && hz=$(gzip -dc /proc/config.gz 2>/dev/null | grep "CONFIG_HZ=" | head -1 | cut -d= -f2)
	fi

	# Если через конфиг не вышло, пробуем через время прерываний (эвристика)
	if [ -z "$hz" ] || [ "$hz" = "Unknown" ]; then
		# Для ARM64 в 99% случаев на Android это 100, 250 или 300
		# Оставляем "Unknown", чтобы не гадать, или используем значение из USER_HZ
		hz=$(getconf CLK_TCK 2>/dev/null || echo "100")
	fi

	local entropy=$(cat /proc/sys/kernel/random/entropy_avail)
	local entropy_status="Low"
	[ "$entropy" -gt 256 ] && entropy_status="Healthy"
	[ "$entropy" -gt 1024 ] && entropy_status="Excellent"

	log "Entropy Avail:   $entropy bits ($entropy_status)"
	log "Tick Rate (HZ):  $hz"

	# 4. Boot Args (сокращенно)
	local cmd=$(cat /proc/cmdline)
	log "Boot Args:       ${cmd:0:100}..."

	# 5. Специфика и Виртуализация
	if [ -e /dev/kvm ]; then
		log "Virtualization: KVM Enabled"
	fi

	if [[ "$(uname -r)" == *"android"* ]]; then
		log "Kernel Type:     GKI (Generic Kernel Image)"
	else
		log "Kernel Type:     Legacy / Custom Vendor"
	fi
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
			echo "_____________________________________"
			echo "LOG SESSION START: $(date '+%Y-%m-%d %H:%M:%S')"
			echo "_____________________________________"
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
	check_wakelocks
	check_network
	check_iperf3_speed
	check_logcat
	print_top
	print_io
	check_io_schedulers
	check_partitions
	check_pixel_security

	# Блок расширенной информации
	if [ "$EXTENDED" -eq 1 ]; then
		print_magisk_modules
		print_kernel_extended
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
		-s|--net-speed) ENABLE_NET_TEST=1;;
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
