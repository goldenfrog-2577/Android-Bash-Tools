#!/system/bin/sh
# shellcheck shell=bash
#
# monitor.sh v3.14 — мониторинг состояния rooted Android
# Автор: GoldenFrog
# Проверено на: Pixel 8 Pro (husky, Tensor G3) и POCO F3 (alioth, SM8250)
#
# Запуск:  su -c sh /sdcard/monitor.sh [опции]     (bash найдётся сам)
# Справка: sh monitor.sh --help
#
# Коды выхода: 0 — ОК, 1 — есть предупреждения, 2 — критично, 3 — ошибка скрипта.
# Флаги и коды выхода совместимы с v2 — cron/задачи переделывать не нужно.

# ── [3.6] Уходим из рабочей папки ─────────────────────────────────────────
# Если запустить скрипт через su из папки, которую root не видит (каталог
# приложения в другом пространстве монтирования), bash на КАЖДОЙ подстановке
# $(...) пишет «job-working-directory: error retrieving current directory:
# getcwd: …». Скрипту текущая папка не нужна — все пути абсолютные, поэтому
# переходим в «/». Сначала превращаем $0 в абсолютный путь для перезапуска в bash.
case "$0" in
	/*) _self="$0" ;;
	*)  _self="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)/${0##*/}" ;;
esac
[ -f "$_self" ] && cd / 2>/dev/null
[ -f "$_self" ] || _self="$0"

# ── bash обязателен: если запустили через sh — перезапускаемся в bash ──────────
if [ -z "${BASH_VERSION:-}" ]; then
	for _b in "$(command -v bash 2>/dev/null)" \
		/data/user/0/bin.mt.plus/files/term/bin/bash \
		/data/data/bin.mt.plus/files/term/bin/bash \
		/data/data/com.termux/files/usr/bin/bash \
		/system/xbin/bash /system/bin/bash /usr/bin/bash /bin/bash; do
		[ -n "$_b" ] && [ -x "$_b" ] && exec "$_b" "$_self" "$@"
	done
	echo "[!] Нужен bash (MT Manager / Termux)." >&2
	exit 3
fi

shopt -s extglob nullglob
# Байтовая локаль: ширину кириллических подписей считаем сами (см. kv),
# а printf/awk не путаются в многобайтовых символах на bionic.
export LC_ALL=C

readonly VERSION="3.14"

# ═════════════════════════════════════════════════════════════════════════════
#  НАСТРОЙКИ
# ═════════════════════════════════════════════════════════════════════════════

LOG="/data/media/0/.GoldenFrog/logs/android_monitor.log"
ERR_LOG="/data/media/0/.GoldenFrog/logs/last_errors.log"
LOCK_DIR="/dev/.goldenfrog_monitor.lock"   # /dev — tmpfs, писать туда может только root

# Тестовый хук: корень с поддельными /sys, /proc, /dev (как в cpu.sh).
# [3.7] Подменяет только ФАЙЛЫ. Команды (getprop, dumpsys, df, ip, uname, ps…)
# идут из PATH — для теста их подменяют своими скриптами-заглушками в начале PATH:
#   PATH=/путь/к/заглушкам:$PATH MONITOR_SYSROOT=/путь/к/корню bash monitor.sh -d cpu
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

# [3.9] Ширина экрана для переноса длинных строк. Только в терминале: в файл и
# в конвейер строки идут целиком. MONITOR_COLS=N задаёт ширину вручную
# (0 — не переносить). Termux на телефоне: 53–60 символов в портрете.
TERM_COLS=0
if [ -n "${MONITOR_COLS:-}" ]; then
	[[ "$MONITOR_COLS" =~ ^[0-9]+$ ]] && TERM_COLS=$MONITOR_COLS
elif [ -t 1 ]; then
	read -r _ TERM_COLS < <(stty size < /dev/tty 2>/dev/null)
	[[ "${TERM_COLS:-}" =~ ^[0-9]+$ ]] || TERM_COLS="${COLUMNS:-0}"
	[[ "$TERM_COLS" =~ ^[0-9]+$ ]] || TERM_COLS=0
fi
[ "$TERM_COLS" -gt 0 ] && [ "$TERM_COLS" -lt 40 ] && TERM_COLS=40   # уже 40 — не ломаем вёрстку

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
	# [3.9] Длинное значение переносится под колонку значений
	if [ "$TERM_COLS" -gt 0 ] && [ "$BRIEF_MODE" -eq 0 ]; then   # в --brief строки идут по одной
		strip_ansi "$2"; char_len "$REPLY"
		if [ $((KV_WIDTH + 5 + REPLY)) -gt "$TERM_COLS" ]; then
			wrap_text "$2" $((TERM_COLS - KV_WIDTH - 5))
			local first=1 ln ind
			printf -v ind '%*s' $((KV_WIDTH + 5)) ""
			while IFS= read -r ln; do
				if [ "$first" -eq 1 ]; then emit "  $1$sp : $ln"; first=0
				else emit "$ind$ln"; fi
			done <<< "$REPLY"
			return
		fi
	fi
	emit "  $1$sp : $2"
}

# [3.9] wrap_text "текст" ширина → REPLY: строки через \n. Сначала режем по « · »
# (разделитель остаётся в конце строки), длинный кусок — по пробелам.
# Ширина считается без ANSI-кодов; цвет, начатый на одной строке, терминал
# продолжает на следующей, так что раскраска не ломается.
wrap_text() {
	local text="$1" w="$2" out="" line="" llen=0 seg word wlen sep=" · "
	local -a segs words
	[ "$w" -lt 10 ] && w=10
	# Разбиваем на сегменты по « · »
	local rest="$text"
	segs=()
	while [[ "$rest" == *"$sep"* ]]; do segs+=("${rest%%"$sep"*}"); rest="${rest#*"$sep"}"; done
	segs+=("$rest")
	local i n=${#segs[@]}
	for ((i = 0; i < n; i++)); do
		seg="${segs[$i]}"
		[ "$i" -lt $((n - 1)) ] && seg="$seg ·"
		strip_ansi "$seg"; char_len "$REPLY"; wlen=$REPLY
		if [ "$llen" -gt 0 ] && [ $((llen + 1 + wlen)) -le "$w" ]; then
			line="$line $seg"; llen=$((llen + 1 + wlen)); continue
		fi
		if [ "$wlen" -le "$w" ]; then
			[ "$llen" -gt 0 ] && out="$out$line"$'\n'
			line="$seg"; llen=$wlen; continue
		fi
		# Сегмент длиннее строки — по словам
		read -ra words <<< "$seg"
		for word in "${words[@]}"; do
			strip_ansi "$word"; char_len "$REPLY"; wlen=$REPLY
			# [3.13.1] Слово длиннее строки (версия ядра, имя сборки) — режем после
			# «- = / . , _» (знак остаётся в конце строки); если их нет — по символам.
			# Раньше такое слово уходило целиком, и его переносил уже терминал —
			# с начала строки, мимо колонки значений.
			if [ "$wlen" -gt "$w" ] && [[ "$word" != *$'\e'* ]]; then
				[ "$llen" -gt 0 ] && out="$out$line"$'\n'
				line=""; llen=0
				local part rest2="$word" plen
				while [ -n "$rest2" ]; do
					if [[ "$rest2" =~ ^([^-=/.,_]*[-=/.,_])(.+)$ ]]; then part="${BASH_REMATCH[1]}"; rest2="${BASH_REMATCH[2]}"
					else part="$rest2"; rest2=""; fi
					char_len "$part"; plen=$REPLY
					while [ "$plen" -gt "$w" ]; do      # кусок без дефисов длиннее строки
						[ "$llen" -gt 0 ] && { out="$out$line"$'\n'; line=""; llen=0; }
						out="$out${part:0:$w}"$'\n'; part="${part:$w}"; char_len "$part"; plen=$REPLY
					done
					if [ $((llen + plen)) -le "$w" ]; then line="$line$part"; llen=$((llen + plen))
					else out="$out$line"$'\n'; line="$part"; llen=$plen; fi
				done
				continue
			fi
			if [ "$llen" -gt 0 ] && [ $((llen + 1 + wlen)) -le "$w" ]; then
				line="$line $word"; llen=$((llen + 1 + wlen))
			else
				[ "$llen" -gt 0 ] && out="$out$line"$'\n'
				line="$word"; llen=$wlen
			fi
		done
	done
	REPLY="$out$line"
}

note() { wrap_emit 2 "${DIM}$*${NC}"; }

# [3.9] wrap_emit отступ "текст" — свободный текст с переносом по ширине экрана
wrap_emit() {
	local ind; printf -v ind '%*s' "$1" ""
	if [ "$TERM_COLS" -gt 0 ] && [ "$BRIEF_MODE" -eq 0 ]; then
		strip_ansi "$2"; char_len "$REPLY"
		if [ $(( $1 + REPLY )) -gt "$TERM_COLS" ]; then
			local ln
			wrap_text "$2" $((TERM_COLS - $1))
			while IFS= read -r ln; do emit "$ind$ln"; done <<< "$REPLY"
			return
		fi
	fi
	emit "$ind$2"
}

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

# [3.6] can_read ФАЙЛ — можно ли прочитать, проверкой настоящим открытием файла.
# «[ -r файл ]» спрашивает ядро через faccessat, и на части ядер с KernelSU
# (Redmi Note 13 Pro 5G, ядро Zen-Itsu) он отвечает «нет» на файлы, которые
# прекрасно читаются. Из-за этого пропадали частоты CPU, износ UFS, ZRAM,
# давление и честный статус AVB. Открытие файла таких сюрпризов не даёт.
can_read() { { : < "$1"; } 2>/dev/null; }

# rd ФАЙЛ → REPLY (первая строка, без пробелов по краям; пусто, если нет файла)
rd() {
	REPLY=""
	can_read "$1" || return 1
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
# [3.8] Массив был назван TZ и затирал одноимённую переменную окружения часового
# пояса: время в шапке и даты выводились по UTC, если пояс задан через TZ.
declare -A TZONE
load_zones() {
	TZONE=()
	local z t v
	for z in "$R"/sys/class/thermal/thermal_zone*; do
		IFS= read -r t 2>/dev/null < "$z/type" || continue
		IFS= read -r v 2>/dev/null < "$z/temp" || continue
		is_int "$v" || continue
		[ "$v" -gt -30000 ] && [ "$v" -lt 150000 ] || continue
		if [ -z "${TZONE[$t]:-}" ] || [ "$v" -gt "${TZONE[$t]}" ]; then TZONE[$t]="$v"; fi
	done
}

# Thermal HAL: dumpsys thermalservice — один раз за проход
declare -A HAL HAL_TYPE HAL_STAT
HAL_STATUS=""; HAL_READY=""
load_thermal_hal() {
	HAL=(); HAL_TYPE=(); HAL_STAT=(); HAL_STATUS=""; HAL_READY=""
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
			# [3.9] Статус датчика 0–6: выше 0 — датчик перешёл свой порог
			[[ "$line" =~ mStatus=([0-9]+) ]] && HAL_STAT[$name]="${BASH_REMATCH[1]}"
		fi
	done < <(dumpsys thermalservice 2>/dev/null)
}

# м°C → «47.2»
mdeg() { REPLY="$(( $1 / 1000 )).$(( ( ${1#-} % 1000 ) / 100 ))"; }
# дробные °C из HAL → «47.2»
fdeg() { printf -v REPLY '%.1f' "$1" 2>/dev/null || REPLY="$1"; }

# [3.8] Длительность в секундах → REPLY: «~35 мин», «~1 ч 25 мин». Без склонений —
# сокращения читаются одинаково при любом числе.
fmt_dur() {
	local s="$1" m h
	m=$(( (s + 59) / 60 ))
	if [ "$m" -lt 60 ]; then REPLY="~$m мин"
	else h=$((m / 60)); m=$((m % 60)); REPLY="~$h ч${m:+ $m мин}"; [ "$m" -eq 0 ] && REPLY="~$h ч"; fi
}

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
		can_read "$src" || continue
		local data; data=$(tr ' ' '\n' < "$src" 2>/dev/null)
		[ -z "$VB_REAL" ] && VB_REAL=$(printf '%s\n' "$data" | sed -n 's/^androidboot\.verifiedbootstate=\{0,1\}"\{0,1\}\([a-z]*\).*/\1/p' | head -n 1)
		[ -z "$VB_DEVSTATE" ] && VB_DEVSTATE=$(printf '%s\n' "$data" | sed -n 's/^androidboot\.vbmeta\.device_state=\{0,1\}"\{0,1\}\([a-z]*\).*/\1/p' | head -n 1)
	done
	# bootconfig пишет «key = "value"» — после tr ключ и значение в разных строках
	if can_read "$R/proc/bootconfig"; then
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
			# [3.7.2] bd_stat считает в страницах ядра: 4 КБ обычно, но 16 КБ на ядрах
			# с большой страницей (Pixel 8+ в режиме 16K) — берём реальный размер.
			local pg_kb=4 pg; pg=$(getconf PAGESIZE 2>/dev/null)
			is_int "${pg:-x}" && [ "$pg" -ge 4096 ] && pg_kb=$((pg / 1024))
			[ "$bdw" -gt 0 ] && wb="$wb ${DIM}(там $(hsize_kb $((bdw * pg_kb))))${NC}"
		fi
		kv "Подкачка" "занято $(hsize_kb $((swt - swf))) из $(hsize_kb "$swt")$wb"
	fi

	# Давление (PSI): строки «some avg10=… avg60=…» и «full …»
	local psi_some="" psi_full="" plvl=0
	if can_read "$R/proc/pressure/memory"; then
		psi_some=$(awk '$1 == "some" { for (i = 2; i <= NF; i++) if ($i ~ /^avg60=/) { sub(/avg60=/, "", $i); print $i } }' "$R/proc/pressure/memory")
		psi_full=$(awk '$1 == "full" { for (i = 2; i <= NF; i++) if ($i ~ /^avg60=/) { sub(/avg60=/, "", $i); print $i } }' "$R/proc/pressure/memory")
	fi
	# [3.7] Считаем, даже если есть только одна из строк (some или full)
	if [ -n "$psi_some" ] || [ -n "$psi_full" ]; then
		plvl=$(awk -v s="${psi_some:-0}" -v f="${psi_full:-0}" -v w="$PSI_MEM_WARN" -v c="$PSI_MEM_CRIT" \
			'BEGIN { print (f >= c) ? 2 : (s >= w) ? 1 : 0 }')
		local cs="" cf=""
		[ "$plvl" -ge 1 ] && cs="$YELLOW"
		[ "$plvl" -ge 2 ] && cf="$RED"
		kv "Давление" "${cs}${psi_some:-?}%${cs:+$NC} · полное ${cf}${psi_full:-?}%${cf:+$NC} ${DIM}(за минуту)${NC}"
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
	done 2>/dev/null < "$R/proc/cpuinfo"   # [3.7] 2> раньше <, иначе ошибка открытия видна
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
	# [3.7] /proc/stat не прочитался — загрузка «н/д», а не 0%
	local t1="" i1="" t2="" i2="" load=""
	if can_read "$R/proc/stat"; then
		cpu_snapshot; read -r t1 i1 <<< "$REPLY"
		[ -z "$R" ] && sleep 0.5
		cpu_snapshot; read -r t2 i2 <<< "$REPLY"
		if is_int "${t1:-x}" && is_int "${t2:-x}" && [ $((t2 - t1)) -gt 0 ]; then
			load=$(( ( (t2 - t1) - (i2 - i1) ) * 100 / (t2 - t1) ))
		fi
	fi

	local soc board cores la1 la5 la15
	prop ro.soc.model; soc="$REPLY"
	[ -z "$soc" ] && { prop ro.board.platform; soc="$REPLY"; }
	prop ro.product.board; board="$REPLY"
	cores=$(grep -c '^processor' "$R/proc/cpuinfo" 2>/dev/null)
	read -r la1 la5 la15 _ 2>/dev/null < "$R/proc/loadavg"

	local lvl=0
	kv "Модель" "${soc:-?}${board:+ · плата $board}"
	if [ -n "$load" ]; then
		level_by "$load" "$CPU_WARN" "$CPU_CRIT"; lvl=$REPLY
		color_by_level "$lvl"
		kv "Загрузка" "${REPLY}${load}%${NC} · ядер онлайн: ${cores:-?}"
	else
		kv "Загрузка" "н/д · ядер онлайн: ${cores:-?}"
	fi
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
		2) verdict 2 "перегрузка" ;; 1) verdict 1 "высокая нагрузка" ;;
		*) if [ -z "$load" ] && [ -z "${la1:-}" ]; then verdict 1 "данные о загрузке недоступны"
		   else verdict 0 "нагрузка в норме"; fi ;;
	esac
}

# ── Температуры и троттлинг ─────────────────────────────────────────────────

# Самая горячая зона по шаблону имени: zone_max 'gpuss-*-usr' → REPLY (м°C)
zone_max() {
	local k best=""
	for k in "${!TZONE[@]}"; do
		# shellcheck disable=SC2053
		[[ "$k" == $1 ]] || continue
		if [ -z "$best" ] || [ "${TZONE[$k]}" -gt "$best" ]; then best="${TZONE[$k]}"; fi
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
		if [ -n "${TZONE[$name]:-}" ]; then
			mdeg "${TZONE[$name]}"; t="$REPLY"
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
	if [ -n "${TZONE[G3D]:-}" ]; then mdeg "${TZONE[G3D]}"; color_temp "$REPLY"; kv "Графика" "$REPLY"
	elif zone_max 'gpuss-*-usr' || zone_max 'gpu*'; then mdeg "$REPLY"; color_temp "$REPLY"; kv "Графика" "$REPLY"
	elif rd "$R/sys/class/kgsl/kgsl-3d0/temp" && is_int "$REPLY"; then mdeg "$REPLY"; color_temp "$REPLY"; kv "Графика" "$REPLY"
	fi
	[ -n "${TZONE[TPU]:-}" ] && { mdeg "${TZONE[TPU]}"; color_temp "$REPLY"; kv "Нейроблок TPU" "$REPLY"; }

	local skin=""
	for name in "${!HAL_TYPE[@]}"; do
		[ "${HAL_TYPE[$name]}" = "3" ] && { fdeg "${HAL[$name]}"; skin="$REPLY ${DIM}($name)${NC}"; break; }
	done
	if [ -z "$skin" ]; then
		for name in skin_therm xo_therm quiet_therm; do
			[ -n "${TZONE[$name]:-}" ] && { mdeg "${TZONE[$name]}"; skin="$REPLY°C ${DIM}($name)${NC}"; break; }
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
			chg_mdis|dc_icl) continue ;;   # [3.8] зарядка — в «Батарее», строка «Контроллер»
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
		elif can_read "$k/gpubusy"; then
			load=$(awk '{ if ($2 > 0) printf "%d", $1 * 100 / $2; else print 0 }' "$k/gpubusy")
		fi
		rd "$k/devfreq/governor" && gov="$REPLY"
	else
		local c
		for c in "$R/sys/devices/platform/1f000000.mali" "$R"/sys/devices/platform/*.mali \
			"$R/sys/class/misc/mali0/device"; do
			can_read "$c/cur_freq" || can_read "$c/gpuinfo" && { mali="$c"; break; }
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
	local res period hz="" wsz
	wsz=$(wm size 2>/dev/null)
	res=$(printf '%s\n' "$wsz" | awk -F': ' '/Override/ {o=$2} /Physical/ {p=$2} END {print (o ? o " (физ. " p ")" : p)}')
	period=$(dumpsys SurfaceFlinger --latency 2>/dev/null | head -n 1)
	is_int "${period:-x}" && [ "$period" -gt 0 ] && hz=$(( (1000000000 + period / 2) / period ))
	detect_ltpo
	kv "Экран" "${res:-?}${hz:+ · $hz Гц}${REPLY:+ · $REPLY}"
	[ -n "$PANEL_MODEL" ] && kv "Панель" "$PANEL_MODEL"

	# [3.12] Плотность и минимальная ширина (smallest width, dp) — то, по чему
	# приложения выбирают раскладку. sw = короткая сторона × 160 / dpi, с
	# округлением, как в системе (Pixel 8 Pro: 1344 × 160 / 480 = 448 dp).
	# Если плотность или размер изменены (wm density / wm size), берём изменённые.
	local dens a b
	dens=$(wm density 2>/dev/null | awk -F': ' '/Override/ {o=$2} /Physical/ {p=$2} END {print p " " o}')
	read -r a b <<< "$dens"
	if is_int "${a:-x}" && [ "$a" -gt 0 ]; then
		local d="${b:-$a}" sz w h sw=""
		sz=$(printf '%s\n' "$wsz" | awk -F': ' '/Override/ {o=$2} /Physical/ {p=$2} END {print (o ? o : p)}')
		w="${sz%%x*}"; h="${sz##*x}"
		if is_int "${d:-x}" && [ "$d" -gt 0 ] && is_int "${w:-x}" && is_int "${h:-x}"; then
			[ "$h" -lt "$w" ] && w="$h"
			sw=$(( (w * 160 + d / 2) / d ))
		fi
		kv "Плотность" "$d dpi${b:+ ${DIM}(физ. $a)${NC}}${sw:+ · $sw dp}"
	fi

	# [3.14] Аппаратные видеокодеки (порядок — от новых форматов к старым)
	local -a cxf=()
	local f cx dec="" enc="" fm k2 v2
	for f in "$R"/vendor/etc/media_codecs*.xml "$R"/odm/etc/media_codecs*.xml; do can_read "$f" && cxf+=("$f"); done
	if [ "${#cxf[@]}" -gt 0 ]; then
		cx=$(LC_ALL=C awk "$CODEC_AWK" "${cxf[@]}" 2>/dev/null | sort -u)
		for fm in AV1 HEVC VP9 "Dolby Vision" APV H.264 VP8 MPEG-4 MPEG-2 H.263; do
			while IFS=$'\t' read -r k2 v2; do
				[ "$v2" = "$fm" ] || continue
				[ "$k2" = "D" ] && dec="${dec:+$dec · }$fm"
				[ "$k2" = "E" ] && enc="${enc:+$enc · }$fm"
			done <<< "$cx"
		done
		# «Видеокодер» (запись, только с -e) выше «Видеодекодера» (просмотр).
		# Если декодер умеет ровно те же форматы — список не повторяем.
		local same=0
		if [ "$EXTENDED" -eq 1 ] && [ -n "$enc" ]; then
			kv "Видеокодер" "$enc"
			[ "$enc" = "$dec" ] && same=1
		fi
		if [ -n "$dec" ]; then
			if [ "$same" -eq 1 ]; then kv "Видеодекодер" "те же форматы"
			else
				[[ " $dec " == *" AV1 "* ]] || dec="$dec ${DIM}(AV1 — только программно)${NC}"
				kv "Видеодекодер" "$dec"
			fi
		fi
	fi
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

# [3.7] Батарея: нет данных — «н/д», а не 0 °C / 0% (раньше пустое чтение
# выглядело как реальный ноль). Температура с десятыми, ёмкость больше паспортной
# показывается как есть (у новой батареи это норма, паспорт — гарантированный
# минимум). Добавлены технология, даты производства и первого применения (Pixel),
# модель и подлинность батареи (Qualcomm bms / Maxim), в -e — сопротивление.
check_battery() {
	section "БАТАРЕЯ"
	local b="$R/sys/class/power_supply/battery" bms="$R/sys/class/power_supply/bms"
	if [ ! -d "$b" ]; then kv "Батарея" "нет данных"; return; fi

	local cap="" status temp="" tdeg="" volt="" cur_ua="" health cycles full design tech
	rd "$b/capacity" && is_int "$REPLY" && cap="$REPLY"
	rd "$b/status"; status="$REPLY"
	if rd "$b/temp" && is_int "$REPLY"; then
		temp=$((REPLY / 10))                     # целые °C — для порога
		tdeg=$(awk -v t="$REPLY" 'BEGIN { printf "%.1f", t / 10 }')
	fi
	rd "$b/voltage_now" && is_int "$REPLY" && [ "$REPLY" -gt 0 ] && volt=$((REPLY / 1000))
	rd "$b/current_now" && is_int "$REPLY" && cur_ua="$REPLY"
	rd "$b/health"; health="$REPLY"
	rd "$b/cycle_count"; cycles="$REPLY"
	rd "$b/charge_full"; full="$REPLY"
	rd "$b/charge_full_design"; design="$REPLY"
	rd "$b/technology"; tech="$REPLY"

	# Знак тока у вендоров разный (Pixel: разряд < 0, Qualcomm: разряд > 0) — приводим к
	# «минус = разряд» по статусу
	if [ -n "$cur_ua" ]; then
		case "$status" in
			Discharging) [ "$cur_ua" -gt 0 ] && cur_ua=$(( -cur_ua )) ;;
			Charging) [ "$cur_ua" -lt 0 ] && cur_ua=$(( -cur_ua )) ;;
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
	[ -n "$cap" ] && [ "$status" = "Discharging" ] && [ "$cap" -lt 20 ] && cap_c="$RED"
	local cap_s="н/д"
	[ -n "$cap" ] && cap_s="${cap_c}${cap}%${cap_c:+$NC}"
	kv "Уровень" "$cap_s · $st_ru"

	# Источник питания
	# [3.8.1] Формат «USB PD, быстрая · 8.3 В · до 20 Вт»: единицы прямо в тексте
	# (раньше «(8 В)» читалось двусмысленно), напряжение с десятыми.
	local src="" ps tp on pmax=""
	for ps in "$R"/sys/class/power_supply/*; do
		rd "$ps/online" && [ "$REPLY" = "1" ] || continue
		rd "$ps/type"; tp="$REPLY"
		case "${ps##*/}:$tp" in
			wireless:*|*:Wireless) src="беспроводная" ;;
			usb:*|*:USB*)
				local uv=0 proto="USB"
				rd "$ps/voltage_now" && is_int "$REPLY" && uv=$((REPLY / 1000))
				case "$tp" in USB_PD*) proto="USB PD" ;; esac   # [3.7] протокол, если драйвер сообщает
				if [ "$uv" -gt 6000 ]; then
					src="$proto, быстрая · $(awk -v v="$uv" 'BEGIN { printf "%.1f", v / 1000 }') В"
				elif [ -z "$src" ]; then src="$proto"; fi
				# Предел мощности от драйвера (Qualcomm power_max)
				rd "$ps/power_max" && is_int "$REPLY" && [ "$REPLY" -gt 0 ] && [ "$REPLY" -lt 500 ] && pmax="$REPLY" ;;
			*:Mains|main:*|ac:*) [ -z "$src" ] && src="сеть" ;;
		esac
	done
	# [3.8.1] Иначе — договорённость телефона с зарядником из BatteryService
	# (Max charging current × voltage, Pixel): это предел, а не текущая мощность.
	if [ -n "$src" ] && [ -z "$pmax" ] && [ "$src" != "беспроводная" ]; then
		pmax=$(dumpsys battery 2>/dev/null | awk -F': ' '
			/Max charging current:/ { i = $2 + 0 } /Max charging voltage:/ { v = $2 + 0 }
			END { if (i > 0 && v > 0) { w = i * v / 1e12; if (w >= 1 && w < 500) printf "%.0f", w } }')
	fi
	[ -n "$pmax" ] && src="$src · до $pmax Вт"
	# Battery Share (обратная беспроводная) — Pixel
	local rn
	for rn in "$R/sys/class/power_supply/wireless/reverse_chg_mode" "$R/sys/class/power_supply/wireless/wireless_out"; do
		rd "$rn" && [ "$REPLY" = "1" ] && { src="${MAGENTA}раздаёт заряд (Battery Share)${NC}"; break; }
	done
	[ -n "$src" ] && kv "Питание" "$src"

	# [3.8] Режимы зарядки и время до заряда. Переключатели живут в Settings
	# Intelligence / SystemUI, но применяются через Health HAL — читаем результат
	# в ядре, стандартные узлы healthd (AOSP, Android 14+):
	#   charging_policy: 1 обычная · 2 LONG_LIFE («Максимум 80%») · 3 ADAPTIVE
	#   charging_state:  1 обычная · 2 холодно · 3 жарко · 4 LONG_LIFE · 5 ADAPTIVE
	# Где узлов нет (F3: HAL отвечает INVALID), режимы не выдумываем.
	local pol="" cst="" modes="" eta="" bd
	rd "$b/charging_policy" && is_int "$REPLY" && pol="$REPLY"
	rd "$b/charging_state" && is_int "$REPLY" && cst="$REPLY"
	case "$pol" in 2) modes="максимум 80%" ;; 3) modes="адаптивная зарядка" ;; esac
	case "$cst" in
		2) modes="${modes:+$modes · }${YELLOW}ограничена: холодно${NC}" ;;
		3) modes="${modes:+$modes · }${YELLOW}ограничена: жарко${NC}" ;;
	esac
	# Battery Defender (Pixel): сам ограничивает заряд, если телефон долго на
	# зарядке в тепле. DISCONNECTED/CONNECTED — штатные состояния «не активен».
	prop vendor.battery.defender.state; bd="$REPLY"
	case "$bd" in ""|DISCONNECTED|CONNECTED) ;; *) modes="${modes:+$modes · }${YELLOW}защита батареи${NC} ${DIM}($bd)${NC}" ;; esac
	[ "$(settings get global low_power 2>/dev/null)" = "1" ] && modes="${modes:+$modes · }энергосбережение"

	if [ "$status" = "Charging" ] && [ -n "$cap" ] && [ "$cap" -lt 100 ]; then
		local ttf="" dl="" ua=0 now tgt=100 rate_eta=""
		rd "$b/time_to_full_now" && is_int "$REPLY" && [ "$REPLY" -gt 0 ] && ttf="$REPLY"
		rd "$b/charge_deadline" && is_int "$REPLY" && [ "$REPLY" -gt 0 ] && dl="$REPLY"
		[ -n "$cur_ua" ] && ua=${cur_ua#-}
		[ "$pol" = "2" ] && tgt=80
		# Своя оценка по току: недостающие проценты × ёмкость / ток. Оптимистична —
		# к концу заряда ток падает, поэтому со знаком «≈» и только при токе ≥ 50 мА.
		if [ "$cap" -lt "$tgt" ] && [ "$ua" -ge 50000 ] && is_int "${full:-x}" && [ "$full" -gt 0 ]; then
			fmt_dur $(( full * (tgt - cap) / 100 * 3600 / ua )); rate_eta="≈${REPLY#\~} ${DIM}(по току)${NC}"
		fi
		case "$pol" in
			3)  # Адаптивная: драйвер Pixel отдаёт срок в секундах от текущего момента
				[ -z "$dl" ] && dl="$ttf"
				if [ -n "$dl" ]; then
					printf -v now '%(%s)T' -1
					printf -v eta '%(%H:%M)T' $((now + dl)); eta="зарядится к $eta"
				fi ;;
			2)  # Лимит 80%: time_to_full_now драйвера считает до 100%, поэтому своя оценка
				if [ "$cap" -ge 80 ]; then eta="держит 80%"
				elif [ -n "$rate_eta" ]; then eta="до 80% через $rate_eta"; fi ;;
			*)  if [ -n "$ttf" ]; then fmt_dur "$ttf"; eta="полный заряд через $REPLY"
				elif [ -n "$rate_eta" ]; then eta="полный заряд через $rate_eta"; fi ;;
		esac
		[ -z "$modes" ] && modes="обычная зарядка"
	fi
	[ -n "$modes" ] && kv "Режимы" "$modes${eta:+ · $eta}"

	# Здоровье: ёмкость по датчику к паспортной
	local hp="" h_ru
	case "$health" in
		Good) h_ru="хорошее" ;; Overheat) h_ru="${RED}перегрев${NC}" ;; Dead) h_ru="${RED}неисправна${NC}" ;;
		Cold) h_ru="холодная" ;; "Over voltage") h_ru="${RED}перенапряжение${NC}" ;; *) h_ru="${health:-н/д}" ;;
	esac
	if is_int "${full:-x}" && is_int "${design:-x}" && [ "$design" -gt 0 ] && [ "$full" -gt 0 ]; then
		local pct=$(( full * 100 / design ))
		if [ "$pct" -lt 80 ]; then hp="${YELLOW}$pct%${NC} ${DIM}($((full / 1000)) из $((design / 1000)) мА·ч)${NC}"
		else hp="$pct% ${DIM}($((full / 1000)) из $((design / 1000)) мА·ч)${NC}"; fi
	fi
	kv "Здоровье" "$h_ru${hp:+ · ёмкость $hp}"
	is_int "${cycles:-x}" && kv "Циклы" "$cycles"

	# [3.7] Паспорт батареи: технология, модель, подлинность, даты (что есть)
	local info="" btype="" auth="" mdate="" fdate=""
	if rd "$bms/battery_type" && [ -n "$REPLY" ] && [ "$REPLY" != "Unknown" ]; then btype="$REPLY"; fi
	if rd "$bms/authentic" && is_int "$REPLY"; then auth="$REPLY"
	elif rd "$R/sys/class/power_supply/batt_verify/authen_result" && is_int "$REPLY"; then auth="$REPLY"; fi
	if rd "$b/manufacturing_date" && is_int "$REPLY" && [ "$REPLY" -gt 946684800 ]; then
		printf -v mdate '%(%d.%m.%Y)T' "$REPLY"
	fi
	if rd "$b/first_usage_date" && is_int "$REPLY" && [ "$REPLY" -gt 946684800 ]; then
		printf -v fdate '%(%d.%m.%Y)T' "$REPLY"
	fi
	[ -n "$tech" ] && info="$tech"
	[ -n "$btype" ] && info="${info:+$info · }$btype"
	case "$auth" in
		1) info="${info:+$info · }${GREEN}подлинная${NC}" ;;
		0) info="${info:+$info · }${YELLOW}не прошла проверку подлинности${NC}" ;;
	esac
	[ -n "$mdate" ] && info="${info:+$info · }произведена $mdate"
	[ -n "$fdate" ] && info="${info:+$info · }в работе с $fdate"
	[ -n "$info" ] && kv "Батарея" "$info"

	if [ -n "$tdeg" ]; then
		local tc=""
		[ "$temp" -ge "$BATT_TEMP_WARN" ] && tc="$RED"
		kv "Температура" "${tc}${tdeg}°C${tc:+$NC}"
	else
		kv "Температура" "н/д"
	fi

	# [3.8] Контроллер заряда: температура и ограничение зарядки из-за нагрева.
	# Pixel: зоны charge_therm / usb_pwr_therm, охлаждение chg_mdis, dc_icl;
	# Qualcomm: зона charger_therm0 (или battery/charger_temp), охлаждение battery.
	local ct="" usbt="" lim="" cd ctype ccur cmax
	if zone_max 'charge_therm' || zone_max 'charger_therm*'; then mdeg "$REPLY"; color_temp "$REPLY"; ct="$REPLY"
	elif rd "$b/charger_temp" && is_int "$REPLY" && [ "$REPLY" -gt 0 ]; then
		fdeg "$(awk -v t="$REPLY" 'BEGIN { print t / 10 }')"; color_temp "$REPLY"; ct="$REPLY"
	fi
	zone_max 'usb_pwr_therm' && { mdeg "$REPLY"; color_temp "$REPLY"; usbt="$REPLY"; }
	for cd in "$R"/sys/class/thermal/cooling_device*; do
		IFS= read -r ctype 2>/dev/null < "$cd/type" || continue
		case "$ctype" in chg_mdis|dc_icl|battery) ;; *) continue ;; esac
		IFS= read -r ccur 2>/dev/null < "$cd/cur_state" || continue
		is_int "$ccur" && [ "$ccur" -gt 0 ] || continue
		IFS= read -r cmax 2>/dev/null < "$cd/max_state"
		lim="${YELLOW}зарядка ограничена${NC} ${DIM}($ccur из ${cmax:-?})${NC}"; break
	done
	if [ -n "$ct" ] || [ -n "$usbt" ]; then
		local cl="${ct:-н/д}"
		[ -n "$usbt" ] && cl="$cl · USB-порт $usbt"
		kv "Контроллер" "$cl${lim:+ · $lim}"
	fi
	if [ -n "$cur_ua" ] && [ -n "$volt" ]; then
		local ma=$((cur_ua / 1000)) w dir=""
		w=$(awk -v v="$volt" -v i="$ma" 'BEGIN { printf "%.2f", v * i / 1000000 }')
		# [3.11.1] Знак приводится только при «заряжается»/«разряжается». При «заряжена»,
		# «не заряжается» и неизвестном статусе направление по драйверу не определить
		# (у Qualcomm и Pixel знак противоположный) — показываем модуль без знака.
		case "$status" in
			Charging|Discharging) ;;
			*) ma=${ma#-}; dir=" ${DIM}(направление не определено)${NC}" ;;
		esac
		kv "Ток" "$ma мА$dir · ${w#-} Вт · $volt мВ"
	elif [ -n "$volt" ]; then
		kv "Напряжение" "$volt мВ"
	fi
	[ -n "$cur_ua" ] && note "Ток: минус — разряд, плюс — заряд."

	# [3.7] Внутреннее сопротивление (-e): растёт с износом. Драйверы отдают его в мкОм
	# без документации единиц, поэтому только в расширенном режиме и с пометкой.
	if [ "$EXTENDED" -eq 1 ]; then
		local res=""
		for rn in "$b/resistance" "$bms/resistance"; do
			rd "$rn" && is_int "$REPLY" && [ "$REPLY" -gt 0 ] && { res="$REPLY"; break; }
		done
		[ -n "$res" ] && kv "Сопротивление" "$(( (res + 500) / 1000 )) мОм ${DIM}(внутреннее, по датчику)${NC}"
	fi

	if [ -n "$temp" ] && [ "$temp" -ge "$BATT_TEMP_WARN" ]; then
		verdict 1 "батарея перегрета: ${tdeg}°C"
	elif [ -z "$cap" ] && [ -z "$temp" ]; then
		verdict 1 "данные батареи недоступны"
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
			dns = $0; if (sub(/.*DnsAddresses: \[ */, "", dns)) { sub(/ *\].*/, "", dns); gsub(/\//, "", dns); gsub(/ *, */, ", ", dns) } else dns = ""
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

# [3.14] Аппаратные видеокодеки: списки вендора /vendor/etc и /odm/etc
# media_codecs*.xml. Программные кодеки Google (c2.android.*, OMX.google.*) и
# помеченные software-codec не считаем: они есть на любом телефоне.
# c2.google.* в /vendor — это аппаратный блок Tensor (BigOcean), а не программа.
CODEC_AWK='
# media_codecs*.xml → «D|E<TAB>формат» для аппаратных видеокодеков
function attr(s, a,   r) { r = ""; if (match(s, a "=\"[^\"]*\"")) { r = substr(s, RSTART + length(a) + 2, RLENGTH - length(a) - 3) } return r }
function flush() {
	if (nm != "" && !sw && nm !~ /^(c2\.android\.|OMX\.google\.|c2\.vda\.)/) for (t in ty) if (t in F) print sec "\t" F[t]
	nm = ""; sw = 0; delete ty
}
BEGIN {
	F["video/av01"] = "AV1"; F["video/hevc"] = "HEVC"; F["video/x-vnd.on2.vp9"] = "VP9"; F["video/dolby-vision"] = "Dolby Vision"
	F["video/avc"] = "H.264"; F["video/x-vnd.on2.vp8"] = "VP8"; F["video/mp4v-es"] = "MPEG-4"; F["video/mpeg2"] = "MPEG-2"
	F["video/3gpp"] = "H.263"; F["video/apv"] = "APV"
}
/<Decoders/ { sec = "D" } /<Encoders/ { sec = "E" }
/<\/Decoders>|<\/Encoders>/ { flush(); sec = "" }
sec != "" && /<MediaCodec[ >]/ {
	flush(); nm = attr($0, "name"); t = attr($0, "type"); if (t != "") ty[t] = 1
	if ($0 ~ /\/>[ \t]*$/) flush()
	next
}
sec != "" && nm != "" && /<Type / { t = attr($0, "name"); if (t != "") ty[t] = 1 }
sec != "" && nm != "" && /name="software-codec"/ { sw = 1 }
sec != "" && /<\/MediaCodec>/ { flush() }
'

# [3.14] Сотовая: диапазон и агрегация частот из dumpsys telephony.registry.
# По каждому Phone Id: mServiceState (регистрация, полосы всех несущих
# mCellBandwidths, технология), mCellIdentity (mBands, mBandwidth обслуживающей
# соты) и TelephonyDisplayInfo (overrideNetwork=NR_NSA — 5G поверх LTE).
# Номера дополнительных несущих система не отдаёт — только их число и полосу.
# Идентификаторы сот (Cell ID, TAC, PCI) не выводятся.
BAND_AWK='
function val(s, k,   r) {
	r = ""
	if (match(s, k "=\\[[^]]*\\]")) r = substr(s, RSTART + length(k) + 1, RLENGTH - length(k) - 1)
	else if (match(s, k "=[^ ,}]*")) r = substr(s, RSTART + length(k) + 1, RLENGTH - length(k) - 1)
	return r
}
function out() {
	if (ph != "" && reg && typ != "") printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", ph, typ, bands, bw, bws, rat, ovr
	reg = 0; typ = ""; bands = ""; bw = ""; bws = ""; rat = ""; ovr = ""
}
/^  Phone Id=/ { out(); ph = $0; sub(/.*=/, "", ph); seen = 0; next }
/^    mServiceState=/ && !seen {
	seen = 1
	reg = ($0 ~ /mVoiceRegState=0\(/ || $0 ~ /mDataRegState=0\(/)
	bws = val($0, "mCellBandwidths")
	rat = val($0, "getRilDataRadioTechnology"); if (rat ~ /IWLAN|Unknown/) rat = val($0, "getRilVoiceRadioTechnology")
	sub(/^[0-9]+\(/, "", rat); sub(/\)$/, "", rat)
}
/^    mCellIdentity=CellIdentity/ {
	typ = $0; sub(/^    mCellIdentity=CellIdentity/, "", typ); sub(/:.*/, "", typ)
	bands = val($0, "mBands"); bw = val($0, "mBandwidth")
}
/^    mTelephonyDisplayInfo=/ { ovr = val($0, "overrideNetwork") }
END { out() }
'

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
	# [3.14] Диапазон обслуживающей соты; несколько несущих — агрегация (CA)
	local bl ph typ bands bw bws rat ovr nc tot b
	bl=$(dumpsys telephony.registry 2>/dev/null | awk "$BAND_AWK" 2>/dev/null)
	while IFS=$'\t' read -r ph typ bands bw bws rat ovr; do
		[ -n "$typ" ] || continue
		bands="${bands#[}"; bands="${bands%]}"; bws="${bws#[}"; bws="${bws%]}"
		local line="" pre=""
		case "$typ" in
			Lte) pre="B"; line="LTE" ;;
			Nr)  pre="n"; line="5G" ;;
			Wcdma|Tdscdma) line="3G" ;;
			Gsm) line="2G" ;;
			*) line="$typ" ;;
		esac
		[ -n "$bands" ] && [ -n "$pre" ] && line="$line $pre${bands//, /\/$pre}"
		[ "$typ" = "Wcdma" ] && [ -n "$rat" ] && line="$line ($rat)"
		nc=0; tot=0
		for b in ${bws//,/ }; do is_int "$b" && [ "$b" -gt 0 ] && { nc=$((nc + 1)); tot=$((tot + b)); }; done
		if [ "$nc" -ge 2 ]; then
			line="$line · ${GREEN}CA ×$nc${NC} · $((tot / 1000)) МГц"
		elif is_int "${bw:-x}" && [ "$bw" -gt 0 ] && [ "$bw" -lt 2147483647 ]; then
			line="$line · $((bw / 1000)) МГц"
		fi
		case "$ovr" in NR_NSA|NR_NSA_MMWAVE|NR_ADVANCED) line="$line ${GREEN}+ 5G NSA${NC}" ;; esac
		kv "Диапазон" "$line ${DIM}(SIM$((ph + 1)))${NC}"
	done <<< "$bl"
	[ -n "$NET_DNS" ] && kv "DNS" "$NET_DNS"

	# [3.9] Модем: температура и ограничение сети из-за нагрева.
	# Pixel (модем Exynos): зоны cp_on_chip_*, ограничение — статус датчика
	# усилителя cellular-emergency в Thermal HAL (отдельных устройств охлаждения нет).
	# Qualcomm: зоны modem-N-usr, ограничение — устройства охлаждения modem_*.
	local mt="" mlim="" cd ctype ccur cmax
	if zone_max 'cp_on_chip_*' || zone_max 'modem-[0-9]-usr'; then
		mdeg "$REPLY"; color_temp "$REPLY"; mt="$REPLY"
		for cd in "$R"/sys/class/thermal/cooling_device*; do
			IFS= read -r ctype 2>/dev/null < "$cd/type" || continue
			case "$ctype" in modem_*) ;; *) continue ;; esac
			IFS= read -r ccur 2>/dev/null < "$cd/cur_state" || continue
			is_int "$ccur" && [ "$ccur" -gt 0 ] || continue
			IFS= read -r cmax 2>/dev/null < "$cd/max_state"
			local why
			case "$ctype" in
				modem_pa*) why="усилитель" ;; modem_tj) why="чип" ;; modem_*skin*) why="корпус" ;;
				modem_current|modem_bcl) why="питание" ;; modem_charge_state) why="зарядка" ;;
				modem_mmw*) why="mmWave" ;; *) why="${ctype#modem_}" ;;
			esac
			mlim="${YELLOW}ограничен${NC} ${DIM}($why, $ccur из ${cmax:-?})${NC}"; break
		done
		if [ -z "$mlim" ] && is_int "${HAL_STAT[cellular-emergency]:-x}" && [ "${HAL_STAT[cellular-emergency]}" -gt 0 ]; then
			mlim="${YELLOW}ограничен${NC} ${DIM}(перегрев усилителя)${NC}"
		fi
		kv "Модем" "$mt${mlim:+ · $mlim}"
	fi

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

# [3.9] «Топ процессов» в духе htop. %CPU из ps — среднее за всё время жизни
# процесса, поэтому берём второй кадр toybox top: реальная загрузка за 1 с.
# Из того же кадра — память (RES), так что обе таблицы согласованы. Потоки ядра
# ([kworker/…], [sugov:4]) и сам top скрыты, как в htop по умолчанию.
# Имена длиннее колонки обрезаются посередине: начало…конец.
mid_trunc() {   # mid_trunc "строка" ширина → REPLY
	local t="$1" w="$2" h
	if [ "${#t}" -le "$w" ] || [ "$w" -lt 5 ]; then REPLY="$t"; return; fi
	h=$(( (w - 1) / 2 ))
	REPLY="${t:0:$h}…${t: -$((w - 1 - h))}"
}

print_top() {
	local raw tasks="" rows=5 sub="(замер за 1 с)"
	[ "$EXTENDED" -eq 1 ] && rows=10
	raw=$(top -b -n 2 -d 1 -m 1000 2>/dev/null)
	# Записи «pid|cpu|res_kb|имя» из второго кадра
	local data
	data=$(printf '%s\n' "$raw" | awk '
		/^ *PID +USER/ { frame++; next }
		/^Tasks:/ { if (frame >= 1) tasks = $0; next }
		frame < 2 { next }
		NF >= 12 && $1 ~ /^[0-9]+$/ {
			name = $12; for (i = 13; i <= NF; i++) name = name " " $i
			if (name ~ /^\[/ || name ~ /^top -b/) next
			r = $6; m = 1
			if (r ~ /[Kk]$/) m = 1; else if (r ~ /M$/) m = 1024; else if (r ~ /G$/) m = 1048576
			sub(/[KkMG]$/, "", r)
			printf "%s|%s|%d|%s\n", $1, $9, r * m, name
		}
		END { if (tasks != "") print "T|" tasks }')
	if ! printf '%s' "$data" | grep -q '^[0-9]'; then
		# Запасной путь: ps (среднее с запуска процесса)
		data=$(ps -A -o pid,%cpu,rss,name 2>/dev/null | awk 'NR > 1 && $4 !~ /^\[/ && !seen[$1]++ { printf "%s|%s|%s|%s\n", $1, $2, $3, $4 }')
		sub="(по ps: среднее с запуска)"
	fi
	[ -z "$data" ] && return
	section "ТОП ПРОЦЕССОВ" "$sub"

	# Задачи: процессы и состояния из top, потоки — знаменатель из /proc/loadavg
	local tl tot run zom thr=""
	tl=$(printf '%s\n' "$data" | sed -n 's/^T|//p')
	if [ -n "$tl" ]; then
		read -r tot run zom <<< "$(printf '%s' "$tl" | awk '{
			for (i = 1; i <= NF; i++) { if ($(i+1) ~ /^total/) t = $i; if ($(i+1) ~ /^running/) r = $i; if ($(i+1) ~ /^zombie/) z = $i }
			print t + 0, r + 0, z + 0 }')"
		rd "$R/proc/loadavg" && thr="${REPLY#* * * */}" && thr="${thr%% *}"
		local tline="$tot процессов"
		if is_int "${thr:-x}"; then
			# Разряды пробелом: 9700 → «9 700»
			local th="" t="$thr"
			while [ "${#t}" -gt 3 ]; do th=" ${t: -3}$th"; t="${t:0:${#t}-3}"; done
			tline="$tline · $t$th потоков"
		fi
		tline="$tline · работают $run"
		[ "${zom:-0}" -gt 0 ] && tline="$tline · ${YELLOW}зомби $zom${NC}"
		kv "Задачи" "$tline"
	fi

	# Ширина колонки имени: экран минус «  PID(7)  ЦП(5)  ОЗУ(7)  »
	local nw=40
	[ "$TERM_COLS" -gt 0 ] && nw=$((TERM_COLS - 27))
	[ "$nw" -lt 12 ] && nw=12

	local title key
	for key in cpu mem; do
		if [ "$key" = cpu ]; then title="По процессору"; else title="По памяти"; fi
		local bar="── $title "; local bl; char_len "$bar"; bl=$REPLY
		local fill=$(( (TERM_COLS > 0 ? TERM_COLS : 53) - 2 - bl )); [ "$fill" -lt 3 ] && fill=3
		printf -v REPLY '%*s' "$fill" ""; bar="$bar${REPLY// /─}"
		emit "  ${DIM}$bar${NC}"
		emit "  ${BOLD}$(printf '%7s  %5s  %7s  %s' PID 'ЦП, %' 'ОЗУ, МБ' ПРОЦЕСС)${NC}"
		local sorted pid cpu res name cc mc mb
		if [ "$key" = cpu ]; then sorted=$(printf '%s\n' "$data" | grep '^[0-9]' | sort -t'|' -k2,2gr -k3,3nr | head -n "$rows")
		else sorted=$(printf '%s\n' "$data" | grep '^[0-9]' | sort -t'|' -k3,3nr | head -n "$rows"); fi
		while IFS='|' read -r pid cpu res name; do
			[ -n "$pid" ] || continue
			cc=""; mc=""
			case "${cpu%%.*}" in ''|*[!0-9]*) ;; *) [ "${cpu%%.*}" -ge 50 ] && cc="$RED" || { [ "${cpu%%.*}" -ge 20 ] && cc="$YELLOW"; } ;; esac
			mb="?"
			if is_int "${res:-x}"; then
				mb=$(( (res + 512) / 1024 ))
				[ "$res" -ge 1048576 ] && mc="$RED" || { [ "$res" -ge 524288 ] && mc="$YELLOW"; }
			fi
			mid_trunc "$name" "$nw"
			emit "  $(printf '%7s' "$pid")  ${cc}$(printf '%5s' "$cpu")${cc:+$NC}  ${mc}$(printf '%7s' "$mb")${mc:+$NC}  $REPLY"
		done <<< "$sorted"
	done
}

# ── Ввод-вывод ───────────────────────────────────────────────────────────────

print_io() {
	section "ВВОД-ВЫВОД" "(с момента загрузки)"
	can_read "$R/proc/diskstats" || { kv "diskstats" "нет данных"; return; }
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
		can_read "$d/queue/scheduler" || continue
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

# ── Другие подключения ───────────────────────────────────────────────────────
# [3.13] Bluetooth, NFC и оплата, точка доступа, USB, UWB, ИК-порт.
# Сверено с пробами на Pixel 8 Pro (Android 17) и POCO F3 (Android 16).

# dumpsys bluetooth_manager → строки с полями через TAB:
#   S  состояние адаптера (ON/OFF/…)
#   B  MAC  подключено(0/1)  транспорт  CoD  имя        — сохранённые устройства
#   M  MAC  ключ  значение                               — метаданные устройства
#   C  MAC  кодек                                        — кодек A2DP
# Метаданные — BluetoothDevice.METADATA_*: Android 17 пишет их номерами
# (BluetoothStorageManager.Database), Android 16 — именами (custom metadata(…)).
# Номера сверены на одних и тех же наушниках, подключённых к обоим телефонам.
BT_AWK='
BEGIN {
	split("manufacturer_name model_name software_version hardware_version companion_app main_icon is_untethered_headset untethered_left_icon untethered_right_icon untethered_case_icon untethered_left_battery untethered_right_battery untethered_case_battery untethered_left_charging untethered_right_charging untethered_case_charging enhanced_settings_ui_uri device_type main_battery main_charging main_low_battery_threshold untethered_left_low_battery_threshold untethered_right_low_battery_threshold untethered_case_low_battery_threshold spatial_audio fastpair_customized le_audio", kn, " ")
	want["hardware_version"] = want["is_untethered_headset"] = want["device_type"] = want["le_audio"] = 1
	want["untethered_left_battery"] = want["untethered_right_battery"] = want["untethered_case_battery"] = 1
	want["untethered_left_charging"] = want["untethered_right_charging"] = want["untethered_case_charging"] = 1
	want["main_battery"] = want["main_charging"] = 1
}
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function meta(mac, k, v) { v = trim(v); if ((k in want) && v != "" && v != "null") print "M\t" mac "\t" k "\t" v }
!st && /^  [Ss]tate: *[A-Z_]+/ { s = $0; sub(/^  [Ss]tate: */, "", s); print "S\t" trim(s); st = 1 }
/^  Bonded devices:/ { bond = 1; next }
bond && /^  [A-Za-z]/ { bond = 0 }
bond && /^    [0-9A-Fa-fX:][0-9A-Fa-fX:]*\(/ {
	mac = substr($0, 5, 17)
	c = ($0 ~ /ACL BR\/EDR:Y/ || $0 ~ /ACL BR\/EDR:[YN] LE:Y/) ? 1 : 0
	t = ($0 ~ /\[ *LE *\]/) ? "LE" : ($0 ~ /\[ *DUAL *\]/) ? "DUAL" : "BR"
	cod = ""; if (match($0, /\[0x[0-9A-Fa-f]+\]/)) cod = substr($0, RSTART + 1, RLENGTH - 2)
	n = $0; while ((i = index(n, "] ")) > 0) n = substr(n, i + 2)
	print "B\t" mac "\t" c "\t" t "\t" cod "\t" trim(n)
}
# Android 17: «  Device: MAC [Persist on Disk] {» … «      10   100» … «  }»
/^  Device: [0-9A-Fa-fX:]+ / { dev = $2; next }
dev != "" && /^  }/ { dev = ""; next }
dev != "" && /^      [0-9]+ +[^ ]/ { k = $1 + 1; v = $0; sub(/^ *[0-9]+ +/, "", v); if (k in kn) meta(dev, kn[k], v); next }
# Android 16: «  MAC last_active_time=… {… custom metadata(k=v|k=v|…) …}»
/^  [0-9A-Fa-fX:]+ last_active_time=/ && /custom metadata\(/ {
	mac = $1; s = $0; sub(/.*custom metadata\(/, "", s); sub(/\), hfp client.*/, "", s)
	n = split(s, kvs, "|")
	for (i = 1; i <= n; i++) { j = index(kvs[i], "="); if (j) meta(mac, substr(kvs[i], 1, j - 1), substr(kvs[i], j + 1)) }
}
/=== A2dpStateMachine for / { a2 = $4 }
a2 != "" && /mCodecConfig: \{codecName:/ { s = $0; sub(/.*codecName:/, "", s); sub(/,.*/, "", s); print "C\t" a2 "\t" s; a2 = "" }
'

# bt_type CoD тип_из_метаданных → REPLY (тип устройства для списка сохранённых)
bt_type() {
	REPLY=""
	case "$2" in
		"Untethered Headset") REPLY="наушники"; return ;;
		Headset) REPLY="гарнитура"; return ;;
		Speaker) REPLY="колонка"; return ;;
		Watch) REPLY="часы"; return ;;
	esac
	[[ "$1" =~ ^0x[0-9A-Fa-f]+$ ]] || return
	local cod=$(( $1 )) maj
	maj=$(( (cod >> 8) & 0x1F ))
	case $maj in
		1) REPLY="компьютер" ;;
		2) REPLY="телефон" ;;
		4) REPLY="аудио" ;;
		5) if [ $(( cod & 0xC0 )) -eq 64 ]; then REPLY="клавиатура"
		   elif [ $(( cod & 0xC0 )) -eq 128 ]; then REPLY="мышь"
		   elif [ $(( (cod >> 2) & 0xF )) -eq 2 ]; then REPLY="геймпад"
		   else REPLY="периферия"; fi ;;
		7) REPLY="носимое" ;;
	esac
}

check_connections() {
	section "ДРУГИЕ ПОДКЛЮЧЕНИЯ"
	local tether
	tether=$(dumpsys tethering 2>/dev/null | awk '/^  Tether state:/ { f = 1; next } f && /^  [A-Za-z]/ { exit } f && / - TetheredState/ { printf "%s ", $1 }')

	# ── Bluetooth
	local bt line typ mac c tr cod name k v
	bt=$(dumpsys bluetooth_manager 2>/dev/null | LC_ALL=C awk "$BT_AWK" 2>/dev/null)
	if [ -n "$bt" ]; then
		local state="" n_on=0
		local -a macs=() conn=()
		local -A BN=() BC=() BT=() MD=() CD=()
		while IFS=$'\t' read -r typ mac c tr cod name; do
			case "$typ" in
				S) state="$mac" ;;
				B) macs+=("$mac"); BN[$mac]="$name"; BC[$mac]="$cod"; BT[$mac]="$tr"
				   [ "$c" = "1" ] && { conn+=("$mac"); n_on=$((n_on + 1)); } ;;
				M) MD["$mac|$c"]="$tr" ;;
				C) CD[$mac]="$c" ;;
			esac
		done <<< "$bt"
		if [ "$state" = "ON" ]; then
			local extra=""
			[[ " $tether" == *" bt-pan "* ]] && extra=" · режим модема"
			if [ "$n_on" -gt 0 ]; then
				kv "Bluetooth" "${GREEN}вкл.${NC} · подключено: $n_on$extra"
			else
				kv "Bluetooth" "${GREEN}вкл.${NC}$extra"
			fi
			local d bat l r cs ch fp
			for d in "${conn[@]}"; do
				bat=""
				l="${MD[$d|untethered_left_battery]:-}"; r="${MD[$d|untethered_right_battery]:-}"; cs="${MD[$d|untethered_case_battery]:-}"
				if is_int "${l:-x}" || is_int "${r:-x}"; then
					is_int "${l:-x}" && [ "$l" -ge 0 ] && bat="Л $l%"
					is_int "${r:-x}" && [ "$r" -ge 0 ] && bat="${bat:+$bat · }П $r%"
					[ "${MD[$d|untethered_left_charging]:-}" = "true" ] && [ "${MD[$d|untethered_right_charging]:-}" = "true" ] && bat="$bat (заряжаются)"
					if is_int "${cs:-x}" && [ "$cs" -ge 0 ]; then
						bat="$bat · кейс $cs%"
						[ "${MD[$d|untethered_case_charging]:-}" = "true" ] && bat="$bat (заряжается)"
					fi
				elif is_int "${MD[$d|main_battery]:-x}" && [ "${MD[$d|main_battery]}" -ge 0 ]; then
					bat="заряд ${MD[$d|main_battery]}%"
					[ "${MD[$d|main_charging]:-}" = "true" ] && bat="$bat (заряжается)"
				fi
				ch="${CD[$d]:-}"
				[ -z "$ch" ] && [ "${MD[$d|le_audio]:-}" = "true" ] && [ "${BT[$d]}" != "BR" ] && ch="LE Audio"
				fp=""; [[ "${MD[$d|hardware_version]:-}" == FAST_PAIR_* ]] && fp=" ${DIM}· Fast Pair${NC}"
				wrap_emit 18 "${BOLD}${BN[$d]:-$d}${NC}${ch:+ · $ch}${bat:+ · $bat}$fp"
			done
			if [ "$EXTENDED" -eq 1 ] && [ "${#macs[@]}" -gt 0 ]; then
				kv "Сохранённые" "${#macs[@]}"
				for d in "${macs[@]}"; do
					bt_type "${BC[$d]}" "${MD[$d|device_type]:-}"
					wrap_emit 18 "${BN[$d]:-$d}${REPLY:+ ${DIM}· $REPLY${NC}}"
				done
			fi
		else
			kv "Bluetooth" "выкл."
		fi
	fi

	# ── NFC и бесконтактная оплата. Приложение оплаты с Android 15 — системная
	# роль кошелька («Current wallet payment service»), а не настройка
	# nfc_payment_default_component; на старых — «Preferred payment service».
	local nfc
	nfc=$(dumpsys nfc 2>/dev/null)
	if [[ "$nfc" == *mState=* ]]; then
		local ns chip="" sec="" pay pkg desc
		ns=$(printf '%s\n' "$nfc" | sed -n 's/^mState=//p' | head -n 1)
		if compgen -G "$R/dev/st21nfc" >/dev/null || compgen -G "$R/dev/st54*" >/dev/null; then chip="STMicroelectronics"
		elif compgen -G "$R/dev/nq-nci" >/dev/null || compgen -G "$R/dev/pn5*" >/dev/null || compgen -G "$R/dev/nxp*" >/dev/null; then chip="NXP"
		elif compgen -G "$R/dev/sec-nfc" >/dev/null; then chip="Samsung"; fi
		prop vendor.qti.nfc.fwver; [ -n "$REPLY" ] && chip="${chip:-контроллер} · прошивка $REPLY"
		[[ "$nfc" == *mIsSecureNfcEnabled=true* ]] && sec=" · только при разблокировке"
		case "$ns" in
			on)  kv "NFC" "${GREEN}вкл.${NC}${chip:+ · $chip}$sec" ;;
			off) kv "NFC" "выкл.${chip:+ · $chip}" ;;
			*)   kv "NFC" "${ns:-?}${chip:+ · $chip}" ;;
		esac
		pay=$(printf '%s\n' "$nfc" | sed -n 's/.*Current wallet payment service: ComponentInfo{\([^}]*\)}.*/\1/p' | head -n 1)
		[ -z "$pay" ] && pay=$(printf '%s\n' "$nfc" | sed -n 's/.*[Pp]referred payment service: ComponentInfo{\([^}]*\)}.*/\1/p' | head -n 1)
		if [ -n "$pay" ]; then
			pkg="${pay%%/*}"
			desc=$(printf '%s\n' "$nfc" | grep -F "ComponentInfo{$pay} (Description: " | head -n 1 | sed 's/.*(Description: \([^)]*\)).*/\1/')
			[ "$desc" = "null" ] && desc=""
			if [ -n "$desc" ]; then kv "Оплата" "$desc ${DIM}($pkg)${NC}"; else kv "Оплата" "$pkg"; fi
		else
			kv "Оплата" "${YELLOW}приложение не выбрано${NC}"
		fi
	fi

	# ── Точка доступа: настройки из WifiConfigStoreSoftAp.xml (на Android 17 —
	# в /data/misc_ce, на 16 — в /data/misc); состояние — по dumpsys tethering,
	# а частоты и клиенты — из dumpsys wifi, только если точка работает.
	local ap="" f
	for f in "$R/data/misc_ce/0/apexdata/com.android.wifi/WifiConfigStoreSoftAp.xml" \
		"$R/data/misc/apexdata/com.android.wifi/WifiConfigStoreSoftAp.xml"; do
		can_read "$f" && grep -q '<SoftAp>' "$f" 2>/dev/null && { ap="$f"; break; }
	done
	local ap_on=0 i
	for i in $tether; do case "$i" in wlan*|softap*|ap_br*|swlan*) ap_on=1 ;; esac; done
	if [ -n "$ap" ] || [ "$ap_on" -eq 1 ]; then
		local ssid="" secu="" bands="" hid="" maxc="" auto="" tmo="" out=""
		if [ -n "$ap" ]; then
			IFS=$'\t' read -r ssid secu bands hid maxc auto tmo < <(awk '
				/name="WifiSsid"/ {
					s = $0; sub(/.*name="WifiSsid">/, "", s); sub(/<\/string>.*/, "", s)
					# [3.13.1] Значение экранировано по правилам XML: &quot;Имя&quot;
					gsub(/&quot;/, "\"", s); gsub(/&apos;/, "\047", s); gsub(/&lt;/, "<", s); gsub(/&gt;/, ">", s); gsub(/&amp;/, "\\&", s)
					gsub(/^"|"$/, "", s)
				}
				/name="SecurityType"/ { t = $0; sub(/.*value="/, "", t); sub(/".*/, "", t) }
				/name="Band"/ { b = $0; sub(/.*value="/, "", b); sub(/".*/, "", b); bl = bl (bl == "" ? "" : ",") b }
				/name="HiddenSSID"/ { h = ($0 ~ /value="true"/) }
				/name="MaxNumberOfClients"/ { m = $0; sub(/.*value="/, "", m); sub(/".*/, "", m) }
				/name="AutoShutdownEnabled"/ { a = ($0 ~ /value="true"/) }
				/name="ShutdownTimeoutMillis"/ { o = $0; sub(/.*value="/, "", o); sub(/".*/, "", o) }
				END { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", s, t, bl, h + 0, m, a + 0, o }' "$ap" 2>/dev/null)
		fi
		# SoftApConfiguration.SECURITY_TYPE_*: 0 открытая, 1 WPA2, 2 WPA2/WPA3,
		# 3 WPA3, 4/5 OWE. Band — битовая маска: 1 = 2,4 ГГц, 2 = 5, 4 = 6.
		case "$secu" in
			0) secu="${YELLOW}без пароля${NC}" ;; 1) secu="WPA2" ;; 2) secu="WPA2/WPA3" ;;
			3) secu="WPA3" ;; 4|5) secu="OWE" ;; *) secu="" ;;
		esac
		# Две записи — мостовой режим (две сети одновременно): у каждой берём
		# старший диапазон. Одна запись с несколькими битами — выбор системы.
		local bl="" b bt2 nb=0
		for b in ${bands//,/ }; do nb=$((nb + 1)); done
		for b in ${bands//,/ }; do
			if [ "$nb" -gt 1 ]; then
				case "$b" in 1) bt2="2,4" ;; 2|3) bt2="5" ;; 4|5|6|7) bt2="6" ;; *) bt2="" ;; esac
			else
				case "$b" in 1) bt2="2,4" ;; 2) bt2="5" ;; 3) bt2="2,4/5" ;; 4) bt2="6" ;; 6) bt2="5/6" ;; 7) bt2="2,4/5/6" ;; *) bt2="" ;; esac
			fi
			[ -n "$bt2" ] && bl="${bl:+$bl + }$bt2"
		done
		[ -n "$bl" ] && bl="$bl ГГц"
		if [ "$ap_on" -eq 1 ]; then
			local live fr="" cl="" std="" idle=""
			live=$(dumpsys wifi 2>/dev/null | awk '
				/^Dump of SoftApManager/ { f = 1 }
				f && /^getConnectedClientList\(\)\.size\(\):/ { c = $2 }
				f && /^mCurrentSoftApInfoMap/ {
					s = $0
					while (match(s, /frequency= *[0-9]+/)) { q = substr(s, RSTART, RLENGTH); gsub(/[^0-9]/, "", q); fl = fl " " q; s = substr(s, RSTART + RLENGTH) }
					if (match($0, /wifiStandard= *[0-9]+/)) { w = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", w) }
					if (match($0, /mIdleShutdownTimeoutMillis= *[0-9]+/)) { t = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", t) }
				}
				f && /^SoftApManager:/ { exit }
				END { printf "%s\t%s\t%s\t%s\n", fl, c, w, t }')
			IFS=$'\t' read -r fr cl std idle <<< "$live"
			local fq h24=0 h5=0 h6=0 fb=""
			for fq in $fr; do
				if [ "$fq" -lt 3000 ]; then h24=1; elif [ "$fq" -lt 5925 ]; then h5=1; else h6=1; fi
			done
			[ "$h24" -eq 1 ] && fb="2,4"
			[ "$h5" -eq 1 ] && fb="${fb:+$fb + }5"
			[ "$h6" -eq 1 ] && fb="${fb:+$fb + }6"
			[ -n "$fb" ] && bl="$fb ГГц"
			{ is_int "${tmo:-x}" && [ "$tmo" -gt 0 ]; } || { is_int "${idle:-x}" && tmo="$idle"; }
			# ScanResult.WIFI_STANDARD_*: 4 — 802.11n, 5 — ac, 6 — ax, 8 — be
			case "$std" in 4) std="Wi-Fi 4" ;; 5) std="Wi-Fi 5" ;; 6) std="Wi-Fi 6" ;; 8) std="Wi-Fi 7" ;; *) std="" ;; esac
			out="${GREEN}вкл.${NC}"
			[ -n "$ssid" ] && out="$out · «$ssid»"
			out="$out${secu:+ · $secu}${bl:+ · $bl}${std:+ · $std}${cl:+ · клиентов: $cl}"
		else
			out="выкл."
			[ -n "$ssid" ] && out="$out · «$ssid»"
			out="$out${secu:+ · $secu}${bl:+ · $bl}"
		fi
		[ "$hid" = "1" ] && out="$out · скрытая"
		is_int "${maxc:-x}" && [ "$maxc" -gt 0 ] && out="$out · до $maxc клиентов"
		if [ "$auto" = "1" ]; then
			if is_int "${tmo:-x}" && [ "$tmo" -gt 0 ]; then out="$out · автоотключение $((tmo / 60000)) мин"
			else out="$out · автоотключение"; fi
		fi
		kv "Точка доступа" "$out"
	fi

	# ── USB: порт Type-C, источник питания, функции и максимальная скорость порта
	local pres="" typ2="" pr="" dr="" fn="" spd="" u
	rd "$R/sys/class/power_supply/usb/present" && pres="$REPLY"
	rd "$R/sys/class/power_supply/usb/real_type" && typ2="$REPLY"
	if [ -z "$typ2" ] || [ "$typ2" = "Unknown" ]; then
		rd "$R/sys/class/power_supply/usb/usb_type" && [[ "$REPLY" =~ \[([A-Za-z_]+)\] ]] && typ2="${BASH_REMATCH[1]}"
	fi
	rd "$R/sys/class/typec/port0/power_role" && [[ "$REPLY" =~ \[([a-z]+)\] ]] && pr="${BASH_REMATCH[1]}"
	rd "$R/sys/class/typec/port0/data_role" && [[ "$REPLY" =~ \[([a-z]+)\] ]] && dr="${BASH_REMATCH[1]}"
	for u in "$R"/sys/class/udc/*/maximum_speed; do rd "$u" && spd="$REPLY" && break; done
	prop sys.usb.config; fn="$REPLY"
	case "$spd" in super-speed*) spd="USB 3" ;; high-speed) spd="USB 2.0" ;; *) spd="" ;; esac
	if [ -n "$pres$pr$spd" ]; then
		local st2=""
		if [ "$dr" = "host" ]; then st2="${GREEN}OTG${NC} (устройство подключено к телефону)"
		elif [ "$pres" = "1" ]; then
			case "$typ2" in
				USB_PD|USB_PD_DRP) st2="зарядка USB PD" ;;
				DCP|USB_DCP|USB_HVDCP*|HVDCP*) st2="зарядное устройство" ;;
				SDP|USB) st2="компьютер" ;;
				CDP|USB_CDP) st2="компьютер (зарядный порт)" ;;
				*) st2="подключён" ;;
			esac
		else st2="не подключён"; fi
		local fns=""
		[ -n "$fn" ] && [ "$fn" != "none" ] && fns="${fn^^}" && fns="${fns//,/, }"
		[[ " $tether" == *" ncm"* || " $tether" == *" rndis"* || " $tether" == *" usb"* ]] && fns="${fns:+$fns, }режим модема"
		kv "USB" "$st2${spd:+ · порт $spd}${fns:+ · $fns}"
	fi

	# ── UWB (перенесено из «Google Pixel»): служба и переключатель в настройках
	local uwb
	uwb=$(dumpsys uwb 2>/dev/null | awk '/settings_toggle=/ { t = ($0 ~ /settings_toggle=true/) ? "on" : "off" } /^Device state =/ { s = $4 } END { if (s != "") print t " " s }')
	if [ -n "$uwb" ]; then
		case "$uwb" in
			"on READY"*) kv "UWB" "${GREEN}включён${NC}" ;;
			off*)        kv "UWB" "выключен" ;;
			*)           kv "UWB" "${uwb#* } ${DIM}(состояние службы)${NC}" ;;
		esac
	fi

	# ── ИК-порт (пульт): устройство lirc
	compgen -G "$R/dev/lirc*" >/dev/null && kv "ИК-порт" "есть"
	return 0
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
	# [3.11] Прошивка Titan: vendor.nos.citadel.version = «0.1.114/3f217f1f 0.3.2/…» → «0.1.114»
	prop vendor.nos.citadel.version; local tv="${REPLY%%/*}"
	if [ -e "$R/dev/gsc0" ] || [ -e "$R/dev/citadel0" ] || [ -n "$sb" ]; then
		kv "Чип защиты" "${GREEN}${sb:-Titan M}${NC}${tv:+ · прошивка $tv} ${DIM}(StrongBox)${NC}"
	else
		kv "Чип защиты" "${YELLOW}не найден${NC}"
	fi
	# [3.12] AOC — отдельный экономичный процессор для «Always-On»-функций
	if [ -e "$R/dev/aoc" ] || [ -d "$R/sys/devices/platform/aoc" ]; then
		kv "AOC" "${GREEN}есть${NC} ${DIM}(Always-On Compute)${NC}"
	else
		kv "AOC" "${RED}нет${NC}"
	fi

	# [3.12] DRM: Widevine по данным его HAL (dumpsys …IDrmFactory/widevine).
	# Уровень L1/L3 из поля default_security_level не берём: на Pixel 8 Pro оно
	# отставало на одно переключение (L1 при программном модуле). Надёжно другое:
	# модуль OEMCrypto. «Software» — программная защита, это всегда L3;
	# иначе — аппаратный модуль в доверенной среде (TEE). Программный режим
	# включается в «Для разработчиков» → «Настройки DRM для медиаконтента»
	# (свойство persist.drm.forcel3.enabled).
	local wv wsoc wtee wcdm force
	wv=$(dumpsys android.hardware.drm.IDrmFactory/widevine 2>/dev/null)
	if [[ "$wv" == *oemcrypto_build_info* ]]; then
		wsoc=$(printf '%s\n' "$wv" | sed -n 's/.*"soc_model": *"\([^"]*\)".*/\1/p' | head -n 1)
		wtee=$(printf '%s\n' "$wv" | sed -n 's/.*"tee_os": *"\([^"]*\)".*/\1/p' | head -n 1)
		wcdm=$(printf '%s\n' "$wv" | sed -n 's/^ *version_widevine_cdm: *\([0-9.]*\).*/\1/p' | head -n 1)
		prop persist.drm.forcel3.enabled; force="$REPLY"
		if [ "$wsoc" = "Software" ]; then
			kv "DRM" "Widevine ${YELLOW}L3 · программная защита${NC}${wcdm:+ ${DIM}· CDM $wcdm${NC}}"
			[ "$force" = "true" ] && [ "$EXTENDED" -eq 1 ] && note "включено в «Для разработчиков» → «Настройки DRM для медиаконтента»"
		elif [ -n "$wsoc" ]; then
			wtee="${wtee:-TEE}"; [ "$wtee" = "TRUSTY" ] && wtee="Trusty"
			kv "DRM" "Widevine ${GREEN}аппаратная защита${NC} ${DIM}($wtee)${NC}${wcdm:+ ${DIM}· CDM $wcdm${NC}}"
		fi
	fi

	# [3.12] Термометр: только наличие датчика. Название — первое слово имени
	# сенсора типа fir_temperature («MLX90632 FIR Temperature | Melexis …»).
	local fir
	fir=$(dumpsys sensorservice 2>/dev/null | awk -F'|' '/fir_temperature\(/ { n = $1; sub(/^[^)]*\) */, "", n); split(n, a, " "); print a[1]; exit }')
	if [ -n "$fir" ]; then
		kv "Термометр" "есть · датчик $fir"
	else
		kv "Термометр" "нет"
	fi

	# [3.11] AICore — системная среда Gemini Nano. Сборка из versionName
	# («0.release.prod_aicore_20260917.00_RC01» → 17.09.2026). Есть ли скачанная
	# модель, по файлам не видно — поэтому про модель не пишем.
	local ai
	ai=$(dumpsys package com.google.android.aicore 2>/dev/null | sed -n 's/^ *versionName=//p' | head -n 1)
	if [ -n "$ai" ]; then
		if [[ "$ai" =~ _(20[0-9]{2})([01][0-9])([0-3][0-9]) ]]; then
			ai="сборка ${BASH_REMATCH[3]}.${BASH_REMATCH[2]}.${BASH_REMATCH[1]}"
		fi
		pm list packages -d 2>/dev/null | grep -qx 'package:com.google.android.aicore' && ai="${YELLOW}отключён${NC} ${DIM}($ai)${NC}"
		kv "AICore" "$ai ${DIM}(среда Gemini Nano)${NC}"
	fi

	# [3.11] Сканер отпечатков: производитель — по службе vendor.fingerprint-<имя>,
	# «под экраном» — по свойствам persist.vendor.udfps.*
	local k fpv="" udfps=0
	for k in "${!PROP[@]}"; do
		case "$k" in
			init.svc.vendor.fingerprint-*) fpv="${k#init.svc.vendor.fingerprint-}" ;;
			persist.vendor.udfps.*) udfps=1 ;;
		esac
	done
	if [ -n "$fpv" ] || [ "$udfps" -eq 1 ]; then
		case "$fpv" in goodix) fpv="Goodix" ;; fpc) fpv="FPC" ;; qcom|qti) fpv="Qualcomm" ;; esac
		local fpl=""
		[ "$udfps" -eq 1 ] && fpl="под экраном"
		[ -n "$fpv" ] && fpl="${fpl:+$fpl · }$fpv"
		kv "Отпечаток" "$fpl"
	fi

	# [3.13] UWB перенесён в «Другие подключения»
	# [3.7.1] Модем сверяем с тем, что ожидает прошивка (ro.build.expect.baseband):
	# расхождение бывает после ручной прошивки без radio-образа или кривой OTA.
	local bb exp_bb
	prop gsm.version.baseband; bb="${REPLY%%,*}"
	prop ro.build.expect.baseband; exp_bb="$REPLY"
	if [ -n "$bb" ]; then
		if [ -n "$exp_bb" ] && [ "$bb" != "$exp_bb" ]; then
			kv "Модем" "$bb ${YELLOW}⚠ ВНИМАНИЕ: прошивка ожидает $exp_bb${NC}"
			raise_status 1
		else
			kv "Модем" "$bb"
		fi
	fi
	kv "Статус AVB" "$VB_LABEL"
}

# ── Система ──────────────────────────────────────────────────────────────────

# [3.12] ROOT_VER — версия менеджера root для подзаголовка «Модули …»
ROOT_INFO=""; ZYGISK_INFO=""; ROOT_KIND="ROOT"; ROOT_VER=""   # ROOT_KIND — для заголовка «МОДУЛИ …»
detect_root() {
	ROOT_INFO=""; ZYGISK_INFO=""; ROOT_KIND="ROOT"; ROOT_VER=""
	if command -v magisk >/dev/null 2>&1 || [ -d "$R/data/adb/magisk" ]; then
		local v vc
		v=$(magisk -v 2>/dev/null); v="${v%%:*}"
		vc=$(magisk -V 2>/dev/null)
		ROOT_INFO="Magisk"; ROOT_KIND="MAGISK"; ROOT_VER="Magisk ${v:-?}${vc:+ · $vc}"
		# Zygisk: настройка в БД Magisk + реальное присутствие в zygote64
		local on="" active=0 pid
		# [3.7] Если --sqlite не сработал, настройка неизвестна («?») — тогда не называем
		# активный Zygisk сторонним: это может быть и встроенный Zygisk Magisk.
		on=$(magisk --sqlite "SELECT value FROM settings WHERE key='zygisk'" 2>/dev/null) || on="?"
		on="${on#value=}"
		for pid in $(pidof zygote64 zygote 2>/dev/null); do
			grep -q zygisk "$R/proc/$pid/maps" 2>/dev/null && { active=1; break; }
		done
		if [ "$on" = "1" ] && [ "$active" -eq 1 ]; then ZYGISK_INFO="${GREEN}включён и активен${NC}"
		elif [ "$on" = "1" ]; then ZYGISK_INFO="${YELLOW}включён, но не загружен — нужна перезагрузка${NC}"
		elif [ "$on" = "?" ] && [ "$active" -eq 1 ]; then ZYGISK_INFO="${GREEN}активен${NC} ${DIM}(настройку Magisk прочитать не удалось)${NC}"
		elif [ "$active" -eq 1 ]; then ZYGISK_INFO="${GREEN}активен${NC} ${DIM}(сторонний: ZygiskNext/NeoZygisk)${NC}"
		else ZYGISK_INFO="выключен"; fi
	elif [ -d "$R/data/adb/ksu" ] || command -v ksud >/dev/null 2>&1; then
		ROOT_INFO="KernelSU"; ROOT_KIND="KERNELSU"
		# [3.12] По исходникам ksud (не проверено на устройстве): «ksud -V» →
		# «ksud v1.0.5 (uapi: 2)», «ksud debug version» → «Kernel Version: 12345»
		local k kv_ kc t=""
		command -v timeout >/dev/null 2>&1 && t="timeout 5"
		for k in ksud "$R/data/adb/ksud"; do command -v "$k" >/dev/null 2>&1 && break; k=""; done
		if [ -n "$k" ]; then
			kv_=$($t "$k" -V 2>/dev/null | head -n 1); kv_="${kv_#ksud }"; kv_="${kv_%% (*}"
			kc=$($t "$k" debug version 2>/dev/null | sed -n 's/^Kernel Version: *//p')
			ROOT_VER="KernelSU${kv_:+ $kv_}${kc:+ · $kc}"
		fi
	elif [ -d "$R/data/adb/ap" ] || command -v apd >/dev/null 2>&1; then
		ROOT_INFO="APatch"; ROOT_KIND="APATCH"
		# [3.12] По исходникам apd (не проверено): «apd -V» → «apd 11142» (код версии)
		local a av t=""
		command -v timeout >/dev/null 2>&1 && t="timeout 5"
		for a in apd "$R/data/adb/apd"; do command -v "$a" >/dev/null 2>&1 && break; a=""; done
		[ -n "$a" ] && av=$($t "$a" -V 2>/dev/null | head -n 1) && av="${av#apd }"
		ROOT_VER="APatch${av:+ $av}"
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
	# [3.12] Часовой пояс: имя зоны + смещение от UTC; «авто» — по сети
	local tz off auto
	prop persist.sys.timezone; tz="$REPLY"
	off=$(date +%z 2>/dev/null)
	[[ "$off" =~ ^[+-][0-9]{4}$ ]] && off="UTC${off:0:3}:${off:3:2}" || off=""
	[ "$(settings get global auto_time_zone 2>/dev/null)" = "1" ] && auto=" ${DIM}· авто${NC}"
	[ -n "$tz$off" ] && kv "Часовой пояс" "${tz:-?}${off:+ ($off)}$auto"
	# [3.12.1] Формат часов: settings system time_12_24 = 12 / 24. Пусто — включено
	# «Использовать формат языка»: тогда формат задаёт первый язык системы.
	# 12-часовой по умолчанию (CLDR) — у США, Канады, Австралии, Новой Зеландии,
	# Индии, Филиппин, Пакистана, Египта, Саудовской Аравии, Кореи и Тайваня.
	local f12 lc
	f12=$(settings get system time_12_24 2>/dev/null)
	case "$f12" in
		12|24) kv "Формат часов" "$f12-часовой" ;;
		*)
			prop persist.sys.locale; lc="${REPLY%%,*}"
			[ -z "$lc" ] && { prop ro.product.locale; lc="$REPLY"; }
			lc="${lc%%-u-*}"; lc="${lc//_/-}"
			case "$lc" in
				*-US|*-CA|*-AU|*-NZ|*-IN|*-PH|*-PK|*-EG|*-SA|*-KR|*-TW|ko|hi) f12=12 ;;
				*) f12=24 ;;
			esac
			kv "Формат часов" "$f12-часовой ${DIM}(по языку${lc:+ $lc})${NC}" ;;
	esac
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
	# [3.7] Версия загрузчика и ревизия платы. Pixel отдаёт версию в ro.bootloader
	# («ripcurrent-…»); Xiaomi пишет туда «unknown» — тогда строку не показываем.
	local bl rev hv hc hl
	prop ro.bootloader; bl="$REPLY"
	[ -z "$bl" ] || [ "$bl" = "unknown" ] && { prop ro.boot.bootloader; bl="$REPLY"; }
	# [3.7.1] Сверка с ro.build.expect.bootloader: Google шьёт загрузчик с каждой
	# прошивкой, и расхождение значит, что его пропустили при ручной прошивке.
	if [ -n "$bl" ] && [ "$bl" != "unknown" ]; then
		local exp_bl; prop ro.build.expect.bootloader; exp_bl="$REPLY"
		if [ -n "$exp_bl" ] && [ "$bl" != "$exp_bl" ]; then
			kv "Bootloader" "$bl ${YELLOW}⚠ ВНИМАНИЕ: прошивка ожидает $exp_bl${NC}"
			raise_status 1
		else
			kv "Bootloader" "$bl"
		fi
	fi
	prop ro.boot.hwversion; hv="$REPLY"
	if [ -n "$hv" ]; then
		prop ro.boot.hwc; hc="$REPLY"; prop ro.boot.hwlevel; hl="$REPLY"
		rev="$hv${hc:+ · $hc}${hl:+ · $hl}"          # Xiaomi: 9.19.0 · GLOBAL · MP
	else
		prop ro.boot.hardware.revision; rev="$REPLY"   # Pixel: MP1.0
		[ -z "$rev" ] && { prop ro.revision; [ "$REPLY" != "0" ] && rev="$REPLY"; }
	fi
	[ -n "$rev" ] && kv "Ревизия" "$rev"
	kv "Драйверы" "Vulkan: ${vk:-по умолчанию} · EGL: ${egl:-по умолчанию}"
}

# [3.1] Модули: заголовок по типу root, статус у каждого модуля, версия через
# разделитель, описание строкой ниже. Флаги — штатные файлы Magisk/KernelSU/APatch:
#   disable → выкл., remove → удалится, update или modules_update/<id> → обновлён.
# Новые модули, которые появятся только после перезагрузки, тоже показываем.
mod_prop() {   # mod_prop ФАЙЛ КЛЮЧ → REPLY (без управляющих символов)
	REPLY=""
	can_read "$1" || return 1
	REPLY=$(sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1)
	REPLY="${REPLY//[[:cntrl:]]/}"
	[ -n "$REPLY" ]
}

# [3.10] Строка модуля «  вкл.     Название · версия»: колонка статуса 8 символов,
# длинный хвост переносится под название (отступ 11), а не на начало строки.
tag_line() {
	local tag="$1" text="$2" first=1 ln
	if [ "$TERM_COLS" -gt 0 ] && [ "$BRIEF_MODE" -eq 0 ]; then
		strip_ansi "$text"; char_len "$REPLY"
		if [ $((11 + REPLY)) -gt "$TERM_COLS" ]; then
			wrap_text "$text" $((TERM_COLS - 11))
			while IFS= read -r ln; do
				if [ "$first" -eq 1 ]; then emit "  $tag $ln"; first=0; else emit "           $ln"; fi
			done <<< "$REPLY"
			return
		fi
	fi
	emit "  $tag $text"
}

# [3.4] Было print_magisk_modules: секция универсальная — теперь print_modules,
# а заголовок берётся из глобальной ROOT_KIND (её видит и список секций в -d).
print_modules() {
	[ -z "$ROOT_INFO" ] && detect_root
	local dir="$R/data/adb/modules" upd="$R/data/adb/modules_update"
	[ -d "$dir" ] || [ -d "$upd" ] || [ "$ROOT_KIND" != "ROOT" ] || return 0
	section "МОДУЛИ $ROOT_KIND" "${ROOT_VER:+($ROOT_VER)}"

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
		can_read "$upd/$id/module.prop" && propf="$upd/$id/module.prop"
		mod_prop "$propf" name;        name="${REPLY:-$id}"
		mod_prop "$propf" version;     ver="$REPLY"
		mod_prop "$propf" versionCode; vc="$REPLY"
		mod_prop "$propf" description; desc="$REPLY"
		# Колонка статуса шириной 8 символов
		char_len "$st"; printf -v sp '%*s' $((8 - REPLY)) ""
		tag="${stc}${st}${NC}${sp}"
		tag_line "$tag" "${BOLD}${name}${NC}${ver:+ ${DIM}·${NC} $ver}${vc:+ ${DIM}($vc)${NC}}"
		if [ -n "$desc" ]; then
			# [3.9] На экране — перенос целиком, без экрана (файл, конвейер) — обрезка
			[ "$TERM_COLS" -eq 0 ] && [ ${#desc} -gt 160 ] && desc="${desc:0:157}..."
			wrap_emit 11 "${DIM}${desc}${NC}"
		fi
	done
	[ "$pend" -eq 1 ] && note "обновлён / удалится / новый — изменения применятся после перезагрузки"
}

# ── Модули LSPosed ───────────────────────────────────────────────────────────
# [3.10] Секция только с -e (как «Модули Magisk») и только если фреймворк стоит:
# LSPosed или его форк Vector (JingMatrix), id zygisk_vector / zygisk_lsposed.
# Источники (сверено с исходниками Vector 2.2):
#   • список и вкл./выкл. — CLI фреймворка: cli --json modules ls (~1.5 с, Java);
#     версия API фреймворка — cli --json status («API Version», есть с 2.2);
#   • описание и API модуля — кэш менеджера module-detection.tsv (Vector 2.1+,
#     ModuleDetectionCache.kt): описание там уже взято из ресурсов APK на языке
#     системы. Кэш появляется после первого открытия списка модулей в менеджере;
#   • в строке модуля — имя пакета: подписи приложения нет ни в CLI, ни в кэше,
#     а у большинства модулей она лежит в resources.arsc, который без Java не прочесть.
# Без кэша описание и API читаются из APK так же, как это делает менеджер
# (ModuleDetection.kt): module.prop нового API или meta-data xposed* старого.
LSP_AXML_AWK='
# AXML (двоичный AndroidManifest.xml) из od -An -v -tu1 → строки:
#   D<TAB>описание приложения (строкой или @), M<TAB>имя meta-data<TAB>тип<TAB>значение
function u16(o) { return b[o] + b[o+1] * 256 }
function u32(o) { return b[o] + b[o+1] * 256 + b[o+2] * 65536 + b[o+3] * 16777216 }
# Байт → текст для printf %b: не-ASCII как \xHH (awk на Android может сам
# перекодировать %c > 127 в UTF-8), обратный слэш удваивается, управляющие — пробел
function bt(c) { return c >= 128 ? sprintf("\\x%02x", c) : c == 92 ? "\\\\" : c < 32 ? " " : sprintf("%c", c) }
function utf8(c) {   # кодовая точка UTF-16 → байты UTF-8
	if (c < 128) return bt(c)
	if (c < 2048) return bt(192 + int(c / 64)) bt(128 + c % 64)
	return bt(224 + int(c / 4096)) bt(128 + int(c / 64) % 64) bt(128 + c % 64)
}
function str(i,    o, n, s, k) {
	if (i < 0 || i >= scount || i == 4294967295) return ""
	o = sp + sstart + u32(sp + shdr + 4 * i)
	s = ""
	if (sutf8) {
		o += (b[o] >= 128) ? 2 : 1                       # длина в символах
		n = b[o]; o++; if (n >= 128) { n = (n - 128) * 256 + b[o]; o++ }
		for (k = 0; k < n; k++) s = s bt(b[o + k])
	} else {
		n = u16(o); o += 2; if (n >= 32768) { n = (n - 32768) * 65536 + u16(o); o += 2 }
		for (k = 0; k < n; k++) s = s utf8(u16(o + 2 * k))
	}
	return s
}
{ for (i = 1; i <= NF; i++) b[nb++] = $i + 0 }
END {
	if (nb < 8 || u16(0) != 3) exit 1
	o = u16(2)
	while (o + 8 <= nb) {
		t = u16(o); h = u16(o + 2); sz = u32(o + 4); if (sz < 8) break
		if (t == 1) {                                      # пул строк
			sp = o; shdr = h; scount = u32(o + 8); sutf8 = int(u32(o + 16) / 256) % 2; sstart = u32(o + 20)
		} else if (t == 384) {                             # карта ресурсов
			for (k = 0; (k + 1) * 4 <= sz - h; k++) rid[k] = u32(o + h + 4 * k)
		} else if (t == 258) {                             # начало элемента
			e = o + h; tag = str(u32(e + 4)); as = u16(e + 8); asz = u16(e + 10); ac = u16(e + 12)
			split("", A); split("", AT); split("", AD); split("", AR)
			for (k = 0; k < ac; k++) {
				a = e + as + k * asz; ni = u32(a + 4); nm = str(ni)
				if (ni in rid) { if (rid[ni] == 16842753) nm = "label"; else if (rid[ni] == 16842755) nm = "name"; else if (rid[ni] == 16842788) nm = "value"; else if (rid[ni] == 16843056) nm = "description" }
				AR[nm] = u32(a + 8); AT[nm] = b[a + 15]; AD[nm] = u32(a + 16)
			}
			if (tag == "application") {
				if ("description" in AT) print "D\t" (AT["description"] == 3 ? str(AR["description"]) : "@")
			} else if (tag == "meta-data" && ("name" in AT)) {
				mn = str(AR["name"])
				if (mn ~ /^xposed/) {
					if (!("value" in AT)) print "M\t" mn "\t-\t"
					else if (AT["value"] == 3) print "M\t" mn "\ts\t" str(AR["value"])
					else if (AT["value"] == 1) print "M\t" mn "\tr\t"
					else print "M\t" mn "\ti\t" AD["value"]
				}
			}
		}
		o += sz
	}
}
'
LSP_CACHE_AWK='
# Кэш менеджера Vector: пакет → «legacy<TAB>minApi<TAB>targetApi<TAB>описание» (описание
# раскодировано из base64 и экранировано для printf %b). Из нескольких записей пакета — с большим versionCode.
function bt(c) { return c >= 128 ? sprintf("\\x%02x", c) : c == 92 ? "\\\\" : c < 32 ? " " : sprintf("%c", c) }
function b64(s,    i, c, v, n, bits, out) {
	out = ""; v = 0; bits = 0
	for (i = 1; i <= length(s); i++) {
		c = index(B64, substr(s, i, 1)); if (c == 0) continue
		v = v * 64 + c - 1; bits += 6
		if (bits >= 8) { bits -= 8; n = int(v / 2 ^ bits); v -= n * 2 ^ bits; out = out bt(n) }
	}
	return out
}
BEGIN { FS = "\t"; B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" }
NF == 10 && $4 == "1" && (!($1 in vc) || $2 + 0 > vc[$1]) { vc[$1] = $2 + 0; rec[$1] = $5 "\t" $6 "\t" $7 "\t" b64($10) }
END { for (p in rec) print p "\t" rec[p] }
'

print_lsposed() {
	local m id fwdir="" desc0
	for m in "$R"/data/adb/modules/*/; do
		m="${m%/}"; id="${m##*/}"
		case "${id,,}" in *lsposed*|*vector*) ;; *) continue ;; esac
		mod_prop "$m/module.prop" description; desc0="$REPLY"
		case "${id,,}:${desc0,,}" in *lsposed*|*xposed*) fwdir="$m"; break ;; esac
	done
	[ -n "$fwdir" ] || return 0

	local fork fwver api="" cli="" to="" sub
	mod_prop "$fwdir/module.prop" name; fork="${REPLY:-${fwdir##*/}}"
	fork="${fork#Zygisk - }"; fork="${fork#Riru - }"
	mod_prop "$fwdir/module.prop" version; fwver="${REPLY%% (*}"
	for m in "$R/data/adb/lspd/cli" "$fwdir/cli"; do [ -f "$m" ] && { cli="$m"; break; }; done
	command -v timeout >/dev/null 2>&1 && to="timeout 20"

	# Список модулей: пакет<TAB>enabled|disabled
	local list="" cli_ok=0
	if [ -n "$cli" ] && [ ! -e "$fwdir/disable" ]; then
		api=$($to sh "$cli" --json status 2>/dev/null | awk -F': *' '/"API Version"/ { gsub(/[^0-9]/, "", $2); print $2; exit }')
		list=$($to sh "$cli" --json modules ls 2>/dev/null | awk '
			/"success": *true/ { ok = 1 }
			/"PACKAGE"/ { p = $0; sub(/^[^:]*: *"/, "", p); sub(/".*/, "", p) }
			/"STATUS"/  { s = $0; sub(/^[^:]*: *"/, "", s); sub(/".*/, "", s); if (p != "") print p "\t" s; p = "" }
			END { if (ok) print "OK" }')
		[[ "$list" == *OK ]] && cli_ok=1
		list="${list%OK}"; list="${list%$'\n'}"
	fi

	# Кэш менеджера: встроенный менеджер живёт в com.android.shell, отдельный — в своём пакете
	local cache=""
	for m in "$R"/data/user/0/com.android.shell/cache/module-detection.tsv "$R"/data/user/0/*/cache/module-detection.tsv; do
		[ -f "$m" ] && { cache="$m"; break; }
	done
	local -A C_LEG=() C_MIN=() C_TGT=() C_DSC=()
	local pkg leg mn tg d
	if [ -n "$cache" ]; then
		while IFS=$'\t' read -r pkg leg mn tg d; do
			[ -n "$pkg" ] || continue
			C_LEG[$pkg]="$leg"; C_MIN[$pkg]="$mn"; C_TGT[$pkg]="$tg"; C_DSC[$pkg]="$d"
		done < <(LC_ALL=C awk "$LSP_CACHE_AWK" "$cache" 2>/dev/null)
		# CLI не ответил — список хотя бы из кэша, без статуса
		if [ "$cli_ok" -eq 0 ]; then
			list=""
			for pkg in "${!C_LEG[@]}"; do list+="$pkg"$'\t'"?"$'\n'; done
			list=$(printf '%s' "$list" | sort)
		fi
	fi

	sub="($fork${fwver:+ $fwver}${api:+ · API $api})"
	[ -e "$fwdir/disable" ] && sub="($fork${fwver:+ $fwver} · отключён)"
	section "МОДУЛИ LSPOSED" "$sub"
	[ "$cli_ok" -eq 0 ] && [ -n "$cli" ] && [ ! -e "$fwdir/disable" ] && note "CLI фреймворка не ответил — статус модулей неизвестен"
	# [3.11] Старый LSPosed без CLI и без кэша: список модулей скрипту не прочитать —
	# не пишем «модулей нет», а говорим, что нужен свежий Vector.
	if [ -z "$cli" ] && [ -z "$cache" ]; then
		emit "  ${YELLOW}Список модулей недоступен: нужен свежий форк Vector от JingMatrix (2.2+)${NC}"
		return 0
	fi
	if [ -z "$list" ]; then
		emit "  ${RED}Модули не установлены, не обнаружены или не активированы${NC}"
		return 0
	fi

	local st tag stc sp out ver cp apk name apis desc dref nocache=0
	local p_desc p_min p_tgt m_dsc m_min k a b c
	while IFS=$'\t' read -r pkg st; do
		[ -n "$pkg" ] || continue
		case "$st" in
			enabled)  st="вкл.";  stc="$GREEN" ;;
			disabled) st="выкл."; stc="$YELLOW" ;;
			*)        st="?";     stc="$DIM" ;;
		esac
		char_len "$st"; printf -v sp '%*s' $((8 - REPLY)) ""
		tag="${stc}${st}${NC}${sp}"

		out=$(dumpsys package "$pkg" 2>/dev/null)
		ver=$(printf '%s\n' "$out" | sed -n 's/^ *versionName=//p' | head -n 1)
		cp=$(printf '%s\n' "$out" | sed -n 's/^ *codePath=//p' | head -n 1)

		# Метаданные из APK: module.prop нового API и манифест (двоичный AXML)
		p_desc=""; p_min=""; p_tgt=""; m_dsc=""; m_min=""; dref=0
		apk="$R$cp/base.apk"
		if [ -n "$cp" ] && [ -f "$apk" ] && command -v unzip >/dev/null 2>&1; then
			out=$(unzip -p "$apk" META-INF/xposed/module.prop 2>/dev/null | tr -d '\r')
			if [ -n "$out" ]; then
				p_desc=$(printf '%s\n' "$out" | sed -n 's/^description=//p' | head -n 1)
				p_min=$(printf '%s\n' "$out" | sed -n 's/^minApiVersion=\([0-9]*\).*/\1/p' | head -n 1)
				p_tgt=$(printf '%s\n' "$out" | sed -n 's/^targetApiVersion=\([0-9]*\).*/\1/p' | head -n 1)
			fi
			while IFS=$'\t' read -r k a b c; do
				case "$k" in
					D) if [ "$a" = "@" ]; then dref=1; else printf -v m_dsc '%b' "$a"; fi ;;
					M) case "$a:$b" in
						xposeddescription:s) printf -v m_dsc '%b' "$c" ;;
						xposeddescription:r) dref=1 ;;
						xposedminversion:i) m_min="$c" ;;
						xposedminversion:s) m_min="${c%%[!0-9]*}" ;;
					   esac ;;
				esac
			done < <(unzip -p "$apk" AndroidManifest.xml 2>/dev/null | od -An -v -tu1 | LC_ALL=C awk "$LSP_AXML_AWK" 2>/dev/null)
		fi

		name="$pkg"

		# API: кэш → module.prop → xposedminversion
		# [3.10.1] Внутри «API 93 (старый)» — неразрывные пробелы (U+00A0, байты C2 A0):
		# перенос не отрывает «(старый)» от номера. На экране это обычный пробел.
		local nb=$'\xc2\xa0'
		apis=""
		if [ -n "${C_LEG[$pkg]+x}" ]; then
			if [ "${C_LEG[$pkg]}" = "1" ]; then
				[ "${C_MIN[$pkg]:-0}" -gt 0 ] && apis="API$nb${C_MIN[$pkg]}$nb(старый)"
			else
				a="${C_TGT[$pkg]:-0}"; [ "$a" -gt 0 ] || a="${C_MIN[$pkg]:-0}"
				[ "$a" -gt 0 ] && apis="API$nb$a"
			fi
		elif [ -n "$p_tgt$p_min" ]; then apis="API$nb${p_tgt:-$p_min}"
		elif [ -n "$m_min" ]; then apis="API$nb$m_min$nb(старый)"
		fi

		tag_line "$tag" "${BOLD}${name}${NC}${ver:+ ${DIM}·${NC} $ver}${apis:+ ${DIM}·${NC} $apis}"

		# Описание: кэш (уже из ресурсов, на языке системы) → module.prop → манифест
		desc=""
		if [ -n "${C_LEG[$pkg]+x}" ]; then
			printf -v desc '%b' "${C_DSC[$pkg]}"
			[ -z "$desc" ] && desc="описание отсутствует"
		elif [ -n "$p_desc" ]; then desc="$p_desc"
		elif [ -n "$m_dsc" ]; then desc="$m_dsc"
		elif [ "$dref" -eq 1 ]; then desc="описание недоступно"; nocache=1
		else desc="описание отсутствует"; fi
		desc="${desc//[[:cntrl:]]/ }"
		[ "$TERM_COLS" -eq 0 ] && [ ${#desc} -gt 160 ] && desc="${desc:0:157}..."
		wrap_emit 11 "${DIM}${desc}${NC}"
	done <<< "$list"
	[ "$nocache" -eq 1 ] && note "Описания хранятся в ресурсах APK: откройте список модулей в менеджере $fork — он сохранит их в кэш, и скрипт их покажет."
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
	is_int "${pg:-x}" && [ "$pg" -gt 0 ] && kv "Страница" "$((pg / 1024)) КБ"   # [3.11.1] без «0 КБ»
	if can_read "$R/proc/modules"; then
		local nmod; nmod=$(grep -c '' "$R/proc/modules" 2>/dev/null)
		kv "Модули ядра" "${nmod:-0} загружено"
	fi

	local tcp avail
	tcp=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
	avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
	kv "TCP" "${tcp:-?} ${DIM}(доступно: ${avail:-?})${NC}"
	if rd "$R/sys/module/wireguard/version"; then kv "WireGuard" "v$REPLY"; fi

	local hz=""
	can_read "$R/proc/config.gz" && hz=$( (zcat "$R/proc/config.gz" || gzip -dc "$R/proc/config.gz") 2>/dev/null | sed -n 's/^CONFIG_HZ=//p' | head -n 1)
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
	check_connections
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
		print_lsposed
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
  -e, --extended        расширенно: модули root и LSPosed, ядро, сборка, драйверы
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
		# [3.11.1] PID мог достаться другому процессу после падения прежнего монитора:
		# живым считаем только процесс, в командной строке которого есть имя скрипта.
		# Если cmdline не прочитать — осторожно считаем его живым.
		local cmd=""
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
			cmd=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline")
			[ -n "$cmd" ] && [[ "$cmd" != *"${0##*/}"* ]] && pid=""
		else
			pid=""
		fi
		if [ -n "$pid" ]; then
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
#
# Изменения v3.6 — по первому запуску на чужом устройстве (Redmi Note 13 Pro 5G):
#  скрипт переходит в «/» до запуска — без этого при старте из недоступной
#  root'у папки bash засыпал вывод ошибками getcwd.
#  Проверка «можно ли прочитать» — открытием файла (can_read), а не [ -r ]:
#  на ядрах, где faccessat врёт (KernelSU, Zen-Itsu), пропадали CPU, UFS,
#  ZRAM, PSI и статус AVB. DNS: несколько серверов выводятся через запятую
#  (с 3.1 они склеивались в «10.11.12.1310.11.12.14»).
#
# Изменения v3.7: батарея — технология, модель и подлинность (bms/Maxim), даты
#  производства и первого применения (Pixel), температура с десятыми, ёмкость
#  выше паспортной без «калибруется», «н/д» вместо 0 °C/0% при недоступных
#  данных, в -e — внутреннее сопротивление; СИСТЕМА -e — Bootloader и ревизия
#  платы. По аудиту ChatGPT: загрузка CPU «н/д» без /proc/stat, Zygisk не
#  называется сторонним, если настройку Magisk прочитать не удалось, PSI
#  считается и при одной строке, пояснение к MONITOR_SYSROOT.
#
# Изменения v3.7.1: «Bootloader» (-e) и «Модем» (Pixel) сверяются с версиями,
#  которые ожидает прошивка (ro.build.expect.*); при расхождении — ВНИМАНИЕ.
#
# Изменения v3.7.2: объём сброса zram на диск считается по реальному размеру
#  страницы (getconf PAGESIZE), а не по фиксированным 4 КБ — готовность к 16K.
#
# Изменения v3.8: «Батарея» — строка «Режимы» (максимум 80%, адаптивная зарядка,
#  защита батареи Pixel, энергосбережение, ограничение по температуре) со временем:
#  «полный заряд через ~N», «до 80% через ≈N», «зарядится к чч:мм»; строка
#  «Контроллер» — температура зарядки, USB-порта и ограничение зарядки из-за нагрева.
#  Охлаждение зарядки (chg_mdis, dc_icl) убрано из «Троттлинга», чтобы не дублировать.
#
# Изменения v3.8.1: «Питание» — «USB PD, быстрая · 8.3 В · до 20 Вт»: напряжение
#  с десятыми и единицей в тексте; предел мощности на Pixel из BatteryService.
#
# Изменения v3.9: «Топ процессов» в духе htop — замер за 1 с (второй кадр top),
#  таблицы «По процессору» и «По памяти» (5 строк, с -e — 10), строка «Задачи»,
#  длинные имена обрезаются посередине. Перенос длинных строк под колонку
#  значений по ширине терминала (MONITOR_COLS=N — вручную, 0 — выкл.).
#  «Сеть»: строка «Модем» — температура и ограничение из-за нагрева.
#
# Изменения v3.10: новая секция «Модули LSPosed» (-e, только если стоит LSPosed
#  или Vector): имя пакета, статус из CLI фреймворка, версия, API (новый / «старый»
#  XposedBridge), описание из кэша менеджера Vector 2.1+ или из APK. «Модули Magisk»: длинная строка модуля переносится
#  под название.
#
# Изменения v3.10.1: «Модули LSPosed» — «API 93 (старый)» переносится целиком
#  (неразрывные пробелы), а не обрывается перед «(старый)».
#
# Изменения v3.11: «Google Pixel» — последний замер приложения «Термометр»
#  предметов (Pixel 8 Pro – 10 Pro XL), прошивка Titan, сборка AICore (среда
#  Gemini Nano), сканер отпечатков, UWB. Проверено на Pixel 8 Pro.
#  «Модули LSPosed»: на старом LSPosed без CLI и кэша — подсказка про Vector 2.2+
#  вместо ложного «модулей нет».
#
# Изменения v3.11.1 (по независимому аудиту): блокировка --loop не принимает чужой
#  процесс с тем же PID за работающий монитор; «Ток» при статусах «заряжена» и
#  «не заряжается» — без знака с пометкой «направление не определено»;
#  строка «Страница» не выводит «0 КБ».
#
# Изменения v3.12: «Система» — часовой пояс со смещением от UTC. «Графика» —
#  плотность (dpi) и минимальная ширина (dp). «Google Pixel» — «Термометр» только
#  сообщает, есть ли датчик и как он называется; «AOC» — есть/нет цветом; новая
#  строка «DRM» (Widevine: программная или аппаратная защита, версия CDM).
#  Заголовок «Модули Magisk/KernelSU/APatch» — с версией менеджера; в «Root»
#  версия больше не дублируется.
#
# Изменения v3.12.1: «Система» — формат часов (12- или 24-часовой; если включено
#  «Использовать формат языка» — по первому языку системы).
#
# Изменения v3.13: новая секция «Другие подключения» под «Сетью»: Bluetooth
#  (вкл./выкл., подключённые устройства с кодеком и зарядом — у наушников с Fast
#  Pair по каждому наушнику и кейсу; с -e — сохранённые устройства), NFC с
#  контроллером и приложением бесконтактной оплаты, точка доступа (настройки,
#  а если работает — частоты, стандарт и клиенты), USB (источник питания,
#  OTG, скорость порта, функции), UWB (перенесён из «Google Pixel»), ИК-порт.
#
# Изменения v3.13.1: «Точка доступа» — имя без XML-экранирования
#  (было «&quot;Pixel 8 Pro&quot;»). Перенос строк: слово длиннее строки
#  (например, версия ядра 4.19.325-cip135-…) режется по дефисам, точкам, «=»
#  и «/» и продолжается
#  с колонки значений, а не с начала строки.
#
# Изменения v3.14: «Графика» — «Видеодекодер»: какие форматы телефон аппаратно
#  декодирует (если AV1 нет — «только программно»); с -e выше — «Видеокодер»
#  (аппаратное кодирование). Берётся из списков кодеков вендора. «Сеть» — диапазон
#  обслуживающей соты (LTE B7 · 20 МГц), агрегация частот (число несущих и
#  суммарная полоса) и 5G NSA.
