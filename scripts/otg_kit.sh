#!/data/user/0/bin.mt.plus/files/term/bin/bash

# ================================================
# OTG RESCUE TOOLKIT - version shown on script
# Target: POCO devices (Snapdragon SoC) & Google Pixel (Tensor SoC)
# Environment: bash binary in MT Manager (Root Required)
# ================================================

# --- [ КОНФИГУРАЦИЯ И ЦВЕТА ] ---
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- [ ОПРЕДЕЛЕНИЕ ВЕРСИИ И ДАТЫ СБОРКИ ] ---
readonly MAJOR=1
readonly MINOR=5
readonly PATCH=0
readonly CHANNEL="dev"
readonly VERSION="${MAJOR}.${MINOR}.${PATCH}-${CHANNEL}"
readonly BUILD_DATE="${BUILD_DATE:-$(date +%d.%m.%Y)}"
readonly BUILD_ID="${BUILD_ID:-$(date +%Y%m%d%H%M)}"

# --- [ ОБРАБОТКА ОШИБОК ] ---
set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo -e "\n${RED}${BOLD}[FATAL]${NC} Строка ${YELLOW}${LINENO}${NC} | Команда: ${CYAN}${BASH_COMMAND}${NC}" >&2; exit 1' ERR

# --- [ ОБРАБОТКА ПРЕРЫВАНИЙ ] ---
trap 'echo -e "\n${YELLOW}Выход из OTG Rescue ToolKit...${NC}"; exit 0' INT TERM

ADB_BIN="adb"
FB_BIN="fastboot"
WORKDIR="/sdcard/OTG_ToolKit" # Папка для образов, создаётся автоматически

# --- [ СИСТЕМНЫЕ ПРОВЕРКИ ] ---

# Проверка на ROOT (скрипт должен иметь доступ к USB шине без ограничений)
check_root() {
	if [ "$EUID" -ne 0 ]; then
		echo -e "${RED}[!] ОШИБКА: Запустите скрипт от имени ROOT (sudo/tsu)${NC}"
		echo -e "Это необходимо для прямого доступа к USB-устройствам в режиме OTG"
		exit 1
	fi
}

# Проверка наличия бинарников
check_bins() {
	if ! command -v "$ADB_BIN" &> /dev/null || ! command -v "$FB_BIN" &> /dev/null; then
		echo -e "${RED}[!] ОШИБКА: adb или fastboot не найдены${NC}"
		echo -e "Выполните в Termux: ${YELLOW}pkg install android-tools${NC}"
		echo -e "Или установите их вручную в директорию: ${YELLOW}/data/user/0/bin.mt.plus/files/term/bin/bash${NC}"
		exit 1
	fi
	# Создаем рабочую директорию, если нет
	mkdir -p "$WORKDIR"

	# Проверяем, есть ли доступ к папке
	if [[ ! -w "$WORKDIR" ]]; then
		echo -e "${RED}[!] Нет прав на запись в $WORKDIR${NC}"
		echo -e "Попробуйте другую папку (например, /data/local/tmp/)"
		exit 1
	fi
}

# --- [ ОПРЕДЕЛЕНИЕ СОСТОЯНИЯ ] ---

# Глобальные переменные состояния
DEVICE_STATE="DISCONNECTED"
DEVICE_ID="N/A"
DEVICE_MODEL="Unknown"

refresh_status() {
	# Сброс
	DEVICE_STATE="DISCONNECTED"
	DEVICE_ID="N/A"
	DEVICE_MODEL="Unknown"

	# 1. Проверка ADB
	local adb_check
	adb_check=$("$ADB_BIN" devices 2>/dev/null | awk 'NR>1 && NF' || true)
	if [[ -n "${adb_check:-}" ]]; then
		DEVICE_ID=$(echo "$adb_check" | awk '{print $1}')
		local state=$(echo "$adb_check" | awk '{print $2}')

		if [[ "$state" == "device" ]]; then
			DEVICE_STATE="ADB_SYSTEM"
			# Пытаемся узнать модель
			DEVICE_MODEL=$("$ADB_BIN" -s "$DEVICE_ID" shell getprop ro.product.model 2>/dev/null)
		elif [[ "$state" == "recovery" ]]; then
			DEVICE_STATE="ADB_RECOVERY"
			# В TWRP это сработает, в Stock - нет
			DEVICE_MODEL=$("$ADB_BIN" -s "$DEVICE_ID" shell getprop ro.product.model 2>/dev/null)
		elif [[ "$state" == "sideload" ]]; then
			DEVICE_STATE="ADB_SIDELOAD"
		elif [[ "$state" == "unauthorized" ]]; then
			DEVICE_STATE="UNAUTHORIZED"
		fi
		return
	fi

	# 2. Проверка Fastboot
	local fb_check
	fb_check=$("$FB_BIN" devices 2>/dev/null | awk 'NF')
	if [[ -n "${fb_check:-}" ]]; then
		DEVICE_ID=$(echo "$fb_check" | awk '{print $1}')
		DEVICE_STATE="FASTBOOT"
		# Пробуем узнать product (для Pixel/Xiaomi сработает)
		local product
		product=$("$FB_BIN" -s "$DEVICE_ID" getvar product 2>&1 | awk -F ': ' '/product:/ {print $2}')
		if [[ -n "${product:-}" ]]; then
			DEVICE_MODEL="$product"
		fi
		return
	fi
}

# Отображение предупреждения в зависимости от модели устройства
show_device_warning() {
    detect_manufacturer

    case "$DEVICE_TYPE" in
        xiaomi)
            show_warning_xiaomi
            ;;
        pixel)
            show_warning_pixel
            ;;
        samsung)
            show_warning_samsung
            ;;
        *|unknown)
            echo "Обнаружено неизвестное устройство"
            echo "Все приведённые ниже действия будут проводиться на ваш страх и риск."
            confirm_continue
            ;;
    esac
}

# Отдельная функция подтверждения операции через 'YES'
confirm_continue() {
    echo
    read -p "Введите YES для продолжения: " CONFIRM

    if [[ "$CONFIRM" != "YES" ]]; then
        echo "Операция отменена..."
        exit 1
    fi
}

detect_manufacturer() {

    # Проверка наличия ADB
    if ! command -v "$ADB_BIN" >/dev/null 2>&1; then
        echo "ADB not found."
        exit 1
    fi

    # Проверка подключения устройства
    DEVICE_STATE=$("$ADB_BIN" get-state 2>/dev/null)

    if [[ "$DEVICE_STATE" != "device" ]]; then
        echo "No authorized ADB device detected."
        echo "Ensure USB debugging is enabled and device is authorized."
        exit 1
    fi

    # Получение пропертей
    MANUFACTURER=$("$ADB_BIN" shell getprop ro.product.manufacturer 2>/dev/null | tr -d '\r')
    BRAND=$("$ADB_BIN" shell getprop ro.product.brand 2>/dev/null | tr -d '\r')
    VENDOR=$("$ADB_BIN" shell getprop ro.product.vendor.manufacturer 2>/dev/null | tr -d '\r')

    # Проверка, что данные вообще получены
    if [[ -z "$MANUFACTURER" && -z "$BRAND" && -z "$VENDOR" ]]; then
        echo "Failed to retrieve device properties."
        echo "Device may not be fully booted or ADB is unstable."
        exit 1
    fi

    COMBINED="$(echo "$MANUFACTURER $BRAND $VENDOR" | tr '[:upper:]' '[:lower:]')"

    if [[ "$COMBINED" == *"xiaomi"* ]] || \
       [[ "$COMBINED" == *"redmi"* ]] || \
       [[ "$COMBINED" == *"poco"* ]]; then
        DEVICE_TYPE="xiaomi"

    elif [[ "$COMBINED" == *"google"* ]]; then
        DEVICE_TYPE="pixel"

    elif [[ "$COMBINED" == *"samsung"* ]]; then
        DEVICE_TYPE="samsung"

    else
        DEVICE_TYPE="unknown"
    fi
}

# Предупреждение для семейства устройств Xiaomi
show_warning_xiaomi() {
    clear
    echo "=========================================="
    echo "XIAOMI / REDMI / POCO DEVICE DETECTED"
    echo "=========================================="
    echo
    echo "ВАЖНО:"
    echo
    echo "1. Устройство должно иметь разблокированный загрузчик."
    echo "2. Никогда НЕ блокируйте загрузчик на кастомной прошивке."
    echo "3. Проверьте Anti-Rollback (ARB) перед понижением firmware."
    echo "4. Не прошивайте более старый firmware (tz, abl, xbl и т.п.)."
    echo "5. Не используйте 'clean all and lock' в MiFlash."
    echo
    echo "Нарушение этих правил может привести к EDL (9008) состоянию."
    echo
    confirm_continue
}

# Предупреждение для Google Pixel
show_warning_pixel() {
    clear
    echo "=========================================="
    echo "GOOGLE PIXEL DEVICE DETECTED"
    echo "=========================================="
    echo
    echo "ВАЖНО:"
    echo
    echo "1. Pixel использует AVB 2.0 и Rollback Index."
    echo "2. Даунгрейд может быть невозможен даже на разблокированом загрузчике."
    echo "3. Никогда не блокируйте загрузчик на несовместимой прошивке."
    echo "4. Используйте только официальные factory images."
    echo "5. Команда fastboot flash может завершиться успешно, но система не загрузится из-за rollback protection."
    echo
    confirm_continue
}

# Предупреждение для Samsung
show_warning_samsung() {
    clear
    echo "=========================================="
    echo "SAMSUNG DEVICE DETECTED"
    echo "=========================================="
    echo
    echo "ВАЖНО:"
    echo
    echo "1. Samsung НЕ использует Fastboot."
    echo "2. Для прошивки используется Download Mode (Odin/Heimdall)."
    echo "3. Неправильный CSC может вызвать bootloop (цикличная перезагрузка устройства)."
    echo "4. Версия загрузчика (BL) не может быть понижена."
    echo "5. Никогда не блокируйте загрузчик на модифицированной системе."
    echo
    confirm_continue
}

# --- [ AFE: Anti Flash & Erase ] ---

readonly AFE_BLACKLIST=(
	# Boot chain
	"abl"
	"xbl"
	"xbl_config"
	"pbl"
	"bl1"
	"bl2"
	"bl31"
	"tz"
	"tzsw"
	"hyp"
	"aop"
	"devcfg"
	"cdt"
	"ddr"
	"qupfw"
	"dram_train"
	"ldfw"
	"pvmfw"
	"dpm"

	# Security
	"gsa"
	"fips"
	"keymaster"
	"keystore"
	"secdata"
	"ssd"
	"storsec"
	"mdtp"
	"mdtpsecapp"

	# Radio / Calibration
	"modem"
	"modemst1"
	"modemst2"
	"modem_userdata"
	"fsg"
	"fsc"
	"efs"
	"efs_backup"

	# Device-unique
	"persist"
	"devinfo"
)

afe_guard() {
	local operation="$1"	# flash / erase
	local target="$2"

	# Убираем суффиксы слота
	target="${target%_a}"
	target="${target%_b}"

	# Специальная защита для super
	if [[ "$target" == "super" && "$operation" == "erase" ]]; then
		echo -e "${RED}${BOLD} [AFE BLOCKED] ${NC}"
		echo -e "${RED}Запрещено стирание раздела: ${YELLOW}super${NC}"
		echo -e "${RED}Это приведёт к soft-brick (перестанет загружатся fastbootd)${NC}"
		pause
		return 1
	fi

	# Общий blacklist
	for blocked in "${AFE_BLACKLIST[@]}"; do
		if [[ "$target" == "$blocked" ]]; then
			echo -e "${RED}${BOLD} [AFE BLOCKED] ${NC}"
			echo -e "${RED}Попытка $operation критического раздела: ${YELLOW}$target${NC}"
			echo -e "${RED}Операция запрещена во избежание hard-brick${NC}"
			pause
			return 1
		fi
	done
	return 0
}

# --- [ ФУНКЦИИ: ADB БЛОК ] ---

adb_reboot_bootloader() {
	echo -e "${YELLOW}>>> Перезагрузка в Bootloader...${NC}"
	"$ADB_BIN" reboot bootloader || true
	pause
}

adb_reboot_recovery() {
	echo -e "${YELLOW}>>> Перезагрузка в Recovery...${NC}"
	"$ADB_BIN" reboot recovery || true
	pause
}

adb_reboot_fastbootd() {
	echo -e "${YELLOW}>>> Перезагрузка в Userspace Fastboot (FastbootD)...${NC}"
	"$ADB_BIN" reboot fastboot || true
	pause
}

adb_sideload_zip() {
	echo
	echo -e "${CYAN}--- ADB SIDELOAD WIZARD ---${NC}"
	echo -e "Положите прошивку (.zip) в папку: ${BOLD}$WORKDIR${NC}"
	echo -e "Список доступных файлов:"
	local zips=("$WORKDIR"/*.zip)

	if [[ -e "${zips[0]}" ]]; then
		printf '%s\n' "${zips[@]}"
	else
		echo
		echo -e "[!] В $WORKDIR ничего не найдено."
		pause && return
	fi

	echo
	read -p "Введите имя файла (например, update.zip): " filename
	
	if [[ -z "${filename:-}" ]]; then
		echo -e "${RED}[!] Имя файла не указано.${NC}"
		pause && return
	fi
	
	local filesize=$(wc -c < "$WORKDIR/$filename" 2>/dev/null | tr -d ' ')
	if [[ -z "$filesize" ]]; then
		filesize=0
	fi

	if [[ -f "$WORKDIR/$filename" ]]; then
		echo -e "${YELLOW}>>> Начинаю прошивку файла $filename...${NC}"
		echo -e "${RED}НЕ ОТКЛЮЧАЙТЕ КАБЕЛЬ!${NC}"
		"$ADB_BIN" sideload "$WORKDIR/$filename" || true
	else
		echo -e "${RED}[!] Файл не найден!${NC}"
	fi
	pause
}

adb_remove_magisk_modules() {
	echo
	echo -e "${CYAN}--- УДАЛЕНИЕ МОДУЛЕЙ MAGISK (TWRP) ---${NC}"
	echo -e "Работает только если доступен Shell и расширенное Recovery"

	echo -e "Список модулей:"
	if ! "$ADB_BIN" shell ls /data/adb/modules >/dev/null 2>&1; then
		echo -e "${RED}[!] Не удалось получить доступ к /data. Раздел зашифрован или это Stock Recovery${NC}"
	else
		read -p "Введите название папки модуля для удаления (или all для всех): " mod_name
		if [[ "$mod_name" == "all" ]]; then
			"$ADB_BIN" shell rm -rf /data/adb/modules/*
			echo -e "${GREEN}Все модули удалены${NC}"
		else
			"$ADB_BIN" shell rm -rf "/data/adb/modules/$mod_name" || true
			echo -e "${GREEN}Попытка удаления $mod_name завершена${NC}"
		fi
	fi
	pause
}

adb_logcat_brief() {
	echo
	echo -e "${CYAN}--- LOGCAT (Error Only) ---${NC}"
	"$ADB_BIN" logcat *:E -d | tail -n 50 || true
	pause
}

adb_dump_partition() {
	echo
	echo -e "${CYAN}--- ADB PARTITION DUMPER ---${NC}"
	read -p "Введите имя раздела (например, boot): " part
	read -p "Введите активный слот (a / b): " slot
	
	# Валидация слота
	if [[ "$slot" != "a" && "$slot" != "b" ]]; then
		echo -e "${RED}[!] Неверный слот. Допустимо: a или b${NC}"
		pause && return
	fi

	local final_part="${part}_${slot}"
	local part_path="/dev/block/by-name/$final_part"
	local local_file="$WORKDIR/${final_part}_dump.img"

	echo -e "${BLUE}[*] Используется раздел: ${YELLOW}$final_part${NC}"
	echo -e "${YELLOW}>>> Анализ раздела на целевом устройстве...${NC}"

	# Используем временную переменную, чтобы не сломать pipefail
	local raw_size
	# Добавляем "|| true", чтобы скрипт не падал, если команда вернула ошибку
	raw_size=$("$ADB_BIN" shell "su -c 'blockdev --getsize64 $part_path'" 2>/dev/null | tr -d '\r\n' || true)

	if [[ -z "$raw_size" ]]; then
		echo -e "${RED}[!] ОШИБКА: Не удалось получить размер раздела${NC}"
		echo -e "${YELLOW}[?] Проверьте: подключен ли кабель, разблокирован ли экран и выдан ли ROOT на TARGET-устройстве${NC}"
		pause && return
	fi

	# Убедимся, что в переменной только цифры (очистка от мусора терминала)
	local target_size=$(echo "$raw_size" | grep -oE '[0-9]+' | head -n 1)

	echo -e "${BLUE}[*] Размер раздела: $target_size байт${NC}"

	# 2. Снимаем дамп. Используем su -c cat для чистого бинарного потока
	"$ADB_BIN" shell "su -c cat $part_path" > "$local_file" || true

	# 3. Проверка результата на Host
	local host_size=$(wc -c < "$local_file" | tr -d ' ')

	echo -e "${BLUE}[*] Получено: $host_size байт${NC}"

	if [[ "$target_size" -eq "$host_size" ]]; then
		echo -e "${GREEN}[+] УСПЕХ: Размеры совпадают байт в байт!${NC}"

		# Дополнительная проверка MD5 (опционально, если нужна 100% уверенность)
		echo -e "${YELLOW}>>> Сверка хэш-сумм (MD5)...${NC}"
		local target_md5=$("$ADB_BIN" shell "su -c md5sum $part_path" | awk '{print $1}' | tr -d '\r\n')
		local host_md5=$(md5sum "$local_file" | awk '{print $1}')

		if [[ "$target_md5" == "$host_md5" ]]; then
			echo -e "${GREEN}[+] Хэш совпадает: $host_md5${NC}"
		else
			echo -e "${RED}[!] ВНИМАНИЕ: Хэш не совпал! Образ поврежден${NC}"
			rm "$local_file"
		fi
	else
		echo -e "${RED}[!] ОШИБКА: Размер образа ($host_size) отличается от оригинала ($target_size)${NC}"
		echo -e "${YELLOW}Совет: Попробуйте сменить OTG кабель${NC}"
		rm "$local_file"
	fi
	pause
}

adb_reboot_download_mode() {
	echo -e "${YELLOW}>>> Перезагрузка в Download Mode...${NC}"
	"$ADB_BIN" reboot download || true
	pause
}

# --- [ ФУНКЦИИ: FASTBOOT БЛОК ] ---

fb_reboot_recovery() {
	echo -e "${YELLOW}>>> Перезагрузка в Recovery...${NC}"
	"$FB_BIN" reboot recovery || true
	pause
}

fb_reboot_fastbootd() {
	echo -e "${YELLOW}>>> Перезагрузка в Userspace Fastboot (FastbootD)...${NC}"
	"$FB_BIN" reboot fastboot || true
	pause
}

fb_get_info() {
	echo
	echo -e "${CYAN}--- ИНФОРМАЦИЯ ОБ УСТРОЙСТВЕ ---${NC}"
	"$FB_BIN" getvar all 2>&1 | grep -E "(product|slot|secure|unlocked|version)" || true
	pause
}

fb_switch_slot() {
	echo
	echo -e "${CYAN}--- ПЕРЕКЛЮЧЕНИЕ A/B СЛОТОВ ---${NC}"
	local current
	current=$("$FB_BIN" getvar current-slot 2>&1 | awk -F ': ' '/current-slot/ {print $2}' || true)
	echo -e "Текущий слот: ${BOLD}$current${NC}"

	if [[ "$current" == "a" ]]; then
		echo -e "Переключаем на слот ${BOLD}B${NC}..."
		"$FB_BIN" --set-active=b || true
	elif [[ "$current" == "b" ]]; then
		echo -e "Переключаем на слот ${BOLD}A${NC}..."
		"$FB_BIN" --set-active=a || true
	else
		echo -e "${RED}[!] Не удалось определить слот. Возможно, устройство A-only${NC}"
	fi
	pause
}

fb_flash_image() {
	echo
	echo -e "${CYAN}--- FASTBOOT FLASHER ---${NC}"
	echo -e "1. Boot (boot.img)"
	echo -e "2. Recovery (recovery.img)"
	echo -e "3. Vendor Boot (vendor_boot.img - Pixel 6+)"
	echo -e "4. Init Boot (init_boot.img - Pixel 7+)"
	echo -e "5. Ввести раздел вручную"

	read -p "Выберите раздел: " choice
	local partition=""

	case $choice in
		1) partition="boot" ;;
		2) partition="recovery" ;;
		3) partition="vendor_boot" ;;
		4) partition="init_boot" ;;
		5) read -p "Введите имя раздела: " partition ;;
		*) echo "Отмена..."; pause; return ;;
	esac

	echo -e "Файлы .img в $WORKDIR:"
	ls "$WORKDIR"/*.img 2>/dev/null || true

	read -p "Введите имя файла образа: " imgname

	if [[ -z "${imgname:-}" ]]; then
		echo "Имя образа не указано..."
		pause && return
	fi

	if [[ -f "$WORKDIR/$imgname" ]]; then
		echo -e "${YELLOW}>>> Прошивка $imgname в раздел $partition...${NC}"

	# Простая проверка на минимальный размер и признаки boot-образа
	local filesize
	filesize=$(wc -c < "$WORKDIR/$imgname" 2>/dev/null || echo 0)

	if [[ "$filesize" -lt 1024 ]]; then
		echo -e "${RED}[!] Файл слишком маленький (${filesize} байт). Это точно образ?${NC}"
		read -p "Продолжить? (yes/no): " confirm
		[[ "$confirm" != "yes" ]] && return
	fi

	# Проверка на наличие магической подписи Android bootimg (необязательно)
	if command -v file &> /dev/null; then
		if file "$WORKDIR/$imgname" | grep -q "Android bootimg"; then
			echo -e "${GREEN}[+] Образ опознан как Android bootimg${NC}"
		else
			echo -e "${YELLOW}[!] Не удалось опознать тип файла. Прошивка вслепую...${NC}"
		fi
	fi

		if ! afe_guard flash "$partition"; then
			return
		fi
		"$FB_BIN" flash "$partition" "$WORKDIR/$imgname" || true
	else
		echo -e "${RED}[!] Файл не найден!${NC}"
	fi
	pause
}

fb_bootloader_lock_menu() {
	echo
	echo -e "${CYAN}--- УПРАВЛЕНИЕ ЗАГРУЗЧИКОМ ---${NC}"
	echo -e "${RED}[!] ВНИМАНИЕ: Любое действие ниже приведет к Factory Reset (WIPE DATA)!${NC}"
	echo "1. Разблокировать (UNLOCK)"
	echo "2. Заблокировать (LOCK)"
	echo "3. Проверить статус CRITICAL (для некоторых Xiaomi/Pixel)"
	echo "0. Назад"

	read -p "Выбор: " bl_opt
	case $bl_opt in
		1)
			echo -e "${YELLOW}Попытка разблокировки...${NC}"
			# Для современных Pixel/Nexus
			"$FB_BIN" flashing unlock || "$FB_BIN" oem unlock || true
			;;
		2)
			echo -e "${RED}ВНИМАНИЕ: Убедитесь, что стоит СТОКОВАЯ прошивка!${NC}"
			read -p "Вы уверены? (yes/no): " confirm
			local unlocked=$(get_fb_var "unlocked")
			if [[ "$unlocked" == "yes" ]]; then
			    "$FB_BIN" flashing lock || true
			else
			    echo "Загрузчик уже заблокирован"
			fi
			;;
		3)
			echo -e "${YELLOW}Unlock Critical...${NC}"
			"$FB_BIN" flashing unlock_critical || true
			;;
		*) return ;;
	esac
	pause
}

fb_boot_temp_image() {
	echo
	echo -e "${CYAN}--- ВРЕМЕННАЯ ЗАГРУЗКА ОБРАЗА (Fastboot Boot) ---${NC}"
	echo -e "Эта команда загрузит образ в RAM без прошивки в память"
	echo -e "Идеально для тестирования ядер (blu_spark, N0-Kernel и т.п.)"
	echo

	echo -e "Файлы .img в $WORKDIR:"

	# Включаем nullglob чтобы шаблон *.img не выводился как строка, если файлов не окажется
	shopt -s nullglob

	local imgs=("$WORKDIR"/*.img)

	if (( ${#imgs[@]} == 0 )); then
		echo -e "${RED}[!] Файлы .img не найдены${NC}" && pause; return
	else
		local i=1
		for img in "${imgs[@]}"; do
			printf "[%d] %s\n" "$i" "$(basename "$img")"
			((i++))
		done
	fi

	shopt -u nullglob

	echo
	read -p "Введите имя файла образа: " imgname

	if [[ -f "$WORKDIR/$imgname" ]]; then
		echo -e "${YELLOW}>>> Загрузка $imgname...${NC}"
		echo -e "${RED}Устройство перезагрузится автоматически после загрузки образа${NC}"
		"$FB_BIN" boot "$WORKDIR/$imgname" || true
	else
		echo -e "${RED}[!] Файл не найден или его имя не указано!${NC}"
	fi
	pause
}

fb_flash_vbmeta_safe() {
	echo -e "${RED}>>> Прошивка vbmeta с отключением проверок...${NC}"

	if [[ ! -f "$WORKDIR/vbmeta.img" ]]; then
		echo -e "${RED}[!] vbmeta.img не найден в $WORKDIR${NC}"
		pause && return
	fi

	"$FB_BIN" flash --disable-verity --disable-verification vbmeta "$WORKDIR/vbmeta.img" || true
	pause
}

# Специальный режим для Google Pixel
fb_reboot_rescue() {
	local product=$(get_fb_var "product")
	if [[ "$product" =~ ^(oriole|raven|bluejay|panther|cheetah|lynx|shiba|husky|akita|tokay|caiman|komodo|tegu)$ ]]; then
		echo -e "${YELLOW}>>> Перезагрузка в Rescue Mode (Google Pixel Exclusive)...${NC}"
		"$FB_BIN" reboot rescue || true
	else
		echo -e "${RED}[!] Этот режим официально поддерживается только на устройствах Google Pixel${NC}"
		read -p "Ваше устройство определено как $DEVICE_MODEL. Всё равно попробовать? (yes/no): " force
		if [[ "$force" == "yes" ]]; then
			"$FB_BIN" reboot rescue || true
		fi
	fi
	pause
}

# --- [ ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ] ---

pause() {
	echo -e "${NC}"
	read -n 1 -s -r -p "Нажмите любую клавишу для возврата в меню..."
}

# Функция для получения конкретной переменной без лишнего мусора
get_fb_var() {
	local key="$1"
	"$FB_BIN" getvar "$key" 2>&1 | \
		awk -F ': ' -v k="$key" '$1 ~ k {print $2; exit}' || true
}

header() {
	clear
	local display_model="${DEVICE_MODEL:-Unknown Device}"

	# Определяем тип устройства по модели
	local device_family=""
	if [[ "$display_model" == *"Pixel"* || "$display_model" == *"oriole"* ]]; then
		device_family="Tensor"
	elif [[ "$display_model" == *"POCO"* || "$display_model" == *"alioth"* ]]; then
		device_family="Snapdragon"
	fi

	# Заголовок
	echo -e "${BLUE}=================================================${NC}"
	echo -e "${BOLD}          OTG RESCUE TOOLKIT v${VERSION}         ${NC}"
	echo -e "${BOLD}          Build Date: ${NC}${BUILD_DATE}              "
	echo -e "${BOLD}          Build ID:   ${NC}${BUILD_ID}                "
	echo -e "${BOLD}          Target:     ${GREEN}${display_model}        "
	echo -e "${BLUE}=================================================${NC}"

	case "$DEVICE_STATE" in
		"FASTBOOT")
			# Вызываем переменные ТОЛЬКО если мы в фастбуте
			local lock_status=$(get_fb_var "unlocked")
			local current_slot=$(get_fb_var "current-slot")
			local b_ver
			b_ver=$(get_fb_var "version-bootloader" || true)

			local lock_msg="${RED}LOCKED${NC}"
			[[ "$lock_status" == "yes" ]] && lock_msg="${GREEN}UNLOCKED${NC}"

			echo -e " Статус:  ${CYAN}FASTBOOT${NC} | Slot: ${YELLOW}${current_slot:-N/A}${NC}"
			echo -e " Bootloader: $lock_msg | BL Ver: ${YELLOW}${b_ver:-N/A}${NC}"
			;;
		"ADB_SYSTEM")
			echo -e " Статус:  ${GREEN}SYSTEM (ADB)${NC}"
			echo -e " ID:      $DEVICE_ID"
			;;
		"ADB_RECOVERY")
			echo -e " Статус:  ${YELLOW}RECOVERY (ADB)${NC}"
			echo -e " Model:   $DEVICE_MODEL"
			;;
		"ADB_SIDELOAD")
			echo -e " Статус:  ${YELLOW}SIDELOAD MODE${NC}"
			;;
		"UNAUTHORIZED")
			echo -e " Статус:  ${RED}UNAUTHORIZED${NC}"
			echo -e " [!] Подтвердите доступ на экране телефона"
			;;
		"DISCONNECTED")
			echo -e " Статус:  ${RED}DISCONNECTED${NC}"
			echo -e " Ожидание подключения по OTG..."
			;;
	esac

	if [[ -n "$device_family" ]]; then
		echo -e " Chipset: ${CYAN}${device_family}${NC}"
	fi

	echo -e "${BLUE}-------------------------------------------------${NC}"
}

# --- [ ГЛАВНЫЙ ЦИКЛ (MAIN LOOP) ] ---

check_root
check_bins

# Сбрасываем ADB-сервер, чтобы не вис на мёртвых устройствах
echo -e "${BLUE}[*] Сброс ADB-сервера...${NC}"
"$ADB_BIN" kill-server >/dev/null 2>&1 || true
"$ADB_BIN" start-server >/dev/null 2>&1 || true
sleep 1
echo # Пустая строка для читаемости

while true; do
	refresh_status
	header

	# Динамическое меню на основе состояния
	if [[ "$DEVICE_STATE" == "FASTBOOT" ]]; then
		echo -e "${BOLD}--- [ РЕЖИМ: FASTBOOT ] ---${NC}"
		echo -e "\n${CYAN}Управление прошивкой:${NC}"
		echo " 1. Информация об устройстве [getvar all]"
		echo " 2. Переключить A/B слот [Активный: $(get_fb_var current-slot)]"
		echo " 3. Прошить образ [boot / recovery / init_boot]"
		echo " 4. Прошить vbmeta [Disable Verity / Verification]"
		echo " 5. Загрузить временный образ [fastboot boot]"
		echo -e "\n${YELLOW}Перезагрузка:${NC}"
		echo " 6. В FastbootD [Для прошивки разделов внутри super.img]"
		echo " 7. В Recovery [Меню восстановления / TWRP / OrangeFox]"
		echo " 8. В Rescue Mode [Только для Pixel: восстановление OTA]"
		echo " 9. В систему [Обычная перезагрузка]"
		echo -e "\n${RED}Опасные операции:${NC}"
		echo "10. Format Data [Полная очистка: userdata + metadata]"
		echo "11. Erase FRP [Сброс Factory Reset Protection]"
		echo "12. Управление загрузчиком [Lock / Unlock]"
		echo -e "${BLUE}-------------------------------------------------${NC}"
		echo " 0. Выход"
		read -p "Выбор: " opt
		case $opt in
			1) fb_get_info ;;
			2) fb_switch_slot ;;
			3) fb_flash_image ;;
			4) fb_flash_vbmeta_safe ;;
			5) fb_boot_temp_image ;;
			6) fb_reboot_fastbootd ;;
			7) fb_reboot_recovery ;;
			8) fb_reboot_rescue ;;
			9) "$FB_BIN" reboot || true ;;
			10)
			echo -e "${RED}⚠ ВНИМАНИЕ: Все данные будут удалены!${NC}"
			read -p "Введите 'yes' для подтверждения: " confirm

			if [ "$confirm" == "yes" ]; then
				for p in userdata metadata; do
					if afe_guard erase "$p"; then
						"$FB_BIN" erase "$p" || true
					fi
				done
			fi ;;
			11)
            local unlocked
            unlocked=$(get_fb_var "unlocked")

            if [[ "$unlocked" != "yes" ]]; then
                echo -e "${RED}Bootloader заблокирован. Операция невозможна.${NC}"
                pause
                continue
            else
                echo -e "${RED}⚠ ВНИМАНИЕ: Будет очищен раздел FRP.${NC}"
                echo -e "${YELLOW}Это сбросит защиту Factory Reset Protection.${NC}"
                read -p "Введите 'ERASE_FRP' для подтверждения: " confirm

                if [[ "$confirm" == "ERASE_FRP" ]]; then
                    if afe_guard erase "frp"; then
                "$FB_BIN" erase frp || true
                        echo -e "${GREEN}FRP раздел очищен.${NC}"
                    fi
                fi
            fi ;;
			12) fb_bootloader_lock_menu ;;
			0) exit 0 ;;
			*) ;;
		esac

	elif [[ "$DEVICE_STATE" == "ADB_RECOVERY" || "$DEVICE_STATE" == "ADB_SYSTEM" ]]; then
		echo -e "${BOLD}--- [ РЕЖИМ: ADB TOOLS ] ---${NC}"
		echo -e "\n${YELLOW}Перезагрузка:${NC}"
		echo " 1.  В Bootloader [Режим Fastboot]"
		echo " 2.  В Recovery [Меню восстановления / TWRP / OrangeFox]"
		echo " 3.  В FastbootD [Для прошивки разделов внутри super.img]"
		echo " 4.  В Download Mode [Samsung / Odin]"
		echo " 5.  В систему [Обычная перезагрузка]"
		echo -e "\n${CYAN}Инструменты:${NC}"
		echo " 6.  Обновить статус [Для режима sideload]"
		echo " 7.  Удалить модули Magisk [Необходим TWRP / OrangeFox]"
		echo " 8.  Снять дамп раздела [Активный слот: $(getprop ro.boot.slot_suffix)]"
		echo " 9.  Просмотр логов [Logcat: поиск ошибок]"
		echo " 10. ADB Shell [Консольный доступ к устройству]"
		echo -e "${BLUE}-------------------------------------------------${NC}"
		echo " 0. Выход"
		read -p "Выбор: " opt
		case $opt in
			1) adb_reboot_bootloader ;;
			2) adb_reboot_recovery ;;
			3) adb_reboot_fastbootd ;;
			4) adb_reboot_download_mode ;;
			5) "$ADB_BIN" reboot || true ;;
			6) pause; refresh_status;;
			7) adb_remove_magisk_modules ;;
			8) adb_dump_partition ;;
			9) adb_logcat_brief ;;
			10) "$ADB_BIN" shell || true; pause ;;
			0) exit 0 ;;
		esac

	elif [[ "$DEVICE_STATE" == "ADB_SIDELOAD" ]]; then
		echo -e "${BOLD}--- [ РЕЖИМ: ADB SIDELOAD ] ---${NC}"
		echo "1. Прошить ZIP-архив [Sideload / OTA обновление]"
		echo "2. Обновить статус [Для режима recovery]"
		echo -e "${BLUE}-------------------------------------------------${NC}"
		echo "0. Выход"
		read -p "Выбор: " opt
		case $opt in
			1) adb_sideload_zip ;;
			2) pause; refresh_status;;
			0) exit 0 ;;
		esac

	else
		# Устройство не подключено
		echo -e "${YELLOW}Ожидание подключения устройства...${NC}"
		echo "1. Обновить статус"
		echo "2. Перезапустить ADB сервер (Kill Server)"
		echo "0. Выход"

		# Читаем ввод с тайм-аутом 3 секунды
		if ! read -t 5 -p "Выбор (автообновление через 5с.): " opt; then
			opt="" && echo    # перенос строки после тайм-аута
		fi
		
		# Если время вышло, $opt будет пустым, и цикл просто начнется заново
		case $opt in
			1) sleep 0.5 ;; 
			2) "$ADB_BIN" kill-server || true; echo "Сервер перезапущен..."; sleep 1 ;;
			0) exit 0 ;;
			*) ;; # Пустой ввод или любой другой символ просто обновят экран
		esac
	fi
done
