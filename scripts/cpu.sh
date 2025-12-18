#!/system/bin/sh
# Улучшенный мониторинг CPU, GPU и батареи для Android (Termux/Shizuku-friendly)
# Скрипт предназначен для запуска в среде Android (например, Termux с root/ADB/Shizuku)
# и использует стандартные инструменты Android (dumpsys, /sys, /proc).

# --- Глобальные переменные для расчета загрузки CPU ---
# Ассоциативные массивы для хранения предыдущих значений активного и общего времени
# работы каждого ядра CPU (получены из /proc/stat).
declare -A PREV_ACTIVE PREV_TOTAL
# Инициализация массивов для 8 ядер (cpu0..cpu7).
for i in {0..7}; do
    # Устанавливаем начальные значения. PREV_TOTAL=1, чтобы избежать деления на ноль
    # при первом запуске, хотя разница (diff) в любом случае будет 0.
    PREV_ACTIVE[cpu$i]=0
    PREV_TOTAL[cpu$i]=1
done

# --- Функция: Получение Статистики Батареи ---
get_battery_stats() {
    # Получение полного дампа данных батареи, это основной источник информации.
    battery_data=$(dumpsys battery 2>/dev/null)

    # Использование awk для парсинга нужных полей из дампа.
    level=$(echo "$battery_data" | awk '/level/ {print $2}')
    health=$(echo "$battery_data" | awk '/health/ {print $2}')
    current=$(echo "$battery_data" | awk '/current now/ {print $3}')
    status=$(echo "$battery_data" | awk '/status/ {print $2}')
    temp=$(echo "$battery_data" | awk '/temperature/ {print $2}')

    # Преобразование числового кода состояния здоровья в понятный текст.
    case $health in
        2) health="Good" ;; 
        3) health="Overheat" ;; 
        4) health="Dead" ;;
        5) health="Over Voltage" ;; 
        6) health="Failure" ;; 
        7) health="Cold" ;;
        *) health="Unknown" ;;
    esac

    # Преобразование числового кода статуса зарядки в понятный текст.
    case $status in
        1) status="Discharging" ;; 
        2) status="Charging" ;; 
        3) status="Full" ;; 
        *) status="N/A" ;;
    esac

    # Конвертация тока (обычно в мкА) в мА и форматирование (используя 'bc' для плавающей точки).
    [ -n "$current" ] && current=$(echo "scale=1; $current / 1000" | bc)mA || current="N/A"
    # Конвертация температуры (обычно в десятых градуса Цельсия) в °C и форматирование.
    [ -n "$temp" ] && temp=$(echo "scale=1; $temp / 10" | bc)°C || temp="N/A"
    
    # Возвращаем все значения, разделенные символом '|'.
    echo "$level|$health|$current|$status|$temp"
}

# --- Функция: Получение Температуры из Thermal Zone ---
get_zone_temp() {
    path="$1" # Ожидается путь к thermal_zone (например, /sys/class/thermal/thermal_zone0)
    # Проверяем наличие файла 'temp' и считываем его.
    # Значение обычно в миллиградусах, поэтому делим на 1000.
    [ -f "$path/temp" ] && echo "$(($(cat "$path/temp") / 1000))°C" || echo "N/A"
}

# --- Основной Цикл Мониторинга ---
while true; do
    clear # Очистка консоли для "живого" обновления
    echo "===== Мониторинг CPU / GPU / батареи ====="
    echo

    # Вызов функции, чтение вывода и присвоение переменных с использованием IFS='|'.
    IFS='|' read -r level health current status temp <<< "$(get_battery_stats)"
    echo "======= Батарея ============"
    echo "Уровень заряда   : ${level}%"
    echo "Состояние        : ${health}"
    echo "Ток              : ${current}"
    echo "Статус           : ${status}"
    echo "Температура      : ${temp}"
    echo

    # Получение температур CPU и GPU из системных thermal_zone.
    # Номера зон могут отличаться на разных устройствах.
    cpu_temp=$(get_zone_temp /sys/class/thermal/thermal_zone0)
    gpu_temp=$(get_zone_temp /sys/class/thermal/thermal_zone10)
    echo "Температура CPU  : ${cpu_temp}"
    echo "Температура GPU  : ${gpu_temp}"
    echo

    echo "======= Загрузка CPU ========"
    total_load=0
    active_cores=0
    # Итерация по ядрам CPU (с 0 по 7).
    for i in {0..7}; do
        # --- Получение Частоты Ядра ---
        # Текущая частота ядра.
        freq=$(cat /sys/devices/system/cpu/cpu$i/cpufreq/scaling_cur_freq 2>/dev/null)
        # Максимальная частота ядра.
        max_freq=$(cat /sys/devices/system/cpu/cpu$i/cpufreq/cpuinfo_max_freq 2>/dev/null)
        
        # Конвертация частоты (обычно в кГц) в МГц.
        [ -n "$freq" ] && freq_mhz=$((freq / 1000)) || freq_mhz="off"
        [ -n "$max_freq" ] && max_mhz=$((max_freq / 1000)) || max_mhz="N/A"

        # --- Расчет Загрузки Ядра (Load) ---
        # Чтение статистики CPU из /proc/stat.
        # `< <(...)` используется для безопасного чтения статистики конкретного ядра.
        # Поля: user, nice, system, idle, iowait, irq, softirq, steal.
        if read -r cpu user nice system idle iowait irq softirq steal _ < <(grep "^cpu$i " /proc/stat); then
            # Общее время работы ядра.
            total=$((user + nice + system + idle + iowait + irq + softirq + steal))
            # Активное время работы (общее время минус простои и ожидание ввода/вывода).
            active=$((total - idle - iowait))
            
            # Разница между текущим и предыдущим общим/активным временем.
            diff_total=$((total - ${PREV_TOTAL[cpu$i]}))
            diff_active=$((active - ${PREV_ACTIVE[cpu$i]}))
            
            # Расчет загрузки ядра в процентах: (diff_active / diff_total) * 100.
            # Условный оператор для избежания деления на ноль.
            load=$(( diff_total > 0 ? 100 * diff_active / diff_total : 0 ))
            
            # Сохранение текущих значений для следующей итерации.
            PREV_ACTIVE[cpu$i]=$active
            PREV_TOTAL[cpu$i]=$total
        else
            load="N/A" # Ядро не найдено в /proc/stat
        fi

        # Суммирование загрузки и подсчет активных ядер для расчета среднего.
        [ "$load" != "N/A" ] && total_load=$((total_load + load)) && active_cores=$((active_cores + 1))
        # Вывод основной информации о ядре.
        printf "Ядро %d: %4s / %4s МГц | Загрузка: %3s%%" "$i" "$freq_mhz" "$max_mhz" "$load"

        # --- Получение Температуры Ядра (опционально) ---
        # Путь к температурному датчику конкретного ядра (может отличаться/отсутствовать).
        core_temp_path="/sys/devices/virtual/thermal/thermal_zone$i/temp"
        if [ -f "$core_temp_path" ]; then
            # Вывод температуры в °C.
            printf " | Темп: %s°C" "$(($(cat $core_temp_path)/1000))"
        fi
        echo
    done

    # Расчет средней загрузки CPU.
    [ "$active_cores" -gt 0 ] && avg_load=$((total_load / active_cores)) || avg_load=0
    echo
    echo "Средняя загрузка CPU : ${avg_load}%"
    echo

    # --- Проверка Троттлинга ---
    # Поиск по всем thermal_zone, чтобы найти те, которые имеют тип "throttl" (т.е. связанные с троттлингом).
    throttle_flag=$(grep -i "throttl" /sys/class/thermal/thermal_zone*/type 2>/dev/null | wc -l)
    if [ "$throttle_flag" -gt 0 ]; then
        echo "⚠️  Система обнаружила активный **тротлинг**!"
    else
        echo "✅  Тротлинг не обнаружен."
    fi

    echo
    echo "Обновление через 5 секунд... (Ctrl+C для выхода)"
    sleep 5 # Пауза перед следующей итерацией.
done
