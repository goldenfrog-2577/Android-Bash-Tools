#!/system/bin/sh
# shellcheck shell=bash
#
# monitor.sh v3.5 — мониторинг состояния rooted Android
# Автор: GoldenFrog
# Проверено на: Pixel 8 Pro (husky, Tensor G3) и POCO F3 (alioth, SM8250)
#
# Запуск:  su -c sh /sdcard/monitor.sh [опции]     (bash найдётся сам)
# Справка: sh monitor.sh --help
#
# Коды выхода: 0 — ОК, 1 — есть предупреждения, 2 — критично, 3 — ошибка скрипта.
# Флаги и коды выхода совместимы с v2 — cron/задачи переделывать не нужно.

# ── bash обязателен: если запустили через sh — перезапускаемся в bash ──────────
if [ -z "${BASH_VERSION:-}" ]; then
	for _b in "$(command -v bash 2>/dev/null)" \
		/data/user/0/bin.mt.plus/files/term/bin/bash \
		/data/data/bin.mt.plus/files/term/bin/bash \
		/data/data/com.termux/files/usr/bin/bash \
		/system/xbin/bash /system/bin/bash /usr/bin/bash /bin/bash; do
		[ -n "$_b" ] && [ -x "$_b" ] && exec "$_b" "$0" "$@"
	done
	echo "[!] Нужен bash (MT Manager / Termux)." >&2
	exit 3
fi

shopt -s extglob nullglob
# Байтовая локаль: ширину кириллических подписей считаем сами (см. kv),
# а printf/awk не путаются в многобайтовых символах на bionic.
export LC_ALL=C

readonly VERSION="3.5"

# ═════════════════════════════════════════════════════════════════════════════
#  НАСТРОЙКИ
# ═════════════════════════════════════════════════════════════════════════════

LOG="/data/media/0/.GoldenFrog/logs/android_monitor.log"
ERR_LOG="/data/media/0/.GoldenFrog/logs/last_errors.log"
LOCK_DIR="/dev/.goldenfrog_monitor.lock"   # /dev — tmpfs, писать туда может только root

# Тестовый хук: корень с поддельными /sys, /proc, /dev (как в cpu.sh)
R="${MONITOR_SYSROOT:-}"

EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2
EXIT_INTERNAL=3

# Флаги (совместимы с v2)
NO_LOGCAT=0
NO_FILE_LOG=0
BRIEF_MODE=0
EXTENDED=0
DRY_RUN=0
DRY_SECTIONS=""   # [3.3] -d cpu,gpu — какие секции вывести в пробном запуске
QUIET=0
LOOP_INTERVAL=0
ENABLE_NET_TEST=0

# Пороги
DISK_WARN=80
DISK_CRIT=90
RAM_WARN=80
RAM_CRIT=90
GPU_WARN=80
GPU_CRIT=90
CPU_WARN=70           # загрузка CPU, %
CPU_CRIT=90
CPU_WARN_MULT=1.5     # load average относительно числа ядер
CPU_CRIT_MULT=2.0
BATT_TEMP_WARN=45     # °C

SYSTEM_STATUS=$EXIT_OK

# ── Цвета: только в терминале ─────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'
	CYAN=$'\033[1;36m'; MAGENTA=$'\033[1;35m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
	RED=""; GREEN=""; YELLOW=""; CYAN=""; MAGENTA=""; DIM=""; BOLD=""; NC=""
fi

# ═════════════════════════════════════════════════════════════════════════════
#  ВЫВОД: терминал + лог-файл, режимы --quiet и --brief
# ═════════════════════════════════════════════════════════════════════════════
# Все строки идут через emit(). В --brief на экран попадают только строки
# со словами ВНИМАНИЕ / КРИТИЧНО / ОШИБКА (с названием секции), в --quiet —
# ничего. В файл (если не --no-file) пишется всё, без цветов, с временем.

LOG_FD_OPEN=0
CUR_SECTION=""
readonly KV_WIDTH=13      # ширина подписи в символах

strip_ansi() { REPLY="${1//$'\033'\[*([0-9;])m/}"; }

EMIT_COUNT=0   # [3.3] сколько строк выведено — по нему dry-run понимает, есть ли у секции данные
emit() {
	local line="$1" ts
	EMIT_COUNT=$((EMIT_COUNT + 1))
	if [ "$QUIET" -eq 0 ]; then
		if [ "$BRIEF_MODE" -eq 1 ] && [ "$CUR_SECTION" = "ИТОГ" ]; then
			case "$line" in *Итог:*) printf '%s\n' "$line" ;; esac
		elif [ "$BRIEF_MODE" -eq 1 ]; then
			case "$line" in
				*ВНИМАНИЕ*|*КРИТИЧНО*|*ОШИБКА*)
					printf '%s[%s]%s %s\n' "$DIM" "$CUR_SECTION" "$NC" "${line#"${line%%[! ]*}"}" ;;
			esac
		else
			printf '%s\n' "$line"
		fi
	fi
	if [ "$LOG_FD_OPEN" -eq 1 ]; then
		strip_ansi "$line"
		printf -v ts '%(%H:%M:%S)T' -1
		printf '%s  %s\n' "$ts" "$REPLY" >&3
	fi
}

# Длина строки в символах (UTF-8): байты минус байты-продолжения 0x80–0xBF
char_len() {
	local t="${1//[$'\x80'-$'\xbf']/}"
	REPLY=${#t}
}

# kv "Подпись" "значение" — ровная колонка с кириллицей.
# [3.1] Перед двоеточием всегда есть пробел, даже у подписи во всю ширину колонки.
kv() {
	strip_ansi "$1"
	char_len "$REPLY"
	local pad=$((KV_WIDTH - REPLY)) sp=""
	[ $pad -gt 0 ] && printf -v sp '%*s' "$pad" ""
	emit "  $1$sp : $2"
}

note() { emit "  ${DIM}$*${NC}"; }

section() {
	CUR_SECTION="$1"
	emit ""
	emit "${CYAN}[ $1 ]${NC}${2:+ ${DIM}$2${NC}}"
}

separator() { emit "  ${DIM}────────────────────────────────────${NC}"; }

raise_status() { [ "$1" -gt "$SYSTEM_STATUS" ] && SYSTEM_STATUS=$1; return 0; }

# verdict УРОВЕНЬ "пояснение" — строка «Статус» в едином стиле
verdict() {
	local lvl="$1" msg="$2"
	case "$lvl" in
		0) kv "Статус" "${GREEN}ОК${NC}${msg:+ ($msg)}" ;;
		1) kv "Статус" "${YELLOW}ВНИМАНИЕ${NC}${msg:+ ($msg)}" ;;
		2) kv "Статус" "${RED}КРИТИЧНО${NC}${msg:+ ($msg)}" ;;
		*) kv "Статус" "${RED}ОШИБКА${NC}${msg:+ ($msg)}" ;;
	esac
	[ "$lvl" -le 2 ] && raise_status "$lvl"
	[ "$lvl" -gt 2 ] && raise_status "$EXIT_WARNING"
	return 0
}

# Уровень по порогам: level_by ЗНАЧЕНИЕ WARN CRIT → REPLY = 0/1/2
level_by() {
	if [ "$1" -ge "$3" ]; then REPLY=2
	elif [ "$1" -ge "$2" ]; then REPLY=1
	else REPLY=0; fi
}

color_by_level() {
	case "$1" in 2) REPLY="$RED" ;; 1) REPLY="$YELLOW" ;; *) REPLY="$GREEN" ;; esac
}

# Температура в цвете: color_temp °C → REPLY
color_temp() {
	local t=${1%.*}
	if   [ "$t" -ge 75 ]; then REPLY="${RED}$1°C${NC}"
	elif [ "$t" -ge 55 ]; then REPLY="${YELLOW}$1°C${NC}"
	else REPLY="$1°C"; fi
}

exit_code_label() {
	case "$1" in
		0) printf '%sОК%s' "$GREEN" "$NC" ;;
		1) printf '%sВНИМАНИЕ%s' "$YELLOW" "$NC" ;;
		2) printf '%sКРИТИЧНО%s' "$RED" "$NC" ;;
		3) printf '%sОШИБКА СКРИПТА%s' "$RED" "$NC" ;;
		*) printf 'НЕИЗВЕСТНО' ;;
	esac
}

# ═════════════════════════════════════════════════════════════════════════════
#  ЧТЕНИЕ ДАННЫХ (без подоболочек — кэши живут весь проход)
# ═════════════════════════════════════════════════════════════════════════════

# rd ФАЙЛ → REPLY (первая строка, без пробелов по краям; пусто, если нет файла)
rd() {
	REPLY=""
	[ -r "$1" ] || return 1
	IFS= read -r REPLY 2>/dev/null < "$1" || [ -n "$REPLY" ] || return 1
	REPLY="${REPLY#"${REPLY%%[! ]*}"}"; REPLY="${REPLY%"${REPLY##*[! ]}"}"
	return 0
}

is_int() { [[ "$1" =~ ^-?[0-9]+$ ]]; }

# Все свойства — одним вызовом getprop
declare -A PROP
load_props() {
	PROP=()
	local line k v
	while IFS= read -r line; do
		[[ "$line" =~ ^\[([^]]*)\]:\ \[(.*)\]$ ]] || continue
		k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
		PROP[$k]="$v"
	done < <(getprop 2>/dev/null)
}
prop() { REPLY="${PROP[$1]:-}"; }

# Термозоны: тип → температура (м°C). Отбрасываем заведомо мусорные значения.
declare -A TZ
load_zones() {
	TZ=()
	local z t v
	for z in "$R"/sys/class/thermal/thermal_zone*; do
		IFS= read -r t 2>/dev/null < "$z/type" || continue
		IFS= read -r v 2>/dev/null < "$z/temp" || continue
		is_int "$v" || continue
		[ "$v" -gt -30000 ] && [ "$v" -lt 150000 ] || continue
		if [ -z "${TZ[$t]:-}" ] || [ "$v" -gt "${TZ[$t]}" ]; then TZ[$t]="$v"; fi
	done
}

# Thermal HAL: dumpsys thermalservice — один раз за проход
declare -A HAL HAL_TYPE
HAL_STATUS=""; HAL_READY=""
load_thermal_hal() {
	HAL=(); HAL_TYPE=(); HAL_STATUS=""; HAL_READY=""
	local line name val typ in_cached=0
	while IFS= read -r line; do
		case "$line" in
			"Thermal Status:"*) HAL_STATUS="${line##*: }" ;;
			"HAL Ready:"*)      HAL_READY="${line##*: }" ;;
			"Cached temperatures:"*) in_cached=1; continue ;;
		esac
		if [ "$in_cached" -eq 1 ]; then
			[[ "$line" == *"Temperature{"* ]] || { in_cached=0; continue; }
			[[ "$line" =~ mValue=([-0-9.]+).*mType=(-?[0-9]+).*mName=([^,]+) ]] || continue
			val="${BASH_REMATCH[1]}"; typ="${BASH_REMATCH[2]}"; name="${BASH_REMATCH[3]}"
			[ -n "${HAL[$name]:-}" ] && continue
			HAL[$name]="$val"; HAL_TYPE[$name]="$typ"
		fi
	done < <(dumpsys thermalservice 2>/dev/null)
}

# м°C → «47.2»
mdeg() { REPLY="$(( $1 / 1000 )).$(( ( ${1#-} % 1000 ) / 100 ))"; }
# дробные °C из HAL → «47.2»
fdeg() { printf -v REPLY '%.1f' "$1" 2>/dev/null || REPLY="$1"; }

hsize_kb() {   # КБ → «12.3 ГБ»
	awk -v k="$1" 'BEGIN { if (k >= 1048576) printf "%.1f ГБ", k/1048576;
		else if (k >= 1024) printf "%.0f МБ", k/1024; else printf "%d КБ", k }'
}

# Верификация загрузки: правда из ядра (cmdline/bootconfig) против свойств
VB_REAL=""; VB_DEVSTATE=""; VB_PROP=""; VB_LOCKPROP=""; VB_LABEL=""; VB_SPOOF=0
load_verified_boot() {
	VB_REAL=""; VB_DEVSTATE=""; VB_SPOOF=0
	local src
	for src in "$R/proc/bootconfig" "$R/proc/cmdline"; do
		[ -r "$src" ] || continue
		local data; data=$(tr ' ' '\n' < "$src" 2>/dev/null)
		[ -z "$VB_REAL" ] && VB_REAL=$(printf '%s\n' "$data" | sed -n 's/^androidboot\.verifiedbootstate=\{0,1\}"\{0,1\}\([a-z]*\).*/\1/p' | head -n 1)
		[ -z "$VB_DEVSTATE" ] && VB_DEVSTATE=$(printf '%s\n' "$data" | sed -n 's/^androidboot\.vbmeta\.device_state=\{0,1\}"\{0,1\}\([a-z]*\).*/\1/p' | head -n 1)
	done
	# bootconfig пишет «key = "value"» — после tr ключ и значение в разных строках
	if [ -r "$R/proc/bootconfig" ]; then
		[ -z "$VB_REAL" ] && VB_REAL=$(sed -n 's/^androidboot\.verifiedbootstate *= *"\([a-z]*\)".*/\1/p' "$R/proc/bootconfig" | head -n 1)
		[ -z "$VB_DEVSTATE" ] && VB_DEVSTATE=$(sed -n 's/^androidboot\.vbmeta\.device_state *= *"\([a-z]*\)".*/\1/p' "$R/proc/bootconfig" | head -n 1)
	fi
	prop ro.boot.verifiedbootstate; VB_PROP="$REPLY"
	prop ro.boot.flash.locked;      VB_LOCKPROP="$REPLY"

	local state="$VB_REAL"
	[ -z "$state" ] && [ "$VB_DEVSTATE" = "unlocked" ] && state="orange"
	[ -z "$state" ] && state="$VB_PROP"
	# ядро говорит orange/unlocked, а свойства — green/locked → подмена (PIF/модули)
	if [ "$state" = "orange" ] && { [ "$VB_PROP" = "green" ] || [ "$VB_LOCKPROP" = "1" ]; }; then
		VB_SPOOF=1
	fi
	case "$state" in
		orange) VB_LABEL="${RED}разблокирован${NC} (orange)" ;;
		green)  VB_LABEL="${GREEN}заблокирован${NC} (green)" ;;
		yellow) VB_LABEL="${YELLOW}заблокирован, свой ключ${NC} (yellow)" ;;
		red)    VB_LABEL="${RED}проверка не пройдена${NC} (red)" ;;
		*)      VB_LABEL="неизвестно" ;;
	esac
	[ "$VB_SPOOF" -eq 1 ] && VB_LABEL="$VB_LABEL ${MAGENTA}· свойства подменены${NC}"
	return 0
}

# ═════════════════════════════════════════════════════════════════════════════
#  СЕКЦИИ
# ═════════════════════════════════════════════════════════════════════════════

print_header() {
	local model codename slot sdk build
	prop ro.product.model;  model="$REPLY"
	prop ro.product.device; codename="$REPLY"
	prop ro.boot.slot_suffix; slot="${REPLY#_}"
	prop ro.build.version.sdk; sdk="$REPLY"
	prop ro.build.display.id; build="$REPLY"
	prop ro.build.version.release; local rel="$REPLY"
	local ts; printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1
	CUR_SECTION="ЗАГОЛОВОК"
	emit "${BOLD}════════════════════════════════════════${NC}"
	emit "${BOLD} МОНИТОРИНГ СИСТЕМЫ ANDROID${NC}  v$VERSION"
	emit "${BOLD}════════════════════════════════════════${NC}"
	kv "Устройство" "${model:-?} (${codename:-?})"
	kv "Android" "${rel:-?}${sdk:+ (SDK $sdk)}${build:+ · $build}"
	kv "Ядро" "$(uname -r 2>/dev/null)"
	kv "Слот" "${slot:-нет (A-only)}"
	kv "Загрузчик" "$VB_LABEL"
	kv "Время" "$ts"
}

# ── Хранилище ────────────────────────────────────────────────────────────────

UFS_PATH=""; UFS_PATH_DONE=0
find_ufs_path() {
	[ "$UFS_PATH_DONE" -eq 1 ] && return
	UFS_PATH_DONE=1
	local p
	# Pixel: готовая ссылка; остальные — идём вверх от /sys/block/sda
	for p in "$R/dev/sys/block/bootdevice"; do
		[ -d "$p/health_descriptor" ] && { UFS_PATH="$p"; return; }
	done
	p=$(readlink -f "$R/sys/block/sda/device" 2>/dev/null)
	local i=0
	while [ -n "$p" ] && [ "$p" != "/" ] && [ $i -lt 10 ]; do
		[ -d "$p/health_descriptor" ] && { UFS_PATH="$p"; return; }
		p="${p%/*}"; i=$((i + 1))
	done
	for p in "$R"/sys/devices/platform/soc/*.ufshc "$R"/sys/devices/platform/*.ufs; do
		[ -d "$p/health_descriptor" ] && { UFS_PATH="$p"; return; }
	done
}

# JEDEC: 0x01 = 0–10%, …, 0x0A = 90–100%, 0x0B = ресурс исчерпан
life_label() {
	local v=$(( ${1:-0} ))
	case $v in
		0)  REPLY="нет данных" ;;
		11) REPLY="${RED}ресурс исчерпан${NC}" ;;
		*)  if [ $v -ge 1 ] && [ $v -le 10 ]; then
				REPLY="$(( (v - 1) * 10 ))–$(( v * 10 ))%"
				[ $v -ge 8 ] && REPLY="${RED}$REPLY${NC}" || { [ $v -ge 5 ] && REPLY="${YELLOW}$REPLY${NC}"; }
			else REPLY="код $1"; fi ;;
	esac
}

check_storage() {
	section "ХРАНИЛИЩЕ" "(/data)"
	find_ufs_path
	local vendor="" model=""
	rd "$R/sys/block/sda/device/vendor" && vendor="$REPLY"
	rd "$R/sys/block/sda/device/model" && model="$REPLY"

	if [ -n "$UFS_PATH" ]; then
		local ver="UFS" spec a b eol worst
		if rd "$UFS_PATH/device_descriptor/specification_version" && [[ "$REPLY" =~ ^0x([0-9A-Fa-f]{2})([0-9A-Fa-f])[0-9A-Fa-f]$ ]]; then
			ver="UFS $(( 16#${BASH_REMATCH[1]} )).${BASH_REMATCH[2]}"
		fi
		kv "Тип" "$ver · ${vendor:-?} ${model}"
		rd "$UFS_PATH/health_descriptor/life_time_estimation_a" && a="$REPLY" || a=0
		rd "$UFS_PATH/health_descriptor/life_time_estimation_b" && b="$REPLY" || b=0
		rd "$UFS_PATH/health_descriptor/eol_info" && eol="$REPLY" || eol=0
		worst=$(( a > b ? a : b ))
		life_label "$worst"
		local life="$REPLY"
		life_label "$a"; local la="$REPLY"; life_label "$b"
		kv "Износ" "$life  ${DIM}(A: $la, B: $REPLY)${NC}"
		case $(( eol )) in
			1) kv "Резерв" "${GREEN}норма${NC}" ;;
			2) kv "Резерв" "${YELLOW}израсходовано 80% резервных блоков${NC}"; raise_status 1 ;;
			3) kv "Резерв" "${RED}израсходовано 90% резервных блоков${NC}"; raise_status 2 ;;
		esac
		[ $(( worst )) -ge 11 ] && raise_status 2
	elif [ -d "$R/sys/block/mmcblk0" ]; then
		local lt pe
		rd "$R/sys/block/mmcblk0/device/life_time" && lt="$REPLY"
		rd "$R/sys/block/mmcblk0/device/pre_eol_info" && pe="$REPLY"
		kv "Тип" "eMMC${model:+ · $model}"
		if [ -n "${lt:-}" ]; then
			set -- $lt
			life_label "${1:-0}"; local la="$REPLY"; life_label "${2:-0}"
			kv "Износ" "A: $la, B: $REPLY"
		fi
	else
		kv "Тип" "${vendor:+$vendor }${model:-неизвестно}"
	fi

	local line size used avail pct
	line=$(df -k /data 2>/dev/null | awk 'NR > 1 && $2 ~ /^[0-9]+$/ { print $2, $3, $4, $5; exit }')
	if [ -z "$line" ]; then
		verdict 3 "не удалось прочитать df /data"
		return
	fi
	read -r size used avail pct <<< "$line"
	pct="${pct%\%}"
	kv "Объём" "$(hsize_kb "$size") · занято $(hsize_kb "$used") · свободно $(hsize_kb "$avail")"
	if ! is_int "$pct"; then verdict 3 "непонятный ответ df"; return; fi
	level_by "$pct" "$DISK_WARN" "$DISK_CRIT"
	verdict "$REPLY" "занято $pct%"
}

# ── Память ───────────────────────────────────────────────────────────────────

# [3.4] Память: не только «занято %». Процент на Android мало что значит —
# система нарочно держит RAM занятой кэшем. Реальную картину дают:
#   PSI (/proc/pressure/memory) — доля времени, когда задачи ждали память;
#   выгрузки lmkd — сколько приложений система убила из-за нехватки;
#   zram mm_stat — сколько данных в подкачке и как хорошо они сжались.
# Статус = худшее из «занято %» (пороги --ram-warn/--ram-crit) и давления за минуту:
#   some ≥ 5%  — ВНИМАНИЕ (задачи заметно ждут память → подлагивания);
#   full ≥ 20% — КРИТИЧНО (всё стоит, ожидая память).
PSI_MEM_WARN=5     # some avg60, %
PSI_MEM_CRIT=20    # full avg60, %

check_memory() {
	section "ПАМЯТЬ" "(RAM)"
	local total=0 avail=0 cached=0 swt=0 swf=0 k v _
	while read -r k v _; do
		case "$k" in
			MemTotal:) total=$v ;; MemAvailable:) avail=$v ;; Cached:) cached=$v ;;
			SwapTotal:) swt=$v ;; SwapFree:) swf=$v ;;
		esac
	done < "$R/proc/meminfo"
	if [ "$total" -le 0 ]; then verdict 3 "нет /proc/meminfo"; return; fi
	local pct=$(( (total - avail) * 100 / total )) apct=$(( avail * 100 / total ))

	# Тип памяти: Pixel пишет «12GiB,Samsung,LPDDR5,0109»
	local ddr="" dtype dvend
	prop ro.boot.hardware.ddr
	if [ -n "$REPLY" ]; then
		IFS=',' read -r _ dvend dtype _ <<< "$REPLY"
		ddr="${dtype}${dvend:+, $dvend}"
	fi
	kv "Всего" "$(hsize_kb "$total")${ddr:+ · $ddr}"
	kv "Доступно" "$(hsize_kb "$avail") ($apct%) · кэш $(hsize_kb "$cached")"

	# zram: все активные устройства из /proc/swaps (их может быть несколько —
	# например, прошивочный zram0 + добавленный zram1); mm_stat = orig compr mem_used …
	local zdevs zn zd orig compr used algo="" algos="" back="" bdw=0 o_sum=0 u_sum=0 nz=0 r
	zdevs=$(awk 'NR > 1 && $1 ~ /zram/ { sub(/.*\//, "", $1); print $1 }' "$R/proc/swaps" 2>/dev/null)
	for zn in $zdevs; do
		zd="$R/sys/block/$zn"
		rd "$zd/mm_stat" || continue
		read -r orig compr used _ <<< "$REPLY"
		is_int "${orig:-x}" && is_int "${used:-x}" || continue
		o_sum=$((o_sum + orig)); u_sum=$((u_sum + used)); nz=$((nz + 1))
		if rd "$zd/comp_algorithm" && [[ "$REPLY" =~ \[([^]]+)\] ]]; then
			algo="${BASH_REMATCH[1]}"
			[[ " $algos " == *" $algo "* ]] || algos="${algos:+$algos }$algo"
		fi
		if rd "$zd/backing_dev" && [ -n "$REPLY" ] && [ "$REPLY" != "none" ]; then
			back="$REPLY"
			rd "$zd/bd_stat" && { read -r r _ <<< "$REPLY"; is_int "${r:-x}" && bdw=$((bdw + r)); }   # страниц на диске
		fi
	done
	if [ "$nz" -gt 0 ] && [ "$u_sum" -gt 0 ]; then
		local ratio devs=""
		ratio=$(awk -v o="$o_sum" -v u="$u_sum" 'BEGIN { printf "%.1f", o / u }')
		[ "$nz" -gt 1 ] && devs=" ${DIM}($nz устройства)${NC}"
		kv "ZRAM" "$(hsize_kb $((o_sum / 1024))) → $(hsize_kb $((u_sum / 1024))) ${DIM}(сжатие ×$ratio)${NC}${algos:+ · ${algos// //}}$devs"
	fi
	if [ "$swt" -gt 0 ]; then
		local wb=""
		if [ -n "$back" ]; then
			wb=" · сброс на диск: вкл."
			[ "$bdw" -gt 0 ] && wb="$wb ${DIM}(там $(hsize_kb $((bdw * 4))))${NC}"
		fi
		kv "Подкачка" "занято $(hsize_kb $((swt - swf))) из $(hsize_kb "$swt")$wb"
	fi

	# Давление (PSI): строки «some avg10=… avg60=…» и «full …»
	local psi_some="" psi_full="" plvl=0
	if [ -r "$R/proc/pressure/memory" ]; then
		psi_some=$(awk '$1 == "some" { for (i = 2; i <= NF; i++) if ($i ~ /^avg60=/) { sub(/avg60=/, "", $i); print $i } }' "$R/proc/pressure/memory")
		psi_full=$(awk '$1 == "full" { for (i = 2; i <= NF; i++) if ($i ~ /^avg60=/) { sub(/avg60=/, "", $i); print $i } }' "$R/proc/pressure/memory")
	fi
	if [ -n "$psi_some" ]; then
		plvl=$(awk -v s="$psi_some" -v f="${psi_full:-0}" -v w="$PSI_MEM_WARN" -v c="$PSI_MEM_CRIT" \
			'BEGIN { print (f >= c) ? 2 : (s >= w) ? 1 : 0 }')
		local cs="" cf=""
		[ "$plvl" -ge 1 ] && cs="$YELLOW"
		[ "$plvl" -ge 2 ] && cf="$RED"
		kv "Давление" "${cs}${psi_some}%${cs:+$NC} · полное ${cf}${psi_full:-?}%${cf:+$NC} ${DIM}(за минуту)${NC}"
	fi

	# Выгрузки lmkd с момента загрузки и в среднем за час
	local kills up_s
	kills=$(dumpsys activity lmk 2>/dev/null | awk -F': *' '/Total number of kills/ { print $2; exit }')
	if is_int "${kills:-x}"; then
		read -r up_s _ < "$R/proc/uptime" 2>/dev/null
		local rate=""
		up_s="${up_s%%.*}"
		is_int "${up_s:-x}" && [ "$up_s" -ge 3600 ] && rate=" ${DIM}(~$(( kills * 3600 / up_s )) в час)${NC}"
		kv "Выгрузки" "$kills приложений с загрузки$rate"
	fi

	# Настройки vm — в расширенном режиме: видно, что применил 99_init.kernel
	if [ "$EXTENDED" -eq 1 ]; then
		local sw mf vcp
		rd "$R/proc/sys/vm/swappiness"; sw="$REPLY"
		rd "$R/proc/sys/vm/min_free_kbytes"; mf="$REPLY"
		rd "$R/proc/sys/vm/vfs_cache_pressure"; vcp="$REPLY"
		kv "Настройки VM" "swappiness ${sw:-?} · min_free $(( ${mf:-0} / 1024 )) МБ · cache_pressure ${vcp:-?}"
	fi

	level_by "$pct" "$RAM_WARN" "$RAM_CRIT"; local lvl=$REPLY
	[ "$plvl" -gt "$lvl" ] && lvl=$plvl
	verdict "$lvl" "занято $pct%${psi_some:+ · давление $psi_some%}"
}

# ── Процессор ────────────────────────────────────────────────────────────────

cpu_snapshot() {   # → REPLY="total idle" по строке cpu из /proc/stat
	local c u n s i w q sq st
	read -r c u n s i w q sq st _ < "$R/proc/stat"
	REPLY="$((u + n + s + i + w + q + sq + ${st:-0})) $((i + w))"
}

# [3.1] Тип ядер по /proc/cpuinfo (CPU implementer + CPU part) — работает на любом
# ARM SoC без таблицы чипов. Неизвестный код → пусто, и вывод будет обобщённым.
declare -A CORE_TYPE
core_name() {   # core_name 0x41 0xd46 → REPLY="A510"
	REPLY=""
	case "${1,,}:${2,,}" in
		0x41:0xd03) REPLY="A53" ;;  0x41:0xd04) REPLY="A35" ;;  0x41:0xd05) REPLY="A55" ;;
		0x41:0xd07) REPLY="A57" ;;  0x41:0xd08) REPLY="A72" ;;  0x41:0xd09) REPLY="A73" ;;
		0x41:0xd0a) REPLY="A75" ;;  0x41:0xd0b) REPLY="A76" ;;  0x41:0xd0d) REPLY="A77" ;;
		0x41:0xd41) REPLY="A78" ;;  0x41:0xd44) REPLY="X1" ;;   0x41:0xd46) REPLY="A510" ;;
		0x41:0xd47) REPLY="A710" ;; 0x41:0xd48) REPLY="X2" ;;   0x41:0xd4d) REPLY="A715" ;;
		0x41:0xd4e) REPLY="X3" ;;   0x41:0xd80) REPLY="A520" ;; 0x41:0xd81) REPLY="A720" ;;
		0x41:0xd82) REPLY="X4" ;;   0x41:0xd85) REPLY="X925" ;; 0x41:0xd87) REPLY="A725" ;;
		# [3.5] Qualcomm отдаёт для части ядер свои коды (implementer 0x51), хотя
		# внутри — обычные ядра ARM. Пишем настоящее ядро, как и для остальных:
		# 0x800/0x801 — Kryo 2xx (SD835): A73 / A53; 0x802/0x803 — Kryo 3xx (SD845):
		# A75 / A55; 0x804/0x805 — Kryo 4xx (SD855/860): A76 / A55. У SD865/870 большие
		# ядра отдают обычный код ARM (A77), а малые — те же 0x51:0x805.
		# Например, у SM8250 малые ядра отдают 0x51:0x805 — это Cortex-A55.
		0x51:0x800) REPLY="A73" ;; 0x51:0x801) REPLY="A53" ;;
		0x51:0x802) REPLY="A75" ;; 0x51:0x803) REPLY="A55" ;;
		0x51:0x804) REPLY="A76" ;; 0x51:0x805) REPLY="A55" ;;
	esac
	[ -n "$REPLY" ]
}
load_core_types() {
	CORE_TYPE=()
	local line key val cpu="" impl=""
	while IFS= read -r line; do
		key="${line%%:*}"; key="${key//$'\t'/}"; key="${key%"${key##*[! ]}"}"
		val="${line#*: }"
		case "$key" in
			processor)         cpu="$val"; impl="" ;;
			"CPU implementer") impl="$val" ;;
			"CPU part")        [ -n "$cpu" ] && core_name "$impl" "$val" && CORE_TYPE[$cpu]="$REPLY" ;;
		esac
	done < "$R/proc/cpuinfo" 2>/dev/null
}

# «4 ядра», «1 ядро», «8 ядер»
cores_word() {
	local n=$1 m10=$(($1 % 10)) m100=$(($1 % 100))
	if [ "$m10" -eq 1 ] && [ "$m100" -ne 11 ]; then REPLY="$n ядро"
	elif [ "$m10" -ge 2 ] && [ "$m10" -le 4 ] && { [ "$m100" -lt 12 ] || [ "$m100" -gt 14 ]; }; then REPLY="$n ядра"
	else REPLY="$n ядер"; fi
}

check_cpu() {
	section "ПРОЦЕССОР"
	local t1 i1 t2 i2 load=0
	cpu_snapshot; read -r t1 i1 <<< "$REPLY"
	[ -z "$R" ] && sleep 0.5
	cpu_snapshot; read -r t2 i2 <<< "$REPLY"
	[ $((t2 - t1)) -gt 0 ] && load=$(( ( (t2 - t1) - (i2 - i1) ) * 100 / (t2 - t1) ))

	local soc board cores la1 la5 la15
	prop ro.soc.model; soc="$REPLY"
	[ -z "$soc" ] && { prop ro.board.platform; soc="$REPLY"; }
	prop ro.product.board; board="$REPLY"
	cores=$(grep -c '^processor' "$R/proc/cpuinfo" 2>/dev/null)
	read -r la1 la5 la15 _ < "$R/proc/loadavg" 2>/dev/null

	level_by "$load" "$CPU_WARN" "$CPU_CRIT"; local lvl=$REPLY
	kv "Модель" "${soc:-?}${board:+ · плата $board}"
	color_by_level "$lvl"
	kv "Загрузка" "${REPLY}${load}%${NC} · ядер онлайн: ${cores:-?}"
	# [3.2] load average — по-русски и отдельной строкой: за 1, 5 и 15 минут
	[ -n "${la1:-}" ] && kv "Ср. нагрузка" "$la1 / ${la5:-?} / ${la15:-?} ${DIM}(за 1, 5, 15 мин)${NC}"

	# [3.1] Частоты по кластерам: «Кластер N : 4× A510 · текущая / предел МГц».
	# ▼ — предел ниже паспортного. Регулятор — одной строкой, а не в каждой.
	load_core_types
	local p cpus first n cur max hw gov govs="" line ctype idx=0
	local -a _cl
	for p in "$R"/sys/devices/system/cpu/cpufreq/policy*; do
		[ -d "$p" ] || continue
		rd "$p/related_cpus"; cpus="$REPLY"
		rd "$p/scaling_cur_freq"; cur="$REPLY"
		rd "$p/scaling_max_freq"; max="$REPLY"
		rd "$p/cpuinfo_max_freq"; hw="$REPLY"
		rd "$p/scaling_governor"; gov="$REPLY"
		is_int "$cur" && is_int "$max" || continue
		idx=$((idx + 1))
		read -r -a _cl <<< "$cpus"; n=${#_cl[@]}; first="${_cl[0]:-}"
		ctype="${CORE_TYPE[$first]:-}"
		if [ -n "$ctype" ] && [ "$n" -gt 0 ]; then
			line="${n}× $ctype · "
		elif [ "$n" -gt 0 ]; then
			cores_word "$n"; line="$REPLY · "
		else
			line=""
		fi
		line="$line$((cur / 1000)) / $((max / 1000)) МГц"
		if is_int "$hw" && [ "$max" -lt "$hw" ]; then
			line="$line ${YELLOW}▼${NC} ${DIM}(паспорт $((hw / 1000)))${NC}"
		fi
		kv "Кластер $idx" "$line"
		[ -n "$gov" ] && [[ " $govs " != *" $gov "* ]] && govs="${govs:+$govs }$gov"
	done
	[ -n "$govs" ] && kv "Регулятор" "${govs// / \/ }"

	# load average относительно числа ядер (пороги CPU_*_MULT)
	if is_int "${cores:-x}" && [ -n "${la1:-}" ]; then
		local la_lvl
		la_lvl=$(awk -v l="$la1" -v c="$cores" -v w="$CPU_WARN_MULT" -v k="$CPU_CRIT_MULT" \
			'BEGIN { print (l >= c*k) ? 2 : (l >= c*w) ? 1 : 0 }')
		[ "$la_lvl" -gt "$lvl" ] && lvl=$la_lvl
	fi
	case $lvl in
		2) verdict 2 "перегрузка" ;; 1) verdict 1 "высокая нагрузка" ;; *) verdict 0 "нагрузка в норме" ;;
	esac
}

# ── Температуры и троттлинг ─────────────────────────────────────────────────

# Самая горячая зона по шаблону имени: zone_max 'gpuss-*-usr' → REPLY (м°C)
zone_max() {
	local k best=""
	for k in "${!TZ[@]}"; do
		# shellcheck disable=SC2053
		[[ "$k" == $1 ]] || continue
		if [ -z "$best" ] || [ "${TZ[$k]}" -gt "$best" ]; then best="${TZ[$k]}"; fi
	done
	REPLY="$best"
	[ -n "$best" ]
}

# [3.3] Строка «Перегрев»: «нет (0)», «лёгкий (1)» … — читается как обычная фраза
THERMAL_STATUS_NAMES=(нет лёгкий умеренный сильный критический аварийный отключение)

check_thermal() {
	section "ТЕМПЕРАТУРА И ТРОТТЛИНГ"
	local shown=0 name t max=-999

	# CPU: Tensor — зоны LITTLE/MID/BIG; Qualcomm — cpu-<кластер>-<n>-usr; иначе HAL
	local -A TLABEL=([LITTLE]="Малые ядра" [MID]="Средние ядра" [BIG]="Большие ядра")
	for name in LITTLE MID BIG; do
		if [ -n "${TZ[$name]:-}" ]; then
			mdeg "${TZ[$name]}"; t="$REPLY"
		elif [ -n "${HAL[$name]:-}" ]; then
			fdeg "${HAL[$name]}"; t="$REPLY"
		else
			continue
		fi
		color_temp "$t"; kv "${TLABEL[$name]}" "$REPLY"; shown=1
		[ "${t%.*}" -gt "$max" ] && max="${t%.*}"
	done
	if [ "$shown" -eq 0 ]; then
		local c
		for c in 0 1 2 3; do
			zone_max "cpu-$c-*-usr" || zone_max "cpu-$c-*" || continue
			mdeg "$REPLY"; t="$REPLY"
			color_temp "$t"; kv "Кластер $((c + 1))" "$REPLY"; shown=1
			[ "${t%.*}" -gt "$max" ] && max="${t%.*}"
		done
	fi
	if [ "$shown" -eq 0 ] && zone_max '*cpu*'; then
		mdeg "$REPLY"; t="$REPLY"; color_temp "$t"; kv "Процессор" "$REPLY"; shown=1
	fi
	[ "$shown" -eq 0 ] && kv "Процессор" "нет данных"

	# GPU / TPU / корпус / батарея
	if [ -n "${TZ[G3D]:-}" ]; then mdeg "${TZ[G3D]}"; color_temp "$REPLY"; kv "Графика" "$REPLY"
	elif zone_max 'gpuss-*-usr' || zone_max 'gpu*'; then mdeg "$REPLY"; color_temp "$REPLY"; kv "Графика" "$REPLY"
	elif rd "$R/sys/class/kgsl/kgsl-3d0/temp" && is_int "$REPLY"; then mdeg "$REPLY"; color_temp "$REPLY"; kv "Графика" "$REPLY"
	fi
	[ -n "${TZ[TPU]:-}" ] && { mdeg "${TZ[TPU]}"; color_temp "$REPLY"; kv "Нейроблок TPU" "$REPLY"; }

	local skin=""
	for name in "${!HAL_TYPE[@]}"; do
		[ "${HAL_TYPE[$name]}" = "3" ] && { fdeg "${HAL[$name]}"; skin="$REPLY ${DIM}($name)${NC}"; break; }
	done
	if [ -z "$skin" ]; then
		for name in skin_therm xo_therm quiet_therm; do
			[ -n "${TZ[$name]:-}" ] && { mdeg "${TZ[$name]}"; skin="$REPLY°C ${DIM}($name)${NC}"; break; }
		done
	else
		skin="${skin/ /°C }"
	fi
	[ -n "$skin" ] && kv "Корпус" "$skin"

	# Статус Thermal HAL (0–6)
	if [ "$HAL_READY" = "false" ]; then
		kv "Перегрев" "${DIM}неизвестно — Thermal HAL не готов на этой прошивке${NC}"
	elif is_int "${HAL_STATUS:-x}"; then
		local s="$HAL_STATUS" lbl="${THERMAL_STATUS_NAMES[$HAL_STATUS]:-$HAL_STATUS}"
		if   [ "$s" -ge 4 ]; then kv "Перегрев" "${RED}$lbl ($s)${NC}"; raise_status 2
		elif [ "$s" -ge 2 ]; then kv "Перегрев" "${YELLOW}$lbl ($s)${NC}"; raise_status 1
		else kv "Перегрев" "${GREEN}$lbl ($s)${NC}"; fi
	fi

	# Троттлинг: охлаждающие устройства CPU/GPU/TPU с cur_state > 0
	local cd type cur mx list="" off=""
	for cd in "$R"/sys/class/thermal/cooling_device*; do
		IFS= read -r type 2>/dev/null < "$cd/type" || continue
		case "$type" in
			*backlight*|*brightness*|battery|*modem*|*-tj) continue ;;
		esac
		IFS= read -r cur 2>/dev/null < "$cd/cur_state" || continue
		is_int "$cur" && [ "$cur" -gt 0 ] || continue
		IFS= read -r mx 2>/dev/null < "$cd/max_state"
		case "$type" in
			thermal-cpufreq-*)  list="$list, CPU-${type##*-} $cur/$mx" ;;
			cpufreq-hw-*)       list="$list, CPU-${type##*-} $cur/$mx" ;;
			cpu-isolate*)       off="$off ${type#cpu-isolate}" ;;
			thermal-gpufreq-*|thermal-devfreq-*) list="$list, GPU $cur/$mx" ;;
			tpu_cooling)        list="$list, TPU $cur/$mx" ;;
			*)                  list="$list, $type $cur/$mx" ;;
		esac
	done
	[ -n "$off" ] && list="$list, отключены ядра:$off"
	if [ -n "$list" ]; then
		kv "Троттлинг" "${YELLOW}активен${NC}: ${list#, }"
	else
		kv "Троттлинг" "${GREEN}нет${NC}"
	fi
}

# ── GPU и экран ──────────────────────────────────────────────────────────────

check_gpu() {
	section "ГРАФИКА"
	local model="" freq="" load="" gov="" k="$R/sys/class/kgsl/kgsl-3d0" mali=""

	if [ -d "$k" ]; then
		rd "$k/gpu_model" && model="$REPLY"
		model="${model:-Adreno}"
		rd "$k/gpuclk"; is_int "$REPLY" && [ "$REPLY" -gt 0 ] || rd "$k/devfreq/cur_freq"
		is_int "$REPLY" && [ "$REPLY" -gt 0 ] && freq="$((REPLY / 1000000)) МГц"
		if rd "$k/gpu_busy_percentage"; then load="${REPLY%%[ %]*}"
		elif [ -r "$k/gpubusy" ]; then
			load=$(awk '{ if ($2 > 0) printf "%d", $1 * 100 / $2; else print 0 }' "$k/gpubusy")
		fi
		rd "$k/devfreq/governor" && gov="$REPLY"
	else
		local c
		for c in "$R/sys/devices/platform/1f000000.mali" "$R"/sys/devices/platform/*.mali \
			"$R/sys/class/misc/mali0/device"; do
			[ -r "$c/cur_freq" ] || [ -r "$c/gpuinfo" ] && { mali="$c"; break; }
		done
		if [ -n "$mali" ]; then
			# gpuinfo kbase: «Mali-G715 7 cores r0p1 0xA862»
			if rd "$mali/gpuinfo" && [[ "$REPLY" =~ (Mali-[A-Za-z0-9]+)\ ([0-9]+)\ cores ]]; then
				model="${BASH_REMATCH[1]} MP${BASH_REMATCH[2]}"
			else
				prop ro.soc.model
				case "$REPLY" in
					*G1*) model="Mali-G78 MP20" ;; *G2*) model="Mali-G710 MP7" ;;
					*G3*|*G4*) model="Mali-G715 MP7" ;; *) model="Mali" ;;
				esac
			fi
			if rd "$mali/cur_freq" && is_int "$REPLY" && [ "$REPLY" -gt 0 ]; then
				# Pixel отдаёт кГц, некоторые ядра — Гц
				if [ "$REPLY" -ge 10000000 ]; then freq="$((REPLY / 1000000)) МГц"; else freq="$((REPLY / 1000)) МГц"; fi
			fi
			rd "$mali/utilization" && is_int "$REPLY" && load="$REPLY"
			rd "$mali/governor" && gov="$REPLY"
		fi
	fi

	if [ -z "$model" ]; then
		kv "GPU" "нет данных"
	else
		kv "Модель" "$model"
		kv "Частота" "${freq:-н/д}${gov:+ ${DIM}· $gov${NC}}"
		if is_int "${load:-x}"; then
			level_by "$load" "$GPU_WARN" "$GPU_CRIT"; local lvl=$REPLY
			color_by_level "$lvl"
			case $lvl in
				2) kv "Загрузка" "${REPLY}$load% — КРИТИЧНО${NC}"; raise_status 2 ;;
				1) kv "Загрузка" "${REPLY}$load% — ВНИМАНИЕ${NC}"; raise_status 1 ;;
				*) kv "Загрузка" "$load%" ;;
			esac
		else
			kv "Загрузка" "н/д"
		fi
	fi

	# Экран: разрешение и текущая частота обновления (период vsync из SurfaceFlinger)
	local res period hz=""
	res=$(wm size 2>/dev/null | awk -F': ' '/Override/ {o=$2} /Physical/ {p=$2} END {print (o ? o " (физ. " p ")" : p)}')
	period=$(dumpsys SurfaceFlinger --latency 2>/dev/null | head -n 1)
	is_int "${period:-x}" && [ "$period" -gt 0 ] && hz=$(( (1000000000 + period / 2) / period ))
	detect_ltpo
	kv "Экран" "${res:-?}${hz:+ · $hz Гц}${REPLY:+ · $REPLY}"
	[ -n "$PANEL_MODEL" ] && kv "Панель" "$PANEL_MODEL"
}

# [3.1] LTPO / адаптивная частота экрана → REPLY («LTPO 1–120 Гц» или пусто).
# 1) Драйвер панели Pixel (gs-panel): panel_idle есть только у панелей, которые
#    умеют снижать частоту в простое; нижняя граница — min_vrefresh.
# 2) Запасной путь — dumpsys display: частоты ниже 60 Гц в mSupportedRefreshRates.
#    Это признак адаптивной частоты, но не обязательно LTPO, поэтому подпись мягче.
PANEL_MODEL=""
detect_ltpo() {
	REPLY=""; PANEL_MODEL=""
	local pp minv="" rates lo hi
	for pp in "$R"/sys/devices/platform/exynos-drm/primary-panel "$R"/sys/devices/platform/*/primary-panel; do
		[ -d "$pp" ] || continue
		rd "$pp/panel_model" && PANEL_MODEL="$REPLY"
		[ -z "$PANEL_MODEL" ] && rd "$pp/panel_name" && PANEL_MODEL="$REPLY"
		REPLY=""
		if [ -e "$pp/panel_idle" ]; then
			rd "$pp/min_vrefresh" && is_int "$REPLY" && [ "$REPLY" -gt 0 ] && minv="$REPLY"
			REPLY="LTPO"
		fi
		break
	done
	# Диапазон частот из DisplayManager (один раз, первая строка списка)
	rates=$(dumpsys display 2>/dev/null | sed -n 's/.*mSupportedRefreshRates=\[\([^]]*\)\].*/\1/p' | head -n 1)
	read -r lo hi <<< "$(printf '%s' "$rates" | awk -F', *' '{ lo = 1e9; hi = 0
		for (i = 1; i <= NF; i++) { v = $i + 0; if (v <= 0) continue; if (v < lo) lo = v; if (v > hi) hi = v }
		if (hi > 0) printf "%.0f %.0f", lo, hi }')"
	if [ "$REPLY" = "LTPO" ]; then
		# Нижняя граница LTPO (до 1 Гц) системе не видна — берём её только у драйвера
		if [ -n "$minv" ] && is_int "${hi:-x}"; then REPLY="LTPO $minv–$hi Гц"
		elif is_int "${hi:-x}"; then REPLY="LTPO до $hi Гц"; fi
	elif is_int "${lo:-x}" && is_int "${hi:-x}" && [ "$lo" -lt 60 ]; then
		REPLY="адаптивная $lo–$hi Гц"
	fi
	return 0
}

# ── Батарея ──────────────────────────────────────────────────────────────────

check_battery() {
	section "БАТАРЕЯ"
	local b="$R/sys/class/power_supply/battery"
	if [ ! -d "$b" ]; then kv "Батарея" "нет данных"; return; fi

	local cap status temp=0 volt=0 cur_ua="" health cycles full design
	rd "$b/capacity"; cap="$REPLY"; is_int "$cap" || cap=0
	rd "$b/status"; status="$REPLY"
	rd "$b/temp" && is_int "$REPLY" && temp=$((REPLY / 10))
	rd "$b/voltage_now" && is_int "$REPLY" && volt=$((REPLY / 1000))
	rd "$b/current_now" && is_int "$REPLY" && cur_ua="$REPLY"
	rd "$b/health"; health="$REPLY"
	rd "$b/cycle_count"; cycles="$REPLY"
	rd "$b/charge_full"; full="$REPLY"
	rd "$b/charge_full_design"; design="$REPLY"

	# Знак тока у вендоров разный (Pixel: разряд < 0, Qualcomm: разряд > 0) — приводим к
	# «минус = разряд» по статусу
	if [ -n "$cur_ua" ]; then
		case "$status" in
			Discharging) [ "$cur_ua" -gt 0 ] && cur_ua=$(( -cur_ua )) ;;
			Charging|Full) [ "$cur_ua" -lt 0 ] && cur_ua=$(( -cur_ua )) ;;
		esac
	fi

	local st_ru
	case "$status" in
		Charging) st_ru="${GREEN}заряжается${NC}" ;;
		Discharging) st_ru="разряжается" ;;
		Full) st_ru="${GREEN}заряжена${NC}" ;;
		"Not charging") st_ru="${YELLOW}не заряжается${NC}" ;;
		*) st_ru="${status:-?}" ;;
	esac
	local cap_c=""
	[ "$status" = "Discharging" ] && [ "$cap" -lt 20 ] && cap_c="$RED"
	kv "Уровень" "${cap_c}${cap}%${cap_c:+$NC} · $st_ru"

	# Источник питания
	local src="" ps tp on
	for ps in "$R"/sys/class/power_supply/*; do
		rd "$ps/online" && [ "$REPLY" = "1" ] || continue
		rd "$ps/type"; tp="$REPLY"
		case "${ps##*/}:$tp" in
			wireless:*|*:Wireless) src="беспроводная" ;;
			usb:*|*:USB*)
				local uv=0; rd "$ps/voltage_now" && is_int "$REPLY" && uv=$((REPLY / 1000))
				if [ "$uv" -gt 6000 ]; then src="USB, быстрая ($((uv / 1000)) В)"
				elif [ -z "$src" ]; then src="USB"; fi ;;
			*:Mains|main:*|ac:*) [ -z "$src" ] && src="сеть" ;;
		esac
	done
	# Battery Share (обратная беспроводная) — Pixel
	local rn
	for rn in "$R/sys/class/power_supply/wireless/reverse_chg_mode" "$R/sys/class/power_supply/wireless/wireless_out"; do
		rd "$rn" && [ "$REPLY" = "1" ] && { src="${MAGENTA}раздаёт заряд (Battery Share)${NC}"; break; }
	done
	[ -n "$src" ] && kv "Питание" "$src"

	# Здоровье: ёмкость по датчику к паспортной
	local hp="" h_ru
	case "$health" in
		Good) h_ru="хорошее" ;; Overheat) h_ru="${RED}перегрев${NC}" ;; Dead) h_ru="${RED}неисправна${NC}" ;;
		Cold) h_ru="холодная" ;; "Over voltage") h_ru="${RED}перенапряжение${NC}" ;; *) h_ru="${health:-?}" ;;
	esac
	if is_int "${full:-x}" && is_int "${design:-x}" && [ "$design" -gt 0 ]; then
		local pct=$(( full * 100 / design ))
		if [ "$pct" -gt 100 ]; then hp="100% ${DIM}(датчик: $pct% — ещё калибруется)${NC}"
		elif [ "$pct" -lt 80 ]; then hp="${YELLOW}$pct%${NC} ${DIM}($((full / 1000)) из $((design / 1000)) мА·ч)${NC}"
		else hp="$pct% ${DIM}($((full / 1000)) из $((design / 1000)) мА·ч)${NC}"; fi
	fi
	kv "Здоровье" "$h_ru${hp:+ · ёмкость $hp}"
	is_int "${cycles:-x}" && kv "Циклы" "$cycles"

	local tc=""
	[ "$temp" -ge "$BATT_TEMP_WARN" ] && tc="$RED"
	kv "Температура" "${tc}${temp}°C${tc:+$NC}"
	if [ -n "$cur_ua" ] && [ "$volt" -gt 0 ]; then
		local ma=$((cur_ua / 1000)) w
		w=$(awk -v v="$volt" -v i="$ma" 'BEGIN { printf "%.2f", v * i / 1000000 }')
		kv "Ток" "$ma мА · ${w#-} Вт · $volt мВ"
	else
		kv "Напряжение" "$volt мВ"
	fi
	note "Ток: минус — разряд, плюс — заряд."

	if [ "$temp" -ge "$BATT_TEMP_WARN" ]; then
		verdict 1 "батарея перегрета: ${temp}°C"
	else
		verdict 0 ""
	fi
}

# ── Wakelock ────────────────────────────────────────────────────────────────

check_wakelocks() {
	section "WAKELOCK" "(удержание пробуждения)"
	local raw
	raw=$(dumpsys power 2>/dev/null | sed -n '/Wake Locks: size=/,/^[[:space:]]*$/p' | grep 'PARTIAL_WAKE_LOCK')
	if [ -z "$raw" ]; then
		kv "Активные" "${GREEN}нет${NC}"
		return
	fi
	local line tag owner n=0
	while IFS= read -r line; do
		n=$((n + 1)); [ $n -gt 5 ] && break
		tag=$(printf '%s' "$line" | grep -oE "'[^']+'" | head -n 1 | tr -d "'")
		owner=$(printf '%s' "$line" | grep -oE 'uid=[0-9]+' | head -n 1)
		kv "Wakelock $n" "${tag:-?} ${DIM}(${owner:-?})${NC}"
	done <<< "$raw"
	local total; total=$(printf '%s\n' "$raw" | wc -l)
	[ "$total" -gt 5 ] && note "…и ещё $((total - 5))"
}

# ── Сеть ─────────────────────────────────────────────────────────────────────

# Данные о сети из dumpsys connectivity: тип, интерфейс, DNS, Wi-Fi.
# [3.1] Раньше бралась первая проверенная не-VPN сеть. На Pixel мобильные данные
# остаются подключены и проверены даже при Wi-Fi, и в списке они часто первые —
# отсюда ложное «VPN поверх мобильной сети». Теперь разбираем все сети сразу:
#   1) транспорт VPN-сети: Android дописывает к ней транспорты нижележащей сети
#      («Transports: WIFI|VPN»);
#   2) иначе — её Underlying networks по номеру сети;
#   3) иначе — как выбирает сам Android: проверенный Wi-Fi важнее мобильной сети.
NET_TRANSPORT=""; NET_IFACE=""; NET_DNS=""; NET_WIFI=""; NET_VPN_UNDER=""; NET_HAS_VPN=0
load_connectivity() {
	NET_TRANSPORT=""; NET_IFACE=""; NET_DNS=""; NET_WIFI=""; NET_VPN_UNDER=""; NET_HAS_VPN=0
	local recs
	recs=$(dumpsys connectivity 2>/dev/null | awk '
		/NetworkAgentInfo\{/ && /Transports: / {
			id = ""; if (match($0, /network\{[0-9]+\}/)) id = substr($0, RSTART + 8, RLENGTH - 9)
			tr = $0; sub(/.*Transports: /, "", tr); sub(/ .*/, "", tr); gsub(/\|/, "+", tr)
			ifc = ""; if (match($0, /InterfaceName: [^ ]+/)) ifc = substr($0, RSTART + 15, RLENGTH - 15)
			dns = $0; if (sub(/.*DnsAddresses: \[ */, "", dns)) { sub(/ *\].*/, "", dns); gsub(/\//, "", dns); gsub(/,/, "", dns) } else dns = ""
			ssid = ""; if (match($0, /SSID: "[^"]*"/)) ssid = substr($0, RSTART + 7, RLENGTH - 8)
			rssi = ""; if (match($0, /RSSI: -?[0-9]+/)) rssi = substr($0, RSTART + 6, RLENGTH - 6)
			fr = ""; if (match($0, /Frequency: [0-9]+/)) fr = substr($0, RSTART + 11, RLENGTH - 11)
			ls = ""; if (match($0, /Link speed: [0-9]+/)) ls = substr($0, RSTART + 12, RLENGTH - 12)
			val = ($0 ~ /VALIDATED/) ? 1 : 0
			und = ""; if (match($0, /[Uu]nderlying[ A-Za-z]*: *\[[0-9, ]*\]/)) {
				und = substr($0, RSTART, RLENGTH); sub(/.*\[/, "", und); sub(/\].*/, "", und); gsub(/[ ,]+/, " ", und) }
			gsub(/\|/, "", ssid)
			print id "|" tr "|" ifc "|" dns "|" ssid "|" rssi "|" fr "|" ls "|" val "|" und
		}')
	[ -z "$recs" ] && return
	local id tr ifc dns ssid rssi fr ls val und
	local -A TR_BY_ID
	local vpn_tr="" vpn_dns="" vpn_und="" wifi="" cell="" first=""
	while IFS='|' read -r id tr ifc dns ssid rssi fr ls val und; do
		[ -n "$id" ] && TR_BY_ID[$id]="$tr"
		case "+$tr+" in
			*+VPN+*)
				[ "$NET_HAS_VPN" -eq 1 ] && continue
				NET_HAS_VPN=1; vpn_tr="$tr"; vpn_dns="$dns"; vpn_und="$und" ;;
			*+WIFI+*)
				[ "$val" = "1" ] && [ -z "$wifi" ] && wifi="$tr|$ifc|$dns|$ssid|$rssi|$fr|$ls" ;;
			*+CELLULAR+*)
				[ "$val" = "1" ] && [ -z "$cell" ] && cell="$tr|$ifc|$dns|||||" ;;
			*)
				[ "$val" = "1" ] && [ -z "$first" ] && first="$tr|$ifc|$dns|||||" ;;
		esac
	done <<< "$recs"

	# Основная физическая сеть — так же, как выбирает Android: Wi-Fi, затем мобильная
	local main="${wifi:-${cell:-$first}}"
	if [ -n "$main" ]; then
		IFS='|' read -r NET_TRANSPORT NET_IFACE NET_DNS ssid rssi fr ls <<< "$main"
		if [ -n "$ssid" ]; then
			NET_WIFI="«$ssid»${fr:+ · $fr МГц}${rssi:+ · $rssi дБм}${ls:+ · $ls Мбит/с}"
		fi
	fi

	if [ "$NET_HAS_VPN" -eq 1 ]; then
		local t u
		# 1) транспорты самой VPN-сети без «VPN»
		for t in ${vpn_tr//+/ }; do [ "$t" != "VPN" ] && { NET_VPN_UNDER="$t"; break; }; done
		# 2) Underlying networks
		if [ -z "$NET_VPN_UNDER" ]; then
			for u in $vpn_und; do
				for t in ${TR_BY_ID[$u]//+/ }; do [ "$t" != "VPN" ] && { NET_VPN_UNDER="$t"; break 2; }; done
			done
		fi
		# 3) приоритет Android
		[ -z "$NET_VPN_UNDER" ] && NET_VPN_UNDER="${NET_TRANSPORT%%+*}"
		# Через VPN DNS обычно свои — показываем их
		[ -n "$vpn_dns" ] && NET_DNS="$vpn_dns"
	fi
}

# Мобильная сеть: берём слот, где SIM реально вставлена (LOADED)
mobile_info() {
	local states ops types i=0 s
	prop gsm.sim.state; states="$REPLY"
	prop gsm.operator.alpha; ops="$REPLY"
	[ -z "${ops//,/}" ] && { prop gsm.sim.operator.alpha; ops="$REPLY"; }
	prop gsm.network.type; types="$REPLY"
	IFS=',' read -r -a S <<< "$states"
	IFS=',' read -r -a O <<< "$ops"
	IFS=',' read -r -a T <<< "$types"
	REPLY=""
	for s in "${S[@]}"; do
		if [ "$s" = "LOADED" ] || [ "$s" = "READY" ]; then
			REPLY="SIM$((i + 1)): ${O[$i]:-?} · ${T[$i]:-?}"
			return 0
		fi
		i=$((i + 1))
	done
	return 1
}

check_network() {
	section "СЕТЬ"
	local route dev src
	route=$( (timeout 2 ip route get 8.8.8.8 || ip route get 8.8.8.8) 2>/dev/null | head -n 1)
	dev=$(printf '%s' "$route" | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i+1); exit } }')
	src=$(printf '%s' "$route" | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i+1); exit } }')
	load_connectivity

	local kind=""
	case "$dev" in
		wlan*)        kind="Wi-Fi" ;;
		rmnet*|ccmni*|seth*) kind="мобильная сеть" ;;
		rndis*|usb*)  kind="USB-модем" ;;
		tun*|wg*|ppp*) kind="VPN" ;;
		"")           kind="" ;;
		*)            kind="$dev" ;;
	esac
	if [ -z "$kind" ]; then
		kv "Подключение" "${RED}нет маршрута в интернет${NC}"
	else
		local via=""
		if [ "$kind" = "VPN" ] && [ -n "$NET_VPN_UNDER" ]; then
			case "$NET_VPN_UNDER" in
				WIFI) via=" поверх Wi-Fi" ;; CELLULAR) via=" поверх мобильной сети" ;;
				ETHERNET) via=" поверх Ethernet" ;; *) via=" поверх $NET_VPN_UNDER" ;;
			esac
		elif [ "$kind" != "VPN" ] && [ "$NET_HAS_VPN" -eq 1 ]; then
			# VPN поднят, но root-трафик идёт мимо него (VPN только для приложений)
			via=" ${DIM}· VPN активен для приложений${NC}"
		fi
		kv "Подключение" "${GREEN}$kind${NC}$via ${DIM}($dev)${NC}"
	fi
	[ -n "$src" ] && kv "Локальный IP" "$src"
	[ -n "$NET_WIFI" ] && kv "Wi-Fi" "$NET_WIFI"
	mobile_info && kv "Сотовая" "$REPLY"
	[ -n "$NET_DNS" ] && kv "DNS" "$NET_DNS"

	# Доступность: 3 пинга на хост; среднее и разброс (mdev) из той же серии
	local host out ok=0 avg mdev loss
	for host in 1.1.1.1 8.8.8.8 google.com; do
		ping -c 1 -W 1 "$host" >/dev/null 2>&1 || continue
		out=$(ping -c 3 -i 0.3 -W 1 "$host" 2>/dev/null || ping -c 3 -W 1 "$host" 2>/dev/null) || continue
		ok=1
		# iputils: «rtt min/avg/max/mdev = a/b/c/d ms», toybox: «round-trip min/avg/max = a/b/c ms»
		read -r avg mdev <<< "$(printf '%s\n' "$out" | awk '/^rtt|^round-trip/ {
			v = $0; sub(/.*= */, "", v); sub(/ *ms.*/, "", v); n = split(v, a, "/")
			print a[2], (n >= 4 ? a[4] : "?"); exit }')"
		loss=$(printf '%s\n' "$out" | grep -oE '[0-9]+% packet loss' | cut -d'%' -f1)
		kv "Интернет" "${GREEN}есть${NC} ${DIM}(ping $host)${NC}"
		[ -n "$avg" ] && kv "Задержка" "${avg%.*} мс · разброс ${mdev%.*} мс${loss:+ · потери $loss%}"
		break
	done
	if [ "$ok" -eq 0 ] && command -v curl >/dev/null 2>&1; then
		if curl -s -o /dev/null -m 4 -w '%{http_code}' http://clients3.google.com/generate_204 2>/dev/null | grep -q 204; then
			ok=1
			kv "Интернет" "${GREEN}есть${NC} ${DIM}(HTTP; ICMP закрыт)${NC}"
		fi
	fi
	if [ "$ok" -eq 0 ]; then
		verdict 1 "интернета нет"
	fi
	# [3.2] Подсказка про iperf3 — строкой этой же секции, серым
	if [ "$ENABLE_NET_TEST" -ne 1 ] && command -v iperf3 >/dev/null 2>&1; then
		kv "${DIM}Тест скорости${NC}" "${DIM}доступен (iperf3): запусти с --net-speed${NC}"
	fi
}

check_iperf3_speed() {
	[ "$BRIEF_MODE" -eq 1 ] && return
	[ "$ENABLE_NET_TEST" -ne 1 ] && return   # [3.2] подсказка теперь в секции «СЕТЬ»
	section "СКОРОСТЬ СЕТИ" "(iperf3)"
	if ! command -v iperf3 >/dev/null 2>&1; then
		kv "iperf3" "не установлен"
		return
	fi
	note "Идёт тест, до 20 секунд на сервер…"
	local server down up
	for server in iperf.he.net ping.online.net bouygues.iperf.fr speedtest.serverius.net; do
		down=$(timeout 12 iperf3 -c "$server" -R -t 5 2>/dev/null | awk '/receiver/ { print $(NF-2), $(NF-1) }')
		[ -n "$down" ] || continue
		kv "Сервер" "$server"
		kv "Загрузка" "$down"
		up=$(timeout 12 iperf3 -c "$server" -t 5 2>/dev/null | awk '/receiver/ { print $(NF-2), $(NF-1) }')
		kv "Отдача" "${up:-не удалось}"
		return
	done
	kv "iperf3" "${YELLOW}серверы недоступны${NC}"
}

# ── Logcat ───────────────────────────────────────────────────────────────────

check_logcat() {
	section "ОШИБКИ LOGCAT" "(main, system, crash)"
	if [ "$NO_LOGCAT" -eq 1 ]; then
		kv "Logcat" "пропущен (--no-logcat)"
		return
	fi
	local errors c
	errors=$(logcat -b main,system,crash -d '*:E' 2>/dev/null | grep -v '^--------- beginning of' | tail -n 2000)
	if [ -z "$errors" ]; then
		kv "Ошибки" "${GREEN}нет${NC}"
		return
	fi
	c=$(printf '%s\n' "$errors" | wc -l)
	[ "$NO_FILE_LOG" -eq 0 ] && printf '%s\n' "$errors" > "$ERR_LOG" 2>/dev/null

	# Реальные падения: Java (FATAL EXCEPTION), нативные (Fatal signal), ANR
	local fatal anr crashes=0
	fatal=$(printf '%s\n' "$errors" | grep -cE 'FATAL EXCEPTION|Fatal signal [0-9]+')
	anr=$(printf '%s\n' "$errors" | grep -c 'ANR in ')
	crashes=$((fatal + anr))

	local more=""; [ "$c" -ge 2000 ] && more="+"
	kv "Строк ошибок" "$c$more ${DIM}(последние 2000)${NC}"
	# Самые шумные теги вместо последних строк — сразу видно, кто спамит
	local tag n
	while read -r n tag; do
		[ -n "$tag" ] && kv "  $tag" "$n"
	done < <(printf '%s\n' "$errors" | awk '{
			t = ""
			for (i = 5; i <= NF; i++) if ($i == "E" || $i == "F") { t = $(i+1); break }
			sub(/:$/, "", t); if (t != "") cnt[t]++
		} END { for (t in cnt) print cnt[t], t }' | sort -rn | head -n 3)
	if [ "$crashes" -gt 0 ]; then
		printf '%s\n' "$errors" | grep -E 'FATAL EXCEPTION|Fatal signal|ANR in ' | tail -n 3 | while IFS= read -r line; do
			note "› ${line:0:150}"
		done
	fi
	[ "$NO_FILE_LOG" -eq 0 ] && note "Полный список: $ERR_LOG"

	if [ "$crashes" -gt 0 ]; then
		verdict 2 "падения приложений: $fatal, ANR: $anr"
	elif [ "$c" -gt 1000 ]; then
		verdict 1 "много ошибок — см. теги выше"
	else
		verdict 0 "падений нет"
	fi
}

# ── Процессы ─────────────────────────────────────────────────────────────────

print_top() {
	local data
	data=$(ps -Ao pid,comm,%cpu,rss --sort=-%cpu 2>/dev/null | awk 'NR > 1 && NR <= 6')
	[ -z "$data" ] && data=$(ps -Ao pid,comm,%cpu,rss -k -%cpu 2>/dev/null | awk 'NR > 1 && NR <= 6')
	[ -z "$data" ] && return
	section "ТОП ПРОЦЕССОВ" "(по CPU)"
	# [3.2] Строка «PID 1234 : имя · CPU % · ОЗУ МБ» — в общей колонке, как остальные
	local pid comm cpu rss name mem mc
	while read -r pid comm cpu rss; do
		name="$comm"
		case "$comm" in
			app_process*|main|base|sh)
				if [ -r "$R/proc/$pid/cmdline" ]; then
					IFS= read -r -d '' name < "$R/proc/$pid/cmdline"
					name="${name##*/}"; [ -z "$name" ] && name="$comm"
				fi ;;
		esac
		mem="?"; mc=""
		if is_int "${rss:-x}"; then
			mem=$(( (rss + 512) / 1024 ))
			[ "$rss" -ge 1048576 ] && mc="$RED" || { [ "$rss" -ge 524288 ] && mc="$YELLOW"; }
		fi
		kv "PID $pid" "${name:0:40} ${DIM}·${NC} ${cpu}% ${DIM}·${NC} ${mc}${mem} МБ${mc:+$NC}"
	done <<< "$data"
}

# ── Ввод-вывод ───────────────────────────────────────────────────────────────

print_io() {
	section "ВВОД-ВЫВОД" "(с момента загрузки)"
	[ -r "$R/proc/diskstats" ] || { kv "diskstats" "нет данных"; return; }
	# Карта «устройство → точка монтирования» из mountinfo, без временных файлов
	local out
	out=$(awk '
		FNR == NR {
			for (i = 1; i <= NF; i++) if ($i == "-") { src = $(i + 2); break }
			n = src; sub(/.*\//, "", n)
			if (!(n in mnt) || length($5) < length(mnt[n])) mnt[n] = $5
			next
		}
		$3 ~ /^(sd[a-z]+|mmcblk[0-9]+|dm-[0-9]+)$/ {
			r = $6 / 2048; w = $10 / 2048
			if (r < 0.1 && w < 0.1) next
			m = ($3 in mnt) ? mnt[$3] : ""
			if ($3 ~ /^dm-/ && (m == "" || m ~ /^\/apex\//)) next   # безымянные dm-* и apex — шум
			printf "%s|%s|%.1f|%.1f\n", $3, (m == "" ? "весь диск" : m), r, w
		}' "$R/proc/self/mountinfo" "$R/proc/diskstats")
	if [ -z "$out" ]; then kv "Активность" "нет (>0.1 МБ)"; return; fi
	local dev mp r w
	while IFS='|' read -r dev mp r w; do
		kv "$dev" "чтение $r МБ · запись $w МБ ${DIM}($mp)${NC}"
	done <<< "$out"
}

check_io_schedulers() {
	section "ПЛАНИРОВЩИКИ I/O"
	declare -A grp
	local d n s ra key
	for d in "$R"/sys/block/sd[a-z] "$R"/sys/block/mmcblk[0-9]; do
		[ -r "$d/queue/scheduler" ] || continue
		n="${d##*/}"
		rd "$d/queue/scheduler"; s="$REPLY"
		[[ "$s" =~ \[([^]]+)\] ]] && s="${BASH_REMATCH[1]}"
		rd "$d/queue/read_ahead_kb"; ra="$REPLY"
		key="$s · read-ahead ${ra:-?} КБ"
		grp[$key]="${grp[$key]:+${grp[$key]} }$n"
	done
	if [ ${#grp[@]} -eq 0 ]; then kv "Устройства" "не найдены"; return; fi
	for key in "${!grp[@]}"; do
		kv "${grp[$key]// /,}" "$key"
	done
}

# ── Разделы ──────────────────────────────────────────────────────────────────

check_partitions() {
	section "РАЗДЕЛЫ"
	# Один проход по mountinfo: точка → тип ФС, опции, источник
	declare -A MFS MOPT MSRC
	local mp fs opt src
	while IFS='|' read -r mp fs opt src; do
		[ -n "${MFS[$mp]:-}" ] && continue
		MFS[$mp]="$fs"; MOPT[$mp]="$opt"; MSRC[$mp]="$src"
	done < <(awk '{ for (i = 1; i <= NF; i++) if ($i == "-") { print $5 "|" $(i+1) "|" $6 "|" $(i+2); break } }' "$R/proc/self/mountinfo")

	local part target acc size used avail line
	for part in system system_ext product vendor odm cache data metadata persist; do
		target=""
		case "$part" in
			system)  for mp in /system / /system_root; do [ -n "${MFS[$mp]:-}" ] && [ "${MFS[$mp]}" != "tmpfs" ] && [ "${MFS[$mp]}" != "rootfs" ] && { target="$mp"; break; }; done ;;
			persist) for mp in /persist /mnt/vendor/persist; do [ -n "${MFS[$mp]:-}" ] && { target="$mp"; break; }; done ;;
			*)       [ -n "${MFS[/$part]:-}" ] && target="/$part" ;;
		esac
		[ -z "$target" ] && continue
		case ",${MOPT[$target]}," in *,ro,*) acc="ro" ;; *,rw,*) acc="rw" ;; *) acc="??" ;; esac
		line=$(df -k "$target" 2>/dev/null | awk 'NR > 1 && $2 ~ /^[0-9]+$/ { print $2, $3, $4; exit }')
		read -r size used avail <<< "$line"
		local sz=""
		is_int "${size:-x}" && sz=" · $(hsize_kb "$size"), свободно $(hsize_kb "$avail")"
		kv "$part" "${MFS[$target]} $acc ${DIM}${target} ← ${MSRC[$target]}${NC}$sz"
	done
}

# ── Pixel ────────────────────────────────────────────────────────────────────

check_pixel_security() {
	prop ro.product.manufacturer
	[[ "${REPLY,,}" == *google* ]] || return 0
	section "GOOGLE PIXEL"
	local soc plat gen=""
	prop ro.soc.model; soc="$REPLY"
	prop ro.board.platform; plat="$REPLY"
	case "$soc $plat" in
		*"Tensor G"[0-9]*) gen="${soc}" ;;
		*gs101*) gen="Tensor G1" ;; *gs201*) gen="Tensor G2" ;; *zumapro*) gen="Tensor G4" ;;
		*zuma*) gen="Tensor G3" ;; *laguna*) gen="Tensor G5" ;;
	esac
	if [ -z "$gen" ]; then
		kv "Платформа" "${soc:-$plat} ${DIM}(не Tensor — Pixel 5 и старше)${NC}"
		return
	fi
	kv "Платформа" "$gen ${DIM}($plat)${NC}"

	if [ -d "$R/sys/class/edgetpu" ] || compgen -G "$R/dev/edgetpu*" >/dev/null; then
		kv "Нейроблок TPU" "${GREEN}есть${NC} ${DIM}(edgetpu)${NC}"
	else
		kv "Нейроблок TPU" "не найден"
	fi

	prop ro.strongbox.model; local sb="$REPLY"
	if [ -e "$R/dev/gsc0" ] || [ -e "$R/dev/citadel0" ] || [ -n "$sb" ]; then
		kv "Чип защиты" "${GREEN}${sb:-Titan M}${NC} ${DIM}(StrongBox)${NC}"
	else
		kv "Чип защиты" "${YELLOW}не найден${NC}"
	fi
	if [ -e "$R/dev/aoc" ] || [ -d "$R/sys/devices/platform/aoc" ]; then
		kv "AOC" "есть ${DIM}(Always-On Compute)${NC}"
	fi
	prop gsm.version.baseband
	[ -n "$REPLY" ] && kv "Модем" "${REPLY%%,*}"
	kv "Статус AVB" "$VB_LABEL"
}

# ── Система ──────────────────────────────────────────────────────────────────

ROOT_INFO=""; ZYGISK_INFO=""; ROOT_KIND="ROOT"   # ROOT_KIND — для заголовка «МОДУЛИ …»
detect_root() {
	ROOT_INFO=""; ZYGISK_INFO=""; ROOT_KIND="ROOT"
	if command -v magisk >/dev/null 2>&1 || [ -d "$R/data/adb/magisk" ]; then
		local v vc
		v=$(magisk -v 2>/dev/null); v="${v%%:*}"
		vc=$(magisk -V 2>/dev/null)
		ROOT_INFO="Magisk ${v:-?}${vc:+ ($vc)}"; ROOT_KIND="MAGISK"
		# Zygisk: настройка в БД Magisk + реальное присутствие в zygote64
		local on="" active=0 pid
		on=$(magisk --sqlite "SELECT value FROM settings WHERE key='zygisk'" 2>/dev/null)
		on="${on#value=}"
		for pid in $(pidof zygote64 zygote 2>/dev/null); do
			grep -q zygisk "$R/proc/$pid/maps" 2>/dev/null && { active=1; break; }
		done
		if [ "$on" = "1" ] && [ "$active" -eq 1 ]; then ZYGISK_INFO="${GREEN}включён и активен${NC}"
		elif [ "$on" = "1" ]; then ZYGISK_INFO="${YELLOW}включён, но не загружен — нужна перезагрузка${NC}"
		elif [ "$active" -eq 1 ]; then ZYGISK_INFO="${GREEN}активен${NC} ${DIM}(сторонний: ZygiskNext/NeoZygisk)${NC}"
		else ZYGISK_INFO="выключен"; fi
	elif [ -d "$R/data/adb/ksu" ] || command -v ksud >/dev/null 2>&1; then
		ROOT_INFO="KernelSU"; ROOT_KIND="KERNELSU"
	elif [ -d "$R/data/adb/ap" ] || command -v apd >/dev/null 2>&1; then
		ROOT_INFO="APatch"; ROOT_KIND="APATCH"
	else
		ROOT_INFO="root (метод не определён)"
	fi
}

uptime_str() {
	local up _
	read -r up _ < "$R/proc/uptime" 2>/dev/null
	up=${up%%.*}
	is_int "${up:-x}" || { REPLY="?"; return; }
	local d=$((up / 86400)) h=$(( (up % 86400) / 3600 )) m=$(( (up % 3600) / 60 ))
	REPLY=""
	[ $d -gt 0 ] && REPLY="$d д "
	REPLY="$REPLY$h ч $m мин"
}

print_system() {
	section "СИСТЕМА"
	uptime_str; kv "Время работы" "$REPLY"
	detect_root
	kv "Root" "${GREEN}есть${NC} · $ROOT_INFO"
	[ -n "$ZYGISK_INFO" ] && kv "Zygisk" "$ZYGISK_INFO"
	local se; se=$(getenforce 2>/dev/null)
	case "$se" in
		Enforcing)  kv "SELinux" "${GREEN}Enforcing${NC}" ;;
		Permissive) kv "SELinux" "${YELLOW}Permissive${NC}" ;;
		*)          kv "SELinux" "${se:-?}" ;;
	esac
	kv "Статус AVB" "$VB_LABEL"
	note "ядро: ${VB_REAL:-${VB_DEVSTATE:-—}} · свойства: ${VB_PROP:-—}/flash.locked=${VB_LOCKPROP:-—}"
	note "Вердикт Play Integrity выносят серверы Google — локально его не проверить."
	prop ro.product.cpu.abi; kv "ABI" "$REPLY"

	[ "$EXTENDED" -eq 1 ] || return 0
	prop persist.sys.locale; local loc="$REPLY"
	[ -z "$loc" ] && { prop ro.product.locale; loc="$REPLY"; }
	kv "Язык" "${loc%%-u-*}"
	prop ro.build.display.id; kv "Сборка" "$REPLY"
	prop ro.build.description; [ -n "$REPLY" ] && kv "Прошивка" "$REPLY"
	local vk egl
	prop ro.hardware.vulkan; vk="$REPLY"; prop ro.hardware.egl; egl="$REPLY"
	kv "Драйверы" "Vulkan: ${vk:-по умолчанию} · EGL: ${egl:-по умолчанию}"
}

# [3.1] Модули: заголовок по типу root, статус у каждого модуля, версия через
# разделитель, описание строкой ниже. Флаги — штатные файлы Magisk/KernelSU/APatch:
#   disable → выкл., remove → удалится, update или modules_update/<id> → обновлён.
# Новые модули, которые появятся только после перезагрузки, тоже показываем.
mod_prop() {   # mod_prop ФАЙЛ КЛЮЧ → REPLY (без управляющих символов)
	REPLY=""
	[ -r "$1" ] || return 1
	REPLY=$(sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1)
	REPLY="${REPLY//[[:cntrl:]]/}"
	[ -n "$REPLY" ]
}

# [3.4] Было print_magisk_modules: секция универсальная — теперь print_modules,
# а заголовок берётся из глобальной ROOT_KIND (её видит и список секций в -d).
print_modules() {
	[ -z "$ROOT_INFO" ] && detect_root
	local dir="$R/data/adb/modules" upd="$R/data/adb/modules_update"
	[ -d "$dir" ] || [ -d "$upd" ] || [ "$ROOT_KIND" != "ROOT" ] || return 0
	section "МОДУЛИ $ROOT_KIND"

	local -a ids=()
	local m id
	for m in "$dir"/*/ "$upd"/*/; do
		id="${m%/}"; id="${id##*/}"
		[ "$id" = "lost+found" ] && continue
		[[ " ${ids[*]} " == *" $id "* ]] || ids+=("$id")
	done
	if [ ${#ids[@]} -eq 0 ]; then
		emit "  ${RED}Модули не установлены${NC}"
		return 0
	fi

	local name ver vc desc st stc tag pend=0 sp
	for id in "${ids[@]}"; do
		m="$dir/$id"
		if [ -d "$m" ]; then
			st="вкл."; stc="$GREEN"
			[ -e "$m/disable" ] && { st="выкл."; stc="$YELLOW"; }
			if [ -e "$m/update" ] || [ -d "$upd/$id" ]; then st="обновлён"; stc="$CYAN"; pend=1; fi
			[ -e "$m/remove" ] && { st="удалится"; stc="$RED"; pend=1; }
		else
			m="$upd/$id"; st="новый"; stc="$CYAN"; pend=1
		fi
		# Свойства берём из обновлённой копии, если она есть
		local propf="$m/module.prop"
		[ -r "$upd/$id/module.prop" ] && propf="$upd/$id/module.prop"
		mod_prop "$propf" name;        name="${REPLY:-$id}"
		mod_prop "$propf" version;     ver="$REPLY"
		mod_prop "$propf" versionCode; vc="$REPLY"
		mod_prop "$propf" description; desc="$REPLY"
		# Колонка статуса шириной 8 символов
		char_len "$st"; printf -v sp '%*s' $((8 - REPLY)) ""
		tag="${stc}${st}${NC}${sp}"
		emit "  ${tag} ${BOLD}${name}${NC}${ver:+ ${DIM}·${NC} $ver}${vc:+ ${DIM}($vc)${NC}}"
		if [ -n "$desc" ]; then
			[ ${#desc} -gt 160 ] && desc="${desc:0:157}..."
			emit "           ${DIM}${desc}${NC}"
		fi
	done
	[ "$pend" -eq 1 ] && note "обновлён / удалится / новый — изменения применятся после перезагрузки"
}

# [3.1] Ядро: полный разбор /proc/version — версия, сборщик, компилятор и линкер,
# флаги сборки и дата, архитектура, размер страницы, модули ядра.
print_kernel_extended() {
	section "ЯДРО"
	local ver rel major minor
	rd "$R/proc/version"; ver="$REPLY"
	rel=$(uname -r 2>/dev/null)
	kv "Версия" "${rel:-?}"
	local arch; arch=$(uname -m 2>/dev/null); [ -n "$arch" ] && kv "Архитектура" "$arch"

	# «Linux version REL (user@host) (toolchain) #N SMP PREEMPT Day Mon DD HH:MM:SS TZ YYYY»
	local builder="" tool="" build="" date=""
	local re_full='^Linux version [^ ]+ [(]([^)]*)[)] [(](.*)[)] (#.*)$'
	local re_short='^Linux version [^ ]+ [(]([^)]*)[)] (#.*)$'
	if [[ "$ver" =~ $re_full ]]; then
		builder="${BASH_REMATCH[1]}"; tool="${BASH_REMATCH[2]}"; build="${BASH_REMATCH[3]}"
	elif [[ "$ver" =~ $re_short ]]; then
		builder="${BASH_REMATCH[1]}"; build="${BASH_REMATCH[2]}"
	fi
	[ -n "$builder" ] && kv "Сборщик" "$builder"

	local cc ld based
	cc=$(printf '%s' "${tool:-$ver}" | grep -oE '(clang|gcc) version [0-9][0-9.]*' | head -n 1)
	ld=$(printf '%s' "${tool:-$ver}" | grep -oE '(LLD|GNU ld[^,)]*) [0-9][0-9.]*' | head -n 1)
	based=$(printf '%s' "$tool" | grep -oE 'based on r[0-9a-z]+' | head -n 1)
	if [ -n "$cc" ]; then
		cc="${cc/ version/}"
		kv "Компилятор" "$cc${ld:+ · $ld}${based:+ ${DIM}(Android, ${based#based on })${NC}}"
	fi

	if [ -n "$build" ]; then
		# Дата — хвост вида «Mon Oct 13 10:00:00 UTC 2026»
		local re_date='^(.*[^ ]) +([A-Z][a-z]{2} [A-Z][a-z]{2} +[0-9]+ [0-9:]+ [A-Za-z0-9+-]+ [0-9]{4})$'
		if [[ "$build" =~ $re_date ]]; then
			build="${BASH_REMATCH[1]}"; date="${BASH_REMATCH[2]}"
		fi
		kv "Сборка" "$build"
		[ -n "$date" ] && kv "Дата сборки" "$date"
	fi

	IFS=. read -r major minor _ <<< "$rel"
	if is_int "${major:-x}" && is_int "${minor%%[!0-9]*}"; then
		minor="${minor%%[!0-9]*}"
		if [ "$major" -gt 5 ] || { [ "$major" -eq 5 ] && [ "$minor" -ge 10 ]; }; then
			kv "Тип" "GKI ${DIM}(ядро ≥ 5.10)${NC}"
		else
			kv "Тип" "не GKI ${DIM}(legacy, ядро < 5.10)${NC}"
		fi
	fi

	local pg; pg=$(getconf PAGESIZE 2>/dev/null)
	is_int "${pg:-x}" && kv "Страница" "$((pg / 1024)) КБ"
	if [ -r "$R/proc/modules" ]; then
		local nmod; nmod=$(grep -c '' "$R/proc/modules" 2>/dev/null)
		kv "Модули ядра" "${nmod:-0} загружено"
	fi

	local tcp avail
	tcp=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
	avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
	kv "TCP" "${tcp:-?} ${DIM}(доступно: ${avail:-?})${NC}"
	if rd "$R/sys/module/wireguard/version"; then kv "WireGuard" "v$REPLY"; fi

	local hz=""
	[ -r "$R/proc/config.gz" ] && hz=$( (zcat "$R/proc/config.gz" || gzip -dc "$R/proc/config.gz") 2>/dev/null | sed -n 's/^CONFIG_HZ=//p' | head -n 1)
	if [ -n "$hz" ]; then kv "Частота тика" "$hz Гц"; else kv "Частота тика" "неизвестно (нет /proc/config.gz)"; fi

	# [3.5] Новый генератор случайных чисел (BLAKE2s, 5.18) в 2022 году перенесли
	# во все стабильные ветки, включая 4.19 и 5.4 — поэтому 256 бывает и на старых
	# ядрах. Признак нового RNG — poolsize 256: тогда entropy_avail всегда 256
	# после инициализации, и это не ошибка. На старом RNG poolsize был 4096.
	if rd "$R/proc/sys/kernel/random/entropy_avail"; then
		local ent="$REPLY" pool=""
		rd "$R/proc/sys/kernel/random/poolsize" && pool="$REPLY"
		if [ "$pool" = "256" ]; then
			kv "Энтропия" "$ent ${DIM}(новый RNG: значение фиксированное, это норма)${NC}"
		else
			kv "Энтропия" "$ent из ${pool:-?} бит"
		fi
	fi
	[ -e "$R/dev/kvm" ] && kv "KVM" "есть ${DIM}(pKVM / виртуализация)${NC}"

	local cmd
	rd "$R/proc/cmdline"; cmd="$REPLY"
	# серийный номер в cmdline старых устройств в лог не пишем
	cmd=$(printf '%s' "$cmd" | sed -E 's/(androidboot\.serialno=)[^ ]+/\1***/g')
	local ell=""; [ ${#cmd} -gt 100 ] && ell="…"
	[ -n "$cmd" ] && kv "cmdline" "${cmd:0:100}$ell"
}

# ═════════════════════════════════════════════════════════════════════════════
#  ЗАПУСК
# ═════════════════════════════════════════════════════════════════════════════

DEPS_OK=0
check_dependencies() {
	[ "$DEPS_OK" -eq 1 ] && return 0
	if [ -z "$R" ] && [ "$(id -u)" -ne 0 ]; then
		printf '%s[!] Нужен root: su -c sh %s%s\n' "$RED" "$0" "$NC" >&2
		return $EXIT_INTERNAL
	fi
	local d missing=""
	for d in awk grep sed df ps dumpsys getprop cat; do
		command -v "$d" >/dev/null 2>&1 || missing="$missing $d"
	done
	[ "$NO_LOGCAT" -eq 0 ] && ! command -v logcat >/dev/null 2>&1 && missing="$missing logcat"
	if [ -n "$missing" ]; then
		printf '%s[!] Не найдены утилиты:%s%s\n' "$RED" "$missing" "$NC" >&2
		return $EXIT_INTERNAL
	fi
	if [ "$NO_FILE_LOG" -eq 0 ] && ! mkdir -p "${LOG%/*}" 2>/dev/null; then
		printf '[!] Не удалось создать папку лога: %s\n' "${LOG%/*}" >&2
		return $EXIT_INTERNAL
	fi
	DEPS_OK=1
	return 0
}

open_log() {
	LOG_FD_OPEN=0
	[ "$NO_FILE_LOG" -eq 1 ] && return
	# ротация: больше 1000 строк — оставляем последние 500
	if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 1000 ]; then
		tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
	fi
	if { exec 3>>"$LOG"; } 2>/dev/null; then
		LOG_FD_OPEN=1
		local ts; printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1
		printf '\n══════ СЕАНС %s ══════\n' "$ts" >&3
	fi
}

close_log() { [ "$LOG_FD_OPEN" -eq 1 ] && exec 3>&-; LOG_FD_OPEN=0; }

# ═════════════════════════════════════════════════════════════════════════════
#  [3.3] ПРОБНЫЙ ЗАПУСК: выборочный вывод секций
# ═════════════════════════════════════════════════════════════════════════════
# Секцией считается любая функция, которая вызывает section "…". Список собирается
# сам из кода скрипта (declare -F / declare -f), поэтому новая функция check_* или
# print_* с section появится здесь без правок — даже если её нет в run_monitor.
#   -d                 заголовок + список секций
#   -d cpu,thermal     заголовок + только эти секции (код выхода — их итог)
#   -d all             заголовок + все секции подряд
# Имя секции — имя функции без check_/print_ (cpu, thermal, magisk_modules…)
# или полное имя функции.

declare -a DRY_FUNCS DRY_TITLES DRY_MAIN
discover_sections() {
	DRY_FUNCS=(); DRY_TITLES=(); DRY_MAIN=()
	local f body title main_body line var nl=$'\n'
	local re_sec="(^|${nl})[[:space:]]*section \"([^\"]*)\""
	local re_var='[$][{]?([A-Za-z_][A-Za-z_0-9]*)[}]?'
	local -A TITLE_OF=() SEEN=()
	main_body=$(declare -f run_monitor)

	# 1) все функции, которые вызывают section "…"
	while read -r _ _ f; do
		case "$f" in section|run_dry|run_monitor|discover_sections) continue ;; esac
		body=$(declare -f "$f")
		[[ "$body" =~ $re_sec ]] || continue
		title="${BASH_REMATCH[2]}"
		# [3.4] $ПЕРЕМЕННАЯ в заголовке: глобальная — подставляем значение, иначе «…»
		while [[ "$title" =~ $re_var ]]; do
			var="${BASH_REMATCH[1]}"
			title="${title/"${BASH_REMATCH[0]}"/${!var:-…}}"
		done
		TITLE_OF[$f]="$title"
	done < <(declare -F)

	# 2) [3.4] порядок как в обычном проходе, затем секции вне прохода по алфавиту
	while IFS= read -r line; do
		line="${line#"${line%%[! ]*}"}"; f="${line%%[; ]*}"
		[ -n "${TITLE_OF[$f]:-}" ] && [ -z "${SEEN[$f]:-}" ] || continue
		SEEN[$f]=1; DRY_FUNCS+=("$f"); DRY_TITLES+=("${TITLE_OF[$f]}"); DRY_MAIN+=(1)
	done <<< "$main_body"
	for f in $(printf '%s\n' "${!TITLE_OF[@]}" | sort); do
		[ -z "${SEEN[$f]:-}" ] || continue
		DRY_FUNCS+=("$f"); DRY_TITLES+=("${TITLE_OF[$f]}"); DRY_MAIN+=(0)
	done
}

short_name() { REPLY="${1#check_}"; REPLY="${REPLY#print_}"; }

run_dry() {
	load_zones
	load_thermal_hal
	detect_root          # нужен для заголовка «МОДУЛИ MAGISK» в списке
	discover_sections
	print_header

	local i n
	if [ -z "$DRY_SECTIONS" ]; then
		CUR_SECTION="ПРОБНЫЙ ЗАПУСК"
		emit ""
		emit "${CYAN}[ СЕКЦИИ ]${NC} ${DIM}(выбор: -d имя[,имя…] или -d all)${NC}"
		# Своя ширина колонки: имена секций длиннее обычных подписей
		local w=0 sp
		for i in "${!DRY_FUNCS[@]}"; do short_name "${DRY_FUNCS[$i]}"; [ ${#REPLY} -gt $w ] && w=${#REPLY}; done
		for i in "${!DRY_FUNCS[@]}"; do
			short_name "${DRY_FUNCS[$i]}"; n="$REPLY"
			printf -v sp '%*s' $((w - ${#n})) ""
			if [ "${DRY_MAIN[$i]}" -eq 1 ]; then
				emit "  ${n}${sp} : ${DRY_TITLES[$i]}"
			else
				emit "  ${n}${sp} : ${DRY_TITLES[$i]} ${DIM}· не в основном проходе${NC}"
			fi
		done
		return $EXIT_OK
	fi

	# Разбор списка: запятые и пробелы, имя без префикса или полное имя функции
	local want sel=() unknown=""
	for want in ${DRY_SECTIONS//,/ }; do
		if [ "$want" = "all" ]; then sel=("${DRY_FUNCS[@]}"); break; fi
		local found=""
		for i in "${!DRY_FUNCS[@]}"; do
			short_name "${DRY_FUNCS[$i]}"
			if [ "$want" = "$REPLY" ] || [ "$want" = "${DRY_FUNCS[$i]}" ]; then found="${DRY_FUNCS[$i]}"; break; fi
		done
		if [ -n "$found" ]; then sel+=("$found"); else unknown="$unknown $want"; fi
	done
	if [ -n "$unknown" ]; then
		printf '%s[!] Нет таких секций:%s%s — список: %s -d\n' "$RED" "$unknown" "$NC" "${0##*/}" >&2
		return $EXIT_INTERNAL
	fi

	# Секции, которые в обычном проходе зависят от флагов, при явном выборе включаем
	local f before
	for f in "${sel[@]}"; do
		[ "$f" = "check_iperf3_speed" ] && ENABLE_NET_TEST=1
		before=$EMIT_COUNT
		"$f"
		if [ "$EMIT_COUNT" -eq "$before" ]; then
			short_name "$f"
			CUR_SECTION="ПРОБНЫЙ ЗАПУСК"
			emit ""
			emit "${DIM}[ $REPLY ] на этом устройстве данных для вывода нет${NC}"
		fi
	done

	CUR_SECTION="ИТОГ"
	emit ""
	emit "${BOLD}════════════════════════════════════════${NC}"
	emit " Итог: $(exit_code_label "$SYSTEM_STATUS") ${DIM}(код $SYSTEM_STATUS · только выбранные секции)${NC}"
	emit "${BOLD}════════════════════════════════════════${NC}"
	return "$SYSTEM_STATUS"
}

run_monitor() {
	check_dependencies || return $?
	SYSTEM_STATUS=$EXIT_OK
	open_log
	load_props
	load_verified_boot

	if [ "$DRY_RUN" -eq 1 ]; then
		run_dry
		local rc=$?
		close_log
		return $rc
	fi

	load_zones
	load_thermal_hal

	print_header
	check_storage
	check_memory
	check_cpu
	check_thermal
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
	print_system
	if [ "$EXTENDED" -eq 1 ]; then
		print_modules
		print_kernel_extended
	fi

	CUR_SECTION="ИТОГ"
	emit ""
	emit "${BOLD}════════════════════════════════════════${NC}"
	emit " Итог: $(exit_code_label "$SYSTEM_STATUS") ${DIM}(код $SYSTEM_STATUS)${NC}"
	if [ "$NO_FILE_LOG" -eq 0 ]; then
		emit " ${DIM}Лог: $LOG${NC}"
	fi
	emit "${BOLD}════════════════════════════════════════${NC}"
	close_log
	return "$SYSTEM_STATUS"
}

show_help() {
	cat <<EOF
МОНИТОРИНГ СИСТЕМЫ ANDROID v$VERSION — нужен root

Запуск:
  su -c sh ${0##*/} [опции]

Опции:
  -h, --help            эта справка
  -q, --quiet           ничего не выводить на экран, только в лог-файл
  -n, --no-logcat       не анализировать logcat (быстрее)
  -f, --no-file         не писать лог-файл
  -l, --loop <сек>      повторять каждые N секунд (Ctrl+C — выход)
  -b, --brief           только предупреждения и критичные события
  -d, --dry-run [секции] заголовок и список секций; с именами — только они:
                        -d cpu,thermal   ·   -d all — все секции подряд
  -e, --extended        расширенно: модули root, ядро, сборка, драйверы
  -s, --net-speed       тест скорости сети (нужен iperf3)
  -c, --clear-log       очистить лог-файл и выйти

Пороги (в процентах):
  --disk-warn N  (по умолчанию $DISK_WARN)    --disk-crit N  ($DISK_CRIT)
  --ram-warn N   (по умолчанию $RAM_WARN)    --ram-crit N   ($RAM_CRIT)
  --gpu-warn N   (по умолчанию $GPU_WARN)    --gpu-crit N   ($GPU_CRIT)

Коды выхода:
  0 — всё в порядке   1 — есть предупреждения   2 — критично   3 — ошибка скрипта

Примеры:
  su -c sh ${0##*/}                 один полный проход
  su -c sh ${0##*/} -l 30 -n        каждые 30 с, без logcat
  su -c sh ${0##*/} -q -b           для cron: только код выхода и лог

Лог: $LOG
EOF
}

require_option_value() {
	if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == -* ]]; then
		printf '[!] Опции %s нужно значение\n' "$1" >&2
		exit $EXIT_INTERNAL
	fi
}

validate_percent_pair() {   # имя, warn, crit
	local v
	for v in "$2" "$3"; do
		if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "$v" -gt 100 ]; then
			printf '[!] Порог %s должен быть числом 0–100, получено: %s\n' "$1" "$v" >&2
			exit $EXIT_INTERNAL
		fi
	done
	if [ "$2" -ge "$3" ]; then
		printf '[!] Порог %s: warn (%s) должен быть меньше crit (%s)\n' "$1" "$2" "$3" >&2
		exit $EXIT_INTERNAL
	fi
}

# ── Блокировка второго экземпляра (только в --loop) ─────────────────────────
# mkdir атомарен; /dev доступен на запись только root — подложить ссылку нельзя.
acquire_lock() {
	local pid
	if ! mkdir "$LOCK_DIR" 2>/dev/null; then
		pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
			printf '[!] Мониторинг уже запущен (PID %s). Если это не так: rm -r %s\n' "$pid" "$LOCK_DIR" >&2
			return $EXIT_INTERNAL
		fi
		rm -rf "$LOCK_DIR"
		mkdir "$LOCK_DIR" 2>/dev/null || { printf '[!] Не удалось создать %s\n' "$LOCK_DIR" >&2; return $EXIT_INTERNAL; }
	fi
	echo $$ > "$LOCK_DIR/pid"
	LOCK_HELD=1
}
LOCK_HELD=0
release_lock() { [ "$LOCK_HELD" -eq 1 ] && rm -rf "$LOCK_DIR"; LOCK_HELD=0; }

# ── Разбор аргументов ───────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help) show_help; exit 0 ;;
		-q|--quiet) QUIET=1 ;;
		-n|--no-logcat) NO_LOGCAT=1 ;;
		-l|--loop) require_option_value "$@"; shift; LOOP_INTERVAL="$1" ;;
		-d|--dry-run)
			DRY_RUN=1
			# [3.3] необязательный список секций: -d cpu,thermal  (всё, что не начинается с «-»)
			if [ $# -gt 1 ] && [ -n "$2" ] && [ "${2#-}" = "$2" ]; then shift; DRY_SECTIONS="$1"; fi ;;
		--dry-run=*) DRY_RUN=1; DRY_SECTIONS="${1#*=}" ;;
		-b|--brief) BRIEF_MODE=1 ;;
		-e|--extended) EXTENDED=1 ;;
		-f|--no-file) NO_FILE_LOG=1 ;;
		-s|--net-speed) ENABLE_NET_TEST=1 ;;
		-c|--clear-log)
			if [ -f "$LOG" ]; then
				: > "$LOG"
				[ "$QUIET" -eq 0 ] && echo "Лог очищен: $LOG"
			else
				[ "$QUIET" -eq 0 ] && echo "Лог-файл не найден, очищать нечего"
			fi
			exit 0 ;;
		--disk-warn) require_option_value "$@"; shift; DISK_WARN="$1" ;;
		--disk-crit) require_option_value "$@"; shift; DISK_CRIT="$1" ;;
		--ram-warn)  require_option_value "$@"; shift; RAM_WARN="$1" ;;
		--ram-crit)  require_option_value "$@"; shift; RAM_CRIT="$1" ;;
		--gpu-warn)  require_option_value "$@"; shift; GPU_WARN="$1" ;;
		--gpu-crit)  require_option_value "$@"; shift; GPU_CRIT="$1" ;;
		*) printf '[!] Неизвестная опция: %s (см. --help)\n' "$1" >&2; exit $EXIT_INTERNAL ;;
	esac
	shift
done

if ! [[ "$LOOP_INTERVAL" =~ ^[0-9]+$ ]]; then
	printf '[!] --loop: нужно целое число секунд, получено: %s\n' "$LOOP_INTERVAL" >&2
	exit $EXIT_INTERNAL
fi
validate_percent_pair "disk" "$DISK_WARN" "$DISK_CRIT"
validate_percent_pair "ram" "$RAM_WARN" "$RAM_CRIT"
validate_percent_pair "gpu" "$GPU_WARN" "$GPU_CRIT"

clear_screen() { [ "$QUIET" -eq 0 ] && [ -t 1 ] && clear; }

if [ "$LOOP_INTERVAL" -gt 0 ]; then
	acquire_lock || exit $?
	trap 'release_lock' EXIT
	trap 'printf "\n"; release_lock; exit 0' INT TERM
	while true; do
		start=$(date +%s)
		clear_screen
		run_monitor
		rc=$?
		[ "$rc" -eq "$EXIT_INTERNAL" ] && exit "$rc"
		elapsed=$(( $(date +%s) - start ))
		if [ "$elapsed" -lt "$LOOP_INTERVAL" ]; then
			[ "$QUIET" -eq 0 ] && printf '\n%sСледующий проход через %s с… Ctrl+C — выход%s\n' "$DIM" "$((LOOP_INTERVAL - elapsed))" "$NC"
			sleep $((LOOP_INTERVAL - elapsed))
		else
			[ "$QUIET" -eq 0 ] && printf '\n%s[!] Проход занял %s с — дольше интервала %s с%s\n' "$YELLOW" "$elapsed" "$LOOP_INTERVAL" "$NC" >&2
			sleep 2
		fi
	done
else
	clear_screen
	run_monitor
	exit $?
fi

# ─────────────────────────────────────────────────────────────────────────────
# Изменения v3 относительно v2 (кратко; подробно — в обсуждении этапа 2):
#  Данные: износ UFS (health_descriptor — папка, версия из specification_version),
#  Zygisk через magisk --sqlite + zygote64, TPU/Titan M2 по реальным путям,
#  честный Verified Boot (ядро против свойств, ловит подмену), Thermal Status
#  из Thermal HAL, датчики CPU из зон ядра (Qualcomm без HAL), троттлинг по
#  охлаждающим устройствам, частоты по кластерам, DNS/Wi-Fi из dumpsys
#  connectivity, SIM по gsm.sim.state, system-as-root и /mnt/vendor/persist,
#  модель Mali из gpuinfo, тип ядра по версии, энтропия ≥5.18, аптайм из /proc.
#  Скорость: getprop и dumpsys thermalservice — по одному вызову за проход
#  (кэши v2 жили в подоболочках и не работали), ping — одна серия на хост.
#  Безопасность: lock в /dev (mkdir, без подмены ссылок), без /tmp-файлов,
#  лог без интерпретации \-последовательностей, logcat '*:E' в кавычках,
#  серийник из cmdline маскируется.
#  Удалено: «Play Integrity» (локально не определяется), bootstrap.sh-опечатка.


#
# Изменения v3.1 (косметика, отдельные блоки):
#  Отступ перед двоеточием во всех строках, «Статус AVB»; кластеры CPU с типом
#  ядер из /proc/cpuinfo и общим регулятором; русские подписи температур;
#  LTPO по драйверу панели Pixel (panel_idle / min_vrefresh), запасной путь —
#  dumpsys display; VPN поверх Wi-Fi определяется по транспортам VPN-сети,
#  а не по первой сети в списке; топ процессов «PID : имя · CPU · ОЗУ МБ»;
#  «Защитный чип»; модули — заголовок по типу root, статусы, описания;
#  ядро — сборщик, компилятор/линкер, флаги и дата сборки, страница, модули.
#
# Изменения v3.2: «Ср. нагрузка» (load average за 1/5/15 мин) отдельной строкой,
#  подсказка iperf3 — серой строкой в секции «СЕТЬ», топ процессов в общей
#  колонке с подписью «PID N», «Чип защиты», «Время работы» вместо «Аптайм».
#
# Изменения v3.3: «Перегрев» вместо «Термостатус» (значения: нет / лёгкий / …);
#  пробный запуск -d [секции]: секции находятся сами по вызову section в коде,
#  выбор через запятую или all, код выхода — итог выбранных секций.
#
# Изменения v3.4: секция «ПАМЯТЬ» — тип памяти, доступно и кэш, zram со сжатием
#  и алгоритмом, подкачка и сброс на диск (writeback), давление PSI, выгрузки
#  lmkd, настройки vm в -e; статус — худшее из «занято %» и давления.
#  Список секций в -d: порядок как в обычном проходе, заголовки с переменными
#  раскрываются («МОДУЛИ MAGISK»), секция модулей теперь называется modules.
#  ZRAM суммируется по всем активным устройствам (zram0 + добавленный zram1).
#
# Изменения v3.5: «Мониторинг» в заголовке и справке; «Настройки VM»; малые и
#  большие ядра Qualcomm с собственными кодами (0x51) показываются настоящими
#  ядрами ARM (у SM8250 — A55); «Энтропия» — фиксированные 256 распознаются по
#  poolsize, а не по версии ядра (новый RNG перенесён и в 4.19, и в 5.4).
