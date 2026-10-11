#!/system/bin/sh
#
# unpacker.sh v2 — распаковка ZIP-архивов с прогрессом и защитой от zip-slip
# Автор: GoldenFrog
#
# Что изменилось относительно v1:
#  - Прогресс наконец работает: системный unzip (ziptool) пишет «  inflating:»
#    строчными, а v1 ловил «Inflating:»/«Extracting:» — счётчик всегда был 0.
#    Число файлов в архиве тоже считалось неверно (NR-3 при 5 служебных строках).
#  - Имена архивов с пробелами: v1 склеивал список в строку и резал её
#    на словах (`for z in $ZIP_LIST`) — «My Archive.zip» превращался в два файла.
#  - Защита от zip-slip: архив с абсолютными путями, `..` или трюком
#    «файл-симлинк + запись сквозь него» отклоняется ДО распаковки.
#    Симлинки, указывающие за пределы папки, после распаковки удаляются.
#  - Имя папки назначения проверяется: `../../system` больше не проходит.
#    По умолчанию — имя архива без .zip (просто нажми Enter).
#  - Если папка уже есть и не пустая — спрашивает: перезаписать / пропустить
#    существующие / новая папка (имя_2) / отмена. v1 молча перезаписывал (-o).
#  - Проверка свободного места перед распаковкой (с запасом 2%).
#  - Код возврата unzip больше не теряется в пайпе: ошибки видны, а не
#    «Распаковка завершена!» при битом архиве.
#  - Мультивыбор: «1 3 5-7», Enter — все. Каждый архив — в свою папку.
#  - Поиск без учёта регистра (.zip/.ZIP), поддержка путей в кавычках и ~.
#  - Режим проверки целостности (-t) и удаление архива после успеха (--delete).
#  - Аргументы командной строки — можно запускать без вопросов (-y).
#  - Убраны `echo -e` (в sh печатает «-e») и прочие bash-измы.
#  - Работает с системным unzip (ziptool), Info-ZIP (Termux) и busybox unzip.
#
# Запуск:
#   su -c sh /sdcard/unpacker.sh                       — интерактивно
#   sh unpacker.sh /sdcard/Download                    — архивы из папки
#   sh unpacker.sh -y "/sdcard/Download/My Game.zip"   — без вопросов
#   sh unpacker.sh -t /sdcard/Download                 — только проверить архивы
#
# Опции:
#   -d ПАПКА    куда распаковывать (по умолчанию — рядом с архивом)
#   -o          перезаписывать существующие файлы
#   -n          не трогать существующие файлы (докачать недостающие)
#   -y          не задавать вопросов (по умолчанию: все архивы, папка
#               по имени архива, при конфликте — новая папка имя_2)
#   -t          только проверить целостность, ничего не распаковывать
#   --delete    удалить архив после успешной распаковки
#   -h          справка

VERSION="2.0"
DEFAULT_DIR="${UNPACKER_DIR:-/sdcard/Download}"

say()  { printf '%s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }

ASSUME_YES=0
POLICY=""        # "" — спросить, over, skip, new
DEST_BASE=""
DELETE_SRC=""    # "" — спросить, 1, 0
TEST_ONLY=0

# ask "вопрос" ["значение по умолчанию"] — ответ в $ANSWER
ask() {
	if [ "$ASSUME_YES" -eq 1 ]; then
		ANSWER="$2"
		return
	fi
	if [ -n "$2" ]; then
		printf '%s\n[»] (Enter = %s) ' "$1" "$2"
	else
		printf '%s\n[»] ' "$1"
	fi
	IFS= read -r ANSWER || ANSWER=""
	[ -z "$ANSWER" ] && ANSWER="$2"
}

yes_no() {
	case "$1" in y|Y|yes|Yes|д|Д|да|Да) return 0 ;; *) return 1 ;; esac
}

usage() {
	sed -n '/^# Запуск:/,/^#   -h/p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
}

# ==========================================
# 0. АРГУМЕНТЫ
# ==========================================

while [ $# -gt 0 ]; do
	case "$1" in
		-y|--yes)       ASSUME_YES=1 ;;
		-o|--overwrite) POLICY="over" ;;
		-n|--skip)      POLICY="skip" ;;
		-t|--test)      TEST_ONLY=1 ;;
		--delete)       DELETE_SRC=1 ;;
		--keep)         DELETE_SRC=0 ;;
		-d|--dest)
			[ $# -ge 2 ] || { warn "После $1 нужна папка"; exit 1; }
			DEST_BASE="$2"
			shift
			;;
		-h|--help)      usage; exit 0 ;;
		--)             shift; break ;;
		-*)             warn "Неизвестная опция: $1 (см. -h)"; exit 1 ;;
		*)              break ;;
	esac
	shift
done

# ==========================================
# 1. ОКРУЖЕНИЕ
# ==========================================

UNZIP_MODE=""
if command -v unzip >/dev/null 2>&1; then
	if unzip -v 2>/dev/null | head -n 1 | grep -q '^UnZip'; then
		UNZIP_MODE="infozip"     # Termux / Linux
	else
		UNZIP_MODE="ziptool"     # системный /system/bin/unzip
	fi
elif command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx unzip; then
	UNZIP_MODE="busybox"
fi

if [ -z "$UNZIP_MODE" ]; then
	warn "unzip не найден (ни системный, ни в busybox)."
	exit 1
fi

run_unzip() {
	if [ "$UNZIP_MODE" = "busybox" ]; then
		busybox unzip "$@"
	else
		unzip "$@"
	fi
}

# Временная папка: TMPDIR (Termux) → /data/local/tmp (root/adb)
TMP_BASE="${TMPDIR:-/data/local/tmp}"
[ -d "$TMP_BASE" ] && [ -w "$TMP_BASE" ] || TMP_BASE="/data/local/tmp"
WORK=$(mktemp -d "$TMP_BASE/unpacker.XXXXXX" 2>/dev/null)
if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
	WORK="$TMP_BASE/unpacker.$$"
	mkdir -p "$WORK" 2>/dev/null || { warn "Не удалось создать временную папку в $TMP_BASE"; exit 1; }
fi

cleanup() {
	case "$WORK" in
		"$TMP_BASE"/unpacker.*) rm -rf "$WORK" ;;
	esac
}
trap cleanup EXIT
trap 'printf "\n"; warn "Прервано."; exit 130' INT TERM

# Чистка пути, введённого руками: пробелы по краям, кавычки, ~
clean_path() {
	_p="$1"
	if [ ! -e "$_p" ]; then
		_p=$(printf '%s' "$_p" | sed \
			-e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
			-e "s/^[\"']//" -e "s/[\"']\$//")
	fi
	case "$_p" in
		"~")   _p="/sdcard" ;;
		"~/"*) _p="/sdcard/${_p#\~/}" ;;
	esac
	printf '%s' "$_p"
}

# Абсолютный путь к существующей папке (без завершающего /)
abs_dir() { (cd -- "$1" 2>/dev/null && pwd -P); }

# Человекочитаемый размер из байт (awk — в mksh арифметика 32-битная)
hsize() {
	awk -v b="$1" 'BEGIN {
		split("Б КБ МБ ГБ ТБ", u, " "); i = 1
		while (b >= 1024 && i < 5) { b /= 1024; i++ }
		if (i == 1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i]
	}'
}

file_size() { wc -c < "$1" 2>/dev/null | tr -d ' '; }

# ==========================================
# 2. РАБОТА С АРХИВОМ
# ==========================================

# Список имён внутри архива, по одному на строку
list_names() {
	if [ "$UNZIP_MODE" != "busybox" ] && run_unzip -Z -1 "$1" > "$2" 2>/dev/null && [ -s "$2" ]; then
		return 0
	fi
	# фоллбэк: разбор `unzip -l` (busybox); имя — всё после даты и времени
	run_unzip -l "$1" 2>/dev/null | awk '
		/^ *-+( +-+)* *$/ { sep++; next }
		sep == 1 { sub(/^ *[0-9]+ +[^ ]+ +[^ ]+ +/, ""); print }
	' > "$2"
	[ -s "$2" ]
}

# Суммарный распакованный размер (байт) — из итоговой строки `unzip -l`
total_size() {
	run_unzip -l "$1" 2>/dev/null | awk '
		/^ *-+( +-+)* *$/ { sep++; next }
		sep == 2 && NF { print $1 + 0; found = 1; exit }
		END { if (!found) print 0 }
	'
}

# Проверка имён на zip-slip. Печатает причину и возвращает 1, если архив опасен.
#  - абсолютные пути и `..` в любом компоненте (в т.ч. с обратными слэшами);
#  - «файл используется как папка»: запись `link` + `link/evil` — классический
#    трюк, когда сначала распаковывается симлинк, а потом пишут сквозь него.
check_names() {
	awk '
		{ name[NR] = $0; if ($0 !~ /\/$/) isfile[$0] = 1 }
		END {
			for (i = 1; i <= NR; i++) {
				n = name[i]
				if (n ~ /^\// || n ~ /^\\/ || n ~ /^[A-Za-z]:/) { print "абсолютный путь: " n; exit 1 }
				if (n ~ /(^|[\/\\])\.\.([\/\\]|$)/)          { print "выход за пределы папки (..): " n; exit 1 }
				p = n; sub(/\/+$/, "", p)
				while ((k = match(p, /\/[^\/]*$/)) > 0) {
					p = substr(p, 1, k - 1)
					if (p in isfile) { print "файл «" p "» используется как папка (симлинк-трюк)"; exit 1 }
				}
			}
		}
	' "$1"
}

# Свободное место (КБ) на разделе, где лежит папка
free_kb() {
	df -k "$1" 2>/dev/null | awk 'END { if (NF >= 6) print $4 + 0; else if (NF >= 3) print $3 + 0; else print 0 }'
}

# Рисует прогресс по строкам вывода unzip. $1 — сколько файлов ожидается.
progress() {
	_total=$1; _count=0; _last=-1
	while IFS= read -r _line; do
		case "$_line" in
			*inflating:*|*extracting:*|*linking:*) _count=$((_count + 1)) ;;
			*) continue ;;
		esac
		if [ "$_total" -gt 0 ]; then
			_pct=$((_count * 100 / _total))
			[ "$_pct" -gt 100 ] && _pct=100
		else
			_pct=0
		fi
		[ "$_pct" -eq "$_last" ] && continue
		_last=$_pct
		_fill=$((_pct / 5)); _bar=""; _j=0
		while [ $_j -lt 20 ]; do
			if [ $_j -lt $_fill ]; then _bar="${_bar}#"; else _bar="${_bar}."; fi
			_j=$((_j + 1))
		done
		printf '\r    [%s] %3d%%  %d/%d' "$_bar" "$_pct" "$_count" "$_total"
	done
	[ "$_last" -ge 0 ] && printf '\n'
	return 0
}

# Удаляет симлинки из архива, которые смотрят за пределы папки назначения.
# ziptool симлинки не создаёт (пишет обычным файлом), Info-ZIP и busybox — создают.
fix_symlinks() {
	_names="$1"; _dest="$2"; _real=$(abs_dir "$_dest"); _bad=0
	[ -n "$_real" ] || return 0
	while IFS= read -r _n; do
		_f="$_dest/${_n%/}"
		[ -L "$_f" ] || continue
		_t=$(readlink -f "$_f" 2>/dev/null)
		case "$_t" in
			"$_real"/*) ;;
			*)
				rm -f "$_f"
				warn "Удалён опасный симлинк: ${_n%/} → $(readlink "$_f" 2>/dev/null || echo "$_t")"
				_bad=$((_bad + 1))
				;;
		esac
	done < "$_names"
	[ "$_bad" -eq 0 ]
}

# Безопасное имя папки: без `..`, не пустое, не «.»
valid_dest_name() {
	case "$1" in
		''|.|..) return 1 ;;
		*/../*|../*|*/..|*/./*|./*|*/.) return 1 ;;
	esac
	return 0
}

# Свободное имя: name, name_2, name_3...
free_name() {
	_b="$1"; _k=2
	_c="$_b"
	while [ -e "$_c" ]; do
		_c="${_b}_$_k"
		_k=$((_k + 1))
	done
	printf '%s' "$_c"
}

dir_nonempty() { [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null | head -n 1)" ]; }

# ==========================================
# 3. ВЫБОР АРХИВОВ
# ==========================================

show_header() {
	[ -t 1 ] && [ "$ASSUME_YES" -eq 0 ] && clear
	say "==========================================="
	say "   📦 ANDROID FAST UNPACKER v$VERSION"
	say "==========================================="
}

show_header

LIST="$WORK/list.txt"
SEL="$WORK/selected.txt"
: > "$LIST"
FROM_DIR=0

add_source() {
	_s=$(clean_path "$1")
	if [ -f "$_s" ]; then
		_d=$(abs_dir "$(dirname -- "$_s")")
		printf '%s/%s\n' "$_d" "$(basename -- "$_s")" >> "$LIST"
	elif [ -d "$_s" ]; then
		_d=$(abs_dir "$_s")
		find "$_d" -maxdepth 1 -type f -iname '*.zip' 2>/dev/null | sort >> "$LIST"
		FROM_DIR=1
	else
		warn "Не найдено: $_s"
	fi
}

if [ $# -eq 0 ]; then
	ask "[?] Папка с .zip архивами (или путь к одному архиву):" "$DEFAULT_DIR"
	add_source "$ANSWER"
else
	for src in "$@"; do add_source "$src"; done
fi

# Один и тот же архив могли указать дважды — убираем дубли
sort -u "$LIST" -o "$LIST"
COUNT=$(grep -c '' "$LIST")

if [ "$COUNT" -eq 0 ]; then
	warn "ZIP-архивы не найдены."
	exit 1
fi

if [ "$COUNT" -eq 1 ] || [ "$FROM_DIR" -eq 0 ] || [ "$ASSUME_YES" -eq 1 ]; then
	cp "$LIST" "$SEL"
else
	say ""
	say "[*] Найдено архивов: $COUNT"
	i=1
	while IFS= read -r f <&3; do
		printf '  [%d] %s  (%s)\n' "$i" "${f##*/}" "$(hsize "$(file_size "$f")")"
		i=$((i + 1))
	done 3< "$LIST"
	say ""
	ask "[?] Номера архивов (например: 1 3 5-7, a — все):" "a"
	: > "$SEL"
	case "$ANSWER" in
		a|A|all|все|Все) cp "$LIST" "$SEL" ;;
		*)
			for tok in $(printf '%s' "$ANSWER" | tr ',' ' '); do
				case "$tok" in
					*[!0-9-]*|-*|*-|*-*-*|'') warn "Пропуск некорректного значения: $tok"; continue ;;
					*-*) from=${tok%-*}; to=${tok#*-} ;;
					*)   from=$tok; to=$tok ;;
				esac
				from=$(printf '%s' "$from" | sed 's/^0*//'); [ -z "$from" ] && from=0
				to=$(printf '%s' "$to" | sed 's/^0*//');     [ -z "$to" ] && to=0
				if [ "$from" -lt 1 ] || [ "$to" -gt "$COUNT" ] || [ "$from" -gt "$to" ]; then
					warn "Вне диапазона 1-$COUNT: $tok"
					continue
				fi
				n=$from
				while [ "$n" -le "$to" ]; do
					line=$(sed -n "${n}p" "$LIST")
					grep -qxF -- "$line" "$SEL" || printf '%s\n' "$line" >> "$SEL"
					n=$((n + 1))
				done
			done
			;;
	esac
	if [ ! -s "$SEL" ]; then
		warn "Ничего не выбрано."
		exit 1
	fi
fi

SEL_COUNT=$(grep -c '' "$SEL")

if [ -n "$DEST_BASE" ]; then
	DEST_BASE=$(clean_path "$DEST_BASE")
	mkdir -p -- "$DEST_BASE" 2>/dev/null
	_abs=$(abs_dir "$DEST_BASE")
	[ -n "$_abs" ] || { warn "Не удалось создать папку: $DEST_BASE"; exit 1; }
	DEST_BASE="$_abs"
fi

if [ "$TEST_ONLY" -eq 0 ] && [ -z "$DELETE_SRC" ]; then
	say ""
	ask "[?] Удалять архив после успешной распаковки? (y/N)" "n"
	if yes_no "$ANSWER"; then DELETE_SRC=1; else DELETE_SRC=0; fi
fi
[ -n "$DELETE_SRC" ] || DELETE_SRC=0

# ==========================================
# 4. РАСПАКОВКА
# ==========================================

OK=0; FAIL=0; SKIPPED=0
FAILED_LIST="$WORK/failed.txt"; : > "$FAILED_LIST"
NAMES="$WORK/names.txt"
ERR="$WORK/err.txt"
RC="$WORK/rc.txt"

fail() { FAIL=$((FAIL + 1)); printf '%s\n' "$1" >> "$FAILED_LIST"; }

idx=0
while IFS= read -r ZIP <&4; do
	idx=$((idx + 1))
	ZNAME="${ZIP##*/}"
	say ""
	say "[$idx/$SEL_COUNT] $ZNAME"

	if [ ! -r "$ZIP" ]; then
		warn "Нет доступа на чтение (запусти через su)."
		fail "$ZNAME"; continue
	fi

	if ! list_names "$ZIP" "$NAMES"; then
		warn "Не удалось прочитать архив — битый, не ZIP или пустой."
		fail "$ZNAME"; continue
	fi

	if reason=$(check_names "$NAMES"); then :; else
		warn "Архив отклонён: $reason"
		fail "$ZNAME"; continue
	fi

	FILES=$(grep -cv '/$' "$NAMES")
	BYTES=$(total_size "$ZIP")
	say "    файлов: $FILES, распакованный размер: $(hsize "$BYTES"), архив: $(hsize "$(file_size "$ZIP")")"

	# --- только проверка ---
	if [ "$TEST_ONLY" -eq 1 ]; then
		if run_unzip -tq "$ZIP" > "$ERR" 2>&1 || run_unzip -t "$ZIP" > "$ERR" 2>&1; then
			say "[+] Архив цел."
			OK=$((OK + 1))
		else
			warn "Архив повреждён:"
			grep -iv 'OK$' "$ERR" | tail -n 5 >&2
			fail "$ZNAME"
		fi
		continue
	fi

	# --- куда распаковывать ---
	BASE="${DEST_BASE:-${ZIP%/*}}"
	DEF_NAME="${ZNAME%.[zZ][iI][pP]}"
	[ -n "$DEF_NAME" ] || DEF_NAME="unpacked"

	if [ "$SEL_COUNT" -eq 1 ]; then
		ask "[?] Имя папки (или полный путь /...):" "$DEF_NAME"
		NAME="$ANSWER"
	else
		NAME="$DEF_NAME"
	fi
	NAME="${NAME%/}"

	if ! valid_dest_name "$NAME"; then
		warn "Недопустимое имя «$NAME» — использую «$DEF_NAME»."
		NAME="$DEF_NAME"
	fi
	case "$NAME" in
		/*) DEST="$NAME" ;;
		*)  DEST="$BASE/$NAME" ;;
	esac

	# --- папка уже существует ---
	MODE="-o"
	if [ -e "$DEST" ] && [ ! -d "$DEST" ]; then
		DEST=$(free_name "$DEST")
		say "[*] Это имя занято файлом — распакую в: $DEST"
	elif dir_nonempty "$DEST"; then
		act="$POLICY"
		if [ -z "$act" ]; then
			if [ "$ASSUME_YES" -eq 1 ]; then
				act="new"
			else
				say "[?] Папка уже существует и не пуста: $DEST"
				ask "    o — перезаписать, n — оставить существующие файлы, r — новая папка, s — пропустить" "r"
				case "$ANSWER" in
					o|O) act="over" ;;
					n|N) act="skip" ;;
					s|S) act="cancel" ;;
					*)   act="new" ;;
				esac
			fi
		fi
		case "$act" in
			over)   MODE="-o"; say "[*] Существующие файлы будут перезаписаны." ;;
			skip)   MODE="-n"; say "[*] Существующие файлы останутся как есть." ;;
			new)    DEST=$(free_name "$DEST"); say "[*] Распакую в новую папку: $DEST" ;;
			cancel) say "[*] Пропущено."; SKIPPED=$((SKIPPED + 1)); continue ;;
		esac
	fi

	if ! mkdir -p -- "$DEST" 2>/dev/null; then
		warn "Не удалось создать папку: $DEST"
		fail "$ZNAME"; continue
	fi

	# --- место ---
	AVAIL=$(free_kb "$DEST")
	if [ "${AVAIL:-0}" -gt 0 ] && ! awk -v a="$AVAIL" -v b="$BYTES" 'BEGIN { exit !(a * 1024 >= b * 1.02 + 1048576) }'; then
		warn "Мало места: нужно ~$(hsize "$BYTES"), свободно $(hsize "$(awk -v a="$AVAIL" 'BEGIN{printf "%.0f", a*1024}')")."
		ask "[?] Всё равно продолжить? (y/N)" "n"
		if ! yes_no "$ANSWER"; then
			rmdir -- "$DEST" 2>/dev/null
			fail "$ZNAME"; continue
		fi
	fi

	# --- распаковка ---
	say "[*] Распаковка в: $DEST"
	T0=$(date +%s)
	: > "$ERR"; : > "$RC"
	{ run_unzip "$MODE" "$ZIP" -d "$DEST" 2> "$ERR"; echo $? > "$RC"; } | progress "$FILES"
	rc=$(cat "$RC" 2>/dev/null)
	[ -n "$rc" ] || rc=1
	T1=$(date +%s)

	fix_symlinks "$NAMES" "$DEST"

	if [ "$rc" -eq 0 ]; then
		say "[+] Готово за $((T1 - T0)) с."
		OK=$((OK + 1))
		if [ "$DELETE_SRC" -eq 1 ]; then
			rm -f -- "$ZIP" && say "[*] Архив удалён."
		fi
	else
		warn "unzip завершился с кодом $rc:"
		[ -s "$ERR" ] && tail -n 5 "$ERR" >&2
		fail "$ZNAME"
	fi
done 4< "$SEL"

# ==========================================
# 5. ИТОГ
# ==========================================

say ""
say "==========================================="
if [ "$TEST_ONLY" -eq 1 ]; then
	say "  Проверено: $OK цел(ы), $FAIL с ошибками"
else
	say "  Успешно: $OK   Ошибки: $FAIL   Пропущено: $SKIPPED"
fi
if [ "$FAIL" -gt 0 ]; then
	say "  Проблемные архивы:"
	while IFS= read -r f; do say "   - $f"; done < "$FAILED_LIST"
fi
say "==========================================="

[ "$FAIL" -eq 0 ]
