#!/system/bin/sh

# Этот скрипт предназначен для автоматической установки .apk и .apks файлов
# из указанной исходной директории, используя команду 'pm install'.
# Он обрабатывает многофайловые пакеты .apks (Split APKs) при наличии поддержки
# 'install-multiple' в системе.
# Скрипт выполняется в среде Android (например, через adb shell).

# Логика поиска директории. Обязательна перед запуском основной части скрипта
echo "[?] Укажи директорию для поиска .apk / .apks файлов:"
printf "[»] " && read -r USER_DIR

# Пустой ввод — сразу ошибка
if [ -z "$USER_DIR" ]; then
	echo "[!] Директория не указана"
	exit 1
fi

# Проверка существования
if [ ! -d "$USER_DIR" ]; then
	echo "[!] Такой директории не существует: $USER_DIR"
	exit 1
fi

# --- Конфигурация Директорий ---
# Директория для сохранения логов неудачных установок.
# Использует скрытую папку на внутренней памяти.
LOG_DIR="/sdcard/.My Folder/logs"
# Исходная директория, откуда будут браться APK/APKS файлы.
SRC_DIR="${USER_DIR%/}"
# Временная директория для копирования файлов перед установкой.
# /data/local/tmp часто доступна для записи и предпочтительна для временных файлов.
TMP_DIR="/data/local/tmp"

# Создание директории для логов, если она не существует.
mkdir -p "$LOG_DIR"

# --- Проверка Поддержки 'install-multiple' ---
# Необходима для установки .apks файлов (Split APKs).
INSTALL_MULTIPLE_AVAILABLE=false
# Проверка наличия системной фичи 'install.multiple'.
if pm list features 2>/dev/null | grep -q "install.multiple"; then
	INSTALL_MULTIPLE_AVAILABLE=true
	echo "[+] Система поддерживает install-multiple"
else
	echo "[!] Система НЕ поддерживает install-multiple"
	echo "[!] Установка .apks файлов будет пропускаться"
fi

echo
echo "[*] Поиск .apk и .apks файлов в $SRC_DIR..."

# --- Подсчёт файлов ---
# Ищем все файлы с расширениями .apk и .apks в исходной директории.
# Ошибки (если файлов нет) перенаправляем в /dev/null, чтобы не мусорить в консоли.
APK_LIST=$(ls "$SRC_DIR"/*.apk "$SRC_DIR"/*.apks 2>/dev/null)

# Считаем количество строк в списке (количество файлов).
# tr -d ' ' убирает лишние пробелы, которые может выдать wc на некоторых системах.
APK_COUNT=$(echo "$APK_LIST" | wc -l | tr -d ' ')

# Проверяем, не пуст ли список. Если файлов нет, выводим предупреждение и выходим.
if [ "$APK_COUNT" -eq 0 ]; then
    echo "[!] Нет файлов .apk или .apks в $SRC_DIR"
    exit 1
fi

echo "[*] Найдено файлов: $APK_COUNT"

# Устанавливаем режим установки по умолчанию и инициализируем переменную для выбранных файлов.
INSTALL_MODE="all"
SELECTED_FILES=""

# Логика для случая, если найден всего ОДИН файл.
if [ "$APK_COUNT" -eq 1 ]; then
    echo "[?] Найден один файл. Установить? (y/n)"
    printf "[»] " && read -r confirm
    case "$confirm" in
        y|Y) INSTALL_MODE="single" ;; # Подтверждено: ставим один файл.
        *) echo "[!] Отменено пользователем."; exit 0 ;; # Отказ: завершаем работу.
    esac
else
    # Логика для нескольких файлов: выводим список с номерами для выбора.
    echo "[?] Найдено несколько файлов:"
    i=1
    for f in $APK_LIST; do
        # basename "$f" выводит только имя файла, отсекая полный путь.
        echo "  [$i] $(basename "$f")"
        i=$((i+1))
    done

    echo
    echo "[?] Установить все файлы? (y/n)"
    printf "[»] " && read -r confirm_all

    # Если пользователь хочет поставить всё сразу.
    if [ "$confirm_all" = "y" ] || [ "$confirm_all" = "Y" ]; then
        INSTALL_MODE="all"
    else
        # Режим выборочной установки.
        INSTALL_MODE="select"
        echo "[?] Введи номера файлов через пробел (например: 1 3 5):"
        printf "[»] " && read -r nums

        # Проходим циклом по введенным номерам.
        for n in $nums; do
            # Извлекаем n-ую строку из общего списка файлов и добавляем её в SELECTED_FILES.
            SELECTED_FILES="$SELECTED_FILES $(echo "$APK_LIST" | sed -n "${n}p")"
        done

        # Если в итоге список выбранных файлов пуст (например, ввели буквы вместо цифр).
        if [ -z "$SELECTED_FILES" ]; then
            echo "[!] Ничего не выбрано."
            exit 1
        fi
    fi
fi

found=false # Флаг для отслеживания, были ли найдены файлы

# --- Основной Цикл Обработки Файлов ---
# Итерация по всем .apk и .apks файлам в исходной директории.
if [ "$INSTALL_MODE" = "select" ]; then
    FILES="$SELECTED_FILES"
else
    FILES="$APK_LIST"
fi

for file in $FILES; do
	# Проверка, что файл существует. Важно для случая, когда шаблон не находит файлов.
	[ -f "$file" ] || continue
	found=true

	echo
	echo "[*] Обработка: $(basename "$file")"
	# Копирование файла во временную директорию.
	cp "$file" "$TMP_DIR/"
	# Проверка статуса выхода предыдущей команды (cp).
	if [ $? -eq 0 ]; then
		echo "[*] Копирование в $TMP_DIR..."
		# Извлечение только имени файла из полного пути.
		filename=$(basename "$file")
		echo "[*] Установка $filename..."

		# --- Логика Установки ---
		if [[ "$filename" == *.apks ]]; then
			# Обработка APKS-файлов (пакетов Split APKs)

			# Проверка поддержки 'install-multiple' перед началом обработки APKS.
			if ! $INSTALL_MULTIPLE_AVAILABLE; then
				echo "[!] Пропуск .apks: система не поддерживает install-multiple"
				rm "$TMP_DIR/$filename" # Удаление скопированного временного файла
				continue  # Переход к следуюущему файлу
			fi

			echo "[*] Распаковка .apks архива..."
			# Распаковка APKS-архива во временную поддиректорию.
			# -o: перезаписать существующие файлы без запроса.
			# >/dev/null 2>&1: подавление стандартного вывода и ошибок unzip.
			unzip -o "$TMP_DIR/$filename" -d "$TMP_DIR/apks_extract" >/dev/null 2>&1

			# Поиск всех .apk файлов внутри извлеченной директории.
			# tr '\n' ' ': замена символов новой строки на пробелы для передачи в pm install-multiple.
			apk_files=$(ls "$TMP_DIR/apks_extract"/*.apk 2>/dev/null | tr '\n' ' ')
			if [ -z "$apk_files" ]; then
				echo "[!] В архиве нет APK файлов!"
				continue
			fi

			# Выполнение установки с использованием install-multiple.
			# --staged: требуется для установки нескольких файлов, чтобы они применялись атомарно.
			output=$(pm install-multiple $apk_files 2>&1)
			# Очистка временной директории для извлеченных APK.
			rm -rf "$TMP_DIR/apks_extract"
		else
			# Обработка стандартных APK-файлов
			output=$(pm install "$TMP_DIR/$filename" 2>&1)
		fi

		# --- Проверка Результата Установки ---
		# Проверка вывода команды 'pm' на наличие строки "Success".
		if echo "$output" | grep -q "Success"; then
			echo "[+] Установка успешна: $filename"
			echo "[*] Удаление временного файла..."
			rm "$TMP_DIR/$filename" # Удаление временного файла
			echo "[*] Очистка исходного файла из $SRC_DIR..."
			rm "$file" # Удаление исходного файла
		else
			# --- Обработка Неудачной Установки ---
			echo "[!] Ошибка при установке: $filename"

			# Инициализация переменных для лога.
			reason="Неизвестная ошибка."
			advice="Проверь полный журнал установки."

			# Обработчик ошибок: анализ вывода 'pm' для определения причины.
			if echo "$output" | grep -q "INSTALL_FAILED_UPDATE_INCOMPATIBLE"; then
				reason="Подписи установленных и новых APK не совпадают."
				advice="Удали старое приложение перед установкой."
			elif echo "$output" | grep -q "INSTALL_FAILED_VERSION_DOWNGRADE"; then
				reason="Попытка установить более старую версию."
				advice="Удали старую версию или используй более новую."
			elif echo "$output" | grep -q "INSTALL_PARSE_FAILED_NO_CERTIFICATES"; then
				reason="APK внутри .apks не подписаны."
				advice="Подпиши пакет вручную через apksigner или скачай подписанную сборку."
			elif echo "$output" | grep -q "INSTALL_FAILED_INVALID_APK"; then
				reason="Повреждённый или некорректный APK."
				advice="Проверь файл или скачай заново."
			elif echo "$output" | grep -q "INSTALL_FAILED_INSUFFICIENT_STORAGE"; then
				reason="Недостаточно места на устройстве."
				advice="Очисти память или удали лишние приложения."
			elif echo "$output" | grep -q "INSTALL_FAILED_CPU_ABI_INCOMPATIBLE"; then
				reason="Несовместимая архитектура процессора."
				advice="Скачай подходящую версию."
			elif echo "$output" | grep -q "INSTALL_FAILED_PERMISSION_MODEL_DOWNGRADE"; then
				reason="Устаревшая модель разрешений."
				advice="Используй более новую версию приложения."
			elif echo "$output" | grep -q "INSTALL_FAILED_OLDER_SDK"; then
				reason="APK не поддерживает твою версию Android."
				advice="Найди совместимую версию."
			elif echo "$output" | grep -q "INSTALL_FAILED_MISSING_SHARED_LIBRARY"; then
				reason="Отсутствует нужная системная библиотека."
				advice="Установи недостающую или выбери другую сборку."
			elif echo "$output" | grep -q "INSTALL_FAILED_DUPLICATE_PACKAGE"; then
				reason="Уже установлено приложение с таким же именем пакета."
				advice="Удали конфликтующее приложение или измени пакет."
			elif echo "$output" | grep -q "INSTALL_FAILED_INVALID_URI" || echo "$output" | grep -q "Failed to parse when copying" || echo "$output" | grep -q "Permission denied" ; then
				# Эта ветка обрабатывает ошибки, которые могут возникнуть, если pm
				# пытается читать файл с /sdcard, хотя файл уже скопирован,
				# или указывает на общие проблемы с парсингом/доступом к файлу.
				reason="Ошибка парсинга или недопустимый путь/права доступа."
				advice="pm не может читать /sdcard напрямую, файл уже был скопирован — возможно, APK повреждён или несовместим."
			else
				reason="Установка завершилась с ошибкой."
				advice="Проверь журнал установки ниже."
			fi

			# Генерация уникального имени для файла лога.
			log_file="$LOG_DIR/$(date +"%d-%m-%Y_%H-%M-%S")_fail_$(basename "$file").log"
			# Запись информации об ошибке и полного вывода 'pm' в файл лога.
			{
				echo "•———————————————————•"
				echo "Ошибка при установке APK"
				echo
				echo " Файл   : $file"
				echo " Время  : $(date '+%d-%m-%Y %H:%M:%S')"
				echo " Причина: $reason"
				echo " Совет  : $advice"
				echo "•———————————————————•"
				echo
				echo "•———————————————————•"
				echo "Журнал установки:"
				echo "$output"
				echo "•———————————————————•"
			} > "$log_file"

			echo "[!] Лог сохранён: $log_file"
			rm "$TMP_DIR/$filename" # Удаление временного файла после неудачи
		fi
	else
		echo "[!] Ошибка копирования файла $file"
		# В случае ошибки копирования, временный файл не создается,
		# поэтому нет необходимости его удалять.
	fi
done

# --- Финальная Проверка и Завершение ---
# Проверка флага 'found', чтобы сообщить, если не было найдено ни одного файла.
if ! $found; then
	echo "[!] Нет файлов .apk или .apks в $SRC_DIR"
	exit 1
fi

echo
echo "[*] Завершено."
# Завершение работы скрипта. Вывод перенаправляется в никуда для чистоты.
exit 0 &>/dev/null 2>&1
