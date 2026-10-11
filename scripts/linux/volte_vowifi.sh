#!/system/bin/sh
#
# volte_vowifi.sh v3 — включение VoLTE / VoWiFi / видеозвонков (ViLTE)
# и отображения номера телефона на Google Pixel (Tensor)
# Автор: GoldenFrog
#
# Использование (от root):
#   su -c sh volte_vowifi.sh [команда] [опции]
#
# Команды:
#   apply              — применить (по умолчанию)
#   status             — показать текущее состояние, ничего не меняя
#   restore [файл]     — откатить изменения из бэкапа (по умолчанию — последний)
#
# Опции:
#   --number +7XXXXXXXXXX  — номер для отображения в настройках
#                            (если SIM/оператор его не отдают)
#   --slot N               — работать только с SIM в слоте N (0 или 1)
#   --reboot               — перезагрузить в конце без вопроса
#   --no-reboot            — не перезагружать и не спрашивать
#   -h, --help             — справка
#
# ------------------------------------------------------------------------
# КАК ЭТО РАБОТАЕТ (и чего от скрипта ждать)
# ------------------------------------------------------------------------
# 1. Системные свойства persist.dbg.{volte,vt,wfc}_avail_ovr=1.
#    Их напрямую читает ImsManager в AOSP: при значении 1 он считает, что
#    платформа поддерживает VoLTE / видеозвонки / Wi-Fi Calling, даже если
#    carrier config оператора говорит «нет». Ставятся через init (setprop),
#    поэтому переживают перезагрузку.
#
# 2. Пользовательские переключатели (VoLTE, видеозвонки, Wi-Fi Calling)
#    для каждой активной SIM — колонки таблицы siminfo в telephony.db.
#    С Android 8 они хранятся именно там, а не в `settings global`.
#
# 3. Номер телефона: Android берёт его из трёх источников — оператор,
#    SIM (UICC), IMS. После успешной регистрации VoLTE номер часто
#    появляется сам (из IMS). Если нет — можно задать через --number.
#
# ЧЕСТНО ОБ ОГРАНИЧЕНИЯХ:
#  - Метод через подмену carrier config (overrideConfig), на котором раньше
#    работал Pixel IMS, Google с октября 2025 закрыл для shell
#    ("overrideConfig cannot be invoked by shell"). Нынешний Pixel IMS
#    обходит это через instrumentation внутри APK — из shell-скрипта это
#    не повторить. Если скрипт не помог — пробуй актуальный Pixel IMS.
#  - Реальная регистрация IMS зависит от оператора и профиля модема.
#    Скрипт снимает ограничения со стороны Android, но не может заставить
#    сеть принять регистрацию.
#  - Изменения в siminfo и номер начинают действовать после перезагрузки.
# ------------------------------------------------------------------------

set -u

WORKDIR="${WORKDIR:-/data/local/tmp/volte_vowifi}"
SIMINFO="content://telephony/siminfo"
TS="$(date +%Y%m%d_%H%M%S)"
LOGFILE="$WORKDIR/volte_vowifi_$TS.log"

# Свойства, которые реально читает ImsManager (AOSP frameworks/opt/net/ims)
PROPS="persist.dbg.volte_avail_ovr persist.dbg.vt_avail_ovr persist.dbg.wfc_avail_ovr"

# Колонки siminfo: пользовательские переключатели
#   volte_vt_enabled        — «Расширенный режим 4G / VoLTE»
#   vt_ims_enabled          — видеозвонки
#   wfc_ims_enabled         — Wi-Fi Calling
#   wfc_ims_roaming_enabled — Wi-Fi Calling в роуминге
SIM_TOGGLES="volte_vt_enabled vt_ims_enabled wfc_ims_enabled wfc_ims_roaming_enabled"
# Номер, заданный «от оператора», — у него наивысший приоритет при показе
NUMBER_COL="phone_number_source_carrier"

# ==========================================
# ВСПОМОГАТЕЛЬНОЕ
# ==========================================

log() {
	printf '%s\n' "$*"
	printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOGFILE" 2>/dev/null
}

die() { log "[!] $*"; exit 1; }

usage() {
	sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
}

RESETPROP="$(command -v resetprop 2>/dev/null || true)"

# Записать persist-свойство. setprop идёт через init — значение сохраняется
# в /data/property и переживает ребут. resetprop -p — запасной путь.
set_persist_prop() {
	_k="$1"; _v="$2"
	setprop "$_k" "$_v" 2>/dev/null
	if [ "$(getprop "$_k")" != "$_v" ] && [ -n "$RESETPROP" ]; then
		"$RESETPROP" -p "$_k" "$_v" 2>/dev/null
	fi
	if [ "$(getprop "$_k")" = "$_v" ]; then
		log "[OK] $_k = $_v"
		return 0
	fi
	log "[WARN] Не удалось установить $_k"
	return 1
}

# Удалить persist-свойство (для отката, если его не было до скрипта)
delete_persist_prop() {
	_k="$1"
	if [ -n "$RESETPROP" ]; then
		"$RESETPROP" -p -d "$_k" 2>/dev/null
	fi
	[ -n "$(getprop "$_k")" ] && setprop "$_k" "" 2>/dev/null
	if [ -z "$(getprop "$_k")" ]; then
		log "[OK] $_k удалено"
	else
		log "[WARN] Не удалось удалить $_k"
	fi
}

# Значение одной колонки siminfo для subId.
# Код возврата 1 — колонки нет / провайдер недоступен.
sim_get() {
	_out=$(content query --uri "$SIMINFO" --projection "$2" --where "_id=$1" </dev/null 2>&1) || return 1
	case "$_out" in *"Row:"*) ;; *) return 1 ;; esac
	# Колонка в проекции одна, поэтому значение — весь хвост строки после "col="
	printf '%s\n' "$_out" | sed -n "s/^Row: [0-9]* $2=//p" | head -n 1
}

# sim_set <subId> <колонка> <тип: i|s|n> <значение>
sim_set() {
	if [ "$3" = "n" ]; then
		_bind="$2:n:"
	else
		_bind="$2:$3:$4"
	fi
	if content update --uri "$SIMINFO" --bind "$_bind" --where "_id=$1" </dev/null >/dev/null 2>&1; then
		log "[OK] subId $1: $2 = ${4:-NULL}"
		return 0
	fi
	log "[WARN] subId $1: не удалось записать $2"
	return 1
}

# Список активных SIM: строки "subId slot"
list_active_subs() {
	content query --uri "$SIMINFO" --projection "_id:sim_id" --where "sim_id>=0" </dev/null 2>/dev/null \
		| sed -n 's/^Row: [0-9]* _id=\([0-9]*\), sim_id=\([0-9]*\).*/\1 \2/p'
}

ask_yes_no() {
	[ -t 0 ] || return 1
	printf '%s [y/N]: ' "$1"
	IFS= read -r _a || return 1
	case "$_a" in y|Y|yes|д|Д|да) return 0 ;; *) return 1 ;; esac
}

valid_number() {
	printf '%s' "$1" | grep -Eq '^\+?[0-9]{5,15}$'
}

# ==========================================
# РАЗБОР АРГУМЕНТОВ
# ==========================================

MODE="apply"
RESTORE_FILE=""
NUMBER=""
ONLY_SLOT=""
REBOOT_MODE="ask"

while [ $# -gt 0 ]; do
	case "$1" in
		apply|status) MODE="$1" ;;
		restore)
			MODE="restore"
			if [ $# -gt 1 ]; then
				case "$2" in -*) ;; *) RESTORE_FILE="$2"; shift ;; esac
			fi
			;;
		--number)
			[ $# -gt 1 ] || { echo "[!] --number требует значение"; exit 1; }
			NUMBER="$2"; shift ;;
		--slot)
			[ $# -gt 1 ] || { echo "[!] --slot требует значение"; exit 1; }
			ONLY_SLOT="$2"; shift ;;
		--reboot)    REBOOT_MODE="yes" ;;
		--no-reboot) REBOOT_MODE="no" ;;
		-h|--help)   usage ;;
		*) echo "[!] Неизвестный аргумент: $1 (см. --help)"; exit 1 ;;
	esac
	shift
done

if [ -n "$NUMBER" ] && ! valid_number "$NUMBER"; then
	echo "[!] Некорректный номер: $NUMBER (ожидается +79991234567)"
	exit 1
fi
case "$ONLY_SLOT" in ''|0|1) ;; *) echo "[!] --slot: 0 или 1"; exit 1 ;; esac

# ==========================================
# ПРОВЕРКИ ОКРУЖЕНИЯ
# ==========================================

[ "$(id -u 2>/dev/null)" = "0" ] || { echo "[!] Нужны root-права: su -c sh $0"; exit 1; }

mkdir -p "$WORKDIR" 2>/dev/null || { echo "[!] Не удалось создать $WORKDIR"; exit 1; }
chmod 700 "$WORKDIR" 2>/dev/null

log "[*] volte_vowifi.sh v3 — режим: $MODE"
log "[*] Лог: $LOGFILE"

MANUF="$(getprop ro.product.manufacturer)"
MODEL="$(getprop ro.product.model)"
SOC="$(getprop ro.soc.model)"
SDK="$(getprop ro.build.version.sdk)"

log "[*] Устройство: $MANUF $MODEL (SoC: ${SOC:-?}, SDK $SDK)"

if [ "$MANUF" != "Google" ]; then
	log "[!] Скрипт рассчитан только на Google Pixel. Обнаружено: $MANUF"
	ask_yes_no "Продолжить на свой страх и риск?" || exit 1
fi
case "$SOC" in
	GS*|gs*|Tensor*|zuma*|Zuma*|laguna*) ;;
	*) log "[WARN] SoC не похож на Tensor — на Snapdragon-Pixel часть логики может не сработать." ;;
esac
[ "${SDK:-0}" -ge 33 ] 2>/dev/null || log "[WARN] Android ниже 13 — колонки номера могут отсутствовать."

command -v content >/dev/null 2>&1 || die "Нет утилиты content — не могу работать с telephony.db"

# Список SIM, с которыми работаем
SUBS="$(list_active_subs)"
if [ -n "$ONLY_SLOT" ]; then
	SUBS="$(printf '%s\n' "$SUBS" | awk -v s="$ONLY_SLOT" '$2 == s')"
fi

# ==========================================
# STATUS
# ==========================================

show_status() {
	log ""
	log "==== Свойства (persist.dbg) ===="
	for p in $PROPS; do
		log "  $p = $(getprop "$p")"
	done

	log ""
	log "==== Активные SIM ===="
	if [ -z "$SUBS" ]; then
		log "  (активных SIM не найдено)"
	else
		printf '%s\n' "$SUBS" | while read -r sid slot; do
			[ -n "$sid" ] || continue
			log "  subId $sid (слот $slot): $(sim_get "$sid" display_name)"
			for c in $SIM_TOGGLES; do
				v=$(sim_get "$sid" "$c") || v="(нет колонки)"
				log "    $c = $v"
			done
			for c in phone_number_source_carrier number phone_number_source_ims; do
				v=$(sim_get "$sid" "$c") || v="(нет колонки)"
				log "    $c = $v"
			done
		done
	fi

	log ""
	log "==== IMS (сырые строки dumpsys для ориентира) ===="
	dumpsys phone 2>/dev/null | grep -iE 'ims.?regist|volte|wfc' | head -n 15 \
		| while IFS= read -r l; do log "  $l"; done
	log ""
	log "[i] Точно проверить регистрацию: набери *#*#4636#*#* →"
	log "    «Информация о телефоне» → строки IMS / VoLTE / WFC."
}

if [ "$MODE" = "status" ]; then
	show_status
	exit 0
fi

# ==========================================
# RESTORE
# ==========================================

if [ "$MODE" = "restore" ]; then
	if [ -z "$RESTORE_FILE" ]; then
		RESTORE_FILE="$(ls -1t "$WORKDIR"/backup_*.txt 2>/dev/null | head -n 1)"
	fi
	[ -n "$RESTORE_FILE" ] && [ -f "$RESTORE_FILE" ] || die "Бэкап не найден (ищу в $WORKDIR)"

	log "[*] Откат из: $RESTORE_FILE"
	# Формат строк бэкапа:
	#   prop|<ключ>|<значение или <unset>>
	#   sim|<subId>|<колонка>|<значение или NULL>
	while IFS='|' read -r kind a b c <&3; do
		case "$kind" in
			prop)
				if [ "$b" = "<unset>" ]; then
					delete_persist_prop "$a"
				else
					set_persist_prop "$a" "$b"
				fi
				;;
			sim)
				if [ "$c" = "NULL" ] || [ -z "$c" ]; then
					sim_set "$a" "$b" n ""
				else
					# Номера — всегда строкой (иначе потеряется ведущий 0)
					case "$b:$c" in
						*number*:*|*:*[!0-9-]*) sim_set "$a" "$b" s "$c" ;;
						*)                      sim_set "$a" "$b" i "$c" ;;
					esac
				fi
				;;
		esac
	done 3< "$RESTORE_FILE"

	log "[*] Откат выполнен. Для полного применения нужна перезагрузка."
	if [ "$REBOOT_MODE" = "yes" ] || { [ "$REBOOT_MODE" = "ask" ] && ask_yes_no "Перезагрузить сейчас?"; }; then
		log "[*] Перезагрузка..."
		reboot
	fi
	exit 0
fi

# ==========================================
# APPLY: 1. БЭКАП
# ==========================================

BACKUP="$WORKDIR/backup_$TS.txt"
log ""
log "[*] Бэкап текущих значений → $BACKUP"
{
	for p in $PROPS; do
		v="$(getprop "$p")"
		printf 'prop|%s|%s\n' "$p" "${v:-<unset>}"
	done
	printf '%s\n' "$SUBS" | while read -r sid slot; do
		[ -n "$sid" ] || continue
		for c in $SIM_TOGGLES $NUMBER_COL; do
			# Колонки, которых нет в этой версии Android, не бэкапим
			v=$(sim_get "$sid" "$c") || continue
			printf 'sim|%s|%s|%s\n' "$sid" "$c" "$v"
		done
	done
} > "$BACKUP" || die "Не удалось записать бэкап — без него ничего менять не буду"
chmod 600 "$BACKUP" 2>/dev/null

# ==========================================
# APPLY: 2. СВОЙСТВА ПЛАТФОРМЫ
# ==========================================

log ""
log "[*] Снимаю ограничения платформы (VoLTE / ViLTE / VoWiFi)..."
PROP_FAIL=0
for p in $PROPS; do
	set_persist_prop "$p" 1 || PROP_FAIL=1
done

# ==========================================
# APPLY: 3. ПЕРЕКЛЮЧАТЕЛИ И НОМЕР ДЛЯ КАЖДОЙ SIM
# ==========================================

if [ -z "$SUBS" ]; then
	log "[WARN] Активных SIM не найдено — пропускаю настройки SIM."
else
	# Цикл не в пайпе, чтобы работал интерактивный ввод номера с терминала
	SUBS_FILE="$WORKDIR/.subs_$TS"
	printf '%s\n' "$SUBS" > "$SUBS_FILE"
	while read -r sid slot <&3; do
		[ -n "$sid" ] || continue
		name="$(sim_get "$sid" display_name)"
		log ""
		log "[*] SIM: subId $sid, слот $slot ($name)"

		for c in $SIM_TOGGLES; do
			if sim_get "$sid" "$c" >/dev/null; then
				sim_set "$sid" "$c" i 1
			else
				log "[i] Колонки $c нет в этой версии Android — пропуск"
			fi
		done

		# Номер телефона
		if ! sim_get "$sid" "$NUMBER_COL" >/dev/null; then
			log "[i] Колонки $NUMBER_COL нет — задать номер нельзя"
			continue
		fi
		cur_num=""
		for c in phone_number_source_carrier number phone_number_source_ims; do
			v=$(sim_get "$sid" "$c") || continue
			case "$v" in ''|NULL) ;; *) cur_num="$v"; break ;; esac
		done

		num="$NUMBER"
		if [ -z "$num" ] && [ -z "$cur_num" ] && [ -t 0 ]; then
			printf '[?] Номер для этой SIM (Enter — пропустить, он может подтянуться сам из IMS): '
			IFS= read -r num || num=""
			if [ -n "$num" ] && ! valid_number "$num"; then
				log "[WARN] Некорректный номер «$num» — пропуск"
				num=""
			fi
		fi

		if [ -n "$num" ]; then
			sim_set "$sid" "$NUMBER_COL" s "$num"
		elif [ -n "$cur_num" ]; then
			log "[i] Номер уже известен системе: $cur_num"
		else
			log "[i] Номер не задан — после регистрации VoLTE он часто появляется сам"
		fi
	done 3< "$SUBS_FILE"
	rm -f "$SUBS_FILE"
fi

# ==========================================
# APPLY: 4. МЯГКИЙ ПЕРЕЗАПУСК РАДИО
# ==========================================
# Вместо pkill по подстроке и случайных `service call phone N` (см. список
# изменений) — штатное переключение режима полёта: телефония сама
# переоценит возможности IMS с новыми свойствами.

log ""
AIRPLANE="$(settings get global airplane_mode_on 2>/dev/null)"
if [ "$AIRPLANE" = "1" ]; then
	log "[i] Режим полёта уже включён — не трогаю радио."
else
	log "[*] Перезапуск радио через режим полёта..."
	if cmd connectivity airplane-mode enable >/dev/null 2>&1; then
		sleep 4
		cmd connectivity airplane-mode disable >/dev/null 2>&1 \
			|| log "[WARN] Не удалось выключить режим полёта — выключи вручную!"
	else
		log "[WARN] cmd connectivity недоступен — пропуск (перезагрузка сделает то же самое)"
	fi
fi

# ==========================================
# ИТОГ
# ==========================================

log ""
if [ "$PROP_FAIL" -ne 0 ]; then
	log "[!] Часть свойств не установилась — смотри лог."
fi
log "[*] Готово. Бэкап: $BACKUP"
log "[*] Откат: su -c sh $0 restore"
log ""
log "[i] После перезагрузки проверь:"
log "    Настройки → Сеть и интернет → SIM-карты → <SIM>:"
log "      «Звонки по VoLTE», «Звонки по Wi-Fi», «Видеозвонки», номер телефона."
log "    И регистрацию IMS: *#*#4636#*#* → «Информация о телефоне»."

if [ "$REBOOT_MODE" = "yes" ] || { [ "$REBOOT_MODE" = "ask" ] && ask_yes_no "Перезагрузить сейчас (нужно для применения)?"; }; then
	log "[*] Перезагрузка..."
	reboot
fi

[ "$PROP_FAIL" -eq 0 ] && exit 0
exit 1
