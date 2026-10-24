#!/system/bin/sh
# shellcheck shell=bash
#
# monitor.sh v3.18 — мониторинг состояния rooted Android
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
		/system_ext/bin/bash /system/xbin/bash /system/bin/bash /usr/bin/bash /bin/bash; do
		[ -n "$_b" ] && [ -x "$_b" ] && exec "$_b" "$_self" "$@"
	done
	echo "[!] Нужен bash (MT Manager / Termux)." >&2
	exit 3
fi

shopt -s extglob nullglob
# Байтовая локаль: ширину кириллических подписей считаем сами (см. kv),
# а printf/awk не путаются в многобайтовых символах на bionic.
export LC_ALL=C

readonly VERSION="3.18"

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

# ═════════════════════════════════════════════════════════════════════════════
#  [3.16] ФОНОВЫЕ ЗАДАЧИ И КЭШИ ПРОХОДА
# ═════════════════════════════════════════════════════════════════════════════
# Медленные внешние команды (dumpsys, settings, df, ping, CLI LSPosed) запускаются
# заранее в фоне (prefetch), а секции забирают готовый вывод через jget — в том же
# порядке, что и раньше, поэтому отчёт не меняется. Без фоновой задачи (например,
# с -d или если временную папку не создать) jget просто выполняет команду сам.
#
#   job  ИМЯ команда…  — запустить в фоне (повторный вызов с тем же именем — ничего)
#   jget ИМЯ команда…  — REPLY = вывод (как $(…), без хвостовых переводов строки),
#                        код возврата — код команды
#
# Вывод идёт в файл через «| cat»: settings и cmd пишут ответом system_server
# в наш дескриптор, а ему запрещено писать в файлы root (проба 3.16 на /sdcard).
# jget вызывается только в основном процессе — не внутри $(…), иначе wait не
# дождётся задачи.
JOB_DIR=""
declare -A JOB_PID=()
jobs_init() {
	jobs_done
	local d j
	for d in /dev /data/local/tmp "${TMPDIR:-}" /tmp; do
		[ -n "$d" ] && [ -d "$d" ] || continue
		j="$d/.goldenfrog_monitor.$$.jobs"
		rm -rf "$j" 2>/dev/null
		mkdir -m 700 "$j" 2>/dev/null && { JOB_DIR="$j"; return 0; }
	done
	return 1
}
# [3.17.1] Остановка задачи вместе с её потомками (dumpsys, settings, ping…):
# раньше kill доставался только подоболочке-обёртке, а сама команда дорабатывала.
# Потомки ищутся по PPID в /proc/<pid>/stat (поле после «) »), без pgrep.
kill_tree() {
	local p="$1" f st c kids=()
	for f in /proc/[0-9]*/stat; do
		IFS= read -r st 2>/dev/null < "$f" || continue
		st="${st##*) }"; st="${st#* }"           # «состояние ppid …» → «ppid …»
		[ "${st%% *}" = "$p" ] || continue
		c="${f#/proc/}"; kids+=("${c%/stat}")
	done
	kill "$p" 2>/dev/null
	for c in "${kids[@]}"; do kill_tree "$c"; done
}
jobs_done() {   # конец прохода: недождавшиеся задачи останавливаем, папку удаляем
	local n p
	for n in "${!JOB_PID[@]}"; do
		p="${JOB_PID[$n]}"
		[ "$p" = done ] && continue
		if [ -d "/proc/$p" ]; then kill_tree "$p"; fi
		wait "$p" 2>/dev/null
	done
	JOB_PID=()
	[ -n "$JOB_DIR" ] && rm -rf "$JOB_DIR" 2>/dev/null
	JOB_DIR=""
}
job() {
	local n="$1"; shift
	[ -n "$JOB_DIR" ] && [ -z "${JOB_PID[$n]:-}" ] || return 0
	# готовый вывод появляется под именем ИМЯ только целиком (mv), код — в ИМЯ.rc
	{ "$@" 2>/dev/null < /dev/null | cat > "$JOB_DIR/$n.part"; echo "${PIPESTATUS[0]}" > "$JOB_DIR/$n.rc"
	  mv -f "$JOB_DIR/$n.part" "$JOB_DIR/$n"; } 2>/dev/null &
	JOB_PID[$n]=$!
}
jget() {
	local n="$1" rc=0 i=0; shift
	if [ -n "${JOB_PID[$n]:-}" ]; then
		[ "${JOB_PID[$n]}" = done ] || { wait "${JOB_PID[$n]}" 2>/dev/null; JOB_PID[$n]=done; }
		# из подоболочки wait чужую задачу не ждёт — тогда ждём сам файл (до 60 с)
		while [ ! -f "$JOB_DIR/$n" ] && [ -d "$JOB_DIR" ] && [ "$i" -lt 1200 ]; do sleep 0.05; i=$((i + 1)); done
		# нулевые байты (бывают в дампах) bash отбрасывает — без предупреждения в stderr
		REPLY=""; [ -f "$JOB_DIR/$n" ] && { REPLY=$(< "$JOB_DIR/$n"); } 2>/dev/null
		IFS= read -r rc 2>/dev/null < "$JOB_DIR/$n.rc"
		is_int "${rc:-x}" || rc=1
		return "$rc"
	fi
	{ REPLY=$("$@" 2>/dev/null); } 2>/dev/null
}
jout() { [ -z "$REPLY" ] || printf '%s\n' "$REPLY"; }   # вывод jget — как из самой команды
# Перед замером top: чтобы фоновые команды не попали в замер. [3.16.1] Если
# какая-то ещё работала (её результата не было), ждём ещё 1 с: проба 3161 на
# Pixel 8 Pro — system_server после пачки dumpsys занят ~1,3 с (90 → 34%), потом
# возвращается к фону. Если всё давно готово — без паузы.
jobs_wait_all() {
	local n busy=0
	for n in "${!JOB_PID[@]}"; do
		[ "${JOB_PID[$n]}" = done ] && continue
		[ -f "$JOB_DIR/$n" ] || busy=1
		wait "${JOB_PID[$n]}" 2>/dev/null; JOB_PID[$n]=done
	done
	[ "$busy" -eq 1 ] && sleep 1
	return 0
}

# Настройки Android: «settings list» на пространство имён — один раз за проход
# вместо отдельного «settings get» на каждый ключ (каждый вызов ~0.1 с).
# sget ПРОСТРАНСТВО КЛЮЧ → REPLY, «null» для отсутствующего ключа — как settings get.
# Многострочное значение собирается из строк-продолжений. Большие JSON-значения
# подмены (spoof_pif_config, pi_pixel_device_cache) по-прежнему читаются через get.
declare -A SG_LOADED=() SG=()
# keybox подмены (spoof_trickystore_keybox) заменяется на «1» прямо в конвейере
# (вместе со строками-продолжениями, если значение многострочное): его содержимое
# не попадает ни во временный файл, ни в память скрипта.
settings_list_raw() {
	# [3.18] Внутри keybox новой записью считается только строка с ключом из строчных
	# букв (или конец XML): строка base64 из сертификата без отступа, оканчивающаяся
	# на «=», раньше принималась за новый ключ и проходила дальше в кэш.
	if [ "$1" = secure ]; then settings list secure 2>/dev/null | awk 's && /<\/AndroidAttestation>/ { s = 0; next }
		/^[a-z][a-z0-9_.]*=/ { s = 0 }
		/^spoof_trickystore_keybox=./ { print "spoof_trickystore_keybox=1"; s = 1; next } !s'
	else settings list "$1" 2>/dev/null; fi
}
settings_list() {   # settings_list ПРОСТРАНСТВО → REPLY = вывод «settings list»
	jget "sg_$1" settings_list_raw "$1"
}
sget_load() {
	local ns="$1" line k="" re='^([A-Za-z0-9_.:-]+)=(.*)$'
	SG_LOADED[$ns]=1
	settings_list "$ns"
	[ -n "$REPLY" ] || { SG_LOADED[$ns]=get; return 1; }   # list не ответил — по ключу
	while IFS= read -r line; do
		if [[ "$line" =~ $re ]]; then
			k="${BASH_REMATCH[1]}"; SG[$ns/$k]="${BASH_REMATCH[2]}"
		elif [ -n "$k" ]; then
			SG[$ns/$k]+=$'\n'"$line"
		fi
	done <<< "$REPLY"
}
sget() {
	[ -n "${SG_LOADED[$1]:-}" ] || sget_load "$1"
	if [ "${SG_LOADED[$1]}" = get ]; then REPLY=$(settings get "$1" "$2" 2>/dev/null); return 0; fi
	REPLY="${SG[$1/$2]-null}"
}
sg_reset() { SG_LOADED=(); SG=(); }

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
# [3.15.5] Знак отдельно: раньше −500 м°C выходило «0.5» (целая часть −0 = 0)
mdeg() { local a=${1#-} sg=""; [ "$1" != "$a" ] && sg="-"; REPLY="$sg$(( a / 1000 )).$(( ( a % 1000 ) / 100 ))"; }
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

# [3.16] КБ → «12.3 ГБ» арифметикой bash (раньше — отдельный awk на каждый вызов,
# ~50 мс на Pixel). Округление как у printf %.1f / %.0f: точная половина — к чётному.
hsize_kb() {
	local k="$1" q r
	if ! [[ "$k" =~ ^[0-9]+$ ]] || [ "${#k}" -gt 15 ]; then
		awk -v k="$k" 'BEGIN { if (k >= 1048576) printf "%.1f ГБ", k/1048576;
			else if (k >= 1024) printf "%.0f МБ", k/1024; else printf "%d КБ", k }'
		return
	fi
	k=$((10#$k))
	if [ "$k" -ge 1048576 ]; then
		q=$(( k * 10 / 1048576 )); r=$(( k * 10 % 1048576 ))
		{ [ "$r" -gt 524288 ] || { [ "$r" -eq 524288 ] && [ $((q % 2)) -eq 1 ]; }; } && q=$((q + 1))
		printf '%s.%s ГБ' "$((q / 10))" "$((q % 10))"
	elif [ "$k" -ge 1024 ]; then
		q=$(( k / 1024 )); r=$(( k % 1024 ))
		{ [ "$r" -gt 512 ] || { [ "$r" -eq 512 ] && [ $((q % 2)) -eq 1 ]; }; } && q=$((q + 1))
		printf '%s МБ' "$q"
	else
		printf '%s КБ' "$k"
	fi
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

# [3.17] f2fs на /data: сколько свободного места лежит в полностью чистых
# сегментах (free_segments × 2 МБ — сегмент f2fs всегда 512 блоков по 4 КБ).
# Остальное свободное место раздроблено по частично занятым сегментам (dirty_segments)
# и требует сборки мусора перед записью. gc_urgent ≠ 0 — прошивка включила срочную
# сборку. Проба 3170: Pixel 8 Pro — 68%, POCO F3 — 24% и GC_URGENT_MID.
# Это не «фрагментация файлов» и не fstrim — только состояние сегментов f2fs.
storage_f2fs() {   # storage_f2fs СВОБОДНО_КБ
	[ "$PART_LOADED" -eq 1 ] || load_partitions
	[ "${MFS[/data]:-}" = f2fs ] || return 0
	local dev="${MSRC[/data]##*/}" d fs="" gu="" free_kb pct
	d="$R/sys/fs/f2fs/$dev"
	rd "$d/free_segments" && is_int "$REPLY" && fs="$REPLY"
	[ -n "$fs" ] && is_int "${1:-x}" && [ "$1" -gt 0 ] || return 0
	free_kb=$(( fs * 2048 ))
	[ "$free_kb" -gt "$1" ] && free_kb="$1"
	pct=$(( free_kb * 100 / $1 ))
	rd "$d/gc_urgent" && gu="$REPLY"
	case "$gu" in ""|0|GC_NORMAL) gu="" ;; *) gu=" · ${YELLOW}срочная сборка${NC} ${DIM}($gu)${NC}" ;; esac
	kv "Сборка мусора" "чистые сегменты — $pct% свободного места ${DIM}($(hsize_kb "$free_kb") из $(hsize_kb "$1"))${NC}$gu"
}

# [3.17] Последнее обслуживание Android (StorageManager: fstrim и сборка мусора
# f2fs ночью на зарядке) — «Last maintenance: 2026-10-14 20:41:41» в dumpsys mount.
storage_maint() {
	local re='Last maintenance: ([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}:[0-9]{2})' ago="" t now
	jget mount dumpsys mount
	[[ "$REPLY" =~ $re ]] || return 0
	local y="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" dd="${BASH_REMATCH[3]}" hm="${BASH_REMATCH[4]}"
	t=$(date -d "$y-$m-$dd $hm" +%s 2>/dev/null)
	printf -v now '%(%s)T' -1
	if is_int "${t:-x}" && [ "$now" -ge "$t" ]; then
		t=$(( (now - t) / 86400 ))
		case "$t" in 0) ago="сегодня" ;; 1) ago="вчера" ;; *) ago="$t дн. назад" ;; esac
	fi
	kv "Обслуживание" "$dd.$m.$y $hm${ago:+ ${DIM}($ago)${NC}}"
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
	storage_f2fs "$avail"
	storage_maint
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
	elif can_read "$R/proc/device-tree/memory/ddr_device_type"; then
		# [3.15.4] Qualcomm: тип памяти в device tree — 32-битное число (big-endian).
		# 8 = LPDDR5 проверено на POCO F3 (SM8250, по спецификации LPDDR5); 7 = LPDDR4X
		# и 9 = LPDDR5X — по нумерации Qualcomm, на устройствах не проверены.
		# Неизвестный код не выводим.
		local dt
		dt=$(od -An -tu1 "$R/proc/device-tree/memory/ddr_device_type" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) v = v * 256 + $i } END { print v + 0 }')
		case "$dt" in 7) ddr="LPDDR4X" ;; 8) ddr="LPDDR5" ;; 9) ddr="LPDDR5X" ;; esac
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
		# [3.15.4] Явные подписи: слева — данные в zram (несжатые), справа — сколько
		# они занимают в RAM; объём самих устройств — в строке «Подкачка»
		kv "ZRAM" "$(hsize_kb $((o_sum / 1024))) данных → $(hsize_kb $((u_sum / 1024))) в памяти ${DIM}(сжатие ×$ratio)${NC}${algos:+ · ${algos// //}}$devs"
	elif [ "$nz" -gt 0 ]; then
		# [3.15.5] По аудиту: включённый, но пустой zram не должен выглядеть как отсутствующий
		kv "ZRAM" "пусто${algos:+ · ${algos// //}}$([ "$nz" -gt 1 ] && printf ' %s(%s устройства)%s' "$DIM" "$nz" "$NC")"
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
		# [3.15.4] В Linux load average считает и задачи, ждущие ввода-вывода или
		# ядра (состояние D), а не только занятые процессором. На F3 при зарядке
		# было 18 при 8 ядрах и загрузке 31% — «перегрузка» без нагрузки на CPU.
		# Поэтому, если загрузка измерена и ниже порога, очередь статус не поднимает,
		# а только поясняется строкой ниже.
		if [ "$la_lvl" -gt 0 ] && [ -n "$load" ] && [ "$load" -lt "$CPU_WARN" ]; then
			note "очередь задач большая при низкой загрузке — они ждут ввода-вывода или ядра, а не процессора"
			la_lvl=0
		fi
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

# [3.18] Профиль mi_thermald (Xiaomi): номер в /sys/class/thermal/thermal_message/sconfig
# → название. Таблица — из Parts дерева alioth (ThermalProfiles.kt, PocoF3Releases),
# названия — из его русского перевода. temp_state пишет сам mi_thermald: в пробе 3180
# 0 в покое и ненулевой код под нагрузкой; что значат разряды кода, не документировано,
# поэтому код показывается как есть. board_sensor_temp не обновляется — не используем.
declare -A MI_SCONFIG=([0]="Сбалансированный" [8]="Звонки" [9]="Игровой приоритет"
	[10]="Минимальный троттлинг" [11]="Консервативный" [12]="Камера" [19]="Навигация"
	[20]="Длительная игра" [21]="Воспроизведение видео" [30]="Сбалансированная производительность"
	[41]="Консервативная производительность" [49]="Производительность навигации"
	[51]="Производительность видео")
mi_thermal() {   # → REPLY: «mi_thermald · профиль «…» [· India] [· состояние N]»
	local d="$R/sys/class/thermal/thermal_message" sc="" ts="" s="mi_thermald ${DIM}(Xiaomi)${NC}"
	rd "$d/sconfig" && is_int "$REPLY" && sc="$REPLY"
	rd "$d/temp_state" && is_int "$REPLY" && ts="$REPLY"
	if [ -n "$sc" ]; then
		if [ -n "${MI_SCONFIG[$sc]:-}" ]; then s="$s · профиль «${MI_SCONFIG[$sc]}»"
		else s="$s · профиль $sc"; fi
	fi
	prop persist.sys.xiaomi.thermal.map; [ "$REPLY" = "india" ] && s="$s ${DIM}(India)${NC}"
	[ -n "$ts" ] && [ "$ts" != "0" ] && s="$s · ${YELLOW}состояние нагрева $ts${NC}"
	REPLY="$s"
}

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
	# [3.15.4] Qualcomm: датчики cpu-<группа>-<n>. Группа — физический кластер
	# ядер, и он не всегда совпадает с кластером частот: у Snapdragon 870 (F3)
	# группа 1 — это и средние ядра 4–6, и prime-ядро 7 (policy7). По device tree
	# F3: cpu-1-0…3 — датчики tsens 7…10 (верх ядер 4…7), cpu-1-4…7 — tsens 11…14
	# (низ ядер 4…7), как в sm8250.dtsi ядра Linux. Поэтому датчик n группы
	# относим к ядру (n mod число ядер группы), а ядро — к кластеру cpufreq.
	# Если групп столько же, сколько кластеров, получается прежний результат.
	if [ "$shown" -eq 0 ]; then
		local -A ccl=() cmx=()
		local -a gcores=()
		local nc=0 pp cc g k zn zi
		for pp in "$R"/sys/devices/system/cpu/cpufreq/policy*; do
			rd "$pp/related_cpus" || continue
			nc=$((nc + 1))
			for cc in $REPLY; do ccl[$cc]=$nc; done
		done
		for g in 0 1 2 3; do
			# ядра группы g: g-й кластер cpufreq; последняя группа — все оставшиеся
			gcores=()
			local last=1
			for k in "${!TZONE[@]}"; do [[ "$k" == cpu-$((g + 1))-* ]] && last=0; done
			for cc in $(printf '%s\n' "${!ccl[@]}" | sort -n); do
				if [ "${ccl[$cc]}" -eq $((g + 1)) ] || { [ "$last" -eq 1 ] && [ "${ccl[$cc]}" -gt $((g + 1)) ]; }; then gcores+=("$cc"); fi
			done
			for k in "${!TZONE[@]}"; do
				[[ "$k" =~ ^cpu-$g-([0-9]+)-usr$ ]] || continue
				zi="${BASH_REMATCH[1]}"
				if [ "${#gcores[@]}" -gt 0 ]; then zn="${ccl[${gcores[$((zi % ${#gcores[@]}))]}]}"; else zn=$((g + 1)); fi
				if [ -z "${cmx[$zn]:-}" ] || [ "${TZONE[$k]}" -gt "${cmx[$zn]}" ]; then cmx[$zn]="${TZONE[$k]}"; fi
			done
			# зон с -usr нет — берём любые cpu-g-* целиком на кластер g+1 (как раньше)
			if [ -z "${cmx[$((g + 1))]:-}" ] && zone_max "cpu-$g-*"; then
				[[ " ${!cmx[*]} " == *" $((g + 1)) "* ]] || cmx[$((g + 1))]="$REPLY"
			fi
		done
		for zn in $(printf '%s\n' "${!cmx[@]}" | sort -n); do
			mdeg "${cmx[$zn]}"; t="$REPLY"
			color_temp "$t"; kv "Кластер $zn" "$REPLY"; shown=1
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
	# [3.18] У Xiaomi (POCO F3 и др.) Thermal HAL нет по замыслу: нагревом управляет демон
	# mi_thermald по своим конфигам. Показываем его профиль, а не «HAL не готов».
	prop init.svc.mi_thermald
	if [ "$HAL_READY" = "false" ] && [ "$REPLY" = "running" ]; then
		mi_thermal; kv "Охлаждение" "$REPLY"
		kv "Перегрев" "${DIM}Android не видит — у Xiaomi нагревом управляет mi_thermald${NC}"
	elif [ "$HAL_READY" = "false" ]; then
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
		kv "Троттлинг" "${GREEN}нет${NC} ${DIM}(по данным ядра)${NC}"   # [3.15.5] по аудиту: не абсолютная гарантия
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
	jget wm_size wm size; wsz="$REPLY"
	res=$(printf '%s\n' "$wsz" | awk -F': ' '/Override/ {o=$2} /Physical/ {p=$2} END {print (o ? o " (физ. " p ")" : p)}')
	jget sf_latency dumpsys SurfaceFlinger --latency; period=$(jout | head -n 1)
	is_int "${period:-x}" && [ "$period" -gt 0 ] && hz=$(( (1000000000 + period / 2) / period ))
	detect_ltpo
	kv "Экран" "${res:-?}${hz:+ · $hz Гц}${REPLY:+ · $REPLY}"
	[ -n "$PANEL_MODEL" ] && kv "Панель" "$PANEL_MODEL"

	# [3.12] Плотность и минимальная ширина (smallest width, dp) — то, по чему
	# приложения выбирают раскладку. sw = короткая сторона × 160 / dpi, с
	# округлением, как в системе (Pixel 8 Pro: 1344 × 160 / 480 = 448 dp).
	# Если плотность или размер изменены (wm density / wm size), берём изменённые.
	local dens a b
	jget wm_density wm density; dens=$(jout | awk -F': ' '/Override/ {o=$2} /Physical/ {p=$2} END {print p " " o}')
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

	# [3.15.1] HDR-форматы экрана: HdrCapabilities из dumpsys display
	# (Display.HdrCapabilities: 1 Dolby Vision · 2 HDR10 · 3 HLG · 4 HDR10+)
	local hdr="" ht
	jget display dumpsys display
	for ht in $(jout | sed -n 's/.*mSupportedHdrTypes=\[\([0-9, ]*\)\].*/\1/p' | head -n 1 | tr ',' ' '); do
		case "$ht" in 1) ht="Dolby Vision" ;; 2) ht="HDR10" ;; 3) ht="HLG" ;; 4) ht="HDR10+" ;; *) continue ;; esac
		hdr="${hdr:+$hdr · }$ht"
	done
	[ -n "$hdr" ] && kv "HDR" "$hdr"

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
	local kind="$REPLY"   # jget перезапишет REPLY
	jget display dumpsys display; rates=$(jout | sed -n 's/.*mSupportedRefreshRates=\[\([^]]*\)\].*/\1/p' | head -n 1)
	REPLY="$kind"
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

# ── Камеры ──────────────────────────────────────────────────────────────────

# [3.15.2] Камеры (только с -e): характеристики из dumpsys media.camera.
# Блок «static information» — логическая камера; у Pixel внутри ещё «Physical
# camera N characteristics» — настоящие модули, их и берём. Одна камера в разных
# режимах (кроп, бининг) склеивается по направлению, фокусному и диафрагме.
# Мегапиксели — по полному разрешению: pixelArraySizeMaximumResolution (Pixel)
# или qcfa_dimension (Qualcomm quad-bayer, F3), иначе pixelArraySize.
# Эквивалент 35 мм = фокусное × 43.27 / диагональ сенсора. Роль: основная —
# задняя с самым большим сенсором; шире ×0.75 — широкий угол; длиннее ×1.5 —
# телефото, а при фокусе ближе 5 см (≥ 20 диоптрий) — макро.
CAM_AWK='# Вход: dumpsys media.camera. Выход: по строке на камеру (TAB):
# роль  Мп  f  экв_мм  ois  зум
function flush(   k, mp, d, eq, a) {
	if (!have) return
	have = 0
	if (logical && phys_seen) return          # логическая поверх физических — пропуск
	if (foc == "" || fl == "" || sw == "") return
	mp = pw * ph; if (mw * mh > mp) mp = mw * mh; if (qw * qh > mp) mp = qw * qh
	d = sqrt(sw * sw + sh * sh); if (d <= 0) return
	eq = fl * 43.27 / d
	k = foc SUBSEP fl SUBSEP ap
	# одна и та же камера в разных режимах (кроп, бининг): берём самый большой
	# сенсор, а мегапиксели и OIS — максимум по всем вариантам
	if (k in area) {
		if (mp > MP[k]) MP[k] = mp
		if (ois) OIS[k] = 1
		if (area[k] >= sw * sh) return
	} else { order[++n] = k; MP[k] = mp; OIS[k] = ois }
	area[k] = sw * sh; EQ[k] = eq; F[k] = ap; MF[k] = mf; FAC[k] = foc
}
function start() { flush(); have = 1; foc = fl = ap = sw = sh = ""; pw = ph = mw = mh = qw = qh = 0; ois = 0; mf = 0; logical = 0 }
function nums(s) { gsub(/[\[\]]/, "", s); return split(s, V, " ") }
/static information: ==/ { start(); phys_seen = 0; next }
/^== / { flush(); next }
/^ *Physical camera [0-9]+ characteristics:/ { phys_seen = 1; start(); next }
!have { next }
/android\.lens\.facing \(/ { getline; nums($0); foc = V[1]; next }
/android\.lens\.info\.availableApertures \(/ { getline; nums($0); ap = V[1] + 0; next }
/android\.lens\.info\.availableFocalLengths \(/ { getline; nums($0); fl = V[1] + 0; next }
/android\.lens\.info\.availableOpticalStabilization \(/ { getline; c = nums($0); for (i = 1; i <= c; i++) if (V[i] == 1) ois = 1; next }
/android\.lens\.info\.minimumFocusDistance \(/ { getline; nums($0); mf = V[1] + 0; next }
/android\.sensor\.info\.physicalSize \(/ { getline; nums($0); sw = V[1] + 0; sh = V[2] + 0; next }
/android\.sensor\.info\.pixelArraySize \(/ { getline; nums($0); pw = V[1] + 0; ph = V[2] + 0; next }
/android\.sensor\.info\.pixelArraySizeMaximumResolution \(/ { getline; nums($0); mw = V[1] + 0; mh = V[2] + 0; next }
/quadra_cfa\.qcfa_dimension \(/ { getline; nums($0); qw = V[1] + 0; qh = V[2] + 0; next }
/android\.logicalMultiCamera\.physicalIds \(/ { logical = 1; next }
END {
	flush()
	# основная — задняя с самым большим сенсором
	best = ""; for (i = 1; i <= n; i++) { k = order[i]; if (FAC[k] == "BACK" && (best == "" || area[k] > area[best])) best = k }
	nf = 0
	for (i = 1; i <= n; i++) {
		k = order[i]; z = ""
		if (FAC[k] == "FRONT") role = (++nf > 1) ? "Фронтальная " nf : "Фронтальная"
		else if (FAC[k] != "BACK") role = "Внешняя"
		else if (k == best) role = "Основная"
		else if (EQ[k] < EQ[best] * 0.75) role = "Широкий угол"
		else if (EQ[k] > EQ[best] * 1.5 && MF[k] >= 20) role = "Макро"
		else if (EQ[k] > EQ[best] * 1.5) { role = "Телефото"; z = sprintf("%.1f", int(EQ[k] + 0.5) / int(EQ[best] + 0.5)) }
		else role = "Камера"
		r = (role == "Основная") ? 1 : (role == "Широкий угол") ? 2 : (role == "Телефото") ? 3 : (role == "Макро") ? 4 : (role == "Камера") ? 5 : 6
		m = MP[k] / 1e6; if (m >= 20) m = int(m); else m = int(m * 10) / 10
		printf "%d\t%s\t%s\t%.3g\t%d\t%d\t%s\n", r, role, m, F[k], EQ[k] + 0.5, OIS[k], z
	}
}
'

check_cameras() {
	local rows
	jget camera dumpsys media.camera; rows=$(jout | awk "$CAM_AWK" 2>/dev/null | sort -n -k1,1)
	[ -n "$rows" ] || return 0
	section "КАМЕРЫ"
	# [3.15.5] Модели сенсоров — только где прошивка их называет: Xiaomi пишет
	# persist.vendor.camera.mi.module.info(ext) = «back_main=imx582;back_ultra=imx355_i;…».
	# Pixel отдаёт лишь внутренние кодовые имена Google (lwis-sensor-dokkaebi…) —
	# их не расшифровываем.
	local -A SNS=()
	local mi kvp key val; local -a _mi
	prop persist.vendor.camera.mi.module.info; mi="$REPLY"
	prop persist.vendor.camera.mi.module.infoext; mi="$mi;$REPLY"
	IFS=';' read -r -a _mi <<< "$mi"
	for kvp in "${_mi[@]}"; do
		key="${kvp%%=*}"; val="${kvp#*=}"; [ "$key" != "$kvp" ] && [ -n "$val" ] || continue
		val="${val%%_*}"; val="${val^^}"
		case "$val" in
			IMX*) val="Sony $val" ;; S5K*) val="Samsung $val" ;; OV*) val="OmniVision $val" ;;
			HI*) val="Hynix Hi${val#HI}" ;; GC*) val="GalaxyCore $val" ;; JN*|HM*|GN*|HP*) val="Samsung ISOCELL $val" ;;
		esac
		case "$key" in
			back_main) SNS[Основная]="$val" ;; back_ultra|back_wide) SNS["Широкий угол"]="$val" ;;
			back_tele*) SNS[Телефото]="$val" ;; back_macro*) SNS[Макро]="$val" ;;
			front_main) SNS[Фронтальная]="$val" ;;
		esac
	done
	local r role mp f eq ois z line
	while IFS=$'\t' read -r r role mp f eq ois z; do
		[ -n "$role" ] || continue
		line="$mp Мп · f/$f · $eq мм${z:+ ${DIM}(×$z)${NC}}"
		[ "$ois" = "1" ] && line="$line · OIS"
		[ -n "${SNS[$role]:-}" ] && line="$line · ${SNS[$role]}"
		kv "$role" "$line"
	done <<< "$rows"
	return 0
}

# ── Батарея ──────────────────────────────────────────────────────────────────

# [3.16] Секция разделена на сбор и вывод: bat_read читает узлы в BAT_*, каждая
# строка отчёта собирается своей функцией (значение — в REPLY, пусто — строки нет),
# а check_battery только печатает их по порядку. Логика строк — прежняя.
BAT=""; BMS=""
BAT_CAP=""; BAT_STATUS=""; BAT_TEMP=""; BAT_TDEG=""; BAT_VOLT=""; BAT_CUR=""
BAT_HEALTH=""; BAT_CYCLES=""; BAT_FULL=""; BAT_DESIGN=""; BAT_TECH=""
BAT_DBAT=""; BAT_USB_IN=0; BAT_SRC=""; BAT_SHARE=""; BAT_CUR_KNOWN=0

bat_read() {   # узлы батареи → BAT_*; нет батареи — код 1
	BAT="$R/sys/class/power_supply/battery"; BMS="$R/sys/class/power_supply/bms"
	BAT_CAP=""; BAT_STATUS=""; BAT_TEMP=""; BAT_TDEG=""; BAT_VOLT=""; BAT_CUR=""
	BAT_HEALTH=""; BAT_CYCLES=""; BAT_FULL=""; BAT_DESIGN=""; BAT_TECH=""
	[ -d "$BAT" ] || return 1
	rd "$BAT/capacity" && is_int "$REPLY" && BAT_CAP="$REPLY"
	rd "$BAT/status"; BAT_STATUS="$REPLY"
	if rd "$BAT/temp" && is_int "$REPLY"; then
		BAT_TEMP=$((REPLY / 10))                     # целые °C — для порога
		BAT_TDEG=$(awk -v t="$REPLY" 'BEGIN { printf "%.1f", t / 10 }')
	fi
	rd "$BAT/voltage_now" && is_int "$REPLY" && [ "$REPLY" -gt 0 ] && BAT_VOLT=$((REPLY / 1000))
	rd "$BAT/current_now" && is_int "$REPLY" && BAT_CUR="$REPLY"
	rd "$BAT/health"; BAT_HEALTH="$REPLY"
	rd "$BAT/cycle_count"; BAT_CYCLES="$REPLY"
	rd "$BAT/charge_full"; BAT_FULL="$REPLY"
	rd "$BAT/charge_full_design"; BAT_DESIGN="$REPLY"
	rd "$BAT/technology"; BAT_TECH="$REPLY"

	# Знак тока у вендоров разный (Pixel: разряд < 0, Qualcomm: разряд > 0) — приводим к
	# «минус = разряд» по статусу
	# [3.18] Топливомер Qualcomm (есть power_supply/bms) всегда отдаёт «плюс = разряд»:
	# так пишет Health HAL alioth, проба 3180 подтвердила (от батареи +, на зарядке −).
	# Знак берётся из драйвера, а не из статуса: на зарядке под нагрузкой батарея может
	# разряжаться, и при «заряжена» / «не заряжается» направление тоже известно.
	# [3.18] Pixel (драйвер google,charger) отдаёт «минус = разряд» и при «не заряжается»:
	# проба bd — защита батареи на кабеле, 100%, ток −414…−522 мА, уровень уходит к 80%.
	BAT_CUR_KNOWN=0
	if [ -n "$BAT_CUR" ] && [ -f "$BMS/current_now" ]; then
		BAT_CUR=$(( -BAT_CUR )); BAT_CUR_KNOWN=1
	elif [ -n "$BAT_CUR" ] && [ -d "$R/sys/devices/platform/google,charger" ]; then
		BAT_CUR_KNOWN=1
	elif [ -n "$BAT_CUR" ]; then
		case "$BAT_STATUS" in
			Discharging) [ "$BAT_CUR" -gt 0 ] && BAT_CUR=$(( -BAT_CUR )) ;;
			Charging) [ "$BAT_CUR" -lt 0 ] && BAT_CUR=$(( -BAT_CUR )) ;;
		esac
	fi
	return 0
}

bat_level() {   # «Уровень»
	local st_ru
	case "$BAT_STATUS" in
		Charging) st_ru="${GREEN}заряжается${NC}" ;;
		Discharging) st_ru="разряжается" ;;
		Full) st_ru="${GREEN}заряжена${NC}" ;;
		"Not charging") st_ru="${YELLOW}не заряжается${NC}" ;;
		*) st_ru="${BAT_STATUS:-?}" ;;
	esac
	local cap_c=""
	[ -n "$BAT_CAP" ] && [ "$BAT_STATUS" = "Discharging" ] && [ "$BAT_CAP" -lt 20 ] && cap_c="$RED"
	local cap_s="н/д"
	[ -n "$BAT_CAP" ] && cap_s="${cap_c}${BAT_CAP}%${cap_c:+$NC}"
	REPLY="$cap_s · $st_ru"
}

# [3.15] Прогноз Device Health Services (как в настройках «Батарея»): DHS пишет
# в settings global время расчёта (battery_estimates_last_update_time, мс) и
# сколько осталось на тот момент (time_remaining_estimate_millis). Конец =
# расчёт + остаток. Только при разрядке и если прогноз ещё не прошёл.
# Как SettingsLib (PowerUtil): время окончания округляется до ближайших
# 15 минут — иначе строка расходится со шторкой на пару минут.
bat_estimate() {   # «Хватит до»
	local out=""
	if [ "$BAT_STATUS" = "Discharging" ]; then
		local est upd use end now day wd
		settings_list global; est=$(printf '%s\n' "$REPLY" | grep -E '^(battery_estimates_last_update_time|time_remaining_estimate_millis|time_remaining_estimate_based_on_usage)=')
		upd=$(printf '%s\n' "$est" | sed -n 's/^battery_estimates_last_update_time=//p')
		end=$(printf '%s\n' "$est" | sed -n 's/^time_remaining_estimate_millis=//p')
		use=$(printf '%s\n' "$est" | sed -n 's/^time_remaining_estimate_based_on_usage=//p')
		printf -v now '%(%s)T' -1
		if is_int "${upd:-x}" && is_int "${end:-x}" && [ "$end" -gt 0 ]; then
			end=$(( (upd + end) / 1000 ))
			end=$(( (end + 450) / 900 * 900 ))
			if [ "$end" -gt "$now" ]; then
				printf -v day '%(%Y%m%d)T' "$end"
				if [ "$day" = "$(printf '%(%Y%m%d)T' -1)" ]; then printf -v wd '%(%H:%M)T' "$end"
				else
					printf -v wd '%(%u)T' "$end"
					case "$wd" in 1) wd="пн" ;; 2) wd="вт" ;; 3) wd="ср" ;; 4) wd="чт" ;; 5) wd="пт" ;; 6) wd="сб" ;; 7) wd="вс" ;; esac
					printf -v wd '%s %(%H:%M)T' "$wd" "$end"
				fi
				out="$wd${use:+ ${DIM}($([ "$use" = 1 ] && echo "по использованию" || echo "по среднему расходу"))${NC}}"
			fi
		fi
	fi
	REPLY="$out"
}

# Источник питания → BAT_SRC («Питание»), BAT_SHARE («Battery Share»), BAT_USB_IN.
# [3.8.1] Формат «USB PD, быстрая · 8.3 В · до 20 Вт»: единицы прямо в тексте
# (раньше «(8 В)» читалось двусмысленно), напряжение с десятыми.
bat_source() {
	local src="" ps tp pmax="" usb_hv=0
	BAT_USB_IN=0; BAT_SRC=""; BAT_SHARE=""
	# [3.15.5] dumpsys battery — один раз: предел мощности и режим зарядки
	jget battery dumpsys battery; BAT_DBAT="$REPLY"
	for ps in "$R"/sys/class/power_supply/*; do
		rd "$ps/online" && [ "$REPLY" = "1" ] || continue
		rd "$ps/type"; tp="$REPLY"
		case "${ps##*/}:$tp" in
			wireless:*|*:Wireless) src="беспроводная" ;;
			usb:*|*:USB*)
				BAT_USB_IN=1
				local uv=0 proto="USB"
				rd "$ps/voltage_now" && is_int "$REPLY" && uv=$((REPLY / 1000))
				case "$tp" in USB_PD*) proto="USB PD" ;; esac   # [3.7] протокол, если драйвер сообщает
				# [3.15.5] Слово скорости ставим ниже, по мощности, как Android
				if [ "$uv" -gt 6000 ]; then
					src="$proto · $(awk -v v="$uv" 'BEGIN { printf "%.1f", v / 1000 }') В"; usb_hv=1
				elif [ -z "$src" ]; then src="$proto"; fi
				# Предел мощности от драйвера (Qualcomm power_max)
				rd "$ps/power_max" && is_int "$REPLY" && [ "$REPLY" -gt 0 ] && [ "$REPLY" -lt 500 ] && pmax="$REPLY" ;;
			*:Mains|main:*|ac:*) [ -z "$src" ] && src="сеть" ;;
		esac
	done
	# [3.8.1] Иначе — договорённость телефона с зарядником из BatteryService
	# (Max charging current × voltage, Pixel): это предел, а не текущая мощность.
	if [ -n "$src" ] && [ -z "$pmax" ] && [ "$src" != "беспроводная" ]; then
		pmax=$(printf '%s\n' "$BAT_DBAT" | awk -F': ' '
			/Max charging current:/ { i = $2 + 0 } /Max charging voltage:/ { v = $2 + 0 }
			END { if (i > 0 && v > 0) { w = i * v / 1e12; if (w >= 1 && w < 500) printf "%.0f", w } }')
	fi
	# [3.15.5] Скорость зарядки — как в SettingsLib BatteryStatus.getChargingSpeed():
	# мощность = Max charging current × Max charging voltage (напряжение 0 → 5 В),
	# меньше 5 Вт — медленная, больше 7,5 Вт — быстрая, между — обычная
	# (config_chargingSlowlyThreshold / config_chargingFastThreshold). Нет данных
	# сервиса — по пределу драйвера (power_max), иначе по напряжению > 6 В, как раньше.
	if [ "$BAT_USB_IN" -eq 1 ] && [ -n "$src" ]; then
		local mw spd=""
		mw=$(printf '%s\n' "$BAT_DBAT" | awk -F': ' '
			/Max charging current:/ { i = $2 + 0 } /Max charging voltage:/ { v = $2 + 0 }
			END { if (v <= 0) v = 5000000; if (i > 0) printf "%d", (i / 1000) * (v / 1000) }')
		if is_int "${mw:-x}" && [ "$mw" -gt 0 ]; then
			if [ "$mw" -lt 5000000 ]; then spd="медленная"; elif [ "$mw" -gt 7500000 ]; then spd="быстрая"; else spd="обычная"; fi
		elif is_int "${pmax:-x}"; then
			if [ "$pmax" -lt 5 ]; then spd="медленная"; elif [ "$pmax" -gt 7 ]; then spd="быстрая"; else spd="обычная"; fi
		elif [ "$usb_hv" -eq 1 ]; then spd="быстрая"
		fi
		[ -n "$spd" ] && src="${src%% · *}, $spd${src#"${src%% · *}"}"
	fi
	[ -n "$pmax" ] && src="$src · до $pmax Вт"
	# Battery Share (обратная беспроводная) — Pixel: отдельной строкой.
	# [3.15.1] Узлы беспроводного чипа: wireless/device/rtx_status (available →
	# active) и rtx (0 → 1). [3.15.5] Пробы 3155/3155b на Pixel 8 Pro: «active» и
	# когда Battery Share включён и ждёт устройство на задней панели, и когда Pixel
	# сам ненадолго включает его при подключении кабеля («Включать автоматически»,
	# settings global settings_key_reverse_charging_auto_turn_on=1). Отдельной
	# настройки основного переключателя и порога остановки в settings нет.
	# Прежние reverse_chg_mode / wireless_out остаются запасным путём для других устройств.
	local rn bs="" wd="$R/sys/class/power_supply/wireless/device" bsauto
	if [ -e "$wd/rtx_status" ] || [ -e "$wd/rtx" ]; then
		sget global settings_key_reverse_charging_auto_turn_on; bsauto="$REPLY"
		if { rd "$wd/rtx_status" && [ "$REPLY" = "active" ]; } || { rd "$wd/rtx" && [ "$REPLY" = "1" ]; }; then
			if [ "$BAT_USB_IN" -eq 1 ] && [ "$bsauto" = "1" ]; then
				bs="${MAGENTA}вкл.${NC} ${DIM}(ненадолго, автовключение при подключении кабеля)${NC}"
			else
				bs="${MAGENTA}вкл.${NC} ${DIM}(беспроводная раздача заряда)${NC}"
			fi
		elif [ "$bsauto" = "1" ]; then
			bs="выкл. ${DIM}· включится ненадолго при подключении кабеля${NC}"
		else
			bs="выкл."
		fi
	else
		for rn in "$R/sys/class/power_supply/wireless/reverse_chg_mode" "$R/sys/class/power_supply/wireless/wireless_out"; do
			rd "$rn" && [ "$REPLY" = "1" ] && { src="${MAGENTA}раздаёт заряд (Battery Share)${NC}"; break; }
		done
	fi
	BAT_SRC="$src"; BAT_SHARE="$bs"
}

# [3.8] Режимы зарядки и время до заряда («Режим»). Переключатели живут в Settings
# Intelligence / SystemUI, но применяются через Health HAL — читаем результат
# в ядре, стандартные узлы healthd (AOSP, Android 14+):
#   charging_policy: 1 обычная · 2 LONG_LIFE («Максимум 80%») · 3 ADAPTIVE
#   charging_state:  1 обычная · 2 холодно · 3 жарко · 4 LONG_LIFE · 5 ADAPTIVE
# Где узлов нет (F3: HAL отвечает INVALID), режимы не выдумываем.
bat_modes() {
	local b="$BAT" status="$BAT_STATUS" cap="$BAT_CAP"
	local pol="" cst="" modes="" eta="" bd v
	rd "$b/charging_policy" && is_int "$REPLY" && pol="$REPLY"
	rd "$b/charging_state" && is_int "$REPLY" && cst="$REPLY"
	# [3.15.5] Pixel 8 Pro (Android 17) пишет в charging_policy свой код 4 при
	# «Максимум 80%», а BatteryService отдаёт уже стандартный (AIDL
	# BatteryChargingPolicy: 1 обычная · 2 LONG_LIFE · 3 ADAPTIVE) — берём его.
	v=$(printf '%s\n' "$BAT_DBAT" | sed -n 's/^ *Charging policy: *//p' | head -n 1)
	# Особые режимы (2, 3) из BatteryService главнее; «1» не перекрывает узел ядра,
	# чтобы не потерять адаптивную зарядку, если сервис её не отражает.
	is_int "${v:-x}" && { [ "$v" = "2" ] || [ "$v" = "3" ]; } && pol="$v"
	v=$(printf '%s\n' "$BAT_DBAT" | sed -n 's/^ *Charging state: *//p' | head -n 1)
	is_int "${v:-x}" && [ "$v" -ge 2 ] && [ "$v" -le 5 ] && cst="$v"
	# [3.15.5] Выбранный режим виден и без кабеля: «Максимум 80%» BatteryService
	# отдаёт всегда (2), а адаптивная до начала зарядки не видна в политике —
	# берём настройку secure adaptive_charging_enabled (проба 3155b; «Максимум 80%»
	# там же — charge_optimization_mode=1, оба 0 — оптимизация выключена).
	# Во время зарядки не подставляем: там важно, работает ли режим сейчас.
	if [ "$status" = "Discharging" ] && [ "$pol" != "2" ] && [ "$pol" != "3" ] && { sget secure adaptive_charging_enabled; [ "$REPLY" = "1" ]; }; then
		pol=3
	fi
	case "$pol" in 2) modes="максимум 80%" ;; 3) modes="адаптивная зарядка" ;; esac
	case "$cst" in
		2) modes="${modes:+$modes · }${YELLOW}ограничена: холодно${NC}" ;;
		3) modes="${modes:+$modes · }${YELLOW}ограничена: жарко${NC}" ;;
	esac
	# Battery Defender (Pixel): сам ограничивает заряд, если телефон долго на
	# зарядке в тепле. DISCONNECTED/CONNECTED — штатные состояния «не активен».
	prop vendor.battery.defender.state; bd="$REPLY"
	case "$bd" in ""|DISCONNECTED|CONNECTED) bd="" ;; *) modes="${modes:+$modes · }${YELLOW}защита батареи${NC} ${DIM}($bd)${NC}" ;; esac
	# [3.18] На Android 17 (Pixel 8 Pro) свойство при активной защите остаётся CONNECTED,
	# и ни dumpsys battery, ни узлы bd_* драйвера её не выдают: решение принимает демон
	# google_battery, а видно его только по уведомлению SystemUI с тегом battery_defender
	# (проба bd). Смахнутое уведомление монитор не увидит.
	if [ -z "$bd" ] && [ -d "$R/sys/devices/platform/google,charger" ]; then
		jget notif_list cmd notification list
		[[ "$REPLY" == *"|com.android.systemui|"*"|battery_defender|"* ]] &&
			modes="${modes:+$modes · }${YELLOW}защита батареи${NC} ${DIM}(долго была тёплой на зарядке)${NC}"
	fi
	# [3.15.5] Энергосбережение — в конце строки, после подсказки режима зарядки,
	# иначе «… · энергосбережение · включится при зарядке» читалось как про него.
	local saver=""
	sget global low_power; [ "$REPLY" = "1" ] && saver="энергосбережение"

	if [ "$status" = "Charging" ] && [ -n "$cap" ] && [ "$cap" -lt 100 ]; then
		local ttf="" dl="" ua=0 now tgt=100 rate_eta="" full="$BAT_FULL"
		rd "$b/time_to_full_now" && is_int "$REPLY" && [ "$REPLY" -gt 0 ] && ttf="$REPLY"
		rd "$b/charge_deadline" && is_int "$REPLY" && [ "$REPLY" -gt 0 ] && dl="$REPLY"
		# [3.18] Только ток заряда: при известном знаке на зарядке он может быть и разрядным
		[ -n "$BAT_CUR" ] && [ "$BAT_CUR" -gt 0 ] && ua="$BAT_CUR"
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
	elif [ "$status" = "Discharging" ] && [ "$pol" = "2" ]; then
		eta="${DIM}включится при зарядке${NC}"
	elif [ "$status" = "Discharging" ] && [ "$pol" = "3" ]; then
		# [3.15.5] Ближайший будильник — из AlarmManager («Next alarm clock
		# information: user:0 … time:<мс>»), работает с любым приложением часов.
		# Как подсказка: Pixel может подстраиваться и по привычкам, без будильника.
		local al alh="" ald now_d
		al=$(dumpsys alarm 2>/dev/null | sed -n '/Next alarm clock information/{n;s/.*user:0 .*time:\([0-9][0-9]*\).*/\1/p;q}')
		if is_int "${al:-x}" && [ "$al" -gt 0 ]; then
			al=$((al / 1000))
			printf -v ald '%(%Y%m%d)T' "$al"; printf -v now_d '%(%Y%m%d)T' -1
			printf -v alh '%(%H:%M)T' "$al"
			if [ "$ald" != "$now_d" ]; then
				printf -v ald '%(%u)T' "$al"
				case "$ald" in 1) ald="пн" ;; 2) ald="вт" ;; 3) ald="ср" ;; 4) ald="чт" ;; 5) ald="пт" ;; 6) ald="сб" ;; 7) ald="вс" ;; esac
				alh="$ald $alh"
			fi
		fi
		eta="${DIM}включится при долгой зарядке, обычно ночью${alh:+ · будильник $alh}${NC}"
	elif [ "$pol" = "2" ] && [ "$status" = "Not charging" ]; then
		# [3.15.5] Упёрлись в лимит: драйвер Google держит заряд между
		# charge_start_level и charge_stop_level (Pixel 8 Pro: 77 и 80)
		local gstart=""
		rd "$R/sys/devices/platform/google,charger/charge_start_level" && is_int "$REPLY" && gstart="$REPLY"
		eta="зарядка остановлена${gstart:+ ${DIM}(возобновится ниже $gstart%)${NC}}"
	fi
	modes="$modes${eta:+${modes:+ · }$eta}"
	[ -n "$saver" ] && modes="${modes:+$modes · }$saver"
	REPLY="$modes"   # [3.14.1] строка «Режим» (было «Режимы»)
}

bat_health() {   # «Здоровье»: ёмкость по датчику к паспортной
	local hp="" h_ru full="$BAT_FULL" design="$BAT_DESIGN"
	case "$BAT_HEALTH" in
		Good) h_ru="хорошее" ;; Overheat) h_ru="${RED}перегрев${NC}" ;; Dead) h_ru="${RED}неисправна${NC}" ;;
		Cold) h_ru="холодная" ;; "Over voltage") h_ru="${RED}перенапряжение${NC}" ;; *) h_ru="${BAT_HEALTH:-н/д}" ;;
	esac
	if is_int "${full:-x}" && is_int "${design:-x}" && [ "$design" -gt 0 ] && [ "$full" -gt 0 ]; then
		local pct=$(( full * 100 / design ))
		if [ "$pct" -lt 80 ]; then hp="${YELLOW}$pct%${NC} ${DIM}($((full / 1000)) из $((design / 1000)) мА·ч)${NC}"
		else hp="$pct% ${DIM}($((full / 1000)) из $((design / 1000)) мА·ч)${NC}"; fi
	fi
	REPLY="$h_ru${hp:+ · ёмкость $hp}"
}

# [3.7] Паспорт батареи («Батарея»): технология, модель, подлинность, даты (что есть)
bat_passport() {
	local b="$BAT" bms="$BMS" info="" btype="" auth="" mdate="" fdate=""
	if rd "$bms/battery_type" && [ -n "$REPLY" ] && [ "$REPLY" != "Unknown" ]; then btype="$REPLY"; fi
	if rd "$bms/authentic" && is_int "$REPLY"; then auth="$REPLY"
	elif rd "$R/sys/class/power_supply/batt_verify/authen_result" && is_int "$REPLY"; then auth="$REPLY"; fi
	if rd "$b/manufacturing_date" && is_int "$REPLY" && [ "$REPLY" -gt 946684800 ]; then
		printf -v mdate '%(%d.%m.%Y)T' "$REPLY"
	fi
	if rd "$b/first_usage_date" && is_int "$REPLY" && [ "$REPLY" -gt 946684800 ]; then
		printf -v fdate '%(%d.%m.%Y)T' "$REPLY"
	fi
	[ -n "$BAT_TECH" ] && info="$BAT_TECH"
	[ -n "$btype" ] && info="${info:+$info · }$btype"
	case "$auth" in
		1) info="${info:+$info · }${GREEN}подлинная${NC}" ;;
		0) info="${info:+$info · }${YELLOW}не прошла проверку подлинности${NC}" ;;
	esac
	[ -n "$mdate" ] && info="${info:+$info · }произведена $mdate"
	[ -n "$fdate" ] && info="${info:+$info · }в работе с $fdate"
	REPLY="$info"
}

bat_temp() {   # «Температура»
	if [ -n "$BAT_TDEG" ]; then
		local tc=""
		[ "$BAT_TEMP" -ge "$BATT_TEMP_WARN" ] && tc="$RED"
		REPLY="${tc}${BAT_TDEG}°C${tc:+$NC}"
	else
		REPLY="н/д"
	fi
}

# [3.8] Контроллер заряда («Контроллер»): температура и ограничение зарядки из-за
# нагрева. Pixel: зоны charge_therm / usb_pwr_therm, охлаждение chg_mdis, dc_icl;
# Qualcomm: зона charger_therm0 (или battery/charger_temp), охлаждение battery.
bat_controller() {
	local ct="" usbt="" lim="" cd ctype ccur cmax out=""
	if zone_max 'charge_therm' || zone_max 'charger_therm*'; then mdeg "$REPLY"; color_temp "$REPLY"; ct="$REPLY"
	elif rd "$BAT/charger_temp" && is_int "$REPLY" && [ "$REPLY" -gt 0 ]; then
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
		out="$cl${lim:+ · $lim}"
	fi
	REPLY="$out"
}

bat_current() {   # «Ток» (или «Напряжение», если тока нет): REPLY_K — подпись
	REPLY=""; REPLY_K=""
	if [ -n "$BAT_CUR" ] && [ -n "$BAT_VOLT" ]; then
		local ma=$((BAT_CUR / 1000)) w dir=""
		w=$(awk -v v="$BAT_VOLT" -v i="$ma" 'BEGIN { printf "%.2f", v * i / 1000000 }')
		# [3.11.1] Знак приводится только при «заряжается»/«разряжается». При «заряжена»,
		# «не заряжается» и неизвестном статусе направление по драйверу не определить
		# (у Qualcomm и Pixel знак противоположный) — показываем модуль без знака.
		case "$BAT_STATUS" in
			Charging|Discharging) ;;
			*) [ "$BAT_CUR_KNOWN" -eq 1 ] || { ma=${ma#-}; dir=" ${DIM}(направление не определено)${NC}"; } ;;
		esac
		# [3.18] Зарядка есть, а батарея садится: нагрузка больше, чем даёт зарядное
		[ "$BAT_STATUS" = "Charging" ] && [ "$BAT_CUR" -lt 0 ] && dir=" ${YELLOW}(нагрузка больше зарядки)${NC}"
		REPLY_K="Ток"; REPLY="$ma мА$dir · ${w#-} Вт · $BAT_VOLT мВ"
	elif [ -n "$BAT_VOLT" ]; then
		REPLY_K="Напряжение"; REPLY="$BAT_VOLT мВ"
	fi
}

# [3.7] Внутреннее сопротивление (-e): растёт с износом. Драйверы отдают его в мкОм
# без документации единиц, поэтому только в расширенном режиме и с пометкой.
bat_resistance() {
	local res="" rn
	for rn in "$BAT/resistance" "$BMS/resistance"; do
		rd "$rn" && is_int "$REPLY" && [ "$REPLY" -gt 0 ] && { res="$REPLY"; break; }
	done
	REPLY=""
	[ -n "$res" ] && REPLY="$(( (res + 500) / 1000 )) мОм ${DIM}(внутреннее, по датчику)${NC}"
}

# [3.7] Батарея: нет данных — «н/д», а не 0 °C / 0% (раньше пустое чтение
# выглядело как реальный ноль). Температура с десятыми, ёмкость больше паспортной
# показывается как есть (у новой батареи это норма, паспорт — гарантированный
# минимум). Добавлены технология, даты производства и первого применения (Pixel),
# модель и подлинность батареи (Qualcomm bms / Maxim), в -e — сопротивление.
check_battery() {
	section "БАТАРЕЯ"
	if ! bat_read; then kv "Батарея" "нет данных"; return; fi

	bat_level;      kv "Уровень" "$REPLY"
	bat_estimate;   [ -n "$REPLY" ] && kv "Хватит до" "$REPLY"
	bat_source
	[ -n "$BAT_SRC" ] && kv "Питание" "$BAT_SRC"
	[ -n "$BAT_SHARE" ] && kv "Battery Share" "$BAT_SHARE"
	bat_modes;      [ -n "$REPLY" ] && kv "Режим" "$REPLY"
	bat_health;     kv "Здоровье" "$REPLY"
	is_int "${BAT_CYCLES:-x}" && kv "Циклы" "$BAT_CYCLES"
	bat_passport;   [ -n "$REPLY" ] && kv "Батарея" "$REPLY"
	bat_temp;       kv "Температура" "$REPLY"
	bat_controller; [ -n "$REPLY" ] && kv "Контроллер" "$REPLY"
	bat_current;    [ -n "$REPLY" ] && kv "$REPLY_K" "$REPLY"
	[ -n "$BAT_CUR" ] && note "Ток: минус — разряд, плюс — заряд."
	if [ "$EXTENDED" -eq 1 ]; then
		bat_resistance; [ -n "$REPLY" ] && kv "Сопротивление" "$REPLY"
	fi

	if [ -n "$BAT_TEMP" ] && [ "$BAT_TEMP" -ge "$BATT_TEMP_WARN" ]; then
		verdict 1 "батарея перегрета: ${BAT_TDEG}°C"
	elif [ -z "$BAT_CAP" ] && [ -z "$BAT_TEMP" ]; then
		verdict 1 "данные батареи недоступны"
	else
		verdict 0 ""
	fi
}

# ── Wakelock ────────────────────────────────────────────────────────────────

check_wakelocks() {
	section "WAKELOCK" "(удержание пробуждения)"
	local raw
	jget power dumpsys power; raw=$(jout | sed -n '/Wake Locks: size=/,/^[[:space:]]*$/p' | grep 'PARTIAL_WAKE_LOCK')
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
	jget connectivity dumpsys connectivity; recs=$(jout | awk '
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
			# [3.15] Качество сигнала — по порогам уровней Android (−55/−66/−77/−88 дБм)
			local q=""
			if is_int "${rssi:-x}"; then
				if   [ "$rssi" -ge -55 ]; then q="отлично"
				elif [ "$rssi" -ge -66 ]; then q="хорошо"
				elif [ "$rssi" -ge -77 ]; then q="средне"
				elif [ "$rssi" -ge -88 ]; then q="слабо"
				else q="очень слабо"; fi
			fi
			NET_WIFI="«$ssid»${fr:+ · $fr МГц}${rssi:+ · $rssi дБм}${q:+ ${DIM}($q)${NC}}${ls:+ · $ls Мбит/с}"
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

# [3.15.5] Название модема → REPLY. Pixel: версия baseband «g5300i-…» — модем
# Exynos 5300 (g5123 → 5123, g5400 → 5400). Qualcomm со встроенным модемом — по
# модели SoC (ro.soc.model), только для известных чипов; иначе пусто.
modem_name() {
	local bb soc
	prop gsm.version.baseband; bb="${REPLY%%,*}"
	REPLY=""
	if [[ "$bb" =~ ^g([0-9]{4})[a-z]?- ]]; then REPLY="Exynos ${BASH_REMATCH[1]}"; return; fi
	prop ro.soc.model; soc="$REPLY"; REPLY=""
	case "$soc" in
		SM8250*) REPLY="Snapdragon X55" ;; SM8350*) REPLY="Snapdragon X60" ;;
		SM8450*|SM8475*) REPLY="Snapdragon X65" ;; SM8550*) REPLY="Snapdragon X70" ;;
		SM8650*) REPLY="Snapdragon X75" ;; SM8750*) REPLY="Snapdragon X80" ;;
	esac
}

# [3.16] Секция «Сеть» разделена так же, как «Батарея»: каждая строка (или группа
# строк) собирается своей функцией, check_network печатает их по порядку.
# Маршрут, siminfo и пинги приходят из предзагрузки (jget), логика строк прежняя.
net_route_raw() { (timeout 2 ip route get 8.8.8.8 || ip route get 8.8.8.8) 2>/dev/null | head -n 1; }
NET_DEV=""; NET_SRC=""
net_route() {   # маршрут в интернет → NET_DEV, NET_SRC
	local route
	jget route net_route_raw; route="$REPLY"
	NET_DEV=$(printf '%s' "$route" | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i+1); exit } }')
	NET_SRC=$(printf '%s' "$route" | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i+1); exit } }')
}

net_connection() {   # «Подключение»
	local dev="$NET_DEV" kind=""
	case "$dev" in
		wlan*)        kind="Wi-Fi" ;;
		rmnet*|ccmni*|seth*) kind="мобильная сеть" ;;
		rndis*|usb*)  kind="USB-модем" ;;
		tun*|wg*|ppp*) kind="VPN" ;;
		"")           kind="" ;;
		*)            kind="$dev" ;;
	esac
	if [ -z "$kind" ]; then
		REPLY="${RED}нет маршрута в интернет${NC}"
		return
	fi
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
	REPLY="${GREEN}$kind${NC}$via ${DIM}($dev)${NC}"
}

# [3.15] Защита и стандарт подключения — из «cmd wifi status» (WifiInfo:
# «Security type: 2, … Wi-Fi standard: 11ac»). Номера — WifiInfo.SECURITY_TYPE_*.
net_wifi() {   # «Wi-Fi»
	REPLY=""
	[ -n "$NET_WIFI" ] || return 0
	local wi wsec wstd
	jget wifi_status cmd wifi status; wi=$(jout | sed -n 's/^WifiInfo: //p' | head -n 1)
	wsec=$(printf '%s' "$wi" | sed -n 's/.*Security type: \([0-9]*\).*/\1/p')
	wstd=$(printf '%s' "$wi" | sed -n 's/.*Wi-Fi standard: \([0-9a-z]*\).*/\1/p')
	case "$wsec" in
		0) wsec="${YELLOW}открытая сеть${NC}" ;; 1) wsec="${YELLOW}WEP${NC}" ;; 2) wsec="WPA2" ;;
		3) wsec="WPA2-Enterprise" ;; 4) wsec="WPA3" ;; 5|9) wsec="WPA3-Enterprise" ;; 6) wsec="OWE" ;;
		7|8) wsec="WAPI" ;; 11|12) wsec="Passpoint" ;; 13) wsec="DPP" ;; *) wsec="" ;;
	esac
	case "$wstd" in
		11n) wstd="Wi-Fi 4" ;; 11ac) wstd="Wi-Fi 5" ;; 11ax) wstd="Wi-Fi 6" ;; 11be) wstd="Wi-Fi 7" ;;
		11ad) wstd="WiGig" ;; legacy|11a|11b|11g) wstd="Wi-Fi 1–3" ;; *) wstd="" ;;
	esac
	REPLY="$NET_WIFI${wsec:+ · $wsec}${wstd:+ · $wstd}"
}

# [3.14] Диапазон обслуживающей соты; несколько несущих — агрегация (CA).
net_bands() {   # строки «Диапазон» → REPLY_A
	REPLY_A=()
	local bl ph typ bands bw bws rat ovr nc tot b line pre
	jget telephony dumpsys telephony.registry; bl=$(jout | awk "$BAND_AWK" 2>/dev/null)
	while IFS=$'\t' read -r ph typ bands bw bws rat ovr; do
		[ -n "$typ" ] || continue
		bands="${bands#[}"; bands="${bands%]}"; bws="${bws#[}"; bws="${bws%]}"
		line=""; pre=""
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
		REPLY_A+=("$line ${DIM}(SIM$((ph + 1)))${NC}")
	done <<< "$bl"
}

# [3.15.1] Звонки через IMS: переключатели VoLTE и Wi-Fi Calling активной SIM
# (siminfo; -1 = «как в общих настройках» → settings global). Регистрацию IMS
# Android наружу не отдаёт (cmd phone ims только переключает), поэтому пишем,
# что включено, а не что работает. «принудительно» — доступность включена в
# обход оператора (persist.dbg.volte_avail_ovr / wfc_avail_ovr).
net_siminfo_raw() {
	content query --uri content://telephony/siminfo --projection sim_id:volte_vt_enabled:wfc_ims_enabled:wfc_ims_mode 2>/dev/null \
		| grep -E 'sim_id=[0-9]' | head -n 1
}
net_calls() {   # «Звонки»
	local si sv_vo sv_wf sv_wm call=""
	REPLY=""
	jget siminfo net_siminfo_raw; si="$REPLY"
	[ -n "$si" ] || { REPLY=""; return 0; }
	sv_vo=$(printf '%s' "$si" | sed -n 's/.*volte_vt_enabled=\(-\{0,1\}[0-9]*\).*/\1/p')
	sv_wf=$(printf '%s' "$si" | sed -n 's/.*wfc_ims_enabled=\(-\{0,1\}[0-9]*\).*/\1/p')
	sv_wm=$(printf '%s' "$si" | sed -n 's/.*wfc_ims_mode=\(-\{0,1\}[0-9]*\).*/\1/p')
	case "$sv_vo" in 0|1) ;; *) sget global enhanced_4g_mode_enabled; sv_vo="$REPLY" ;; esac
	case "$sv_wf" in 0|1) ;; *) sget global wfc_ims_enabled; sv_wf="$REPLY" ;; esac
	case "$sv_wm" in 0|1|2) ;; *) sget global wfc_ims_mode; sv_wm="$REPLY" ;; esac
	case "$sv_vo" in 1) call="VoLTE ${GREEN}вкл.${NC}" ;; 0) call="VoLTE выкл." ;; esac
	case "$sv_wf" in
		1) call="${call:+$call · }Wi-Fi Calling ${GREEN}вкл.${NC}"
		   case "$sv_wm" in
			0) call="$call ${DIM}(только Wi-Fi)${NC}" ;;
			1) call="$call ${DIM}(предпочт. моб. сеть)${NC}" ;;
			2) call="$call ${DIM}(предпочт. Wi-Fi)${NC}" ;;
		   esac ;;
		0) call="${call:+$call · }Wi-Fi Calling выкл." ;;
	esac
	local ovr1 ovr2
	prop persist.dbg.volte_avail_ovr; ovr1="$REPLY"; prop persist.dbg.wfc_avail_ovr; ovr2="$REPLY"
	[ -n "$call" ] && { [ "$ovr1" = "1" ] || [ "$ovr2" = "1" ]; } && call="$call · принудительно"
	REPLY="$call"
}

# [3.14.1] Частный DNS (DNS-over-TLS): off / opportunistic («авто», он же
# значение по умолчанию, если настройки нет) / hostname + адрес сервера
net_private_dns() {   # «Частный DNS»
	local pdm
	sget global private_dns_mode; pdm="$REPLY"
	case "$pdm" in
		off)      REPLY="выкл." ;;
		hostname) sget global private_dns_specifier; REPLY="${GREEN}${REPLY:-?}${NC}" ;;
		*)        REPLY="авто ${DIM}(если сеть поддерживает)${NC}" ;;
	esac
}

# [3.9] Модем («Модем»): температура и ограничение сети из-за нагрева.
# Pixel (модем Exynos): зоны cp_on_chip_*, ограничение — статус датчика
# усилителя cellular-emergency в Thermal HAL (отдельных устройств охлаждения нет).
# Qualcomm: зоны modem-N-usr, ограничение — устройства охлаждения modem_*.
net_modem() {
	local mt="" mlim="" cd ctype ccur cmax why
	if zone_max 'cp_on_chip_*' || zone_max 'modem-[0-9]-usr'; then
		mdeg "$REPLY"; color_temp "$REPLY"; mt="$REPLY"
		for cd in "$R"/sys/class/thermal/cooling_device*; do
			IFS= read -r ctype 2>/dev/null < "$cd/type" || continue
			case "$ctype" in modem_*) ;; *) continue ;; esac
			IFS= read -r ccur 2>/dev/null < "$cd/cur_state" || continue
			is_int "$ccur" && [ "$ccur" -gt 0 ] || continue
			IFS= read -r cmax 2>/dev/null < "$cd/max_state"
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
		modem_name; REPLY="$mt${REPLY:+ · $REPLY}${mlim:+ · $mlim}"
		return 0
	fi
	REPLY=""
}

# Доступность: 3 пинга на хост; среднее и разброс (mdev) из той же серии.
# [3.16] Проверка 1 пакетом и сама серия идут в предзагрузке по всем трём хостам
# сразу; хост выбирается в прежнем порядке — первый ответивший из списка.
# [3.17.2] Каждый ping ограничен по времени целиком: -W ждёт только ответ, а имя
# хоста (google.com) ping разрешает сам и без ограничения. Живой прогон на Pixel
# с VPN и частным DNS: «Модем» → «Интернет» заняло 11 с при закрытом ICMP.
net_tmo() {   # net_tmo СЕКУНДЫ команда… — с timeout, если он есть (в toybox есть)
	local s="$1"; shift
	if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; else "$@"; fi
}
net_ping_raw() {   # net_ping_raw ХОСТ: 1 пакет, затем серия из 3; код — успех серии
	net_tmo 3 ping -c 1 -W 1 "$1" >/dev/null 2>&1 || return 1
	net_tmo 4 ping -c 3 -i 0.3 -W 1 "$1" 2>/dev/null || net_tmo 4 ping -c 3 -W 1 "$1" 2>/dev/null
}
NET_PING_HOST=""; NET_PING_LAT=""
net_ping() {   # → NET_PING_HOST (пусто — ни один не ответил), NET_PING_LAT («Задержка»)
	local host out avg mdev loss
	NET_PING_HOST=""; NET_PING_LAT=""
	for host in 1.1.1.1 8.8.8.8 google.com; do
		jget "ping_$host" net_ping_raw "$host" || continue
		out="$REPLY"
		NET_PING_HOST="$host"
		# iputils: «rtt min/avg/max/mdev = a/b/c/d ms», toybox: «round-trip min/avg/max = a/b/c ms»
		read -r avg mdev <<< "$(printf '%s\n' "$out" | awk '/^rtt|^round-trip/ {
			v = $0; sub(/.*= */, "", v); sub(/ *ms.*/, "", v); n = split(v, a, "/")
			print a[2], (n >= 4 ? a[4] : "?"); exit }')"
		loss=$(printf '%s\n' "$out" | grep -oE '[0-9]+% packet loss' | cut -d'%' -f1)
		[ -n "$avg" ] && NET_PING_LAT="${avg%.*} мс · разброс ${mdev%.*} мс${loss:+ · потери $loss%}"
		return 0
	done
	return 1
}

check_network() {
	section "СЕТЬ"
	net_route
	load_connectivity
	net_connection;  kv "Подключение" "$REPLY"
	[ -n "$NET_SRC" ] && kv "Локальный IP" "$NET_SRC"
	net_wifi;        [ -n "$REPLY" ] && kv "Wi-Fi" "$REPLY"
	mobile_info && kv "Сотовая" "$REPLY"
	local l
	net_bands;       for l in "${REPLY_A[@]}"; do kv "Диапазон" "$l"; done
	net_calls;       [ -n "$REPLY" ] && kv "Звонки" "$REPLY"
	[ -n "$NET_DNS" ] && kv "DNS" "$NET_DNS"
	net_private_dns; kv "Частный DNS" "$REPLY"
	net_modem;       [ -n "$REPLY" ] && kv "Модем" "$REPLY"

	local ok=0
	if net_ping; then
		ok=1
		kv "Интернет" "${GREEN}есть${NC} ${DIM}(ping $NET_PING_HOST)${NC}"
		[ -n "$NET_PING_LAT" ] && kv "Задержка" "$NET_PING_LAT"
	fi
	if [ "$ok" -eq 0 ] && command -v curl >/dev/null 2>&1; then
		if curl -s -o /dev/null -m 4 -w '%{http_code}' http://clients3.google.com/generate_204 2>/dev/null | grep -q 204; then
			ok=1
			kv "Интернет" "${GREEN}есть${NC} ${DIM}(HTTP; ICMP закрыт)${NC}"
		fi
	# [3.16.1] curl нет (на Pixel он только у MT Manager: запуск не из MT под VPN
	# писал «интернета нет») — TCP-соединение средствами bash: /dev/tcp, таймаут
	# toybox. Проба 3161: работает на обоих телефонах, имена тоже разрешаются.
	elif [ "$ok" -eq 0 ] && command -v timeout >/dev/null 2>&1; then
		local th
		for th in 1.1.1.1 8.8.8.8; do
			if timeout 3 "${BASH:-bash}" -c "exec 3<>/dev/tcp/$th/443" 2>/dev/null; then
				ok=1
				kv "Интернет" "${GREEN}есть${NC} ${DIM}(TCP $th:443; ICMP закрыт)${NC}"
				break
			fi
		done
	fi
	if [ "$ok" -eq 0 ]; then
		verdict 1 "интернета нет"
	fi
	# [3.2] Подсказка про iperf3 — строкой этой же секции, серым
	if [ "$ENABLE_NET_TEST" -ne 1 ] && command -v iperf3 >/dev/null 2>&1; then
		kv "${DIM}Тест скорости${NC}" "${DIM}доступен (iperf3): запусти с --net-speed${NC}"
	fi
}

# [3.15.4] Скорость из строки «receiver» iperf3 — по-русски, как в строке Wi-Fi:
# «68.3 Mbits/sec» → «68.3 Мбит/с» (также Kbits / Gbits / bits)
IPERF_RATE_AWK='/receiver/ { u = $(NF-1); sub(/bits\/sec$/, "", u)
	r = (u == "K") ? "Кбит/с" : (u == "M") ? "Мбит/с" : (u == "G") ? "Гбит/с" : (u == "") ? "бит/с" : $(NF-1)
	print $(NF-2), r }'

check_iperf3_speed() {
	[ "$BRIEF_MODE" -eq 1 ] && return
	[ "$ENABLE_NET_TEST" -ne 1 ] && return   # [3.2] подсказка теперь в секции «СЕТЬ»
	section "СКОРОСТЬ СЕТИ" "(iperf3)"
	if ! command -v iperf3 >/dev/null 2>&1; then
		kv "iperf3" "не установлен"
		return
	fi
	# [3.15.4] Публичные серверы со своими портами (список iperf.fr и
	# iperf3-public-servers-list, проверено пробой 10.2026). Раньше все шли на
	# 5201: ping.online.net слушает 5200–5209, bouygues.iperf.fr переехал на
	# *.iperf.bytel.fr (9200–9240), serverius — speedtest1.serverius.net:5002.
	# Каждый сервер принимает один тест за раз: «busy» — пробуем другой порт.
	# [3.15.5] По аудиту: без timeout каждый недоступный сервер вис бы надолго,
	# а итог выглядел как «серверы недоступны» — говорим прямо.
	if ! command -v timeout >/dev/null 2>&1; then
		kv "iperf3" "${YELLOW}нет команды timeout${NC} ${DIM}(нужна для ограничения теста)${NC}"
		return
	fi
	# [3.15.5] Общий предел — 60 с на поиск сервера; при неудаче — сводка причин
	note "Идёт тест, обычно 15–20 секунд, не больше минуты…"
	local server down up hp host lo hi port try out rc t0=$SECONDS
	local n_busy=0 n_to=0 n_ref=0 n_dns=0 n_oth=0
	for hp in ping.online.net:5200-5209 speedtest1.serverius.net:5002-5002 paris.bbr.iperf.bytel.fr:9200-9240 \
		speedtest.milkywan.fr:9200-9240 iperf3.moji.fr:5200-5240 speedtest.kamel.network:5201-5205 iperf.he.net:5201-5201; do
		[ $((SECONDS - t0)) -ge 60 ] && break
		host="${hp%%:*}"; lo="${hp#*:}"; hi="${lo#*-}"; lo="${lo%-*}"
		for try in 1 2 3; do
			port=$((lo + RANDOM % (hi - lo + 1)))
			out=$(timeout 8 iperf3 -c "$host" -p "$port" -R -t 5 2>&1); rc=$?
			down=$(printf '%s\n' "$out" | awk "$IPERF_RATE_AWK")
			[ -n "$down" ] && break
			[[ "$out" == *busy* ]] || break      # не «занят» — сервер недоступен, дальше
		done
		if [ -z "$down" ]; then
			case "$out" in
				*busy*) n_busy=$((n_busy + 1)) ;;
				*resolve*|*"Name or service"*|*"No address"*) n_dns=$((n_dns + 1)) ;;
				*refused*|*unreachable*) n_ref=$((n_ref + 1)) ;;
				*) if [ "$rc" -eq 124 ]; then n_to=$((n_to + 1)); else n_oth=$((n_oth + 1)); fi ;;
			esac
			continue
		fi
		server="$host:$port"
		kv "Сервер" "$server"
		kv "Загрузка" "$down"
		up=$(timeout 8 iperf3 -c "$host" -p "$port" -t 5 2>/dev/null | awk "$IPERF_RATE_AWK")
		kv "Отдача" "${up:-не удалось}"
		return
	done
	local why=""
	[ "$n_busy" -gt 0 ] && why="${why:+$why, }заняты: $n_busy"
	[ "$n_to" -gt 0 ] && why="${why:+$why, }не отвечают: $n_to"
	[ "$n_ref" -gt 0 ] && why="${why:+$why, }отказ в подключении: $n_ref"
	[ "$n_dns" -gt 0 ] && why="${why:+$why, }имя не найдено: $n_dns"
	[ "$n_oth" -gt 0 ] && why="${why:+$why, }другая ошибка: $n_oth"
	[ $((SECONDS - t0)) -ge 60 ] && why="${why:+$why, }прервано через минуту"
	kv "iperf3" "${YELLOW}серверы недоступны${NC}${why:+ ${DIM}($why)${NC}}"
}

# ── Logcat ───────────────────────────────────────────────────────────────────

logcat_errors() { logcat -b main,system,crash -d '*:E' 2>/dev/null | grep -v '^--------- beginning of' | tail -n 2000; }
check_logcat() {
	section "ОШИБКИ LOGCAT" "(main, system, crash)"
	if [ "$NO_LOGCAT" -eq 1 ]; then
		kv "Logcat" "пропущен (--no-logcat)"
		return
	fi
	local errors c
	jget logcat logcat_errors; errors="$REPLY"
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
	# [3.16] Сначала дожидаемся фоновых команд, чтобы они не попали в замер
	jobs_wait_all
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

# [3.16] Разделы и их точки монтирования — один проход по mountinfo за проход;
# нужен и секции «Разделы», и предзагрузке (один df на все разделы сразу).
declare -A MFS=() MOPT=() MSRC=()
PART_LIST=()   # «раздел точка» в порядке вывода
PART_LOADED=0
load_partitions() {
	MFS=(); MOPT=(); MSRC=(); PART_LIST=(); PART_LOADED=1
	local mp fs opt src part target
	while IFS='|' read -r mp fs opt src; do
		[ -n "${MFS[$mp]:-}" ] && continue
		MFS[$mp]="$fs"; MOPT[$mp]="$opt"; MSRC[$mp]="$src"
	done < <(awk '{ for (i = 1; i <= NF; i++) if ($i == "-") { print $5 "|" $(i+1) "|" $6 "|" $(i+2); break } }' "$R/proc/self/mountinfo")
	for part in system system_ext product vendor odm cache data metadata persist; do
		target=""
		case "$part" in
			system)  for mp in /system / /system_root; do [ -n "${MFS[$mp]:-}" ] && [ "${MFS[$mp]}" != "tmpfs" ] && [ "${MFS[$mp]}" != "rootfs" ] && { target="$mp"; break; }; done ;;
			persist) for mp in /persist /mnt/vendor/persist; do [ -n "${MFS[$mp]:-}" ] && { target="$mp"; break; }; done ;;
			*)       [ -n "${MFS[/$part]:-}" ] && target="/$part" ;;
		esac
		[ -n "$target" ] && PART_LIST+=("$part $target")
	done
}
part_targets() {   # REPLY_A — точки монтирования для df
	local pt; REPLY_A=()
	for pt in "${PART_LIST[@]}"; do REPLY_A+=("${pt#* }"); done
}

check_partitions() {
	section "РАЗДЕЛЫ"
	[ "$PART_LOADED" -eq 1 ] || load_partitions
	# Один df на все разделы; строки сопоставляем по устройству (первая колонка
	# совпадает с источником в mountinfo). Не нашлось строки — df по разделу, как раньше.
	local -A DFL=()
	local dev a b c
	part_targets
	if [ "${#REPLY_A[@]}" -gt 0 ]; then
		jget df_parts df -k "${REPLY_A[@]}"
		while read -r dev a b c _; do
			[[ "$a" =~ ^[0-9]+$ ]] && [ -z "${DFL[$dev]:-}" ] && DFL[$dev]="$a $b $c"
		done <<< "$REPLY"
	fi

	local part target acc size used avail line pt
	for pt in "${PART_LIST[@]}"; do
		part="${pt%% *}"; target="${pt#* }"
		case ",${MOPT[$target]}," in *,ro,*) acc="ro" ;; *,rw,*) acc="rw" ;; *) acc="??" ;; esac
		line="${DFL[${MSRC[$target]}]:-}"
		[ -n "$line" ] || line=$(df -k "$target" 2>/dev/null | awk 'NR > 1 && $2 ~ /^[0-9]+$/ { print $2, $3, $4; exit }')
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

# [3.17.2] «Другие подключения» разделены на сбор и вывод, как «Батарея» и «Сеть»:
# каждая строка (или группа строк) собирается своей функцией conn_*, значение —
# в REPLY или в глобальных CONN_*/BT_*; check_connections только печатает по
# порядку. Логика строк прежняя, отчёт не меняется.
CONN_TETHER=""
conn_tether() {   # интерфейсы раздачи интернета (wlan…, rndis, ncm, bt-pan) → CONN_TETHER
	jget tethering dumpsys tethering
	CONN_TETHER=$(jout | awk '/^  Tether state:/ { f = 1; next } f && /^  [A-Za-z]/ { exit } f && / - TetheredState/ { printf "%s ", $1 }')
}

# ── Bluetooth → BT_HEAD («Bluetooth»; пусто — секции нет), BT_CONN (строки
# подключённых устройств), BT_SAVED_N и BT_SAVED (сохранённые, только с -e)
BT_HEAD=""; BT_SAVED_N=0
declare -a BT_CONN=() BT_SAVED=()
conn_bluetooth() {
	BT_HEAD=""; BT_CONN=(); BT_SAVED=(); BT_SAVED_N=0
	local bt typ mac c tr cod name
	jget bluetooth dumpsys bluetooth_manager; bt=$(jout | LC_ALL=C awk "$BT_AWK" 2>/dev/null)
	[ -n "$bt" ] || return 0
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
	if [ "$state" != "ON" ]; then
		BT_HEAD="выкл."
		return 0
	fi
	local extra=""
	[[ " $CONN_TETHER" == *" bt-pan "* ]] && extra=" · режим модема"
	if [ "$n_on" -gt 0 ]; then
		BT_HEAD="${GREEN}вкл.${NC} · подключено: $n_on$extra"
	else
		BT_HEAD="${GREEN}вкл.${NC}$extra"
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
		BT_CONN+=("${BOLD}${BN[$d]:-$d}${NC}${ch:+ · $ch}${bat:+ · $bat}$fp")
	done
	if [ "$EXTENDED" -eq 1 ] && [ "${#macs[@]}" -gt 0 ]; then
		BT_SAVED_N="${#macs[@]}"
		for d in "${macs[@]}"; do
			bt_type "${BC[$d]}" "${MD[$d|device_type]:-}"
			BT_SAVED+=("${BN[$d]:-$d}${REPLY:+ ${DIM}· $REPLY${NC}}")
		done
	fi
}

# [3.14.1] LE Audio и Auracast — по профилям, включённым в стеке Bluetooth:
#   bap.unicast.client — LE Audio (наушники по LE);
#   bap.broadcast.source — сам телефон ведёт трансляцию Auracast;
#   bap.broadcast.assist — помогает наушникам подключиться к чужой трансляции.
conn_le_audio() {   # «LE Audio»
	local lea="" aur=""
	prop bluetooth.profile.bap.unicast.client.enabled; [ "$REPLY" = "true" ] && lea=1
	prop bluetooth.profile.bap.broadcast.source.enabled; [ "$REPLY" = "true" ] && aur="трансляция"
	prop bluetooth.profile.bap.broadcast.assist.enabled; [ "$REPLY" = "true" ] && aur="${aur:+$aur и }подключение"
	REPLY=""
	[ -n "$lea$aur" ] || return 0
	if [ -n "$lea" ]; then lea="${GREEN}есть${NC}"; else lea="нет"; fi
	REPLY="$lea${aur:+ · Auracast: $aur}"
}

# ── NFC и бесконтактная оплата → CONN_NFC («NFC»; пусто — строк нет), CONN_PAY
# («Оплата»). Приложение оплаты с Android 15 — системная роль кошелька
# («Current wallet payment service»), а не настройка nfc_payment_default_component;
# на старых — «Preferred payment service».
CONN_NFC=""; CONN_PAY=""
conn_nfc() {
	CONN_NFC=""; CONN_PAY=""
	local nfc
	jget nfc dumpsys nfc; nfc="$REPLY"
	[[ "$nfc" == *mState=* ]] || return 0
	local ns chip="" sec="" pay pkg desc
	ns=$(printf '%s\n' "$nfc" | sed -n 's/^mState=//p' | head -n 1)
	if compgen -G "$R/dev/st21nfc" >/dev/null || compgen -G "$R/dev/st54*" >/dev/null; then chip="STMicroelectronics"
	elif compgen -G "$R/dev/nq-nci" >/dev/null || compgen -G "$R/dev/pn5*" >/dev/null || compgen -G "$R/dev/nxp*" >/dev/null; then chip="NXP"
	elif compgen -G "$R/dev/sec-nfc" >/dev/null; then chip="Samsung"; fi
	prop vendor.qti.nfc.fwver; [ -n "$REPLY" ] && chip="${chip:-контроллер} · прошивка $REPLY"
	[[ "$nfc" == *mIsSecureNfcEnabled=true* ]] && sec=" · только при разблокировке"
	case "$ns" in
		on)  CONN_NFC="${GREEN}вкл.${NC}${chip:+ · $chip}$sec" ;;
		off) CONN_NFC="выкл.${chip:+ · $chip}" ;;
		*)   CONN_NFC="${ns:-?}${chip:+ · $chip}" ;;
	esac
	pay=$(printf '%s\n' "$nfc" | sed -n 's/.*Current wallet payment service: ComponentInfo{\([^}]*\)}.*/\1/p' | head -n 1)
	[ -z "$pay" ] && pay=$(printf '%s\n' "$nfc" | sed -n 's/.*[Pp]referred payment service: ComponentInfo{\([^}]*\)}.*/\1/p' | head -n 1)
	if [ -n "$pay" ]; then
		pkg="${pay%%/*}"
		desc=$(printf '%s\n' "$nfc" | grep -F "ComponentInfo{$pay} (Description: " | head -n 1 | sed 's/.*(Description: \([^)]*\)).*/\1/')
		[ "$desc" = "null" ] && desc=""
		if [ -n "$desc" ]; then CONN_PAY="$desc ${DIM}($pkg)${NC}"; else CONN_PAY="$pkg"; fi
	else
		CONN_PAY="${YELLOW}приложение не выбрано${NC}"
	fi
}

# ── Точка доступа («Точка доступа»): настройки из WifiConfigStoreSoftAp.xml (на
# Android 17 — в /data/misc_ce, на 16 — в /data/misc); состояние — по dumpsys
# tethering, а частоты и клиенты — из dumpsys wifi, только если точка работает.
conn_hotspot() {
	REPLY=""
	local ap="" f
	for f in "$R/data/misc_ce/0/apexdata/com.android.wifi/WifiConfigStoreSoftAp.xml" \
		"$R/data/misc/apexdata/com.android.wifi/WifiConfigStoreSoftAp.xml"; do
		can_read "$f" && grep -q '<SoftAp>' "$f" 2>/dev/null && { ap="$f"; break; }
	done
	local ap_on=0 i
	for i in $CONN_TETHER; do case "$i" in wlan*|softap*|ap_br*|swlan*) ap_on=1 ;; esac; done
	[ -n "$ap" ] || [ "$ap_on" -eq 1 ] || return 0
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
	REPLY="$out"
}

# [3.14.1] Геолокация («Геолокация»): settings secure location_mode (0 — выключена)
conn_location() {
	sget secure location_mode
	case "$REPLY" in
		0) REPLY="выкл." ;;
		[1-3]) REPLY="${GREEN}вкл.${NC}" ;;
		*) REPLY="" ;;
	esac
}

# ── USB («USB»): порт Type-C, источник питания, функции и максимальная скорость порта
conn_usb() {
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
	# [3.14.1] Версия по максимальной скорости контроллера (udc/maximum_speed):
	# high-speed — USB 2.0 (480 Мбит/с), super-speed — USB 3.0 (5 Гбит/с, она же
	# USB 3.2 Gen 1), super-speed-plus — USB 3.2 (10 Гбит/с и выше)
	case "$spd" in
		super-speed-plus*) spd="USB 3.2 ${DIM}(10 Гбит/с)${NC}" ;;
		super-speed)       spd="USB 3.0 ${DIM}(5 Гбит/с)${NC}" ;;
		high-speed)        spd="USB 2.0 ${DIM}(480 Мбит/с)${NC}" ;;
		*) spd="" ;;
	esac
	REPLY=""
	[ -n "$pres$pr$spd" ] || return 0
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
	[[ " $CONN_TETHER" == *" ncm"* || " $CONN_TETHER" == *" rndis"* || " $CONN_TETHER" == *" usb"* ]] && fns="${fns:+$fns, }режим модема"
	REPLY="$st2${spd:+ · $spd}${fns:+ · $fns}"
}

# ── UWB («UWB», перенесено из «Google Pixel»): служба и переключатель в настройках
conn_uwb() {
	local uwb
	jget uwb dumpsys uwb; uwb=$(jout | awk '/settings_toggle=/ { t = ($0 ~ /settings_toggle=true/) ? "on" : "off" } /^Device state =/ { s = $4 } END { if (s != "") print t " " s }')
	REPLY=""
	[ -n "$uwb" ] || return 0
	case "$uwb" in
		"on READY"*) REPLY="${GREEN}включён${NC}" ;;
		off*)        REPLY="выключен" ;;
		*)           REPLY="${uwb#* } ${DIM}(состояние службы)${NC}" ;;
	esac
}

check_connections() {
	section "ДРУГИЕ ПОДКЛЮЧЕНИЯ"
	local l
	conn_tether
	conn_bluetooth
	if [ -n "$BT_HEAD" ]; then
		kv "Bluetooth" "$BT_HEAD"
		for l in "${BT_CONN[@]}"; do wrap_emit 18 "$l"; done
		if [ "$BT_SAVED_N" -gt 0 ]; then
			kv "Сохранённые" "$BT_SAVED_N"
			for l in "${BT_SAVED[@]}"; do wrap_emit 18 "$l"; done
		fi
	fi
	conn_le_audio;  [ -n "$REPLY" ] && kv "LE Audio" "$REPLY"
	conn_nfc
	if [ -n "$CONN_NFC" ]; then kv "NFC" "$CONN_NFC"; kv "Оплата" "$CONN_PAY"; fi
	conn_hotspot;   [ -n "$REPLY" ] && kv "Точка доступа" "$REPLY"
	conn_location;  [ -n "$REPLY" ] && kv "Геолокация" "$REPLY"
	conn_usb;       [ -n "$REPLY" ] && kv "USB" "$REPLY"
	conn_uwb;       [ -n "$REPLY" ] && kv "UWB" "$REPLY"
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
	jget widevine dumpsys android.hardware.drm.IDrmFactory/widevine; wv="$REPLY"
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
	jget sensors dumpsys sensorservice; fir=$(jout | awk -F'|' '/fir_temperature\(/ { n = $1; sub(/^[^)]*\) */, "", n); split(n, a, " "); print a[1]; exit }')
	if [ -n "$fir" ]; then
		kv "Термометр" "${GREEN}есть${NC} · датчик $fir"   # [3.14.1] цвет, как у AOC
	else
		kv "Термометр" "${RED}нет${NC}"
	fi

	# [3.11] AICore — системная среда Gemini Nano. Сборка из versionName
	# («0.release.prod_aicore_20260917.00_RC01» → 17.09.2026). Есть ли скачанная
	# модель, по файлам не видно — поэтому про модель не пишем.
	local ai
	jget pkg_aicore dumpsys package com.google.android.aicore; ai=$(jout | sed -n 's/^ *versionName=//p' | head -n 1)
	if [ -n "$ai" ]; then
		if [[ "$ai" =~ _(20[0-9]{2})([01][0-9])([0-3][0-9]) ]]; then
			ai="сборка ${BASH_REMATCH[3]}.${BASH_REMATCH[2]}.${BASH_REMATCH[1]}"
		fi
		pm list packages -d 2>/dev/null | grep -qx 'package:com.google.android.aicore' && ai="${YELLOW}отключён${NC} ${DIM}($ai)${NC}"
		kv "AICore" "$ai ${DIM}(среда Gemini Nano)${NC}"
	fi

	# [3.17] Сканер отпечатков переехал в «Систему» (строки «Отпечаток» и «Лицо»)

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

# [3.15.3] Время экрана за сегодня — как «Цифровое благополучие»: из журнала
# событий UsageStats за 24 часа (dumpsys usagestats, «Last 24 hour events»).
# С полуночи суммируется время, пока окно приложения на переднем плане
# (ACTIVITY_RESUMED → PAUSED/STOPPED, по instanceId) и экран включён
# (SCREEN_INTERACTIVE); лаунчер, SystemUI и сервисы Google не считаются.
# Разблокировки — KEYGUARD_HIDDEN за сегодня. Сверено с Wellbeing: Pixel 8 Pro
# 8:16 против 8:19 и 19 = 19; POCO F3 2:29 против 2:36 и 13 = 13. Расхождение —
# Custom Tabs: Android пишет их на Chrome, Wellbeing — на приложение-хозяина.
SCR_AWK='
function sod(s,  a) { split(s, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
function adv(t,  p) { if (scr && t > prev) for (p in cnt) if (cnt[p] > 0) app[p] += t - prev; prev = t }
/Last 24 hour events/ { on = 1; next }
/In-memory daily stats/ { exit }
!on || !/ type=/ { next }
{
	if (!match($0, /time="[0-9-]+ [0-9:]+"/)) next
	d = substr($0, RSTART + 6, 10); t = sod(substr($0, RSTART + 17, 8))
	match($0, /type=[A-Z_]+/); ty = substr($0, RSTART + 5, RLENGTH - 5)
	pk = ""; if (match($0, /package=[^ ]+/)) pk = substr($0, RSTART + 8, RLENGTH - 8)
	id = pk; if (match($0, /instanceId=[0-9-]+/)) id = pk "#" substr($0, RSTART + 11, RLENGTH - 11)
	if (d < day) t = 0; else adv(t)
	if (ty == "SCREEN_INTERACTIVE") scr = 1
	else if (ty == "SCREEN_NON_INTERACTIVE") scr = 0
	else if (ty == "ACTIVITY_RESUMED") { if (!(id in open)) { open[id] = pk; cnt[pk]++ } }
	else if (ty == "ACTIVITY_PAUSED" || ty == "ACTIVITY_STOPPED") { if (id in open) { cnt[open[id]]--; delete open[id] } }
	else if (ty == "KEYGUARD_HIDDEN" && d == day) unl++
}
END {
	adv(now)
	for (p in app) if (p != home && p !~ excl) tot += app[p]
	if (tot > 0 || unl > 0) printf "%d %d\n", tot, unl
}
'

# [3.17] Биометрия — для любого телефона, в «Системе». Пробы 3170 / fp:
#   dumpsys biometric «Sensors:» — ID(n), updatedStrength S, modality M:
#     M 2 — отпечаток, 8 — лицо; S 15 — сильная (Class 3), 255 — слабая (Class 2),
#     4095 — удобство (Class 1);
#   dumpsys fingerprint / face — JSON {"prints":[{"count":N}]}: сколько настроено
#     (у текущего пользователя); «Type: 2» планировщика отпечатка — под экраном
#     (UDFPS, BiometricScheduler.SENSOR_TYPE_UDFPS), 3 — любой другой;
#   где «другой» — по вендору: persist.vendor.fingerprint.type=side или настройка
#     sfps_performant_auth_enabled* (есть только у сенсора в кнопке питания).
#   Лицо от SenseProvider (LineageOS / Evolution X) — программное, по камере.
bio_strength() {   # bio_strength S → REPLY
	case "$1" in
		15) REPLY="сильная (Class 3)" ;; 255) REPLY="слабая (Class 2)" ;;
		4095) REPLY="удобство (Class 1)" ;; *) REPLY="" ;;
	esac
}
bio_count() {   # из дампа службы: первое «"count":N»
	local re='"count":([0-9]+)'
	[[ "$1" =~ $re ]] && REPLY="${BASH_REMATCH[1]}" || REPLY=""
}
bio_lines() {   # → BIO_FP, BIO_FACE (пусто — строки нет)
	BIO_FP=""; BIO_FACE=""
	local line fps="" faces="" re=' ID\(([0-9]+)\), oemStrength: [0-9]+, updatedStrength: ([0-9]+), modality ([0-9]+)'
	jget biometric dumpsys biometric
	while IFS= read -r line; do
		[[ "$line" =~ $re ]] || continue
		case "${BASH_REMATCH[3]}" in
			2) [ -z "$fps" ] && fps="${BASH_REMATCH[2]}" ;;
			8) [ -z "$faces" ] && faces="${BASH_REMATCH[2]}" ;;
		esac
	done <<< "$REPLY"

	local out cnt str
	if [ -n "$fps" ]; then
		local where="" vend="" k typ=""
		jget fingerprint dumpsys fingerprint; out="$REPLY"
		[[ "$out" =~ Type:\ ([0-9]+) ]] && typ="${BASH_REMATCH[1]}"
		bio_count "$out"; cnt="$REPLY"
		for k in "${!PROP[@]}"; do
			case "$k" in init.svc.vendor.fingerprint-*) vend="${k#init.svc.vendor.fingerprint-}" ;; esac
		done
		[ "$vend" = default ] && vend=""
		[ -z "$vend" ] && { prop persist.vendor.sys.fp.vendor; vend="$REPLY"; }
		case "$vend" in goodix) vend="Goodix" ;; fpc) vend="FPC" ;; qcom|qti) vend="Qualcomm" ;; egis*) vend="Egis" ;; silead) vend="Silead" ;; esac
		if [ "$typ" = 2 ]; then where="под экраном"
		elif [ "$typ" = 3 ]; then
			local sec; settings_list secure; sec=$'\n'"$REPLY"
			prop persist.vendor.fingerprint.type
			if [[ "$sec" == *$'\n'sfps_performant_auth_enabled* ]]; then where="в кнопке питания"
			elif [ "$REPLY" = side ]; then where="сбоку"
			fi
		fi
		bio_strength "$fps"; str="$REPLY"
		BIO_FP="$where"
		[ -n "$vend" ] && BIO_FP="${BIO_FP:+$BIO_FP · }$vend"
		[ -n "$str" ] && BIO_FP="${BIO_FP:+$BIO_FP · }$str"
		case "$cnt" in
			"") ;; 0) BIO_FP="${BIO_FP:+$BIO_FP · }${YELLOW}не настроен${NC}" ;;
			*) BIO_FP="${BIO_FP:+$BIO_FP · }отпечатков: $cnt" ;;
		esac
		[ -n "$BIO_FP" ] || BIO_FP="есть"
	fi
	if [ -n "$faces" ]; then
		jget face dumpsys face; out="$REPLY"
		bio_count "$out"; cnt="$REPLY"
		bio_strength "$faces"; str="$REPLY"
		BIO_FACE=""
		[[ "$out" == *SenseProvider* ]] && BIO_FACE="программное (Sense)"
		[ -n "$str" ] && BIO_FACE="${BIO_FACE:+$BIO_FACE · }$str"
		case "$cnt" in
			"") ;; 0) BIO_FACE="${BIO_FACE:+$BIO_FACE · }не настроено" ;;
			*) BIO_FACE="${BIO_FACE:+$BIO_FACE · }настроено" ;;
		esac
		[ -n "$BIO_FACE" ] || BIO_FACE="есть"
	fi
}

print_system() {
	section "СИСТЕМА"
	uptime_str; kv "Время работы" "$REPLY"
	# [3.15.3] Время экрана и разблокировки за сегодня (см. SCR_AWK)
	local day sec home st_t st_u
	printf -v day '%(%Y-%m-%d)T' -1; printf -v sec '%(%H:%M:%S)T' -1
	sec=$(( 10#${sec:0:2} * 3600 + 10#${sec:3:2} * 60 + 10#${sec:6:2} ))
	jget home cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME; home=$(jout | tail -n 1)
	jget usagestats dumpsys usagestats
	read -r st_t st_u < <(jout | awk -v day="$day" -v now="$sec" -v home="${home%%/*}" \
		-v excl='^(android|com\.android\.systemui|com\.google\.android\.gms|com\.google\.android\.permissioncontroller|com\.android\.permissioncontroller)$|launcher' \
		"$SCR_AWK" 2>/dev/null)
	if is_int "${st_t:-x}"; then
		local h=$((st_t / 3600)) m=$(((st_t % 3600) / 60)) v
		if [ "$h" -gt 0 ]; then v="$h ч $m мин"; else v="$m мин"; fi
		kv "Время экрана" "$v${st_u:+ · разблокировок: $st_u}"
	fi
	# [3.12] Часовой пояс: имя зоны + смещение от UTC; «авто» — по сети
	local tz off auto
	prop persist.sys.timezone; tz="$REPLY"
	off=$(date +%z 2>/dev/null)
	[[ "$off" =~ ^[+-][0-9]{4}$ ]] && off="UTC${off:0:3}:${off:3:2}" || off=""
	sget global auto_time_zone; [ "$REPLY" = "1" ] && auto=" ${DIM}· авто${NC}"
	[ -n "$tz$off" ] && kv "Часовой пояс" "${tz:-?}${off:+ ($off)}$auto"
	# [3.12.1] Формат часов: settings system time_12_24 = 12 / 24. Пусто — включено
	# «Использовать формат языка»: тогда формат задаёт первый язык системы.
	# 12-часовой по умолчанию (CLDR) — у США, Канады, Австралии, Новой Зеландии,
	# Индии, Филиппин, Пакистана, Египта, Саудовской Аравии, Кореи и Тайваня.
	local f12 lc
	sget system time_12_24; f12="$REPLY"
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

# [3.17] Безопасность — отдельной секцией после «Системы»: обновления, Verified
# Boot, SELinux, root, биометрия; с -e — защита ядра и уязвимости процессора.
check_security() {
	section "БЕЗОПАСНОСТЬ"
	# [3.15] Обновления: патч безопасности системы и вендора (если отличается) и
	# дата обновления системы Google Play — versionName пакета modulemetadata
	# («2026-09-01S+»); у прошивок без mainline Google его нет.
	# Отставание вендора не подсвечивается: на кастомных прошивках для старых
	# устройств (POCO F3) свежего vendor уже не будет, предупреждать не о чем.
	# Неразрывный пробел (U+00A0) держит дату вместе с подписью при переносе.
	local sp vp mm upl="" nb=$'\xc2\xa0'
	prop ro.build.version.security_patch; sp="$REPLY"
	prop ro.vendor.build.security_patch; vp="$REPLY"
	jget pkg_mainline dumpsys package com.google.android.modulemetadata; mm=$(jout | sed -n 's/^ *versionName=\([0-9]\{4\}-[0-9][0-9]-[0-9][0-9]\).*/\1/p' | head -n 1)
	if [[ "$sp" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
		upl="патч безопасности от${nb}${BASH_REMATCH[3]}.${BASH_REMATCH[2]}.${BASH_REMATCH[1]}"
		if [[ "$vp" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] && [ "$vp" != "$sp" ]; then
			upl="$upl · исправления производителя${nb}от${nb}${BASH_REMATCH[3]}.${BASH_REMATCH[2]}.${BASH_REMATCH[1]}"
		fi
	fi
	[ -n "$mm" ] && upl="${upl:+$upl · }системное обновление Google${nb}Play${nb}от${nb}${mm:8:2}.${mm:5:2}.${mm:0:4}"
	[ -n "$upl" ] && kv "Обновления" "$upl"
	kv "Статус AVB" "$VB_LABEL"
	note "ядро: ${VB_REAL:-${VB_DEVSTATE:-—}} · свойства: ${VB_PROP:-—}/flash.locked=${VB_LOCKPROP:-—}"
	note "Вердикт Play Integrity выносят серверы Google — локально его не проверить."
	local se; se=$(getenforce 2>/dev/null)
	case "$se" in
		Enforcing)  kv "SELinux" "${GREEN}Enforcing${NC}" ;;
		Permissive) kv "SELinux" "${YELLOW}Permissive${NC}" ;;
		*)          kv "SELinux" "${se:-?}" ;;
	esac
	detect_root
	kv "Root" "${GREEN}есть${NC} · $ROOT_INFO"
	[ -n "$ZYGISK_INFO" ] && kv "Zygisk" "$ZYGISK_INFO"
	bio_lines
	[ -n "$BIO_FP" ] && kv "Отпечаток" "$BIO_FP"
	[ -n "$BIO_FACE" ] && kv "Лицо" "$BIO_FACE"
	if [ "$EXTENDED" -eq 1 ]; then
		kernel_config; kernel_hardening "$REPLY"
		kernel_vulns
	fi
}

# ── Подмена (Evolution X) ────────────────────────────────────────────────────
# [3.15] Только на Evolution X и только с -e. Подмена встроена в прошивку
# (раздел «Spoofing» приложения Evolver), состояние — в системных настройках
# (сверено с исходниками packages_apps_Evolver и frameworks_base):
#   system spoof_trickystore_enabled / spoof_pif_enabled (по умолчанию 1);
#   secure spoof_trickystore_keybox_source (official|user), _patch,
#          _last_revocation_status / _reason / _check — проверка keybox самой прошивкой;
#   secure spoof_pif_config — JSON с подменяемым отпечатком Pixel;
#   secure pi_pp_spoof (1), pi_pp_model, pi_pp_targets — свойства Pixel;
#   secure pi_tensor_spoof (0), tensor_targets — подмена Tensor;
#   secure pi_photos_spoof (1), pi_snapchat_spoof (0).
# [3.18] Под Evolver с Compose-интерфейсом (ветки bka/cnb, проба 3180s):
#   secure spoof_trickystore_last_fetched (мс) — когда скачан официальный keybox;
#   secure spoof_trickystore_target — список целей TrickyStore, по пакету в строке;
#   PIF-конфиг: _canary_release_date / _canary_month — срок Canary-отпечатка (Evolver
#     считает 42 дня от даты выпуска, иначе от 1-го числа месяца), manually_imported,
#     spoofVendingSdk («Spoof SDK to DroidGuard»);
#   secure per_apps_device_spoof_enabled (1) и per_apps_device_spoof («пакет:профиль,…») —
#     «App & game spoofing»;
#   переключатели Google Фото и Snapchat Evolver показывает, только если приложение стоит.
# Содержимое keybox (spoof_trickystore_keybox) не читается и не выводится.
check_spoofing() {
	prop ro.evolution.version; [ -n "$REPLY" ] || return 0
	local ver; prop ro.evolution.display.version; ver="$REPLY"
	section "ПОДМЕНА" "(Evolution X${ver:+ ${ver%%-*}})"

	local sysl secl kb
	settings_list system; sysl=$(printf '%s\n' "$REPLY" | grep -E '^spoof_(trickystore|pif)_enabled=')
	# keybox уже заменён на «1» в settings_list_raw: его содержимого в памяти нет
	settings_list secure; secl=$(printf '%s\n' "$REPLY" | grep -E '^(spoof_trickystore_(keybox|keybox_source|patch|last_fetched|last_revocation_status|last_revocation_reason|last_revocation_check)|per_apps_device_spoof(_enabled)?|pi_pp_spoof|pi_pp_model|pi_pp_targets|pi_tensor_spoof|tensor_targets|pi_photos_spoof|pi_snapchat_spoof)=')
	sv() {   # sv СПИСОК КЛЮЧ ПО_УМОЛЧАНИЮ → REPLY
		REPLY=$(printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1)
		[ -z "$REPLY" ] || [ "$REPLY" = "null" ] && REPLY="$3"
		return 0
	}
	onoff() { if [ "$1" = "1" ]; then REPLY="${GREEN}вкл.${NC}"; else REPLY="выкл."; fi; }
	ymd() { [[ "$1" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2}) ]] && REPLY="${BASH_REMATCH[3]}.${BASH_REMATCH[2]}.${BASH_REMATCH[1]}" || REPLY="$1"; }
	cnt() { local n; n=$(printf '%s' "$1" | tr ',' '\n' | grep -c .); REPLY="$n"; }
	jstr() { REPLY=$(printf '%s' "$cfg" | grep -oE "\"$1\" *: *\"?[^\",}]*" | head -n 1 | sed 's/.*: *"\{0,1\}//'); }
	inst() { [ -f "$R/data/system/packages.list" ] || return 0; grep -q "^$1 " "$R/data/system/packages.list"; }
	# Дата сборки Evolution X (v11.10-20260907 → 20260907): нужна для ошибки проверки keybox
	local bdate=""; [[ "$ver" =~ ([0-9]{8}) ]] && bdate="${BASH_REMATCH[1]}"

	# Tricky Store: включён ли, keybox (есть ли и что сказала проверка прошивки), патч
	local ts src st rs chk patch line
	sv "$sysl" spoof_trickystore_enabled 1; onoff "$REPLY"; ts="$REPLY"
	sv "$secl" spoof_trickystore_keybox 0; kb="$REPLY"
	sv "$secl" spoof_trickystore_keybox_source ""; src="$REPLY"
	sv "$secl" spoof_trickystore_last_revocation_status ""; st="$REPLY"
	sv "$secl" spoof_trickystore_last_revocation_reason ""; rs="$REPLY"
	sv "$secl" spoof_trickystore_last_revocation_check ""; chk="$REPLY"
	sv "$secl" spoof_trickystore_patch ""; ymd "$REPLY"; patch="$REPLY"
	if [ "$kb" != "1" ]; then line="keybox: ${RED}нет${NC}"
	else
		case "$st" in
			VALID)          line="keybox: ${GREEN}действителен${NC}" ;;
			EXPIRING_SOON)  line="keybox: ${YELLOW}скоро истечёт${NC}" ;;
			REVOKED)        line="keybox: ${RED}отозван${NC}" ;;
			SUSPENDED)      line="keybox: ${RED}приостановлен${NC}" ;;
			CHAIN_INVALID)
				# [3.18] Evolver до 30.09.2026 проверял цепочки EC и RSA одним списком и на
				# любом keybox получал BAD_SIGNATURE_AT_N, а в интерфейсе показывал «Valid».
				# В таких сборках это не вердикт — keybox просто не был проверен.
				if [[ "$rs" == BAD_SIGNATURE_AT_* ]] && [ -n "$bdate" ] && [ "$bdate" -lt 20260930 ]; then
					line="keybox: ${YELLOW}не проверен${NC}"; rs="ошибка проверки в Evolver до 30.09.2026"
				else line="keybox: ${RED}цепочка недействительна${NC}"; fi ;;
			UNTRUSTED_ROOT) line="keybox: ${RED}недоверенный корень${NC}" ;;
			CHECKING)       line="keybox: проверяется" ;;
			*)              line="keybox: есть ${DIM}(не проверялся)${NC}" ;;
		esac
		case "$src" in official) line="$line ${DIM}· официальный${NC}" ;; user) line="$line ${DIM}· свой${NC}" ;; esac
	fi
	# [3.18] Список целей: по пакету в строке (формат target.txt) или через запятую
	local tg=""; sget secure spoof_trickystore_target
	if [ -n "$REPLY" ] && [ "$REPLY" != "null" ]; then
		tg=$(printf '%s\n' "$REPLY" | tr ',' '\n' | grep -c '[^[:space:]]'); tg=" · приложений: $tg"
	fi
	kv "Tricky Store" "$ts · $line${patch:+ · патч $patch}$tg"
	local fet=""; sv "$secl" spoof_trickystore_last_fetched ""; fet="$REPLY"
	if [ -n "$rs" ] || is_int "${chk:-x}" || is_int "${fet:-x}"; then
		local when="" got=""
		is_int "${fet:-x}" && [ "$fet" -gt 0 ] && printf -v got 'скачан %(%d.%m.%Y %H:%M)T' $((fet / 1000))
		is_int "${chk:-x}" && [ "$chk" -gt 0 ] && printf -v when 'проверка %(%d.%m.%Y %H:%M)T' $((chk / 1000))
		[ -n "$got" ] && when="$got${when:+ · $when}"
		note "${when}${rs:+${when:+ · }причина: $rs}"
	fi

	# PIF: включён ли и под какой Pixel подделан отпечаток (модель и продукт из JSON)
	local pif cfg model prod pp
	sv "$sysl" spoof_pif_enabled 1; onoff "$REPLY"; pif="$REPLY"
	cfg=$(settings get secure spoof_pif_config 2>/dev/null)
	model=$(printf '%s' "$cfg" | grep -oE '"MODEL" *: *"[^"]*"' | head -n 1 | sed 's/.*: *"//; s/"$//')
	prod=$(printf '%s' "$cfg" | grep -oE '"PRODUCT" *: *"[^"]*"' | head -n 1 | sed 's/.*: *"//; s/"$//')
	pp=$(printf '%s' "$cfg" | grep -oE '"SECURITY_PATCH" *: *"[^"]*"' | head -n 1 | sed 's/.*: *"//; s/"$//')
	[ -n "$pp" ] && { ymd "$pp"; pp="$REPLY"; }
	# [3.18] Canary-отпечаток: срок как в Evolver — 42 дня от даты выпуска (или от 1-го
	# числа месяца), дни — с отбрасыванием дробной части; ручной импорт; SDK для DroidGuard
	local can="" rel mon exp now d extra=""
	jstr _canary_release_date; rel="$REPLY"; jstr _canary_month; mon="$REPLY"
	[ -z "$rel" ] && [[ "$mon" =~ ^[0-9]{4}-[0-9]{2}$ ]] && rel="$mon-01"
	if [[ "$rel" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && exp=$(date -d "$rel" +%s 2>/dev/null); then
		printf -v now '%(%s)T' -1
		d=$(( (exp + 42 * 86400 - now) / 86400 ))
		if [ $(( exp + 42 * 86400 )) -lt "$now" ]; then can=" · Canary ${YELLOW}истёк${NC}"
		else can=" · Canary, осталось $d дн."; fi
	fi
	jstr manually_imported; [ "$REPLY" = "true" ] && extra="$extra · импортирован вручную"
	jstr spoofVendingSdk; [ "$REPLY" = "1" ] && extra="$extra · SDK для DroidGuard"
	if [ -n "$model" ]; then
		kv "PIF" "$pif · $model${prod:+ ${DIM}($prod)${NC}}${pp:+ · патч $pp}$can$extra"
	else
		kv "PIF" "$pif ${DIM}· конфиг не загружен${NC}"
	fi

	# Свойства Pixel и Tensor для выбранных приложений
	local v m n
	sv "$secl" pi_pp_spoof 1; onoff "$REPLY"; v="$REPLY"
	sv "$secl" pi_pp_model ""; m="$REPLY"
	# [3.15.1] Название модели вместо кодового имени: из PIF, если подделан тот же
	# Pixel, иначе из кэша Evolver (pi_pixel_device_cache: codename → model).
	local mn=""
	if [ -n "$m" ]; then
		[ "$(printf '%s' "$cfg" | grep -oE '"DEVICE" *: *"[^"]*"' | head -n 1 | sed 's/.*: *"//; s/"$//')" = "$m" ] && mn="$model"
		[ -z "$mn" ] && mn=$(settings get secure pi_pixel_device_cache 2>/dev/null | grep -oE "\"codename\":\"$m\",\"model\":\"[^\"]*\"" | head -n 1 | sed 's/.*"model":"//; s/"$//')
		if [ -n "$mn" ]; then m="$mn ${DIM}($m)${NC}"; else m="модель $m"; fi
	fi
	sv "$secl" pi_pp_targets ""; if [ -n "$REPLY" ]; then cnt "$REPLY"; n="приложений: $REPLY"; else n="список по умолчанию"; fi
	kv "Pixel Props" "$v${m:+ · $m} · $n"
	sv "$secl" pi_tensor_spoof 0; onoff "$REPLY"; v="$REPLY"
	sv "$secl" tensor_targets ""; if [ -n "$REPLY" ]; then cnt "$REPLY"; n=" · приложений: $REPLY"; else n=""; fi
	kv "Tensor Props" "$v$n"

	# [3.18] «App & game spoofing»: свои профили устройства для приложений и игр
	sv "$secl" per_apps_device_spoof_enabled 1; onoff "$REPLY"; v="$REPLY"
	sv "$secl" per_apps_device_spoof ""
	if [ -n "$REPLY" ]; then cnt "$REPLY"; n=" · приложений: $REPLY"; else n=" · список пуст"; fi
	[ "$v" = "выкл." ] && n=""
	kv "Прил. и игры" "$v$n"

	# [3.18] Как в Evolver: переключатель есть, только если приложение установлено
	local ph="" sc="" apps=""
	sv "$secl" pi_photos_spoof 1; onoff "$REPLY"; inst com.google.android.apps.photos && ph="Google Фото — $REPLY"
	sv "$secl" pi_snapchat_spoof 0; onoff "$REPLY"; inst com.snapchat.android && sc="Snapchat — $REPLY"
	apps="$ph${ph:+${sc:+ · }}$sc"
	[ -n "$apps" ] && kv "Приложения" "$apps"
	unset -f sv onoff ymd cnt jstr inst
	return 0
}

# [3.1] Модули: заголовок по типу root, статус у каждого модуля, версия через
# разделитель, описание строкой ниже. Флаги — штатные файлы Magisk/KernelSU/APatch:
#   disable → выкл., remove → удалится, update или modules_update/<id> → обновлён.
# Новые модули, которые появятся только после перезагрузки, тоже показываем.
# [3.16] Чтение — циклом bash, без sed и head (было ~70 мс на вызов на Pixel)
mod_prop() {   # mod_prop ФАЙЛ КЛЮЧ → REPLY (первое значение, без управляющих символов)
	REPLY=""
	can_read "$1" || return 1
	local line
	while IFS= read -r line || [ -n "$line" ]; do
		[[ "$line" == "$2="* ]] && { REPLY="${line#"$2="}"; break; }
	done < "$1" 2>/dev/null
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

# [3.16] Фреймворк и его CLI ищутся отдельно: CLI (два запуска Java, ~2.5 с)
# стартует в предзагрузке, а секция забирает готовый ответ.
LSP_FW=""; LSP_CLI=""
# первая строка «  versionName=…» / «  codePath=…» в dumpsys package (как sed -n …p | head -n 1)
LSP_RE_VER=$'(^|\n) *versionName=([^\n]*)'
LSP_RE_CP=$'(^|\n) *codePath=([^\n]*)'
lsp_locate() {
	LSP_FW=""; LSP_CLI=""
	local m id
	for m in "$R"/data/adb/modules/*/; do
		m="${m%/}"; id="${m##*/}"
		case "${id,,}" in *lsposed*|*vector*) ;; *) continue ;; esac
		mod_prop "$m/module.prop" description
		case "${id,,}:${REPLY,,}" in *lsposed*|*xposed*) LSP_FW="$m"; break ;; esac
	done
	[ -n "$LSP_FW" ] || return 1
	for m in "$R/data/adb/lspd/cli" "$LSP_FW/cli"; do [ -f "$m" ] && { LSP_CLI="$m"; break; }; done
	return 0
}
lsp_cli() {   # ответы CLI на status и modules ls подряд, через строку-разделитель
	local to=""
	command -v timeout >/dev/null 2>&1 && to="timeout 20"
	$to sh "$LSP_CLI" --json status 2>/dev/null
	echo "@@modules@@"
	$to sh "$LSP_CLI" --json modules ls 2>/dev/null
}
lsp_prefetch() {
	lsp_locate || return 0
	[ -n "$LSP_CLI" ] && [ ! -e "$LSP_FW/disable" ] && job lsp_cli lsp_cli
}

print_lsposed() {
	local m fwdir
	lsp_locate || return 0
	fwdir="$LSP_FW"

	local fork fwver api="" cli="$LSP_CLI" sub
	mod_prop "$fwdir/module.prop" name; fork="${REPLY:-${fwdir##*/}}"
	fork="${fork#Zygisk - }"; fork="${fork#Riru - }"
	mod_prop "$fwdir/module.prop" version; fwver="${REPLY%% (*}"

	# Список модулей: пакет<TAB>enabled|disabled
	local list="" cli_ok=0 c_st c_ls
	if [ -n "$cli" ] && [ ! -e "$fwdir/disable" ]; then
		jget lsp_cli lsp_cli
		c_st="${REPLY%%@@modules@@*}"; c_ls="${REPLY#*@@modules@@}"
		[[ "$REPLY" == *@@modules@@* ]] || c_ls=""
		api=$(printf '%s\n' "$c_st" | awk -F': *' '/"API Version"/ { gsub(/[^0-9]/, "", $2); print $2; exit }')
		list=$(printf '%s\n' "$c_ls" | awk '
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
	# [3.16] dumpsys package по всем модулям — параллельно (на Pixel 4.9 → 1.5 с)
	while IFS=$'\t' read -r pkg st; do
		[ -n "$pkg" ] && job "pkg_$pkg" dumpsys package "$pkg"
	done <<< "$list"
	while IFS=$'\t' read -r pkg st; do
		[ -n "$pkg" ] || continue
		case "$st" in
			enabled)  st="вкл.";  stc="$GREEN" ;;
			disabled) st="выкл."; stc="$YELLOW" ;;
			*)        st="?";     stc="$DIM" ;;
		esac
		char_len "$st"; printf -v sp '%*s' $((8 - REPLY)) ""
		tag="${stc}${st}${NC}${sp}"

		jget "pkg_$pkg" dumpsys package "$pkg"; out="$REPLY"
		# [3.17.1] Версия и путь — регулярным выражением bash, без sed | head
		# (было 2 процесса на модуль с перегоном всего вывода dumpsys, ~1,5 с на Pixel)
		ver=""; cp=""
		[[ "$out" =~ $LSP_RE_VER ]] && ver="${BASH_REMATCH[2]}"
		[[ "$out" =~ $LSP_RE_CP ]] && cp="${BASH_REMATCH[2]}"

		# Метаданные из APK: module.prop нового API и манифест (двоичный AXML)
		p_desc=""; p_min=""; p_tgt=""; m_dsc=""; m_min=""; dref=0
		apk="$R$cp/base.apk"
		# [3.16] Есть запись в кэше менеджера — APK не разбираем: и API, и описание
		# берутся из кэша раньше всего остального (разбор манифеста — до 2.6 с)
		if [ -z "${C_LEG[$pkg]+x}" ] && [ -n "$cp" ] && [ -f "$apk" ] && command -v unzip >/dev/null 2>&1; then
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

# [3.17] Защита ядра (с -e, в «Безопасности»): что собрано в ядре (config.gz) и что умеет процессор
# (Features в /proc/cpuinfo). Проба 3170: Pixel 8 Pro — CFI, SCS, KASLR, PAC, BTI
# (только для приложений: ARM64_BTI_KERNEL не включён), MTE собран, но выключен
# (arm64.nomte; включается в «Для разработчиков» — свойство arm64.memtag.bootctl);
# POCO F3 (Cortex-A77, ARMv8.2) — CFI, SCS, KASLR, а PAC/BTI/MTE у процессора нет.
# [3.17] Нужные строки /proc/config.gz — распаковываются один раз за проход
# (частота тика в «Ядре», защита в «Безопасности»). REPLY — строки CONFIG_…=…
KCFG=""; KCFG_LOADED=0
kernel_config() {
	if [ "$KCFG_LOADED" -eq 0 ]; then
		KCFG_LOADED=1; KCFG=""
		can_read "$R/proc/config.gz" && KCFG=$( (zcat "$R/proc/config.gz" || gzip -dc "$R/proc/config.gz") 2>/dev/null \
			| grep -E '^CONFIG_(HZ|CFI_CLANG|SHADOW_CALL_STACK|RANDOMIZE_BASE|ARM64_PTR_AUTH|ARM64_BTI|ARM64_BTI_KERNEL|ARM64_MTE)=')
	fi
	REPLY="$KCFG"
}
kernel_hardening() {   # kernel_hardening ТЕКСТ_CONFIG
	local c="$1" out="" feat="" cmd="" y
	[ -n "$c" ] || return 0
	y() { [[ $'\n'"$c"$'\n' == *$'\n'"CONFIG_$1=y"$'\n'* ]]; }
	IFS= read -r feat < <(grep -m1 '^Features' "$R/proc/cpuinfo" 2>/dev/null)
	feat=" ${feat#*:} "
	rd "$R/proc/cmdline"; cmd=" $REPLY "
	y CFI_CLANG && out="CFI"
	y SHADOW_CALL_STACK && out="${out:+$out · }Shadow Call Stack"
	y RANDOMIZE_BASE && [[ "$cmd" != *" nokaslr "* ]] && out="${out:+$out · }KASLR"
	local hw=0
	if [[ "$feat" == *" paca "* ]]; then hw=1; y ARM64_PTR_AUTH && out="${out:+$out · }PAC"; fi
	if [[ "$feat" == *" bti "* ]]; then
		hw=1
		if y ARM64_BTI_KERNEL; then out="${out:+$out · }BTI"
		elif y ARM64_BTI; then out="${out:+$out · }BTI ${DIM}(приложения)${NC}"; fi
	fi
	if y ARM64_MTE; then
		if [[ "$feat" == *" mte "* ]]; then hw=1; out="${out:+$out · }MTE ${GREEN}вкл.${NC}"
		else
			prop ro.arm64.memtag.bootctl_supported
			[ "$REPLY" = 1 ] && { hw=1; out="${out:+$out · }MTE выкл. ${DIM}(включается в «Для разработчиков»)${NC}"; }
		fi
	fi
	[ "$hw" -eq 0 ] && out="${out:+$out }${DIM}(PAC, BTI и MTE процессор не поддерживает)${NC}"
	unset -f y
	[ -n "$out" ] && kv "Защита" "$out"
}

# [3.17] Уязвимости процессора по данным ядра (/sys/devices/system/cpu/vulnerabilities):
# «Not affected» и «Mitigation: …» — норма; «Vulnerable…» — жёлтым с причиной.
kernel_vulns() {
	local f n v bad=""
	for f in "$R"/sys/devices/system/cpu/vulnerabilities/*; do
		rd "$f" || continue
		v="$REPLY"
		[[ "$v" == Vulnerable* ]] || continue
		n="${f##*/}"
		case "$n" in
			spectre_v1) n="Spectre v1" ;; spectre_v2) n="Spectre v2" ;; spec_store_bypass) n="Spectre v4" ;;
			meltdown) n="Meltdown" ;; retbleed) n="Retbleed" ;; *) n="${n//_/ }" ;;
		esac
		v="${v#Vulnerable}"; v="${v#: }"; v="${v#; }"
		case "$v" in "Unprivileged eBPF enabled") v="разрешён непривилегированный eBPF" ;; esac
		bad="${bad:+$bad · }${YELLOW}$n — уязвим${NC}${v:+ ${DIM}($v)${NC}}"
	done
	if [ -n "$bad" ]; then kv "Уязвимости" "$bad"
	elif [ -d "$R/sys/devices/system/cpu/vulnerabilities" ]; then kv "Уязвимости" "${GREEN}нет${NC} ${DIM}(закрыты или не затрагивают — по данным ядра)${NC}"
	fi
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
	kernel_config
	[[ "$REPLY" =~ (^|$'\n')CONFIG_HZ=([0-9]+) ]] && hz="${BASH_REMATCH[2]}"
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
			short_name "$f"; local nm=$REPLY   # emit затирает REPLY
			CUR_SECTION="ПРОБНЫЙ ЗАПУСК"
			emit ""
			emit "${DIM}[ $nm ] на этом устройстве данных для вывода нет${NC}"
		fi
	done

	CUR_SECTION="ИТОГ"
	emit ""
	emit "${BOLD}════════════════════════════════════════${NC}"
	emit " Итог: $(exit_code_label "$SYSTEM_STATUS") ${DIM}(код $SYSTEM_STATUS · только выбранные секции)${NC}"
	emit "${BOLD}════════════════════════════════════════${NC}"
	return "$SYSTEM_STATUS"
}

# [3.16] Предзагрузка: всё медленное и независимое запускается в фоне сразу
# после замера загрузки процессора (чтобы фоновые команды не попали в этот замер).
# Секции забирают результаты через jget в прежнем порядке.
prefetch() {
	[ -n "$JOB_DIR" ] || return 0
	local h
	job wm_size wm size
	job wm_density wm density
	job sf_latency dumpsys SurfaceFlinger --latency
	job display dumpsys display
	[ "$EXTENDED" -eq 1 ] && job camera dumpsys media.camera
	job battery dumpsys battery
	job sg_global settings_list_raw global
	job sg_secure settings_list_raw secure
	job sg_system settings_list_raw system
	job power dumpsys power
	job connectivity dumpsys connectivity
	job wifi_status cmd wifi status
	job telephony dumpsys telephony.registry
	job route net_route_raw
	job siminfo net_siminfo_raw
	for h in 1.1.1.1 8.8.8.8 google.com; do job "ping_$h" net_ping_raw "$h"; done
	job tethering dumpsys tethering
	job bluetooth dumpsys bluetooth_manager
	job nfc dumpsys nfc
	job uwb dumpsys uwb
	[ "$NO_LOGCAT" -eq 0 ] && job logcat logcat_errors
	[ "$PART_LOADED" -eq 1 ] || load_partitions
	part_targets
	[ "${#REPLY_A[@]}" -gt 0 ] && job df_parts df -k "${REPLY_A[@]}"
	job biometric dumpsys biometric
	job fingerprint dumpsys fingerprint
	job face dumpsys face
	prop ro.product.manufacturer
	if [[ "${REPLY,,}" == *google* ]]; then
		job widevine dumpsys android.hardware.drm.IDrmFactory/widevine
		job sensors dumpsys sensorservice
		job pkg_aicore dumpsys package com.google.android.aicore
	fi
	[ -d "$R/sys/devices/platform/google,charger" ] && job notif_list cmd notification list
	job home cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME
	job usagestats dumpsys usagestats
	job pkg_mainline dumpsys package com.google.android.modulemetadata
	[ "$EXTENDED" -eq 1 ] && lsp_prefetch
}

run_monitor() {
	check_dependencies || return $?
	SYSTEM_STATUS=$EXIT_OK
	open_log
	load_props
	load_verified_boot
	# [3.16] Кэши прохода: в режиме --loop каждый проход читает всё заново
	sg_reset; PART_LOADED=0; KCFG_LOADED=0
	jobs_init

	if [ "$DRY_RUN" -eq 1 ]; then
		run_dry
		local rc=$?
		jobs_done
		close_log
		return $rc
	fi

	load_zones
	load_thermal_hal

	print_header
	check_storage
	check_memory
	check_cpu
	prefetch
	check_thermal
	check_gpu
	if [ "$EXTENDED" -eq 1 ]; then
		check_cameras
	fi
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
	check_security
	if [ "$EXTENDED" -eq 1 ]; then
		check_spoofing
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
	jobs_done
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
		pid=$(cat "$LOCK_DIR/pid" 2>/dev/null); local opid="$pid"
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
		# [3.15.5] По аудиту: два монитора могли одновременно счесть блокировку
		# мёртвой, и второй удалял уже свежую блокировку первого. Теперь мёртвую
		# блокировку атомарно переименовываем и проверяем, что унесли именно её
		# (тот же PID); если нет — возвращаем на место и выходим.
		local stale_pid gone="$LOCK_DIR.stale.$$"
		stale_pid="$opid"
		if mv "$LOCK_DIR" "$gone" 2>/dev/null; then
			if [ "$(cat "$gone/pid" 2>/dev/null)" != "$stale_pid" ]; then
				mv "$gone" "$LOCK_DIR" 2>/dev/null
				printf '[!] Мониторинг уже запущен другим процессом\n' >&2; return $EXIT_INTERNAL
			fi
			rm -rf "$gone"
		fi
		mkdir "$LOCK_DIR" 2>/dev/null || { printf '[!] Мониторинг уже запущен другим процессом\n' >&2; return $EXIT_INTERNAL; }
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
	trap 'release_lock; jobs_done' EXIT
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
	trap 'jobs_done' EXIT
	clear_screen
	run_monitor
	exit $?
fi

# ─────────────────────────────────────────────────────────────────────────────
# [3.15] История изменений перенесена в monitor_changelog.md в корне репозитория.
