#!/system/bin/sh

# Этот скрипт предоставляет интерактивный интерфейс командной строки (CLI)
# для выполнения общих административных задач на Android TV через ADB.

# --- 1. Проверка Наличия ADB ---
# Проверяем, доступна ли команда 'adb' в текущей среде (например, Termux).
if ! command -v adb >/dev/null 2>&1; then
	echo "Ошибка: ADB не найден. Установи adb с помощью pkg install android-tools или через модули Magisk."
	exit 1 # Выход с ошибкой, если ADB не найден.
fi

# --- 2. Подключение к Устройству ---
clear
echo
echo "---------------------------------------------"
echo "TV-TOOLS — УТИЛИТЫ ДЛЯ ANDROID TV"
echo "---------------------------------------------"
echo

echo "Введи IP телевизора (например, 192.168.0.50):"
read -p ">>> " tv_ip # Запрашиваем IP-адрес целевого устройства.

echo "Подключаюсь к IP $tv_ip..."
# Попытка установить ADB-соединение по Wi-Fi (должен быть включен режим отладки по сети).
adb connect "$tv_ip" >/dev/null 2>&1
# Проверка статуса выхода (exit status) последней команды.
if [ $? -eq 0 ]; then
	echo "Успешное подключение!"
else
	echo "Ошибка! Не удалось подключиться к $tv_ip"
	exit 1 # Выход в случае неудачного подключения.
fi

# --- 3. Главное Меню и Цикл Обработки Команд ---
while true; do
	echo
	echo "Выбери действие:"
	echo "0) — Информация об устройстве"
	echo "1) — Сделать скриншот"
	echo "2) — Записать экран (30 сек.)"
	echo "3) — Перезагрузить телевизор"
	echo "4) — Открыть проводник (MT Manager)"
	echo "5) — Выключить телевизор"
	echo "6) — Выйти из tv_tools"
	read -p ">>> " choice # Считывание выбора пользователя.

	case $choice in
		# --- 0: Информация об устройстве ---
		0)
			echo "Информация об устройстве:"
			echo
			echo "---------------------------"
			# Получение системных свойств с помощью `getprop`.
			# `tr -d '\r'` удаляет символы возврата каретки, которые adb shell
			# иногда добавляет к выводу, чтобы обеспечить чистый вывод.
			echo "Модель устройства: $(adb shell getprop ro.product.model | tr -d '\r')"
			echo "Версия Android: $(adb shell getprop ro.build.version.release | tr -d '\r')"
			echo "SDK: $(adb shell getprop ro.build.version.sdk | tr -d '\r')"
			echo "---------------------------"
			;;
		# --- 1: Скриншот ---
		1)
			# Генерация временной метки для уникального имени файла.
			timestamp=$(date +%d-%m-%Y_%H-%M-%S)
			path="/sdcard/Pictures/Screenshots/screenshot_$timestamp.png"
			echo "Создаётся скриншот..."
			# Выполнение команды `screencap` на удаленном устройстве и сохранение на его SD-карту.
			adb shell screencap -p "$path" >/dev/null 2>&1
			echo "Скриншот сохранён в $path"
			# Примечание: для получения файла на локальную машину нужно добавить команду 'adb pull'.
			;;
		# --- 2: Запись Экрана (Screenrecord) ---
		2)
			echo
			# Интерактивный ввод параметров для команды `screenrecord`.
			read -p "Укажи длительность записи (по умолчанию 30 сек): " duration
			[ -z "$duration" ] && duration=30 # Установка значения по умолчанию.

			read -p "Укажи битрейт (например, 4M) или нажми Enter (по умолчанию): " bitrate
			read -p "Укажи размер видео (например, 1280x720) или нажми Enter (по умолчанию): " size
			read -p "Укажи ориентацию (0=портрет, 90=альбомная) или нажми Enter (по умолчанию): " orientation

			timestamp=$(date +%d-%m-%Y_%H-%M-%S)
			path="/sdcard/Movies/recording_$timestamp.mp4"

			# Формирование базовой команды.
			cmd="screenrecord --time-limit $duration"
			# Добавление опциональных параметров, если они были указаны пользователем.
			[ -n "$bitrate" ] && cmd="$cmd --bit-rate $bitrate"
			[ -n "$size" ] && cmd="$cmd --size $size"
			[ -n "$orientation" ] && cmd="$cmd --orientation $orientation"
			# Добавление пути сохранения файла.
			cmd="$cmd $path"

			echo
			echo "Запуск записи с параметрами:"
			echo ">>> $cmd"
			# Запуск команды `screenrecord` на удаленном устройстве.
			adb shell "$cmd" >/dev/null 2>&1
			echo "Запись завершена. Файл сохранён в $path"
			;;
		# --- 3: Перезагрузка ---
		3)
			echo "Перезагрузка устройства..."
			# Команда `reboot` для стандартной перезагрузки.
			adb shell reboot >/dev/null 2>&1
			;;
		# --- 4: Открыть Проводник ---
		4)
			echo "Открываю MT Manager..."
			# Использование `am start` (Activity Manager) для запуска конкретной Activity
			# по имени пакета и класса (Package/Activity).
			adb shell am start -n bin.mt.plus/bin.mt.plus.MainLightIcon >/dev/null 2>&1
			;;
		# --- 5: Выключить Устройство ---
		5)
			echo "Окей. Android TV. Выключаю..."
			# Команда `reboot -p` (power off) для полного выключения устройства.
			adb shell reboot -p >/dev/null 2>&1
			# Отключение соединения.
			adb disconnect "$tv_ip" >/dev/null 2>&1
			exit 0 &>/dev/null 2>&1
			;;
		# --- 6: Выход ---
		6)
			echo "Отключаюсь от IP $tv_ip..."
			# Отключение соединения.
			adb disconnect "$tv_ip" >/dev/null 2>&1
			exit 0 &>/dev/null 2>&1
			break
			;;
		# --- Обработка Ошибочного Ввода ---
		*)
			clear
			echo "Ошибка! Неверный ввод, повтори попытку"
			;;
	esac
done
