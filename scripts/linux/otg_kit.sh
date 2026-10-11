#!/system/bin/sh
# shellcheck shell=bash
#
# OTG RESCUE TOOLKIT v2 — спасение Android-устройств по OTG с другого телефона
# Автор: GoldenFrog
# Цели: POCO / Xiaomi (Snapdragon), Google Pixel (Tensor), частично Samsung
# Хост: rooted Android + bash (MT Manager / Termux) + adb/fastboot
#
# Запуск:  su -c sh /sdcard/otg_kit.sh        (сам найдёт bash)
#          или: tsu → bash otg_kit.sh
# Папка для образов/дампов/логов: /sdcard/OTG_ToolKit (переопределить: OTG_WORKDIR)
#
# Главное в v2 (подробности — в конце файла):
#  - единый интерфейс: одна шапка, одинаковые меню, подтверждения и сообщения;
#  - все команды адресуются конкретному устройству (-s SERIAL), выбор при 2+;
#  - исправлены опасные баги v1: блокировка загрузчика без подтверждения,
#    `rm -rf` по вводу пользователя, «проверка статуса», которая на самом деле
#    делала unlock_critical, падение пункта FRP (local вне функции),
#    несуществующий `fastboot reboot rescue`, слот хоста вместо слота цели и др.

# ── bash обязателен: если запустили через sh — перезапускаемся в bash ──────────
if [ -z "${BASH_VERSION:-}" ]; then
	for _b in "$(command -v bash 2>/dev/null)" \
		/data/data/com.termux/files/usr/bin/bash \
		/data/user/0/bin.mt.plus/files/term/bin/bash \
		/data/data/bin.mt.plus/files/term/bin/bash \
		/system/xbin/bash /system/bin/bash /usr/bin/bash /bin/bash; do
		[ -n "$_b" ] && [ -x "$_b" ] && exec "$_b" "$0" "$@"
	done
	echo "[!] Нужен bash (MT Manager / Termux). Не найден." >&2
	exit 1
fi

# ═════════════════════════════════════════════════════════════════════════════
#  КОНФИГУРАЦИЯ
# ═════════════════════════════════════════════════════════════════════════════

readonly VERSION="2.0.0"
readonly BUILD_DATE="10.10.2026"

WORKDIR="${OTG_WORKDIR:-/sdcard/OTG_ToolKit}"
LOG_FILE="$WORKDIR/otg_kit.log"

# adb/fastboot из Termux и MT Manager, даже если запустили через голый su
for _d in /data/data/com.termux/files/usr/bin /data/user/0/bin.mt.plus/files/term/bin \
	/data/data/bin.mt.plus/files/term/bin; do
	[ -d "$_d" ] && case ":$PATH:" in *":$_d:"*) ;; *) PATH="$PATH:$_d" ;; esac
done
export PATH

ADB_BIN="${ADB_BIN:-adb}"
FB_BIN="${FB_BIN:-fastboot}"

# ── Цвета (выключаются, если вывод не в терминал или задан NO_COLOR) ─────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
	C_BLU=$'\033[1;34m'; C_CYN=$'\033[1;36m'; C_BLD=$'\033[1m'
	C_DIM=$'\033[2m';    C_NC=$'\033[0m'
else
	C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYN=""; C_BLD=""; C_DIM=""; C_NC=""
fi

# ═════════════════════════════════════════════════════════════════════════════
#  UI — единые элементы интерфейса
# ═════════════════════════════════════════════════════════════════════════════

readonly LINE="─────────────────────────────────────────────────"
readonly DLINE="═════════════════════════════════════════════════"

info() { printf '%s[*]%s %s\n' "$C_BLU" "$C_NC" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_NC" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_NC" "$*"; }
err()  { printf '%s[✗]%s %s\n' "$C_RED" "$C_NC" "$*"; }
note() { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_NC"; }

# Заголовок экрана операции
title() {
	printf '\n%s%s%s\n' "$C_CYN" "$LINE" "$C_NC"
	printf ' %s%s%s\n' "$C_BLD" "$*" "$C_NC"
	printf '%s%s%s\n' "$C_CYN" "$LINE" "$C_NC"
}

# Группа пунктов меню: section "Название" [цвет]
section() {
	if [ -n "$1" ]; then printf '\n %s%s%s\n' "${2:-$C_CYN}" "$1" "$C_NC"; else printf '\n'; fi
}

# Пункт меню: item НОМЕР "Название" ["подсказка"]
item() {
	printf '  %s%2s%s  %s' "$C_BLD" "$1" "$C_NC" "$2"
	[ -n "${3:-}" ] && printf '  %s· %s%s' "$C_DIM" "$3" "$C_NC"
	printf '\n'
}

pause() {
	printf '\n%sНажмите Enter, чтобы вернуться в меню…%s' "$C_DIM" "$C_NC"
	IFS= read -r _ || true
}

# ask "Вопрос" → $REPLY (EOF = пустая строка)
ask() {
	printf '%s?%s %s ' "$C_CYN" "$C_NC" "$1"
	IFS= read -r REPLY || REPLY=""
}

# confirm_yn "Вопрос" — y/д = да, всё остальное = нет
confirm_yn() {
	ask "$1 [y/N]:"
	case "$REPLY" in y|Y|yes|д|Д|да) return 0 ;; *) return 1 ;; esac
}

# confirm_word СЛОВО "что произойдёт" — для необратимых операций
confirm_word() {
	printf '%s%s%s\n' "$C_RED" "$2" "$C_NC"
	ask "Для подтверждения введите ${C_BLD}$1${C_NC}:"
	if [ "$REPLY" = "$1" ]; then return 0; fi
	info "Отменено."
	return 1
}

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${SERIAL:--}" "$*" >> "$LOG_FILE" 2>/dev/null; }

# run КОМАНДА... — показать, выполнить, залогировать, сообщить результат
run() {
	local shown="$*"
	case "$shown" in
		"A "*) shown="adb ${shown#A }" ;;
		"F "*) shown="fastboot ${shown#F }" ;;
	esac
	printf '%s  $ %s%s\n' "$C_DIM" "$shown" "$C_NC"
	log "RUN $shown"
	"$@"
	local rc=$?
	log "RC=$rc"
	if [ $rc -eq 0 ]; then ok "Выполнено."; else err "Команда завершилась с кодом $rc."; fi
	return $rc
}

# Экранирование строки для удалённого sh: 'a'\''b'
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

hsize() {
	local b=${1:-0}
	if   [ "$b" -ge 1073741824 ]; then awk -v b="$b" 'BEGIN{printf "%.2f ГБ", b/1073741824}'
	elif [ "$b" -ge 1048576 ];    then awk -v b="$b" 'BEGIN{printf "%.1f МБ", b/1048576}'
	elif [ "$b" -ge 1024 ];       then awk -v b="$b" 'BEGIN{printf "%.1f КБ", b/1024}'
	else printf '%d Б' "$b"; fi
}

valid_part() { [[ "$1" =~ ^[A-Za-z0-9_]{1,64}$ ]]; }

# ═════════════════════════════════════════════════════════════════════════════
#  ОКРУЖЕНИЕ ХОСТА
# ═════════════════════════════════════════════════════════════════════════════

check_env() {
	local miss=""
	command -v "$ADB_BIN" >/dev/null 2>&1 || miss="adb"
	command -v "$FB_BIN"  >/dev/null 2>&1 || miss="${miss:+$miss, }fastboot"
	if [ -n "$miss" ]; then
		err "Не найдено: $miss"
		note "Termux:      pkg install android-tools"
		note "MT Manager:  положите бинарники в /data/user/0/bin.mt.plus/files/term/bin/"
		exit 1
	fi

	if [ "$(id -u)" != "0" ]; then
		warn "Скрипт запущен без root."
		note "На Android-хосте без root adb/fastboot обычно не видят OTG-устройство."
		note "Запустите: su -c sh $0"
		confirm_yn "Продолжить без root?" || exit 1
	fi

	if ! mkdir -p "$WORKDIR" 2>/dev/null || [ ! -w "$WORKDIR" ]; then
		err "Нет записи в $WORKDIR"
		note "Укажите другую папку: OTG_WORKDIR=/data/local/tmp/otg sh $0"
		exit 1
	fi

	# под su HOME часто «/» — adb не сможет сохранить ключ и будет падать
	if [ -z "${HOME:-}" ] || [ ! -w "${HOME:-/}" ]; then
		export HOME="$WORKDIR/.home"
		mkdir -p "$HOME"
	fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  УСТРОЙСТВО: обнаружение, выбор, сведения
# ═════════════════════════════════════════════════════════════════════════════

SERIAL=""        # выбранное устройство
STATE="NONE"     # NONE MULTI SYSTEM RECOVERY SIDELOAD RESCUE UNAUTHORIZED OFFLINE NOPERM BOOTLOADER FASTBOOTD
DEVLIST=()       # строки "серийник|состояние|транспорт"

A() { "$ADB_BIN" -s "$SERIAL" "$@"; }
F() { "$FB_BIN" -s "$SERIAL" "$@"; }

# Читаем шину USB напрямую из sysfs: видно, подключено ли что-то к OTG вообще,
# в каком режиме устройство (ADB / fastboot / EDL / Download) — даже если
# adb/fastboot его не видят. Сетевые adb-устройства (Wi-Fi) отсекаются.
# Разрешить сеть всё-таки: OTG_ALLOW_NET=1

USB_SYS="${OTG_USB_SYSFS:-/sys/bus/usb/devices}"
TYPEC_SYS="${OTG_TYPEC_SYSFS:-/sys/class/typec}"
USB_DEVS=()    # "порт|vid:pid|режим|название|скорость|серийник"
USB_MODE=""    # режим первого найденного телефона: adb fastboot edl download brom
USB_HOST=0     # 1 — на хосте есть корневой USB-хаб (OTG-хост активен)

# Серийник пришёл по USB, а не по сети (ip:port, mDNS, tcp:)?
is_usb_serial() {
	[ "${OTG_ALLOW_NET:-0}" = "1" ] && return 0
	case "$1" in
		*:*|*._adb-tls-*|*._tcp*) return 1 ;;
	esac
	return 0
}

usb_vendor() {
	case "$1" in
		18d1) echo Google ;;   2717) echo Xiaomi ;;  05c6) echo Qualcomm ;;
		04e8) echo Samsung ;;  22b8) echo Motorola ;; 2a70) echo OnePlus ;;
		12d1) echo Huawei ;;   22d9) echo OPPO ;;     2d95) echo vivo ;;
		0e8d) echo MediaTek ;; 0bb4) echo HTC ;;      1004) echo LG ;;
	esac
}

# Режим устройства по VID:PID и USB-интерфейсам (класс/подкласс/протокол)
#   ADB      — ff/42/01      fastboot — ff/42/03
#   EDL 9008 — 05c6:9008     Samsung Download (Odin) — 04e8:685d
#   MediaTek BROM — 0e8d:0003
usb_mode() {
	local d="$1" id="$2" i c mode=""
	case "$id" in
		05c6:9008) echo edl; return ;;
		04e8:685d) echo download; return ;;
		0e8d:0003) echo brom; return ;;
	esac
	for i in "$d"/*:*; do
		[ -f "$i/bInterfaceClass" ] || continue
		c="$(cat "$i/bInterfaceClass" "$i/bInterfaceSubClass" "$i/bInterfaceProtocol" 2>/dev/null | tr -d '\n')"
		case "$c" in
			ff4201) mode=adb ;;
			ff4203) [ -z "$mode" ] && mode=fastboot ;;
			060101) [ -z "$mode" ] && mode=mtp ;;
		esac
	done
	echo "${mode:-other}"
}

usb_scan() {
	USB_DEVS=(); USB_MODE=""; USB_HOST=0
	[ -d "$USB_SYS" ] || return 0
	local d n id mode name speed ser
	for d in "$USB_SYS"/*; do
		n="${d##*/}"
		case "$n" in
			usb*) USB_HOST=1; continue ;;   # корневой хаб контроллера
			*:*)  continue ;;               # интерфейсы, не устройства
		esac
		[ -f "$d/idVendor" ] || continue
		[ "$(cat "$d/bDeviceClass" 2>/dev/null)" = "09" ] && continue   # хабы в переходниках
		id="$(cat "$d/idVendor" 2>/dev/null):$(cat "$d/idProduct" 2>/dev/null)"
		mode=$(usb_mode "$d" "$id")
		name=$(cat "$d/product" 2>/dev/null)
		[ -n "$name" ] || name=$(usb_vendor "${id%%:*}")
		speed=$(cat "$d/speed" 2>/dev/null)
		ser=$(cat "$d/serial" 2>/dev/null)
		USB_DEVS+=("$n|$id|$mode|${name:-неизвестно}|$speed|$ser")
		case "$mode" in
			adb|fastboot|edl|download|brom) [ -z "$USB_MODE" ] && USB_MODE="$mode" ;;
		esac
	done
}

# Роль USB-порта хоста по Type-C: host / device / пусто (нет данных)
usb_host_role() {
	local r
	for r in "$TYPEC_SYS"/port*/data_role; do
		[ -f "$r" ] || continue
		sed -n 's/.*\[\(.*\)\].*/\1/p' "$r" 2>/dev/null
		return
	done
}

usb_speed_label() {
	case "$1" in
		1.5)   echo "USB 1.0 (1.5 Мбит/с)" ;;
		12)    echo "USB 1.1 (12 Мбит/с)" ;;
		480)   echo "USB 2.0 (480 Мбит/с)" ;;
		5000)  echo "USB 3.0 (5 Гбит/с)" ;;
		10000) echo "USB 3.1 (10 Гбит/с)" ;;
		20000) echo "USB 3.2 (20 Гбит/с)" ;;
		'')    echo "" ;;
		*)     echo "$1 Мбит/с" ;;
	esac
}

usb_mode_label() {
	case "$1" in
		adb)      echo "ADB" ;;
		fastboot) echo "Fastboot" ;;
		edl)      echo "${C_RED}EDL 9008${C_NC}" ;;
		download) echo "${C_YEL}Samsung Download${C_NC}" ;;
		brom)     echo "${C_RED}MediaTek BROM${C_NC}" ;;
		mtp)      echo "MTP (без отладки)" ;;
		*)        echo "другое" ;;
	esac
}

# Строка для шапки: USB-запись выбранного устройства (по серийнику) или первая
usb_header_line() {
	[ ${#USB_DEVS[@]} -gt 0 ] || return 0
	local e pick="" f
	for e in "${USB_DEVS[@]}"; do
		[ -n "$SERIAL" ] && [ "${e##*|}" = "$SERIAL" ] && { pick="$e"; break; }
	done
	[ -n "$pick" ] || pick="${USB_DEVS[0]}"
	IFS='|' read -r -a f <<< "$pick"
	printf ' USB        : %s  %s%s%s\n' "${f[1]}" "$C_DIM" "$(usb_speed_label "${f[4]}")" "$C_NC"
	if [ "${f[4]}" = "12" ] || [ "${f[4]}" = "1.5" ]; then
		warn "Низкая скорость USB — плохой кабель/переходник, дамп и прошивка будут очень долгими."
	fi
}

# Подсказка, почему меню не появилось (вызывается на экране ожидания)
usb_hint() {
	case "$USB_MODE" in
		edl)
			err "Устройство в EDL (Qualcomm 9008) — аварийный режим загрузчика."
			note "adb/fastboot тут бессильны: нужен MiFlash/QFIL и авторизованный аккаунт."
			note "Иногда помогает выход: зажать Power + Vol− на 15–20 с."
			return ;;
		download)
			warn "Samsung в режиме Download (Odin)."
			note "Прошивка — через Odin/Heimdall, этот скрипт с ним не работает."
			return ;;
		brom)
			err "MediaTek в режиме BROM — нужен SP Flash Tool / mtkclient."
			return ;;
		adb)
			warn "По USB виден ADB-интерфейс, но adb не видит устройство."
			note "Запустите скрипт от root и перезапустите ADB-сервер (пункт 2)."
			return ;;
		fastboot)
			warn "По USB виден fastboot-интерфейс, но fastboot не видит устройство."
			note "Запустите скрипт от root."
			return ;;
	esac
	if [ ${#USB_DEVS[@]} -gt 0 ]; then
		warn "Устройство подключено по USB, но без отладки."
		note "Включите «Отладка по USB» и выберите режим USB «Передача файлов»."
		return
	fi
	if [ "$USB_HOST" -eq 0 ] && [ "$(usb_host_role)" != "host" ]; then
		err "OTG не активен — хост не видит ничего на USB."
		note "1. Включите OTG (Xiaomi/POCO: Настройки → Доп. настройки → OTG)."
		note "2. Нужен кабель с передачей данных (не только зарядный) и рабочий переходник."
		note "3. Подключайте OTG-концом к ХОСТУ, обычным — к целевому устройству."
	else
		warn "OTG активен, но к нему ничего не подключено."
		note "Проверьте кабель/переходник и что целевое устройство включено."
	fi
}

# Экран «Диагностика USB»
op_usb_diag() {
	title "ДИАГНОСТИКА USB / OTG"
	usb_scan
	local role; role=$(usb_host_role)
	printf ' Роль порта хоста : %s\n' "${role:-нет данных (нет /sys/class/typec)}"
	printf ' USB-контроллер   : %s\n' "$([ "$USB_HOST" -eq 1 ] && echo "${C_GRN}хост активен${C_NC}" || echo "${C_RED}не активен${C_NC}")"
	echo
	if [ ${#USB_DEVS[@]} -eq 0 ]; then
		echo " Устройств на шине USB нет."
	else
		local e f vend
		for e in "${USB_DEVS[@]}"; do
			IFS='|' read -r -a f <<< "$e"
			vend=$(usb_vendor "${f[1]%%:*}")
			printf '  %s%s%s  %s%s\n' "$C_BLD" "${f[1]}" "$C_NC" "${f[3]}" "${vend:+  ($vend)}"
			note "режим: $(usb_mode_label "${f[2]}")   $(usb_speed_label "${f[4]}")   порт: ${f[0]}${f[5]:+   серийник: ${f[5]}}"
		done
	fi
	echo
	local s
	s=$("$ADB_BIN" devices 2>/dev/null | tr -d '\r' | awk 'NR>1 && NF' | sed 's/^/    /')
	echo " adb devices:"; printf '%s\n' "${s:-    (пусто)}"
	s=$("$FB_BIN" devices 2>/dev/null | tr -d '\r' | awk 'NF' | sed 's/^/    /')
	echo " fastboot devices:"; printf '%s\n' "${s:-    (пусто)}"
	echo
	usb_hint
	pause
}

scan_devices() {
	DEVLIST=()
	local s st rest
	while read -r s st rest; do
		[ -n "$s" ] || continue
		is_usb_serial "$s" || continue      # ← новая строка
		DEVLIST+=("$s|$st|adb")
	done < <("$ADB_BIN" devices 2>/dev/null | tr -d '\r' | awk 'NR>1 && NF')
	while read -r s st rest; do
		[ -n "$s" ] || continue
		is_usb_serial "$s" || continue      # ← новая строка
		DEVLIST+=("$s|${st:-fastboot}|fastboot")
	done < <("$FB_BIN" devices 2>/dev/null | tr -d '\r' | awk 'NF')
}

state_of() {   # $1 = "серийник|состояние|транспорт"
	local st="${1#*|}"; local tr="${st#*|}"; st="${st%%|*}"
	if [ "$tr" = "fastboot" ]; then echo "FASTBOOT"; return; fi
	case "$st" in
		device)       echo SYSTEM ;;
		recovery)     echo RECOVERY ;;
		sideload)     echo SIDELOAD ;;
		rescue)       echo RESCUE ;;
		unauthorized) echo UNAUTHORIZED ;;
		no*)          echo NOPERM ;;
		*)            echo OFFLINE ;;
	esac
}

refresh_status() {
	usb_scan
	scan_devices
	local n=${#DEVLIST[@]} e found=""
	if [ "$n" -eq 0 ]; then
		SERIAL=""
		if [ ${#USB_DEVS[@]} -eq 0 ]; then STATE="NOUSB"; else STATE="NONE"; fi
		load_info   # сбросить сведения об отключённом устройстве
		return
	fi
	# выбранное ранее устройство всё ещё подключено?
	if [ -n "$SERIAL" ]; then
		for e in "${DEVLIST[@]}"; do
			[ "${e%%|*}" = "$SERIAL" ] && { found="$e"; break; }
		done
	fi
	if [ -z "$found" ]; then
		if [ "$n" -eq 1 ]; then
			found="${DEVLIST[0]}"
		else
			SERIAL=""; STATE="MULTI"; return
		fi
	fi
	local prev_state="$STATE" prev_serial="$SERIAL"
	SERIAL="${found%%|*}"
	STATE=$(state_of "$found")
	if [ "$STATE" = "FASTBOOT" ]; then
		if [ "$(fb_var is-userspace)" = "yes" ]; then STATE="FASTBOOTD"; else STATE="BOOTLOADER"; fi
	fi
	# сведения обновляем только при смене устройства/режима — меню не тормозит
	if [ "$STATE" != "$prev_state" ] || [ "$SERIAL" != "$prev_serial" ]; then
		T_ROOT=""
		load_info
	fi
}

pick_device() {
	title "НАЙДЕНО НЕСКОЛЬКО УСТРОЙСТВ"
	local i=1 e
	for e in "${DEVLIST[@]}"; do
		item "$i" "${e%%|*}" "$(state_of "$e")"
		i=$((i + 1))
	done
	item 0 "Выход"
	echo
	ask "Выберите устройство:"
	case "$REPLY" in
		0) exit_kit ;;
		''|*[!0-9]*) return ;;
	esac
	if [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#DEVLIST[@]}" ]; then
		e="${DEVLIST[$((REPLY - 1))]}"
		SERIAL="${e%%|*}"
		STATE=""   # заставим refresh_status перечитать сведения
	fi
}

# Значение fastboot getvar без мусора ("unlocked: yes" → "yes")
fb_var() {
	F getvar "$1" 2>&1 | tr -d '\r' | awk -v k="$1" '
		{ sub(/^\(bootloader\) /, "") }
		index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit }'
}

# Сведения об устройстве для шапки и проверок
D_MODEL=""; D_CODENAME=""; D_MAKER=""; D_SOC=""; D_SLOT=""; D_ANDROID=""
D_UNLOCKED=""; D_BLVER=""; D_SECURE=""
DEVICE_TYPE="unknown"     # xiaomi / pixel / samsung / unknown
declare -A KNOWN_TYPE     # запоминаем производителя по серийнику (в fastboot его не узнать)
declare -A WARNED         # предупреждение показано для этого серийника

load_info() {
	D_MODEL=""; D_CODENAME=""; D_MAKER=""; D_SOC=""; D_SLOT=""; D_ANDROID=""
	D_UNLOCKED=""; D_BLVER=""; D_SECURE=""
	case "$STATE" in
		SYSTEM|RECOVERY)
			local -a p
			mapfile -t p < <(A shell 'getprop ro.product.model; getprop ro.product.device;
				getprop ro.product.manufacturer; getprop ro.product.brand;
				getprop ro.soc.manufacturer; getprop ro.soc.model;
				getprop ro.boot.slot_suffix; getprop ro.build.version.release' 2>/dev/null | tr -d '\r')
			D_MODEL="${p[0]:-}"; D_CODENAME="${p[1]:-}"
			D_MAKER="$(printf '%s %s' "${p[2]:-}" "${p[3]:-}" | tr '[:upper:]' '[:lower:]')"
			D_SOC="$(printf '%s %s' "${p[4]:-}" "${p[5]:-}" | sed 's/^ *//; s/ *$//')"
			D_SLOT="${p[6]#_}"; D_ANDROID="${p[7]:-}"
			case "$D_MAKER" in
				*xiaomi*|*redmi*|*poco*) DEVICE_TYPE="xiaomi" ;;
				*google*)                DEVICE_TYPE="pixel" ;;
				*samsung*)               DEVICE_TYPE="samsung" ;;
				*)                       DEVICE_TYPE="unknown" ;;
			esac
			[ -n "$SERIAL" ] && KNOWN_TYPE[$SERIAL]="$DEVICE_TYPE"
			;;
		BOOTLOADER|FASTBOOTD)
			D_CODENAME="$(fb_var product)"
			D_SLOT="$(fb_var current-slot)"
			D_UNLOCKED="$(fb_var unlocked)"
			D_SECURE="$(fb_var secure)"
			[ "$STATE" = "BOOTLOADER" ] && D_BLVER="$(fb_var version-bootloader)"
			DEVICE_TYPE="${KNOWN_TYPE[$SERIAL]:-unknown}"
			# Pixel узнаём по кодовому имени и в fastboot
			if [ "$DEVICE_TYPE" = "unknown" ] && is_pixel_codename "$D_CODENAME"; then
				DEVICE_TYPE="pixel"
			fi
			;;
		RESCUE)
			D_CODENAME="$(A rescue getprop ro.product.device 2>/dev/null | tr -d '\r')"
			DEVICE_TYPE="pixel"
			;;
	esac
	[ -z "$D_SOC" ] && D_SOC="$(soc_by_codename "$D_CODENAME")"
}

is_pixel_codename() {
	case "$1" in
		oriole|raven|bluejay|panther|cheetah|lynx|tangorpro|felix|shiba|husky|akita|\
		tokay|caiman|komodo|comet|tegu|frankel|blazer|mustang|rango) return 0 ;;
	esac
	return 1
}

soc_by_codename() {
	case "$1" in
		oriole|raven|bluejay)                       echo "Google Tensor" ;;
		panther|cheetah|lynx|tangorpro|felix)       echo "Google Tensor G2" ;;
		shiba|husky|akita)                          echo "Google Tensor G3" ;;
		tokay|caiman|komodo|comet|tegu)             echo "Google Tensor G4" ;;
		frankel|blazer|mustang|rango)               echo "Google Tensor G5" ;;
		alioth|apollo|lmi|cmi|umi|cas|thyme|munch)  echo "Snapdragon 8xx" ;;
	esac
}

# ═════════════════════════════════════════════════════════════════════════════
#  ШАПКА
# ═════════════════════════════════════════════════════════════════════════════

state_label() {
	case "$STATE" in
		SYSTEM)       printf '%sSYSTEM%s (ADB)' "$C_GRN" "$C_NC" ;;
		RECOVERY)     printf '%sRECOVERY%s (ADB)' "$C_YEL" "$C_NC" ;;
		SIDELOAD)     printf '%sSIDELOAD%s (recovery)' "$C_YEL" "$C_NC" ;;
		RESCUE)       printf '%sRESCUE%s (Pixel)' "$C_YEL" "$C_NC" ;;
		BOOTLOADER)   printf '%sFASTBOOT%s (bootloader)' "$C_CYN" "$C_NC" ;;
		FASTBOOTD)    printf '%sFASTBOOTD%s (userspace)' "$C_CYN" "$C_NC" ;;
		UNAUTHORIZED) printf '%sUNAUTHORIZED%s' "$C_RED" "$C_NC" ;;
		OFFLINE)      printf '%sOFFLINE%s' "$C_RED" "$C_NC" ;;
		NOPERM)       printf '%sNO PERMISSIONS%s' "$C_RED" "$C_NC" ;;
		MULTI)        printf '%sНЕСКОЛЬКО УСТРОЙСТВ%s' "$C_YEL" "$C_NC" ;;
		NOUSB)        printf '%sНЕТ USB-УСТРОЙСТВ%s' "$C_RED" "$C_NC" ;;
		*)            printf '%sНЕ ПОДКЛЮЧЕНО%s' "$C_RED" "$C_NC" ;;
	esac
}

header() {
	[ -t 1 ] && clear
	printf '%s%s%s\n' "$C_BLU" "$DLINE" "$C_NC"
	printf ' %sOTG RESCUE TOOLKIT%s  v%s  %s%s%s\n' "$C_BLD" "$C_NC" "$VERSION" "$C_DIM" "$BUILD_DATE" "$C_NC"
	printf '%s%s%s\n' "$C_BLU" "$DLINE" "$C_NC"

	local name="${D_MODEL:-}"
	[ -n "$D_CODENAME" ] && name="${name:+$name }($D_CODENAME)"
	printf ' Режим      : %s\n' "$(state_label)"
	[ -n "$name" ]      && printf ' Устройство : %s%s%s\n' "$C_GRN" "$name" "$C_NC"
	[ -n "$D_SOC" ]     && printf ' Чипсет     : %s\n' "$D_SOC"
	[ -n "$SERIAL" ]    && printf ' Серийник   : %s\n' "$SERIAL"
	[ -n "$D_ANDROID" ] && printf ' Android    : %s\n' "$D_ANDROID"
	if [ -n "$D_SLOT" ]; then
		printf ' Слот       : %s%s%s\n' "$C_YEL" "$D_SLOT" "$C_NC"
	fi
	if [ -n "$D_UNLOCKED" ]; then
		if [ "$D_UNLOCKED" = "yes" ]; then
			printf ' Загрузчик  : %sUNLOCKED%s' "$C_GRN" "$C_NC"
		else
			printf ' Загрузчик  : %sLOCKED%s' "$C_RED" "$C_NC"
		fi
		[ -n "$D_BLVER" ] && printf '  %s%s%s' "$C_DIM" "$D_BLVER" "$C_NC"
		printf '\n'
	fi
	usb_header_line
	printf '%s%s%s\n' "$C_BLU" "$LINE" "$C_NC"
}

# ═════════════════════════════════════════════════════════════════════════════
#  ПРЕДУПРЕЖДЕНИЯ ПО ПРОИЗВОДИТЕЛЮ (раз на устройство, перед опасными операциями)
# ═════════════════════════════════════════════════════════════════════════════

ensure_warned() {
	[ -n "${WARNED[$SERIAL]:-}" ] && return 0
	title "ПЕРЕД ОПАСНЫМИ ОПЕРАЦИЯМИ"
	case "$DEVICE_TYPE" in
		xiaomi)
			echo " Xiaomi / Redmi / POCO:"
			echo "  1. Нужен разблокированный загрузчик."
			echo "  2. Никогда не блокируйте загрузчик на кастомной прошивке."
			echo "  3. Проверьте Anti-Rollback (ARB) перед понижением прошивки."
			echo "  4. Не прошивайте более старые xbl/abl/tz и т.п."
			echo "  5. Не используйте «clean all and lock» в MiFlash."
			warn "Нарушение этих правил может привести к EDL (9008)."
			;;
		pixel)
			echo " Google Pixel:"
			echo "  1. AVB 2.0 и Rollback Index: даунгрейд может не загрузиться"
			echo "     даже на разблокированном загрузчике."
			echo "  2. Никогда не блокируйте загрузчик на несовместимой прошивке."
			echo "  3. Используйте только официальные factory/OTA образы."
			echo "  4. Pixel 6+: после прошивки bootloader с anti-rollback откат"
			echo "     на старые сборки становится невозможен."
			;;
		samsung)
			echo " Samsung:"
			echo "  1. Fastboot не используется — прошивка через Download Mode (Odin/Heimdall)."
			echo "  2. Неправильный CSC может вызвать bootloop."
			echo "  3. Версию загрузчика (BL) понизить нельзя."
			;;
		*)
			echo " Производитель не определён (в fastboot его не видно —"
			echo " подключите устройство в системе хотя бы раз за сеанс)."
			;;
	esac
	echo
	confirm_word "YES" "Все действия — на ваш страх и риск." || return 1
	WARNED[$SERIAL]=1
}

# ═════════════════════════════════════════════════════════════════════════════
#  AFE — Anti Flash & Erase: критичные разделы
# ═════════════════════════════════════════════════════════════════════════════

readonly -a AFE_BLACKLIST=(
	# цепочка загрузки
	abl xbl xbl_config xbl_ramdump pbl bl1 bl2 bl31 tz tzsw hyp aop aop_config
	devcfg cdt ddr qupfw dram_train ldfw pvmfw dpm uefi uefisecapp imagefv
	shrm cpucp featenabler multiimgoem bootloader
	# безопасность
	gsa fips keymaster keystore secdata ssd storsec mdtp mdtpsecapp
	# радио / калибровки
	modem radio modemst1 modemst2 modem_userdata fsg fsc efs efs_backup
	# уникальное для устройства
	persist devinfo
)

# afe_guard flash|erase РАЗДЕЛ
afe_guard() {
	local op="$1" t="${2,,}" b
	t="${t%_a}"; t="${t%_b}"
	if [ "$op" = "erase" ] && [ "$t" = "super" ]; then
		err "[AFE] Стирание super запрещено — это soft-brick (не будет fastbootd)."
		return 1
	fi
	for b in "${AFE_BLACKLIST[@]}"; do
		if [ "$t" = "$b" ]; then
			err "[AFE] Операция «$op» над разделом «$t» запрещена — риск hard-brick."
			[ "$t" = "bootloader" ] || [ "$t" = "radio" ] && \
				note "bootloader/radio прошивайте только через flash-all.sh / Android Flash Tool."
			return 1
		fi
	done
	return 0
}

# ═════════════════════════════════════════════════════════════════════════════
#  ФАЙЛЫ В WORKDIR
# ═════════════════════════════════════════════════════════════════════════════

# pick_file "Заголовок" расширение... → путь в $PICKED (выбор по номеру)
pick_file() {
	local what="$1"; shift
	local -a files=() expr=()
	local e f i
	for e in "$@"; do
		[ ${#expr[@]} -gt 0 ] && expr+=(-o)
		expr+=(-iname "*.$e")
	done
	mapfile -t files < <(find "$WORKDIR" -maxdepth 1 -type f \( "${expr[@]}" \) 2>/dev/null | sort)
	PICKED=""
	if [ ${#files[@]} -eq 0 ]; then
		err "В $WORKDIR нет файлов: $(printf '*.%s ' "$@")"
		note "Положите $what в эту папку и повторите."
		return 1
	fi
	echo " $what в $WORKDIR:"
	i=1
	for f in "${files[@]}"; do
		item "$i" "${f##*/}" "$(hsize "$(stat -c %s "$f" 2>/dev/null || wc -c < "$f")")"
		i=$((i + 1))
	done
	item 0 "Отмена"
	ask "Номер файла:"
	case "$REPLY" in ''|0|*[!0-9]*) info "Отменено."; return 1 ;; esac
	if [ "$REPLY" -gt ${#files[@]} ]; then err "Нет такого номера."; return 1; fi
	PICKED="${files[$((REPLY - 1))]}"
	return 0
}

# Тип образа по сигнатуре: boot / vendor_boot / vbmeta / sparse / dtbo / zip / unknown
img_kind() {
	local m
	m=$(head -c 8 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')
	case "$m" in
		414e44524f494421*) echo boot ;;          # ANDROID!
		564e4452424f4f54*) echo vendor_boot ;;   # VNDRBOOT
		41564230*)         echo vbmeta ;;        # AVB0
		ed26ff3a*)         echo sparse ;;
		d7b7ab1e*)         echo dtbo ;;
		504b0304*)         echo zip ;;
		*)                 echo unknown ;;
	esac
}

expected_kind() {
	case "${1,,}" in
		boot|boot_a|boot_b|init_boot*|recovery*) echo boot ;;
		vendor_boot*)                            echo vendor_boot ;;
		vbmeta*)                                 echo vbmeta ;;
		dtbo*)                                   echo dtbo ;;
		*)                                       echo "" ;;
	esac
}

# Проверка образа перед прошивкой/загрузкой. $1 — файл, $2 — раздел (или "boot")
check_image() {
	local file="$1" part="$2" kind want size
	size=$(stat -c %s "$file" 2>/dev/null || wc -c < "$file")
	kind=$(img_kind "$file")
	want=$(expected_kind "$part")
	info "Файл: ${file##*/} ($(hsize "$size")), тип: $kind"
	if [ "$kind" = "zip" ]; then
		err "Это ZIP-архив, а не образ. Распакуйте нужный .img (или используйте sideload)."
		return 1
	fi
	if [ "$size" -lt 4096 ]; then
		err "Файл слишком маленький для образа раздела."
		return 1
	fi
	if [ -n "$want" ] && [ "$kind" != "$want" ] && [ "$kind" != "sparse" ]; then
		warn "Ожидался образ типа «$want» для раздела «$part», а файл — «$kind»."
		confirm_word "FLASH" "Прошивка неподходящего образа может окирпичить устройство." || return 1
	fi
	return 0
}

# ═════════════════════════════════════════════════════════════════════════════
#  ROOT НА ЦЕЛЕВОМ УСТРОЙСТВЕ (для дампа, модулей, логов)
# ═════════════════════════════════════════════════════════════════════════════

T_ROOT=""   # direct (TWRP / adb root) | su (Magisk/KSU) | none

detect_target_root() {
	[ -n "$T_ROOT" ] && return 0
	if [ "$(A shell id -u 2>/dev/null | tr -d '\r')" = "0" ]; then
		T_ROOT="direct"
	else
		info "Запрашиваю root на целевом устройстве — подтвердите запрос на его экране."
		if [ "$(A shell "su -c 'id -u'" 2>/dev/null | tr -d '\r')" = "0" ]; then
			T_ROOT="su"
		else
			T_ROOT="none"
		fi
	fi
}

# tsh 'команда' — выполнить на цели от root (строка должна быть уже проверенной)
tsh() {
	case "$T_ROOT" in
		direct) A shell "$1" ;;
		su)     A shell "su -c $(shq "$1")" ;;
		*)      return 1 ;;
	esac
}

# texec — то же, но бинарно-чистый поток (для дампов)
texec() {
	case "$T_ROOT" in
		direct) A exec-out "$1" ;;
		su)     A exec-out "su -c $(shq "$1")" ;;
		*)      return 1 ;;
	esac
}

need_target_root() {
	detect_target_root
	if [ "$T_ROOT" = "none" ]; then
		err "Нет root на целевом устройстве."
		note "Нужен TWRP/OrangeFox или Magisk/KernelSU с выданным доступом для Shell."
		return 1
	fi
	return 0
}

# ═════════════════════════════════════════════════════════════════════════════
#  ОПЕРАЦИИ: ADB (система / recovery)
# ═════════════════════════════════════════════════════════════════════════════

adb_reboot() {   # $1 — цель (пусто = система), $2 — подпись
	info "Перезагрузка: ${2:-в систему}…"
	if [ -n "$1" ]; then run A reboot "$1"; else run A reboot; fi
	sleep 2
}

op_adb_shell() {
	title "ADB SHELL"
	note "Выход из оболочки: exit"
	A shell
	pause
}

op_logcat_errors() {
	title "LOGCAT: последние ошибки"
	A logcat -d '*:E' 2>/dev/null | tail -n 50
	pause
}

# Сбор диагностики в папку: getprop, logcat, crash, dmesg, ramoops/last_kmsg
op_collect_logs() {
	title "СБОР ДИАГНОСТИКИ"
	local dir="$WORKDIR/diag_${D_CODENAME:-dev}_$(date +%Y%m%d-%H%M%S)"
	mkdir -p "$dir" || { err "Не удалось создать $dir"; pause; return; }

	case "$STATE" in
		BOOTLOADER|FASTBOOTD)
			F getvar all > "$dir/getvar_all.txt" 2>&1
			;;
		*)
			info "getprop, logcat…"
			A shell getprop > "$dir/getprop.txt" 2>&1
			A logcat -d -b all > "$dir/logcat.txt" 2>&1 || A logcat -d > "$dir/logcat.txt" 2>&1
			A logcat -d -b crash > "$dir/logcat_crash.txt" 2>/dev/null
			if confirm_yn "Собрать dmesg и логи прошлой загрузки (нужен root на цели)?"; then
				if need_target_root; then
					info "dmesg, pstore/ramoops, last_kmsg…"
					tsh 'dmesg' > "$dir/dmesg.txt" 2>&1
					tsh 'for f in /sys/fs/pstore/*; do [ -f "$f" ] && { echo "=== $f"; cat "$f"; }; done;
						[ -f /proc/last_kmsg ] && { echo "=== /proc/last_kmsg"; cat /proc/last_kmsg; }' \
						> "$dir/last_boot.txt" 2>&1
				fi
			fi
			;;
	esac
	find "$dir" -type f -size 0 -delete 2>/dev/null
	ok "Сохранено в: $dir"
	ls -la "$dir" 2>/dev/null | awk 'NR>1 && $NF !~ /^\.\.?$/ {print "    " $5 "\t" $NF}'
	log "DIAG $dir"
	pause
}

# Снятие дампа раздела с проверкой размера и MD5
op_dump_partition() {
	title "ДАМП РАЗДЕЛА"
	need_target_root || { pause; return; }

	local slot="$D_SLOT"
	note "Активный слот цели: ${slot:-нет (A-only)}. Список разделов — введите «?»."
	ask "Имя раздела (например, boot, init_boot, vendor_boot):"
	local part="$REPLY"
	if [ "$part" = "?" ]; then
		tsh 'ls /dev/block/by-name 2>/dev/null || ls /dev/block/bootdevice/by-name' | tr -d '\r' | tr '\n' ' ' | fold -s -w 60; echo
		ask "Имя раздела:"
		part="$REPLY"
	fi
	if ! valid_part "$part"; then
		err "Недопустимое имя раздела (только латиница, цифры и _)."
		pause; return
	fi

	# Ищем блочное устройство: сначала с суффиксом слота, потом без
	local path
	path=$(tsh "for d in /dev/block/by-name /dev/block/bootdevice/by-name; do
		for n in ${part}_${slot:-x} ${part}; do
			[ -e \"\$d/\$n\" ] && { echo \"\$d/\$n\"; exit 0; }
		done
	done" 2>/dev/null | tr -d '\r' | head -n 1)
	if [ -z "$path" ]; then
		err "Раздел «$part» не найден на устройстве."
		pause; return
	fi

	local size
	size=$(tsh "blockdev --getsize64 $path" 2>/dev/null | tr -d '\r' | grep -oE '^[0-9]+' | head -n 1)
	if [ -z "$size" ] || [ "$size" -eq 0 ]; then
		err "Не удалось получить размер $path."
		pause; return
	fi
	info "Раздел: $path ($(hsize "$size"))"

	local free_kb
	free_kb=$(df -k "$WORKDIR" 2>/dev/null | awk 'END{print $(NF-2)}')
	if [[ "$free_kb" =~ ^[0-9]+$ ]] && [ $((free_kb * 1024)) -lt $((size + 67108864)) ]; then
		err "Мало места на хосте: нужно $(hsize "$size"), свободно $(hsize $((free_kb * 1024)))."
		pause; return
	fi

	local out="$WORKDIR/${path##*/}_$(date +%Y%m%d-%H%M%S).img"
	info "Копирование… (не отключайте кабель)"
	texec "cat $path" > "$out"
	local got
	got=$(stat -c %s "$out" 2>/dev/null || wc -c < "$out")
	if [ "$got" != "$size" ]; then
		err "Размер не совпал: получено $got из $size байт. Дамп удалён."
		note "Попробуйте другой кабель/переходник."
		rm -f "$out"; log "DUMP FAIL $path"
		pause; return
	fi
	ok "Размер совпадает: $got байт."

	info "Сверка MD5…"
	local tm hm
	tm=$(tsh "md5sum $path" 2>/dev/null | tr -d '\r' | awk '{print $1}')
	hm=$(md5sum "$out" 2>/dev/null | awk '{print $1}')
	if [ -n "$tm" ] && [ "$tm" = "$hm" ]; then
		ok "MD5 совпадает: $hm"
		ok "Дамп: $out"
		log "DUMP OK $path → $out md5=$hm"
	else
		err "MD5 не совпал (цель: ${tm:-?}, хост: ${hm:-?}). Дамп удалён."
		rm -f "$out"; log "DUMP MD5 FAIL $path"
	fi
	pause
}

# Модули Magisk / KernelSU: отключить, удалить, аварийный сброс
op_magisk_modules() {
	title "МОДУЛИ MAGISK / KERNELSU"
	need_target_root || { pause; return; }

	local -a mods=()
	mapfile -t mods < <(tsh 'cd /data/adb/modules 2>/dev/null || exit 3
		for m in *; do
			[ -d "$m" ] || continue
			st=on; [ -f "$m/disable" ] && st=off; [ -f "$m/remove" ] && st=del
			nm=$(grep -m1 "^name=" "$m/module.prop" 2>/dev/null | cut -d= -f2-)
			echo "$m|$st|$nm"
		done' 2>/dev/null | tr -d '\r')

	if [ ${#mods[@]} -eq 0 ]; then
		warn "Модули не найдены (или /data зашифрован / нет доступа)."
		pause; return
	fi

	local i=1 e id st nm lbl
	for e in "${mods[@]}"; do
		id="${e%%|*}"; st="${e#*|}"; nm="${st#*|}"; st="${st%%|*}"
		case "$st" in
			on)  lbl="${C_GRN}вкл${C_NC}" ;;
			off) lbl="${C_YEL}выкл${C_NC}" ;;
			del) lbl="${C_RED}удалится${C_NC}" ;;
		esac
		printf '  %s%2d%s  [%s] %s  %s%s%s\n' "$C_BLD" "$i" "$C_NC" "$lbl" "$id" "$C_DIM" "$nm" "$C_NC"
		i=$((i + 1))
	done

	section "Действия"
	item d "Отключить модуль" "файл disable, обратимо"
	item e "Включить модуль"
	item r "Удалить модуль" "файл remove, удалится при загрузке"
	item D "Отключить ВСЕ" "главное средство от bootloop"
	item 0 "Назад"
	ask "Выбор:"
	local act="$REPLY" n target flag
	case "$act" in
		D)
			tsh 'for m in /data/adb/modules/*/; do touch "$m/disable"; done' \
				&& ok "Все модули отключены. Перезагрузите устройство." \
				|| err "Не удалось."
			log "MODULES disable all"
			pause; return ;;
		d|e|r) ;;
		*) return ;;
	esac
	ask "Номер модуля:"
	n="$REPLY"
	case "$n" in ''|*[!0-9]*) info "Отменено."; pause; return ;; esac
	if [ "$n" -lt 1 ] || [ "$n" -gt ${#mods[@]} ]; then err "Нет такого номера."; pause; return; fi
	target="${mods[$((n - 1))]%%|*}"
	# id модуля приходит с устройства — проверяем, прежде чем вставлять в команду
	if ! [[ "$target" =~ ^[A-Za-z0-9._-]+$ ]] || [ "$target" = "." ] || [ "$target" = ".." ]; then
		err "Подозрительное имя модуля: $target"; pause; return
	fi
	case "$act" in
		d) tsh "touch /data/adb/modules/$target/disable" && ok "«$target» отключён." ;;
		e) tsh "rm -f /data/adb/modules/$target/disable /data/adb/modules/$target/remove" && ok "«$target» включён." ;;
		r) tsh "touch /data/adb/modules/$target/remove" && ok "«$target» будет удалён при следующей загрузке." ;;
	esac
	log "MODULE $act $target"
	pause
}

# Официальный способ Magisk: работает, даже если система в бутлупе, но adb поднимается
op_magisk_remove_all() {
	title "MAGISK: УДАЛИТЬ ВСЕ МОДУЛИ"
	note "Команда: adb wait-for-device shell magisk --remove-modules"
	note "Удалит все модули и перезагрузит устройство. Работает даже в бутлупе,"
	note "если adb успевает подняться."
	confirm_yn "Выполнить?" || return
	run A wait-for-device shell magisk --remove-modules
	pause
}

# ═════════════════════════════════════════════════════════════════════════════
#  ОПЕРАЦИИ: SIDELOAD / RESCUE
# ═════════════════════════════════════════════════════════════════════════════

op_sideload() {
	title "ADB SIDELOAD"
	pick_file "Прошивки/OTA (.zip)" zip || { pause; return; }
	info "Прошивка ${PICKED##*/}…"
	warn "НЕ ОТКЛЮЧАЙТЕ КАБЕЛЬ до окончания!"
	# sideload часто возвращает 1 на «Total xfer: 1.00x» при успехе — смотрим экран цели
	run A sideload "$PICKED"
	note "Итог смотрите на экране устройства (код 1 при «xfer: 1.00x» — это норма)."
	pause
}

op_rescue_install() {
	title "PIXEL RESCUE: УСТАНОВКА OTA"
	note "Нужен полный OTA-пакет Google для этого устройства (не factory image)."
	pick_file "OTA-пакеты (.zip)" zip || { pause; return; }
	warn "НЕ ОТКЛЮЧАЙТЕ КАБЕЛЬ до окончания!"
	run A rescue install "$PICKED"
	pause
}

op_rescue_info() {
	title "PIXEL RESCUE: СВЕДЕНИЯ"
	local p
	for p in ro.product.device ro.build.fingerprint ro.build.date.utc; do
		printf ' %-22s %s\n' "$p" "$(A rescue getprop "$p" 2>/dev/null | tr -d '\r')"
	done
	pause
}

# ═════════════════════════════════════════════════════════════════════════════
#  ОПЕРАЦИИ: FASTBOOT
# ═════════════════════════════════════════════════════════════════════════════

fb_reboot() {    # $1 — цель (пусто = система)
	if [ -n "$1" ]; then run F reboot "$1"; else run F reboot; fi
	sleep 2
}

op_fb_info() {
	title "ИНФОРМАЦИЯ (getvar all)"
	local f="$WORKDIR/getvar_${D_CODENAME:-dev}.txt"
	F getvar all 2>&1 | tr -d '\r' | sed 's/^(bootloader) //' > "$f"
	grep -Ei '^(product|current-slot|slot-count|unlocked|secure|version|version-bootloader|version-baseband|is-userspace|hw-revision|anti|battery|off-mode)' "$f" \
		| grep -v 'partition' | sort -u
	echo
	note "Полный вывод сохранён: $f"
	pause
}

op_fb_switch_slot() {
	title "ПЕРЕКЛЮЧЕНИЕ A/B СЛОТА"
	local cur="$D_SLOT" next
	case "$cur" in
		a) next=b ;;
		b) next=a ;;
		*) err "Слот не определён — устройство A-only?"; pause; return ;;
	esac
	info "Текущий слот: $cur → будет: $next"
	note "Во втором слоте должна быть рабочая система (обычно — предыдущая версия после OTA)."
	confirm_yn "Переключить на слот $next?" || return
	run F --set-active="$next" && D_SLOT="$next"
	pause
}

op_fb_flash() {
	title "ПРОШИВКА ОБРАЗА В РАЗДЕЛ"
	ensure_warned || { pause; return; }
	item 1 "boot"
	item 2 "init_boot" "Pixel 7+ и др. с Android 13+ (Magisk патчит его)"
	item 3 "vendor_boot" "Pixel 6+"
	item 4 "recovery"
	item 5 "dtbo"
	item 6 "Ввести вручную"
	item 0 "Отмена"
	ask "Раздел:"
	local part=""
	case "$REPLY" in
		1) part=boot ;; 2) part=init_boot ;; 3) part=vendor_boot ;;
		4) part=recovery ;; 5) part=dtbo ;;
		6) ask "Имя раздела:"; part="$REPLY" ;;
		*) return ;;
	esac
	if ! valid_part "$part"; then err "Недопустимое имя раздела."; pause; return; fi
	afe_guard flash "$part" || { pause; return; }
	if [ "$STATE" = "BOOTLOADER" ] && [ "$D_UNLOCKED" != "yes" ]; then
		warn "Загрузчик заблокирован — прошивка почти наверняка будет отклонена."
	fi

	echo
	pick_file "Образы (.img)" img || { pause; return; }
	check_image "$PICKED" "$part" || { pause; return; }

	local -a slot_opt=()
	if [ -n "$D_SLOT" ] && [[ "$part" != *_a && "$part" != *_b ]]; then
		if confirm_yn "Прошить в оба слота (a и b)? Нет — только в текущий ($D_SLOT)"; then
			slot_opt=(--slot=all)
		fi
	fi
	echo
	info "Раздел: $part ${slot_opt[*]:-(слот $D_SLOT)}   Файл: ${PICKED##*/}"
	confirm_yn "Прошить?" || return
	run F "${slot_opt[@]}" flash "$part" "$PICKED"
	pause
}

op_fb_vbmeta() {
	title "VBMETA: ОТКЛЮЧЕНИЕ VERITY / VERIFICATION"
	ensure_warned || { pause; return; }
	note "Нужно для кастомных ядер/GSI. На Pixel и многих других устройствах после"
	note "первого отключения проверок требуется Format Data, иначе система не загрузится."
	pick_file "vbmeta-образы (.img)" img || { pause; return; }
	check_image "$PICKED" vbmeta || { pause; return; }
	confirm_yn "Прошить ${PICKED##*/} в vbmeta с --disable-verity --disable-verification?" || return
	run F --disable-verity --disable-verification flash vbmeta "$PICKED"
	pause
}

op_fb_boot_temp() {
	title "ВРЕМЕННАЯ ЗАГРУЗКА ОБРАЗА (fastboot boot)"
	note "Образ загружается в RAM без прошивки — для проверки ядер/recovery."
	note "На Pixel 7+ boot.img с ядром, init_boot так не грузится."
	pick_file "Образы (.img)" img || { pause; return; }
	check_image "$PICKED" boot || { pause; return; }
	run F boot "$PICKED"
	pause
}

op_fb_format_data() {
	title "FORMAT DATA"
	ensure_warned || { pause; return; }
	note "fastboot -w: стирание и форматирование userdata, cache и metadata."
	confirm_word "WIPE" "ВСЕ ДАННЫЕ ПОЛЬЗОВАТЕЛЯ БУДУТ УДАЛЕНЫ." || { pause; return; }
	run F -w
	pause
}

op_fb_erase_frp() {
	title "СТИРАНИЕ FRP"
	if [ "$D_UNLOCKED" != "yes" ]; then
		err "Загрузчик заблокирован — операция невозможна."
		pause; return
	fi
	ensure_warned || { pause; return; }
	note "Многие загрузчики (в т.ч. Pixel) откажут в erase frp — это нормально."
	confirm_word "ERASE_FRP" "Будет очищен раздел Factory Reset Protection." || { pause; return; }
	afe_guard erase frp && run F erase frp
	pause
}

op_fb_bootloader() {
	title "УПРАВЛЕНИЕ ЗАГРУЗЧИКОМ"
	printf ' Текущий статус: %s\n' "$([ "$D_UNLOCKED" = "yes" ] && echo "${C_GRN}UNLOCKED${C_NC}" || echo "${C_RED}LOCKED${C_NC}")"
	local ab
	ab="$(fb_var unlock_ability)"; [ -n "$ab" ] && note "unlock_ability: $ab (1 — разблокировка разрешена в настройках)"
	warn "Любая смена статуса = полный сброс данных (Factory Reset)."
	echo
	item 1 "Разблокировать" "flashing unlock"
	item 2 "Заблокировать" "flashing lock — только на стоковой прошивке!"
	item 3 "Разблокировать критические разделы" "flashing unlock_critical"
	item 0 "Назад"
	ask "Выбор:"
	case "$REPLY" in
		1)
			if [ "$D_UNLOCKED" = "yes" ]; then info "Уже разблокирован."; pause; return; fi
			[ "$DEVICE_TYPE" = "xiaomi" ] && note "Xiaomi/POCO разблокируются только через Mi Unlock Tool — fastboot откажет."
			confirm_word "UNLOCK" "Данные будут стёрты. Подтвердите на экране устройства кнопками громкости." || { pause; return; }
			run F flashing unlock || run F oem unlock
			;;
		2)
			if [ "$D_UNLOCKED" != "yes" ]; then info "Загрузчик уже заблокирован."; pause; return; fi
			ensure_warned || { pause; return; }
			echo
			err "Блокировка на кастомной прошивке, с Magisk или изменённым vbmeta = КИРПИЧ."
			note "Блокируйте только после полной прошивки официального factory image."
			confirm_word "LOCK" "Устройство будет заблокировано и сброшено." || { pause; return; }
			run F flashing lock
			;;
		3)
			note "Нужно для прошивки bootloader/radio некоторыми инструментами."
			confirm_word "UNLOCK_CRITICAL" "Данные будут стёрты." || { pause; return; }
			run F flashing unlock_critical
			;;
		*) return ;;
	esac
	STATE=""   # перечитать статус загрузчика
	pause
}

# ═════════════════════════════════════════════════════════════════════════════
#  МЕНЮ ПО СОСТОЯНИЯМ
# ═════════════════════════════════════════════════════════════════════════════

read_choice() {
	printf '\n%s›%s ' "$C_CYN" "$C_NC"
	IFS= read -r CHOICE || exit_kit   # EOF (stdin закрыт) — выходим, а не крутимся
}

menu_system() {   # SYSTEM и RECOVERY
	local is_rec=0; [ "$STATE" = "RECOVERY" ] && is_rec=1
	section "Перезагрузка" "$C_YEL"
	item 1 "В bootloader" "fastboot"
	item 2 "В recovery"
	item 3 "В fastbootd" "прошивка разделов внутри super"
	item 4 "В систему"
	[ "$DEVICE_TYPE" = "samsung" ] && item 5 "В Download Mode" "Odin / Heimdall"
	[ "$is_rec" -eq 1 ] && [ "$DEVICE_TYPE" = "pixel" ] && item 6 "В Rescue Mode" "Pixel: установка OTA"
	section "Инструменты"
	item 7 "Модули Magisk / KernelSU" "отключить / удалить"
	[ "$is_rec" -eq 0 ] && item 8 "Сброс модулей при бутлупе" "magisk --remove-modules"
	item 9 "Дамп раздела" "размер + MD5"
	item 10 "Логи: последние ошибки" "logcat *:E"
	item 11 "Сохранить диагностику" "logcat, dmesg, ramoops"
	item 12 "ADB Shell"
	section "" ; item 0 "Выход"
	read_choice
	case "$CHOICE" in
		1) adb_reboot bootloader "в bootloader" ;;
		2) adb_reboot recovery "в recovery" ;;
		3) adb_reboot fastboot "в fastbootd" ;;
		4) adb_reboot "" ;;
		5) [ "$DEVICE_TYPE" = "samsung" ] && adb_reboot download "в Download Mode" ;;
		6) [ "$is_rec" -eq 1 ] && adb_reboot rescue "в Rescue Mode" ;;
		7) op_magisk_modules ;;
		8) [ "$is_rec" -eq 0 ] && op_magisk_remove_all ;;
		9) op_dump_partition ;;
		10) op_logcat_errors ;;
		11) op_collect_logs ;;
		12) op_adb_shell ;;
		0) exit_kit ;;
	esac
}

menu_sideload() {
	section "Прошивка"
	item 1 "ADB Sideload" "zip / OTA"
	section "Перезагрузка" "$C_YEL"
	item 2 "В систему"
	item 3 "В bootloader"
	[ "$DEVICE_TYPE" != "samsung" ] && item 4 "В Rescue Mode" "Pixel"
	section "" ; item 0 "Выход"
	read_choice
	case "$CHOICE" in
		1) op_sideload ;;
		2) adb_reboot "" ;;
		3) adb_reboot bootloader "в bootloader" ;;
		4) adb_reboot rescue "в Rescue Mode" ;;
		0) exit_kit ;;
	esac
}

menu_rescue() {
	section "Pixel Rescue"
	item 1 "Сведения об устройстве" "adb rescue getprop"
	item 2 "Установить OTA" "adb rescue install"
	section "Перезагрузка" "$C_YEL"
	item 3 "В систему"
	item 4 "В bootloader"
	section "" ; item 0 "Выход"
	read_choice
	case "$CHOICE" in
		1) op_rescue_info ;;
		2) op_rescue_install ;;
		3) adb_reboot "" ;;
		4) adb_reboot bootloader "в bootloader" ;;
		0) exit_kit ;;
	esac
}

menu_fastboot() {   # BOOTLOADER и FASTBOOTD
	local bl=0; [ "$STATE" = "BOOTLOADER" ] && bl=1
	section "Прошивка"
	item 1 "Информация" "getvar all"
	item 2 "Переключить A/B слот" "сейчас: ${D_SLOT:-—}"
	item 3 "Прошить образ" "boot / init_boot / vendor_boot / …"
	item 4 "Прошить vbmeta" "disable verity / verification"
	[ "$bl" -eq 1 ] && item 5 "Загрузить образ без прошивки" "fastboot boot"
	section "Перезагрузка" "$C_YEL"
	if [ "$bl" -eq 1 ]; then
		item 6 "В fastbootd" "разделы внутри super"
	else
		item 6 "В bootloader"
	fi
	item 7 "В recovery"
	item 8 "В систему"
	section "Опасные операции" "$C_RED"
	item 9 "Format Data" "userdata + metadata"
	item 10 "Стереть FRP"
	[ "$bl" -eq 1 ] && item 11 "Загрузчик" "lock / unlock"
	item 12 "Сохранить getvar all"
	section "" ; item 0 "Выход"
	read_choice
	case "$CHOICE" in
		1) op_fb_info ;;
		2) op_fb_switch_slot ;;
		3) op_fb_flash ;;
		4) op_fb_vbmeta ;;
		5) [ "$bl" -eq 1 ] && op_fb_boot_temp ;;
		6) if [ "$bl" -eq 1 ]; then fb_reboot fastboot; else fb_reboot bootloader; fi ;;
		7) fb_reboot recovery ;;
		8) fb_reboot "" ;;
		9) op_fb_format_data ;;
		10) op_fb_erase_frp ;;
		11) [ "$bl" -eq 1 ] && op_fb_bootloader ;;
		12) op_collect_logs ;;
		0) exit_kit ;;
	esac
}

menu_waiting() {   # NONE / UNAUTHORIZED / OFFLINE / NOPERM
	case "$STATE" in
		UNAUTHORIZED) warn "Разрешите отладку на экране телефона (галочка «Всегда разрешать»)." ;;
		OFFLINE)      warn "Устройство offline: переподключите кабель или перезапустите ADB-сервер." ;;
		NOPERM)       warn "Нет прав на USB-устройство: запустите скрипт от root." ;;
		*)            usb_hint ;;
	esac
	section "Действия"
	item 1 "Обновить"
	item 2 "Перезапустить ADB-сервер"
	item 3 "Диагностика USB / OTG"
	section "" ; item 0 "Выход"
	printf '\n%s›%s %s(автообновление через 5 с)%s ' "$C_CYN" "$C_NC" "$C_DIM" "$C_NC"
	CHOICE=""
	IFS= read -r -t 5 CHOICE
	local rc=$?
	if [ $rc -ne 0 ]; then
		[ $rc -gt 128 ] || exit_kit # > 128 — таймаут, просто обновляем экран; иначе EOF — выходим
		echo
	fi
	case "$CHOICE" in
		2) "$ADB_BIN" kill-server >/dev/null 2>&1; "$ADB_BIN" start-server >/dev/null 2>&1
		   ok "ADB-сервер перезапущен."; sleep 1 ;;
		3) op_usb_diag ;;
		0) exit_kit ;;
	esac
}

# ═════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═════════════════════════════════════════════════════════════════════════════

exit_kit() {
	printf '\n%sВыход из OTG Rescue ToolKit.%s\n' "$C_YEL" "$C_NC"
	exit 0
}
trap 'printf "\n"; exit_kit' INT TERM

main() {
	check_env
	log "START v$VERSION"
	info "Запуск ADB-сервера…"
	"$ADB_BIN" start-server >/dev/null 2>&1

	while true; do
		refresh_status
		header
		case "$STATE" in
			MULTI)                     pick_device ;;
			SYSTEM|RECOVERY)           menu_system ;;
			SIDELOAD)                  menu_sideload ;;
			RESCUE)                    menu_rescue ;;
			BOOTLOADER|FASTBOOTD)      menu_fastboot ;;
			*)                         menu_waiting ;;
		esac
	done
}

main "$@"

# ─────────────────────────────────────────────────────────────────────────────
# Изменения v2 относительно v1.5.0-dev:
#  Безопасность
#   - «Заблокировать загрузчик» блокировал БЕЗ учёта ответа «Вы уверены?».
#     Теперь — ввод LOCK и предупреждение о кирпиче на кастомной прошивке.
#   - «Проверить статус CRITICAL» на деле выполнял flashing unlock_critical
#     (= wipe). Пункт переименован и требует ввода UNLOCK_CRITICAL.
#   - Удаление модулей: `rm -rf /data/adb/modules/$ввод` — пустой ввод сносил
#     все модули, а «../../..» — корень. Теперь выбор по номеру, id проверяется,
#     используются штатные флаги Magisk disable/remove (обратимо).
#   - Имя раздела в дампе подставлялось в `su -c '…'` на цели без проверки
#     (инъекция команд). Теперь только [A-Za-z0-9_].
#   - AFE: имя раздела без учёта регистра, добавлены bootloader, radio, uefi и др.
#   - Проверка сигнатуры образа (ANDROID!/VNDRBOOT/AVB0/sparse), ZIP вместо
#     .img отклоняется.
#  Ошибки
#   - `local` вне функции в пункте FRP + set -e → скрипт падал при выборе пункта.
#   - set -Eeuo pipefail ронял меню при любой нештатной ситуации (нет getprop,
#     EOF в read и т.п.) — заменено явной обработкой ошибок.
#   - `fastboot reboot rescue` не существует (fastboot знает только bootloader,
#     recovery, fastboot) — Rescue Mode теперь через `adb reboot rescue` из
#     recovery/sideload, плюс отдельное меню для состояния rescue.
#   - Слот в меню ADB брался с ХОСТА (getprop без adb shell).
#   - detect_manufacturer и предупреждения никогда не вызывались — теперь
#     показываются один раз перед первой опасной операцией.
#   - При 2+ устройствах команды шли без -s и падали с «more than one device»;
#     серийник склеивался из нескольких строк.
#   - Format Data: `erase` без форматирования → `fastboot -w` (erase + format
#     userdata, cache, metadata).
#   - `--disable-verity` стоял после `flash` — перенесён в глобальные опции.
#   - logcat `*:E` без кавычек раскрывался как glob на хосте.
#   - Sideload-список показывал полные пути, а спрашивал имя файла.
#   - Неверный путь в подсказке MT Manager (вместо папки — путь к bash).
#   - HOME под su = «/» → adb не мог сохранить ключ.
#   - Дата сборки была датой запуска.
#  Новое
#   - Состояния FASTBOOTD, RESCUE, OFFLINE, NO PERMISSIONS, выбор устройства.
#   - Pixel Rescue: adb rescue getprop / install.
#   - Сбор диагностики: getprop, logcat (all/crash), dmesg, ramoops/last_kmsg.
#   - magisk --remove-modules для бутлупа с живым adb.
#   - Прошивка в оба слота (--slot=all), проверка места перед дампом,
#     дампы с датой в имени (не перезаписываются), журнал операций otg_kit.log.
#   - Автоперезапуск в bash, если скрипт запущен через sh.
