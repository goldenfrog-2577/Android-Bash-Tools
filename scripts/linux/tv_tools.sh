#!/system/bin/sh
#
# tv_tools.sh v2 — управление Android TV / приставкой с телефона через ADB по Wi-Fi
# Автор: GoldenFrog
#
# Запуск:  sh tv_tools.sh [IP[:порт]]
# Нужно:   adb на телефоне (Termux: pkg install android-tools),
#          на ТВ включена «Отладка по сети» / «Беспроводная отладка».
#
# Что изменилось относительно v1:
#  - `read -p` и `exit 0 &>/dev/null` — это bash. В штатном sh (mksh) `read -p`
#    вообще означает «читать из сопроцесса», а `exit ... &>` запускает exit в фоне.
#    Всё переписано на POSIX sh.
#  - `adb connect` возвращает код 0 даже при неудаче, поэтому v1 всегда писала
#    «Успешное подключение!». Теперь разбирается вывод adb и проверяется
#    реальное состояние устройства (device / unauthorized / offline).
#  - Инъекция команд: введённые длительность, битрейт и размер подставлялись в
#    строку, которую выполняла оболочка ТВ (`adb shell "$cmd"`). Теперь каждое
#    значение проверяется по строгому шаблону, а пути и текст экранируются.
#  - Запись экрана: у screenrecord нет флага --orientation (v1 передавала его,
#    screenrecord завершался с кодом 2, но скрипт всё равно писал «Запись
#    завершена»). Флаг убран, ошибки теперь показываются. Лимит screenrecord —
#    180 секунд, это тоже проверяется.
#  - Скриншоты и записи раньше оставались на ТВ и скрипт даже не проверял,
#    создались ли они. Теперь файлы забираются на телефон, проверяются и
#    удаляются с ТВ.
#  - Указывается устройство (-s), поэтому работает, даже если к adb подключено
#    несколько девайсов.
#  - Введён trap: по Ctrl+C временные файлы удаляются, соединение закрывается.
#  - Подтверждение перед перезагрузкой, выключением и удалением данных.
#
# Новое: пульт, ввод текста, список/запуск/остановка/очистка/удаление
# приложений, установка APK, отправка и получение файлов, перезагрузка в
# recovery/bootloader, сопряжение по коду (Android 11+), запоминание последнего IP.

# ==========================================
# 0. НАСТРОЙКИ
# ==========================================

OUT_BASE="${TV_TOOLS_OUT:-/sdcard/TV-Tools}"
STATE_DIR="${TV_TOOLS_STATE:-${HOME:-/data/local/tmp}/.tv_tools}"
LAST_FILE="$STATE_DIR/last_tv"
REMOTE_TMP="/data/local/tmp"    # на ТВ шелл всегда может сюда писать
TAB="$(printf '\t')"

TARGET=""
WE_CONNECTED=0
TMPD=""

say() { printf '%s\n' "$*"; }

# ask "вопрос" → ответ в $ANSWER. На конце ввода (Ctrl+D) — аккуратный выход.
ask() {
	printf '%s' "$1"
	IFS= read -r ANSWER || { say ""; exit 0; }
}

yes_no() {
	case "$1" in y|Y|yes|Yes|д|Д|да|Да) return 0 ;; *) return 1 ;; esac
}

confirm() {
	ask "$1 (y/N): "
	yes_no "$ANSWER"
}

cleanup() {
	[ -n "$TMPD" ] && [ -d "$TMPD" ] && rm -rf "$TMPD"
	if [ "$WE_CONNECTED" -eq 1 ] && [ -n "$TARGET" ]; then
		adb disconnect "$TARGET" >/dev/null 2>&1
	fi
}
trap cleanup EXIT
trap 'say ""; say "[!] Прервано."; exit 130' INT TERM

# timeout есть не везде; если нет — просто выполняем команду
if command -v timeout >/dev/null 2>&1; then
	tmo() { timeout "$@"; }
else
	tmo() { shift; "$@"; }
fi

# ==========================================
# 1. ПРОВЕРКИ ОКРУЖЕНИЯ
# ==========================================

case "${1:-}" in
	-h|--help)
		sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'
		exit 0 ;;
esac

if ! command -v adb >/dev/null 2>&1; then
	say "Ошибка: adb не найден."
	say "Termux: pkg install android-tools (или поставь модуль Magisk с adb)."
	exit 1
fi

TMPD="$(mktemp -d 2>/dev/null)"
if [ -z "$TMPD" ] || [ ! -d "$TMPD" ]; then
	TMPD="$REMOTE_TMP/tvtools.$$"
	mkdir -p "$TMPD" || { say "Не удалось создать временную папку"; exit 1; }
fi

# Куда сохраняем файлы с ТВ. Без доступа к /sdcard (Termux без termux-setup-storage)
# падаем в домашнюю папку, а не молчим.
mkdir -p "$OUT_BASE" 2>/dev/null
if [ ! -w "$OUT_BASE" ]; then
	OUT_BASE="${HOME:-$REMOTE_TMP}/TV-Tools"
	mkdir -p "$OUT_BASE" 2>/dev/null || { say "Не удалось создать папку для файлов"; exit 1; }
fi
SHOT_DIR="$OUT_BASE/Screenshots"
REC_DIR="$OUT_BASE/Recordings"
PULL_DIR="$OUT_BASE/Pulled"

# ==========================================
# 2. ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ==========================================

A() { adb -s "$TARGET" "$@"; }

ts() { date +%d-%m-%Y_%H-%M-%S; }

# Строка в одинарных кавычках для оболочки ТВ: ab'c → 'ab'\''c'
shq() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Если путь вставили в кавычках или с пробелами по краям — чистим,
# но только когда «как есть» такого пути нет
clean_path() {
	_p="$1"
	if [ ! -e "$_p" ]; then
		_p=$(printf '%s' "$_p" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
			-e "s/^[\"']//" -e "s/[\"']\$//")
	fi
	printf '%s' "$_p"
}

valid_target() {
	printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$' || return 1
	case "$1" in
		*:*)
			_port="${1##*:}"
			[ "$_port" -ge 1 ] && [ "$_port" -le 65535 ] || return 1 ;;
	esac
	return 0
}

valid_pkg() {
	printf '%s' "$1" | grep -Eq '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'
}

# Состояние устройства из `adb devices`: device / unauthorized / offline / пусто
dev_state() {
	adb devices 2>/dev/null | tr -d '\r' | grep -F -- "$1$TAB" | cut -f2 | head -n 1
}

# ==========================================
# 3. ПОДКЛЮЧЕНИЕ
# ==========================================

# connect_tv host[:port] — 0, если устройство в состоянии device
connect_tv() {
	_t="$1"
	case "$_t" in *:*) ;; *) _t="$_t:5555" ;; esac

	if [ "$(dev_state "$_t")" = "device" ]; then
		TARGET="$_t"
		say "Уже подключено: $TARGET"
		return 0
	fi

	say "Подключаюсь к $_t..."
	_o=$(tmo 20 adb connect "$_t" 2>&1 | tr -d '\r')
	[ -n "$_o" ] && say "  adb: $_o"

	_st=$(dev_state "$_t")
	case "$_st" in
		device)
			TARGET="$_t"; WE_CONNECTED=1
			mkdir -p "$STATE_DIR" 2>/dev/null && printf '%s\n' "$_t" > "$LAST_FILE" 2>/dev/null
			say "Подключено."
			return 0 ;;
		unauthorized)
			say "[!] ТВ не доверяет этому телефону. Подтверди запрос «Разрешить отладку по USB/сети»"
			say "    на экране телевизора (отметь «Всегда разрешать») и повтори."
			;;
		offline)
			say "[!] Устройство в состоянии offline. Выключи и включи отладку на ТВ и повтори."
			;;
		*)
			say "[!] Не удалось подключиться. Проверь IP/порт, что оба устройства в одной сети"
			say "    и что на ТВ включена отладка по сети."
			;;
	esac
	return 1
}

# Сопряжение по коду (Android 11+ «Беспроводная отладка»)
pair_tv() {
	say ""
	say "На ТВ: Настройки → Для разработчиков → Беспроводная отладка →"
	say "«Подключить устройство с помощью кода сопряжения»."
	ask "Адрес сопряжения (IP:порт из этого окна): "
	_pa="$ANSWER"
	if ! printf '%s' "$_pa" | grep -Eq ':[0-9]{1,5}$' || ! valid_target "$_pa"; then
		say "[!] Нужен адрес вида 192.168.0.50:37123"
		return 1
	fi
	ask "Код сопряжения (6 цифр): "
	case "$ANSWER" in
		[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
		*) say "[!] Код — ровно 6 цифр"; return 1 ;;
	esac
	_o=$(tmo 30 adb pair "$_pa" "$ANSWER" 2>&1 | tr -d '\r')
	say "  adb: $_o"
	case "$_o" in
		*"Successfully paired"*) say "Сопряжено. Теперь подключись по основному адресу (порт — на главном экране «Беспроводной отладки»)."; return 0 ;;
	esac
	return 1
}

# Спрашиваем адрес и подключаемся; повторяем, пока не выйдет или не откажутся
choose_tv() {
	_def="${1:-}"
	[ -z "$_def" ] && [ -f "$LAST_FILE" ] && _def="$(head -n 1 "$LAST_FILE" 2>/dev/null)"
	while :; do
		if [ -n "$_def" ]; then
			ask "IP телевизора[:порт] [Enter = $_def]: "
		else
			ask "IP телевизора[:порт] (например, 192.168.0.50): "
		fi
		_in="${ANSWER:-$_def}"
		if [ -z "$_in" ]; then
			say "[!] Адрес не указан"
			continue
		fi
		if ! valid_target "$_in"; then
			say "[!] Некорректный адрес: $_in"
			_def=""
			continue
		fi
		connect_tv "$_in" && return 0

		ask "[r] ввести адрес заново, [p] сопряжение по коду, [q] выйти: "
		case "$ANSWER" in
			p|P) pair_tv ;;
			q|Q) exit 1 ;;
		esac
		_def="$_in"
	done
}

# Перед каждым действием: связь жива? Если нет — одна попытка переподключиться
ensure_connected() {
	[ -n "$TARGET" ] || { say "[!] Нет подключения — выбери пункт 11."; return 1; }
	[ "$(dev_state "$TARGET")" = "device" ] && return 0
	say "Связь потеряна, пробую переподключиться..."
	tmo 20 adb connect "$TARGET" >/dev/null 2>&1
	[ "$(dev_state "$TARGET")" = "device" ] && return 0
	say "[!] ТВ недоступен. Проверь питание/сеть и выбери пункт 11."
	return 1
}

# ==========================================
# 4. ДЕЙСТВИЯ
# ==========================================

do_info() {
	ensure_connected || return
	_blob=$(A shell 'getprop ro.product.manufacturer; getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.version.sdk; getprop ro.build.version.security_patch; getprop ro.product.cpu.abi; wm size | head -n 1; wm density | head -n 1; grep MemTotal /proc/meminfo; df /data | tail -n 1; cat /proc/uptime' 2>/dev/null | tr -d '\r')
	[ -n "$_blob" ] || { say "[!] Не удалось получить данные"; return; }

	g() { printf '%s\n' "$_blob" | sed -n "${1}p"; }

	say ""
	say "Информация об устройстве"
	say "---------------------------"
	say "Адрес:          $TARGET"
	say "Производитель:  $(g 1)"
	say "Модель:         $(g 2)"
	say "Android:        $(g 3) (SDK $(g 4))"
	say "Патч безопас.:  $(g 5)"
	say "Архитектура:    $(g 6)"
	say "Экран:          $(g 7 | sed 's/^[^:]*: *//'), $(g 8 | sed 's/^[^:]*: *//') dpi"

	_mem=$(g 9 | sed 's/[^0-9]//g')
	[ -n "$_mem" ] && say "ОЗУ:            $(( _mem / 1024 )) МБ"

	set -- $(g 10)
	if [ "$#" -ge 4 ]; then
		case "$2$3$4" in
			*[!0-9]*) ;;
			*) say "Память /data:   занято $(( $3 / 1024 )) МБ из $(( $2 / 1024 )) МБ, свободно $(( $4 / 1024 )) МБ" ;;
		esac
	fi

	_up=$(g 11 | cut -d' ' -f1); _up="${_up%%.*}"
	case "$_up" in
		''|*[!0-9]*) ;;
		*) say "Аптайм:         $(( _up / 3600 )) ч $(( _up % 3600 / 60 )) мин" ;;
	esac
	say "---------------------------"
}

do_screenshot() {
	ensure_connected || return
	mkdir -p "$SHOT_DIR" 2>/dev/null
	_f="$SHOT_DIR/screenshot_$(ts).png"
	say "Создаётся скриншот..."

	# Быстрый путь: PNG сразу в файл на телефоне, без записи на ТВ
	A exec-out screencap -p > "$_f" 2>/dev/null
	if [ ! -s "$_f" ] || [ "$(head -c 4 "$_f" | tail -c 3)" != "PNG" ]; then
		# Запасной путь для старых adb: снять на ТВ, забрать, удалить
		_r="$REMOTE_TMP/.tvtools_shot_$$.png"
		A shell screencap -p "$_r" >/dev/null 2>&1
		A pull "$_r" "$_f" >/dev/null 2>&1
		A shell rm -f "$_r" >/dev/null 2>&1
	fi

	if [ -s "$_f" ] && [ "$(head -c 4 "$_f" | tail -c 3)" = "PNG" ]; then
		say "Скриншот сохранён: $_f"
	else
		rm -f "$_f"
		say "[!] Не удалось получить скриншот (приложение может запрещать захват экрана)."
	fi
}

do_record() {
	ensure_connected || return

	ask "Длительность, сек (1-180, Enter = 30): "
	_dur="${ANSWER:-30}"
	case "$_dur" in
		*[!0-9]*|'') say "[!] Длительность — целое число"; return ;;
	esac
	if [ "$_dur" -lt 1 ] || [ "$_dur" -gt 180 ]; then
		say "[!] screenrecord пишет не дольше 180 секунд"; return
	fi

	_opts=""
	ask "Битрейт (например 4M или 8000000, Enter = по умолчанию): "
	if [ -n "$ANSWER" ]; then
		printf '%s' "$ANSWER" | grep -Eq '^[0-9]+[Mm]?$' || { say "[!] Некорректный битрейт"; return; }
		_opts="$_opts --bit-rate $ANSWER"
	fi
	ask "Размер видео (например 1280x720, Enter = по умолчанию): "
	if [ -n "$ANSWER" ]; then
		printf '%s' "$ANSWER" | grep -Eq '^[0-9]{2,5}x[0-9]{2,5}$' || { say "[!] Размер вида 1280x720"; return; }
		_opts="$_opts --size $ANSWER"
	fi

	mkdir -p "$REC_DIR" 2>/dev/null
	_f="$REC_DIR/recording_$(ts).mp4"
	_r="$REMOTE_TMP/.tvtools_rec_$$.mp4"

	say "Идёт запись ($_dur с). Не прерывай, пока не закончится..."
	_log=$(A shell "screenrecord --time-limit $_dur$_opts $_r" 2>&1 | tr -d '\r'); _rc=$?
	# код возврата пайпа — это tr; реальный результат проверяем по файлу
	_sz=$(A shell "ls -l $_r" 2>/dev/null | tr -d '\r')
	case "$_sz" in
		*"No such file"*|'')
			say "[!] Запись не создана."
			[ -n "$_log" ] && say "    screenrecord: $_log"
			return ;;
	esac

	say "Копирую на телефон..."
	A pull "$_r" "$_f" >/dev/null 2>&1
	A shell rm -f "$_r" >/dev/null 2>&1
	if [ -s "$_f" ]; then
		say "Запись сохранена: $_f"
	else
		rm -f "$_f"
		say "[!] Не удалось скопировать запись с ТВ."
	fi
}

do_remote() {
	ensure_connected || return
	say ""
	say "Пульт. Можно вводить несколько клавиш подряд, например: ddde"
	say "  w/s/a/d — вверх/вниз/влево/вправо    e — OK         b — назад"
	say "  h — домой    m — меню    c — настройки    i — вход (TV input)"
	say "  + / -  — громкость    x — mute    p — пауза/плей    0-9 — цифры"
	say "  q — выйти из пульта"
	while :; do
		ask "пульт> "
		case "$ANSWER" in
			q|Q) return ;;
			'') continue ;;
		esac
		_keys=""; _bad=""; _rest="$ANSWER"
		while [ -n "$_rest" ]; do
			_c="${_rest%"${_rest#?}"}"
			_rest="${_rest#?}"
			case "$_c" in
				w|W) _k=KEYCODE_DPAD_UP ;;
				s|S) _k=KEYCODE_DPAD_DOWN ;;
				a|A) _k=KEYCODE_DPAD_LEFT ;;
				d|D) _k=KEYCODE_DPAD_RIGHT ;;
				e|E) _k=KEYCODE_DPAD_CENTER ;;
				b|B) _k=KEYCODE_BACK ;;
				h|H) _k=KEYCODE_HOME ;;
				m|M) _k=KEYCODE_MENU ;;
				c|C) _k=KEYCODE_SETTINGS ;;
				i|I) _k=KEYCODE_TV_INPUT ;;
				+) _k=KEYCODE_VOLUME_UP ;;
				-) _k=KEYCODE_VOLUME_DOWN ;;
				x|X) _k=KEYCODE_VOLUME_MUTE ;;
				p|P) _k=KEYCODE_MEDIA_PLAY_PAUSE ;;
				[0-9]) _k="KEYCODE_$_c" ;;
				' ') continue ;;
				*) _bad="$_c"; break ;;
			esac
			_keys="$_keys $_k"
		done
		if [ -n "$_bad" ]; then
			say "[!] Неизвестная клавиша «$_bad» — ничего не отправлено."
			continue
		fi
		# Список клавиш собран только из констант выше — вводу пользователя тут нет места
		[ -n "$_keys" ] && A shell "input keyevent$_keys" >/dev/null 2>&1
	done
}

do_text() {
	ensure_connected || return
	say "Ввод текста в активное поле на ТВ (только латиница, цифры и обычные символы)."
	ask "Текст: "
	[ -n "$ANSWER" ] || return
	# input text не умеет не-ASCII: честно отказываем, а не отправляем мусор
	if printf '%s' "$ANSWER" | LC_ALL=C grep -q '[^ -~]'; then
		say "[!] Есть символы вне ASCII (кириллица и т.п.) — input text их не поддерживает."
		return
	fi
	# Пробелы → %s (так требует input text), кавычки экранируем для оболочки ТВ
	_t=$(printf '%s' "$ANSWER" | sed 's/ /%s/g')
	A shell "input text $(shq "$_t")" >/dev/null 2>&1
	if confirm "Нажать Enter после текста?"; then
		A shell input keyevent KEYCODE_ENTER >/dev/null 2>&1
	fi
	say "Отправлено."
}

# --- приложения ---

launch_pkg() {
	_o=$(A shell "monkey -p $1 -c android.intent.category.LEANBACK_LAUNCHER 1" 2>&1 | tr -d '\r')
	case "$_o" in
		*"Events injected: 1"*) return 0 ;;
	esac
	_o=$(A shell "monkey -p $1 -c android.intent.category.LAUNCHER 1" 2>&1 | tr -d '\r')
	case "$_o" in
		*"Events injected: 1"*) return 0 ;;
	esac
	return 1
}

app_launch() {
	say "  [1] YouTube      [2] Netflix      [3] Kodi"
	say "  [4] MT Manager   [5] Настройки ТВ [0] свой пакет"
	ask "Выбор: "
	case "$ANSWER" in
		1) _pk=com.google.android.youtube.tv ;;
		2) _pk=com.netflix.ninja ;;
		3) _pk=org.xbmc.kodi ;;
		4) _pk=bin.mt.plus ;;
		5) _pk=com.android.tv.settings ;;
		0)
			ask "Имя пакета (например, org.videolan.vlc): "
			_pk="$ANSWER" ;;
		*) return ;;
	esac
	valid_pkg "$_pk" || { say "[!] Некорректное имя пакета"; return; }
	if launch_pkg "$_pk"; then
		say "Запущено: $_pk"
	else
		say "[!] Не удалось запустить $_pk (не установлено или нет экрана запуска)."
	fi
}

app_list() {
	ask "Показать: [1] только установленные пользователем (Enter), [2] все: "
	_flag="-3"; [ "$ANSWER" = "2" ] && _flag=""
	ask "Фильтр по имени (Enter = без фильтра): "
	_flt="$ANSWER"
	# Фильтруем уже на телефоне через grep -F — на ТВ введённое никогда не попадает
	_res=$(A shell "pm list packages $_flag" 2>/dev/null | tr -d '\r' | sed 's/^package://' | sort)
	[ -n "$_flt" ] && _res=$(printf '%s\n' "$_res" | grep -iF -- "$_flt")
	if [ -z "$_res" ]; then
		say "Ничего не найдено."
	else
		printf '%s\n' "$_res"
		say "--- всего: $(printf '%s\n' "$_res" | grep -c '') ---"
	fi
}

app_with_pkg() {
	# app_with_pkg "действие" — спрашивает пакет и печатает его в $PKG
	ask "Имя пакета: "
	PKG="$ANSWER"
	valid_pkg "$PKG" || { say "[!] Некорректное имя пакета"; return 1; }
	return 0
}

do_apps() {
	ensure_connected || return
	while :; do
		say ""
		say "Приложения"
		say "  1) Запустить   2) Список   3) Остановить"
		say "  4) Очистить данные   5) Удалить   0) Назад"
		ask ">>> "
		case "$ANSWER" in
			1) app_launch ;;
			2) app_list ;;
			3)
				app_with_pkg && {
					A shell "am force-stop $PKG" >/dev/null 2>&1
					say "Остановлено: $PKG"
				} ;;
			4)
				app_with_pkg && {
					say "Будут стёрты ВСЕ данные $PKG: вход в аккаунт, настройки, кэш."
					if confirm "Продолжить?"; then
						_o=$(A shell "pm clear $PKG" 2>&1 | tr -d '\r')
						say "  $_o"
					fi
				} ;;
			5)
				app_with_pkg && {
					say "Удаление для текущего пользователя (pm uninstall --user 0)."
					say "Для системных приложений это отключение; вернуть: pm install-existing $PKG"
					if confirm "Удалить $PKG?"; then
						_o=$(A shell "pm uninstall --user 0 $PKG" 2>&1 | tr -d '\r')
						say "  $_o"
					fi
				} ;;
			0|'') return ;;
			*) say "Неверный ввод." ;;
		esac
	done
}

# Выбор одного файла: путь к файлу или к папке (тогда нумерованный список)
# pick_file путь шаблон_find → $PICKED
pick_file() {
	PICKED=""
	if [ -f "$1" ]; then PICKED="$1"; return 0; fi
	[ -d "$1" ] || { say "[!] Не найдено: $1"; return 1; }
	_l="$TMPD/pick.txt"
	find "$1" -maxdepth 1 -type f -iname "$2" 2>/dev/null | sort > "$_l"
	_n=$(grep -c '' "$_l")
	[ "$_n" -gt 0 ] || { say "[!] В папке нет подходящих файлов"; return 1; }
	_i=1
	while IFS= read -r _f <&3; do
		say "  [$_i] ${_f##*/}"
		_i=$(( _i + 1 ))
	done 3< "$_l"
	ask "Номер файла: "
	_num=$(printf '%s' "$ANSWER" | sed 's/^0*//')
	case "$_num" in ''|*[!0-9]*) say "[!] Нужно число"; return 1 ;; esac
	if [ "$_num" -lt 1 ] || [ "$_num" -gt "$_n" ]; then
		say "[!] Вне диапазона 1-$_n"; return 1
	fi
	PICKED=$(sed -n "${_num}p" "$_l")
	[ -n "$PICKED" ]
}

explain_install() {
	case "$1" in
		*INSTALL_FAILED_UPDATE_INCOMPATIBLE*) say "    Причина: подписи установленного и нового APK не совпадают — удали старую версию." ;;
		*INSTALL_FAILED_VERSION_DOWNGRADE*) say "    Причина: версия старее установленной." ;;
		*INSTALL_FAILED_INSUFFICIENT_STORAGE*) say "    Причина: на ТВ мало места." ;;
		*INSTALL_FAILED_NO_MATCHING_ABIS*|*INSTALL_FAILED_CPU_ABI_INCOMPATIBLE*) say "    Причина: сборка не под архитектуру этого ТВ (часто нужен armeabi-v7a)." ;;
		*INSTALL_FAILED_OLDER_SDK*) say "    Причина: APK требует более новый Android." ;;
		*INSTALL_FAILED_DEPRECATED_SDK_VERSION*) say "    Причина: слишком старый targetSdk — Android 14+ такие APK блокирует." ;;
		*INSTALL_FAILED_MISSING_SPLIT*) say "    Причина: это часть split-пакета; нужны все сплиты (.apks/.xapk)." ;;
	esac
}

do_install() {
	ensure_connected || return
	ask "Путь к APK или папке с APK: "
	[ -n "$ANSWER" ] || return
	_p=$(clean_path "$ANSWER")
	pick_file "$_p" '*.apk' || return
	say "Устанавливаю: ${PICKED##*/}"
	_o=$(A install -r "$PICKED" 2>&1 | tr -d '\r')
	case "$_o" in
		*Success*) say "[+] Установлено." ;;
		*)
			say "[!] Ошибка установки:"
			printf '%s\n' "$_o" | tail -n 3 | sed 's/^/    /'
			explain_install "$_o" ;;
	esac
}

# --- файлы ---

do_push() {
	ensure_connected || return
	ask "Что отправить (файл или папка с файлами): "
	[ -n "$ANSWER" ] || return
	_p=$(clean_path "$ANSWER")
	pick_file "$_p" '*' || return
	ask "Куда на ТВ (папка, Enter = /sdcard/Download/): "
	_dst="${ANSWER:-/sdcard/Download/}"
	# Путь передаётся протоколом adb sync, а не оболочкой, поэтому пробелы безопасны
	_o=$(A push "$PICKED" "$_dst" 2>&1 | tr -d '\r' | tail -n 2)
	say "$_o"
}

do_pull() {
	ensure_connected || return
	ask "Показать содержимое папки на ТВ? Путь (Enter = пропустить): "
	if [ -n "$ANSWER" ]; then
		A shell "ls -la $(shq "$ANSWER")" 2>&1 | tr -d '\r'
	fi
	ask "Какой файл/папку скачать (полный путь на ТВ): "
	[ -n "$ANSWER" ] || return
	mkdir -p "$PULL_DIR" 2>/dev/null
	_o=$(A pull "$ANSWER" "$PULL_DIR/" 2>&1 | tr -d '\r' | tail -n 2)
	say "$_o"
	say "Папка назначения: $PULL_DIR"
}

# --- питание ---

after_power() {
	adb disconnect "$TARGET" >/dev/null 2>&1
	WE_CONNECTED=0
	TARGET=""
	say "Соединение закрыто. Когда ТВ включится — выбери пункт 11."
}

do_power() {
	ensure_connected || return
	say ""
	say "Питание"
	say "  1) Перезагрузить   2) В recovery   3) В bootloader   4) Выключить   0) Назад"
	ask ">>> "
	case "$ANSWER" in
		1) confirm "Перезагрузить ТВ?" && { A reboot >/dev/null 2>&1; say "Перезагрузка..."; after_power; } ;;
		2) confirm "Перезагрузить в recovery?" && { A reboot recovery >/dev/null 2>&1; say "Перезагрузка в recovery..."; after_power; } ;;
		3) confirm "Перезагрузить в bootloader?" && { A reboot bootloader >/dev/null 2>&1; say "Перезагрузка в bootloader..."; after_power; } ;;
		4) confirm "Выключить ТВ? Включить его удалённо не получится." && { A shell reboot -p >/dev/null 2>&1; say "Выключение..."; after_power; } ;;
		*) ;;
	esac
}

do_switch() {
	if [ "$WE_CONNECTED" -eq 1 ] && [ -n "$TARGET" ]; then
		adb disconnect "$TARGET" >/dev/null 2>&1
		WE_CONNECTED=0
	fi
	TARGET=""
	choose_tv ""
}

# ==========================================
# 5. ЗАПУСК
# ==========================================

clear 2>/dev/null
say ""
say "---------------------------------------------"
say "TV-TOOLS v2 — УТИЛИТЫ ДЛЯ ANDROID TV"
say "---------------------------------------------"
say ""

if [ -n "${1:-}" ]; then
	if valid_target "$1"; then
		connect_tv "$1" || choose_tv "$1"
	else
		say "[!] Некорректный адрес: $1"
		choose_tv ""
	fi
else
	choose_tv ""
fi

while :; do
	say ""
	say "Подключено: $TARGET"
	say "Выбери действие:"
	say "   1) Информация об устройстве      7) Установить APK"
	say "   2) Скриншот                      8) Отправить файл на ТВ"
	say "   3) Запись экрана                 9) Скачать файл с ТВ"
	say "   4) Пульт                        10) Питание (перезагрузка / выключение)"
	say "   5) Ввод текста                  11) Сменить ТВ / переподключиться"
	say "   6) Приложения                    0) Выход"
	ask ">>> "
	case "$ANSWER" in
		1) do_info ;;
		2) do_screenshot ;;
		3) do_record ;;
		4) do_remote ;;
		5) do_text ;;
		6) do_apps ;;
		7) do_install ;;
		8) do_push ;;
		9) do_pull ;;
		10) do_power ;;
		11) do_switch ;;
		0) say "Отключаюсь..."; exit 0 ;;
		'') ;;
		*) say "Ошибка! Неверный ввод, повтори попытку" ;;
	esac
done

