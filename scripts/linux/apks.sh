#!/system/bin/sh
#
# apks.sh v2 — пакетная установка .apk и .apks (Split APK) через pm
# Автор: GoldenFrog
#
# Что изменилось относительно v1:
#  - Пути и имена файлов с пробелами (и прочими спецсимволами) обрабатываются
#    корректно: список файлов больше не гоняется через `ls` + word splitting,
#    все переменные с путями в кавычках, сплиты передаются в pm как отдельные
#    аргументы через "$@".
#  - Пустая папка больше не считается как «найден 1 файл».
#  - Номера при выборочной установке проверяются (не число / вне диапазона /
#    дубликаты), поддерживаются диапазоны вида 2-5 и запятые.
#  - Убрана ложная проверка `pm list features | grep install.multiple` —
#    такой фичи не существует, а `pm install-multiple` есть с Android 5.
#  - Уникальная временная папка (mktemp) вместо общей /data/local/tmp/apks_extract:
#    больше нет смешивания сплитов от прошлых запусков и коллизий имён.
#    Временные файлы чистятся в любом случае (trap), в т.ч. по Ctrl+C.
#  - .apks от bundletool/SAI: берутся сплиты из splits/, папка standalones/
#    игнорируется (раньше всё валилось в одну кучу или не находилось вовсе).
#  - Защита от zip-slip: архив с путями `../` или абсолютными путями,
#    а также с симлинками внутри — отклоняется.
#  - Одиночные .apk стримятся в pm через stdin (pm install -S), без копирования
#    — не нужно двойное место под тяжёлые APK. Если не вышло — фоллбэк на копию.
#  - Удаление исходников после установки теперь только по явному согласию
#    (раньше файлы молча удалялись).
#  - Успех определяется и по коду возврата, и по "Success".
#  - Расширен разбор ошибок (MISSING_SPLIT, DEPRECATED_SDK_VERSION и др.).
#  - Итоговая сводка и код возврата: 0 — всё ок, 1 — были ошибки.
#  - Исправлен `exit 0 &>/dev/null` — в sh это значит «запусти exit в фоне».
#
# Запуск: su -c sh /data/local/scripts/apks.sh  (или из adb shell)

LOG_DIR="${APKS_LOG_DIR:-/sdcard/.My Folder/logs}"
TMP_BASE="/data/local/tmp"

say() { printf '%s\n' "$*"; }

# ask "вопрос" — ответ кладётся в $ANSWER
ask() {
	printf '%s\n[»] ' "$1"
	IFS= read -r ANSWER || ANSWER=""
}

yes_no() {
	case "$1" in y|Y|yes|Yes|д|Д|да|Да) return 0 ;; *) return 1 ;; esac
}

# ==========================================
# 0. ПРОВЕРКИ ОКРУЖЕНИЯ
# ==========================================

if ! command -v pm >/dev/null 2>&1; then
	say "[!] Команда pm не найдена — скрипт должен запускаться на Android."
	exit 1
fi

# pm от обычного пользователя Termux ставить пакеты не может — нужен root или adb shell
case "$(id -u 2>/dev/null)" in
	0|2000) ;;
	*)
		say "[!] Нужны права root (su) или adb shell (uid 2000)."
		exit 1
		;;
esac

# unzip нужен только для .apks: системный (Termux/toybox) или из busybox
UNZIP_MODE=""
if command -v unzip >/dev/null 2>&1; then
	UNZIP_MODE="native"
elif command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx unzip; then
	UNZIP_MODE="busybox"
fi

run_unzip() {
	if [ "$UNZIP_MODE" = "busybox" ]; then
		busybox unzip "$@"
	else
		unzip "$@"
	fi
}

# ==========================================
# 1. ВРЕМЕННАЯ ПАПКА И ОЧИСТКА
# ==========================================

WORK=$(mktemp -d "$TMP_BASE/apks.XXXXXX" 2>/dev/null)
if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
	WORK="$TMP_BASE/apks.$$"
	mkdir -p "$WORK" || { say "[!] Не удалось создать временную папку в $TMP_BASE"; exit 1; }
fi

# rm -rf только внутри нашей временной папки — никаких сюрпризов с пустой переменной
safe_rm_work() {
	case "$1" in
		"$TMP_BASE"/apks.*) rm -rf "$1" ;;
	esac
}

cleanup() { safe_rm_work "$WORK"; }
trap cleanup EXIT
trap 'say ""; say "[!] Прервано."; exit 130' INT TERM

# ==========================================
# 2. ВЫБОР ДИРЕКТОРИИ
# ==========================================

ask "[?] Укажи директорию для поиска .apk / .apks файлов:"
USER_DIR="$ANSWER"

if [ -z "$USER_DIR" ]; then
	say "[!] Директория не указана"
	exit 1
fi

# Если путь вставили в кавычках или с пробелами по краям — пробуем почистить,
# но только если «сырой» путь не существует (папки с пробелом в конце бывают)
if [ ! -d "$USER_DIR" ]; then
	CLEANED=$(printf '%s' "$USER_DIR" | sed \
		-e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
		-e "s/^[\"']//" -e "s/[\"']\$//")
	[ -d "$CLEANED" ] && USER_DIR="$CLEANED"
fi

if [ ! -d "$USER_DIR" ]; then
	say "[!] Такой директории не существует: $USER_DIR"
	exit 1
fi

SRC_DIR="$USER_DIR"
[ "$SRC_DIR" != "/" ] && SRC_DIR="${SRC_DIR%/}"

# ==========================================
# 3. ПОИСК ФАЙЛОВ
# ==========================================
# Список храним в файле по одному пути на строку — это работает в любом sh
# (mksh/dash/bash) и не ломается на пробелах. Регистр расширения не важен.

LIST="$WORK/list.txt"
SEL="$WORK/selected.txt"

say ""
say "[*] Поиск .apk и .apks файлов в $SRC_DIR..."

find "$SRC_DIR" -maxdepth 1 -type f \( -iname '*.apk' -o -iname '*.apks' \) 2>/dev/null \
	| sort > "$LIST"

COUNT=$(grep -c '' "$LIST")

if [ "$COUNT" -eq 0 ]; then
	say "[!] Нет файлов .apk или .apks в $SRC_DIR"
	exit 1
fi

say "[*] Найдено файлов: $COUNT"

# ==========================================
# 4. ВЫБОР ФАЙЛОВ ДЛЯ УСТАНОВКИ
# ==========================================

if [ "$COUNT" -eq 1 ]; then
	say "[?] Найден один файл: $(basename "$(head -n 1 "$LIST")")"
	ask "[?] Установить? (y/n)"
	yes_no "$ANSWER" || { say "[!] Отменено пользователем."; exit 0; }
	cp "$LIST" "$SEL"
else
	say "[?] Найдено несколько файлов:"
	i=1
	while IFS= read -r f <&3; do
		say "  [$i] ${f##*/}"
		i=$((i + 1))
	done 3< "$LIST"

	say ""
	ask "[?] Установить все файлы? (y/n)"

	if yes_no "$ANSWER"; then
		cp "$LIST" "$SEL"
	else
		ask "[?] Введи номера файлов (например: 1 3 5, 1,3 или 2-5):"
		: > "$SEL"

		add_index() {
			_line=$(sed -n "${1}p" "$LIST")
			# дубликаты не добавляем
			grep -qxF -- "$_line" "$SEL" 2>/dev/null || printf '%s\n' "$_line" >> "$SEL"
		}

		for tok in $(printf '%s' "$ANSWER" | tr ',' ' '); do
			case "$tok" in
				*[!0-9-]*|-*|*-|*-*-*|'')
					say "[!] Пропуск некорректного значения: $tok"
					continue
					;;
				*-*)
					from=${tok%-*}
					to=${tok#*-}
					;;
				*)
					from=$tok
					to=$tok
					;;
			esac
			# убираем ведущие нули, чтобы sh не принял число за восьмеричное
			from=$(printf '%s' "$from" | sed 's/^0*//'); [ -z "$from" ] && from=0
			to=$(printf '%s' "$to" | sed 's/^0*//');     [ -z "$to" ] && to=0

			if [ "$from" -lt 1 ] || [ "$to" -gt "$COUNT" ] || [ "$from" -gt "$to" ]; then
				say "[!] Вне диапазона 1-$COUNT: $tok"
				continue
			fi
			n=$from
			while [ "$n" -le "$to" ]; do
				add_index "$n"
				n=$((n + 1))
			done
		done

		if [ ! -s "$SEL" ]; then
			say "[!] Ничего не выбрано."
			exit 1
		fi
	fi
fi

say ""
ask "[?] Удалять исходные файлы после успешной установки? (y/N)"
DELETE_SRC=0
yes_no "$ANSWER" && DELETE_SRC=1

mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="$TMP_BASE"

# ==========================================
# 5. ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ УСТАНОВКИ
# ==========================================

# Разбор вывода pm → REASON / ADVICE
explain_error() {
	# По умолчанию — первая строка вывода (для наших собственных сообщений
	# вроде «архив отклонён» это и есть причина)
	REASON=$(printf '%s\n' "$1" | sed -n '/./{p;q;}')
	[ -n "$REASON" ] || REASON="Установка завершилась с ошибкой."
	ADVICE="Проверь журнал установки."
	case "$1" in
		*INSTALL_FAILED_UPDATE_INCOMPATIBLE*)
			REASON="Подписи установленного и нового APK не совпадают."
			ADVICE="Удали старое приложение перед установкой." ;;
		*INSTALL_FAILED_VERSION_DOWNGRADE*)
			REASON="Попытка установить более старую версию."
			ADVICE="Удали текущую версию или используй более новую." ;;
		*INSTALL_PARSE_FAILED_NO_CERTIFICATES*)
			REASON="APK не подписан."
			ADVICE="Подпиши пакет через apksigner или скачай подписанную сборку." ;;
		*INSTALL_FAILED_INVALID_APK*|*INSTALL_PARSE_FAILED_NOT_APK*)
			REASON="Повреждённый или некорректный APK."
			ADVICE="Проверь файл или скачай заново." ;;
		*INSTALL_FAILED_INSUFFICIENT_STORAGE*)
			REASON="Недостаточно места на устройстве."
			ADVICE="Очисти память или удали лишние приложения." ;;
		*INSTALL_FAILED_NO_MATCHING_ABIS*|*INSTALL_FAILED_CPU_ABI_INCOMPATIBLE*)
			REASON="Несовместимая архитектура процессора."
			ADVICE="Скачай сборку под arm64-v8a." ;;
		*INSTALL_FAILED_MISSING_SPLIT*)
			REASON="Не хватает обязательного сплита (часть split-пакета отсутствует)."
			ADVICE="Скачай полный .apks / все сплиты под своё устройство." ;;
		*INSTALL_FAILED_DEPRECATED_SDK_VERSION*)
			REASON="Слишком старый targetSdk — Android 14+ блокирует такие APK."
			ADVICE="Поставь вручную: pm install --bypass-low-target-sdk-block <файл>." ;;
		*INSTALL_FAILED_OLDER_SDK*)
			REASON="APK не поддерживает твою версию Android."
			ADVICE="Найди совместимую версию." ;;
		*INSTALL_FAILED_TEST_ONLY*)
			REASON="APK помечен как testOnly."
			ADVICE="Поставь вручную с флагом: pm install -t <файл>." ;;
		*INSTALL_FAILED_MISSING_SHARED_LIBRARY*)
			REASON="Отсутствует нужная системная библиотека."
			ADVICE="Установи недостающую или выбери другую сборку." ;;
		*INSTALL_FAILED_DUPLICATE_PACKAGE*|*INSTALL_FAILED_SHARED_USER_INCOMPATIBLE*)
			REASON="Конфликт с уже установленным пакетом."
			ADVICE="Удали конфликтующее приложение." ;;
		*INSTALL_FAILED_USER_RESTRICTED*|*INSTALL_FAILED_VERIFICATION_FAILURE*)
			REASON="Установка заблокирована политикой/верификацией."
			ADVICE="Проверь Play Protect и ограничения профиля." ;;
		*INSTALL_FAILED_PERMISSION_MODEL_DOWNGRADE*)
			REASON="Устаревшая модель разрешений."
			ADVICE="Используй более новую версию приложения." ;;
		*"Permission denied"*|*INSTALL_FAILED_INVALID_URI*|*"Failed to parse"*)
			REASON="pm не смог прочитать файл."
			ADVICE="Проверь права на файл / SELinux; запусти от root." ;;
	esac
}

# Запись лога неудачной установки
write_fail_log() {
	_file="$1"; _out="$2"
	_log="$LOG_DIR/$(date +"%d-%m-%Y_%H-%M-%S")_fail_${_file##*/}.log"
	{
		echo "•———————————————————•"
		echo "Ошибка при установке APK"
		echo
		echo " Файл   : $_file"
		echo " Время  : $(date '+%d-%m-%Y %H:%M:%S')"
		echo " Причина: $REASON"
		echo " Совет  : $ADVICE"
		echo "•———————————————————•"
		echo
		echo "•———————————————————•"
		echo "Журнал установки:"
		printf '%s\n' "$_out"
		echo "•———————————————————•"
	} > "$_log" 2>/dev/null && say "[!] Лог сохранён: $_log"
}

# Успех = код возврата 0 И строка Success в выводе
is_success() {
	[ "$1" -eq 0 ] && case "$2" in *Success*) return 0 ;; esac
	return 1
}

# Установка одиночного APK. Сначала стримим через stdin (без копии на диск),
# если pm не понял стрим — фоллбэк на копию в нашу временную папку.
install_apk() {
	_src="$1"; _job="$2"
	_size=$(wc -c < "$_src" | tr -d ' ')
	OUTPUT=$(pm install -S "$_size" < "$_src" 2>&1); RC=$?
	is_success "$RC" "$OUTPUT" && return 0

	# Если это осмысленная ошибка установки — повторять бессмысленно
	case "$OUTPUT" in *INSTALL_FAILED*|*INSTALL_PARSE_FAILED*) return 1 ;; esac

	say "[*] Стрим не сработал, пробую через копию..."
	cp -- "$_src" "$_job/base.apk" || { OUTPUT="cp failed: $_src"; return 1; }
	OUTPUT=$(pm install "$_job/base.apk" 2>&1); RC=$?
	is_success "$RC" "$OUTPUT"
}

# Установка .apks (zip со сплитами)
install_apks() {
	_src="$1"; _job="$2"
	_ex="$_job/extract"

	if [ -z "$UNZIP_MODE" ]; then
		OUTPUT="unzip не найден (установи busybox или пакет unzip в Termux)"
		return 1
	fi

	# Zip-slip: не распаковываем архивы с ../ или абсолютными путями.
	# Скрипт работает от root, такой архив мог бы перезаписать что угодно.
	# (строку "Archive: <путь>" пропускаем — там абсолютный путь самого архива)
	if run_unzip -l "$_src" 2>/dev/null | grep -v '^Archive:' \
		| grep -Eq '(^|[[:space:]/])\.\.(/|$)|[[:space:]]/[^[:space:]]'; then
		OUTPUT="Архив содержит небезопасные пути (../ или абсолютные) — отклонён."
		return 1
	fi

	mkdir -p "$_ex"
	if ! run_unzip -o -q "$_src" -d "$_ex" >/dev/null 2>&1; then
		OUTPUT="Не удалось распаковать архив."
		return 1
	fi

	# Симлинки внутри APKS не нужны никогда — это признак подлога
	if [ -n "$(find "$_ex" -type l 2>/dev/null | head -n 1)" ]; then
		OUTPUT="Архив содержит симлинки — отклонён."
		return 1
	fi

	# bundletool/SAI кладут сплиты в splits/, а в standalones/ — отдельные
	# полные APK под разные устройства, которые ставить вместе со сплитами нельзя
	_search="$_ex"
	[ -d "$_ex/splits" ] && _search="$_ex/splits"

	find "$_search" -type f -iname '*.apk' ! -path '*/standalones/*' 2>/dev/null \
		| sort > "$_job/splits.txt"

	if [ ! -s "$_job/splits.txt" ]; then
		OUTPUT="В архиве нет APK файлов."
		return 1
	fi

	# Собираем сплиты в позиционные параметры — каждый путь отдельным
	# аргументом, пробелы в именах больше не ломают команду
	set --
	while IFS= read -r _s <&4; do
		set -- "$@" "$_s"
	done 4< "$_job/splits.txt"

	say "[*] Сплитов в архиве: $#"
	if [ "$#" -eq 1 ]; then
		OUTPUT=$(pm install "$1" 2>&1); RC=$?
	else
		OUTPUT=$(pm install-multiple "$@" 2>&1); RC=$?
	fi
	is_success "$RC" "$OUTPUT"
}

# ==========================================
# 6. ОСНОВНОЙ ЦИКЛ
# ==========================================

OK=0
FAIL=0
n=0

# Читаем список через отдельный дескриптор 3, чтобы pm/cp внутри цикла
# случайно не «съели» stdin и не сбили чтение списка
while IFS= read -r file <&3; do
	[ -n "$file" ] || continue
	n=$((n + 1))
	name="${file##*/}"

	say ""
	say "[*] Обработка: $name"

	if [ ! -f "$file" ]; then
		say "[!] Файл не найден (удалён или переименован?): $file"
		FAIL=$((FAIL + 1))
		continue
	fi

	job="$WORK/job_$n"
	mkdir -p "$job"
	OUTPUT=""
	RC=1

	case "$name" in
		*.[aA][pP][kK][sS]) install_apks "$file" "$job" ;;
		*)                  install_apk  "$file" "$job" ;;
	esac
	status=$?

	if [ "$status" -eq 0 ]; then
		say "[+] Установка успешна: $name"
		OK=$((OK + 1))
		if [ "$DELETE_SRC" -eq 1 ]; then
			rm -f -- "$file" && say "[*] Исходный файл удалён."
		fi
	else
		say "[!] Ошибка при установке: $name"
		explain_error "$OUTPUT"
		say "    Причина: $REASON"
		say "    Совет  : $ADVICE"
		write_fail_log "$file" "$OUTPUT"
		FAIL=$((FAIL + 1))
	fi

	# Чистим за собой сразу, чтобы распакованные архивы не копились
	case "$job" in "$WORK"/job_*) rm -rf "$job" ;; esac
done 3< "$SEL"

# ==========================================
# 7. ИТОГ
# ==========================================

say ""
say "[*] Завершено. Успешно: $OK, с ошибками: $FAIL."

[ "$FAIL" -eq 0 ] && exit 0
exit 1
