#!/system/bin/sh
#
# cpu.sh v2 — живой монитор CPU / GPU / батареи / троттлинга
# Автор: GoldenFrog
#
# Проверено по дампам датчиков:
#   - Google Pixel 8 Pro (husky, Tensor G3 / zuma)
#   - POCO F3 (alioth, Snapdragon 870 / kona)
# На других устройствах работает в «общем» режиме: датчики ищутся по
# стандартным именам, а то, что не найдено, просто не выводится.
#
# Запуск:  su -c sh cpu.sh [интервал_сек]     (по умолчанию 2)
#          su -c sh cpu.sh --once             (один снимок и выход)
#
# Что изменилось относительно v1:
#  - Работает в штатном /system/bin/sh (mksh): убраны bash-only конструкции
#    (declare -A, {0..7}, <<<, < <(...)) и зависимость от bc.
#  - Число ядер берётся из системы: на Tensor G3 их 9 (4+4+1), v1 видел 8
#    и не показывал самое мощное ядро Cortex-X3.
#  - Датчики ищутся по именам зон, а не по номерам thermal_zoneN
#    (номера меняются от прошивки к прошивке).
#  - Температура по кластерам, а не «ядро N = thermal_zoneN» (это была
#    случайная привязка без связи с реальными датчиками).
#  - Троттлинг определяется по cooling devices с cur_state > 0 и по
#    срезанному потолку частот, а не по наличию слова «throttl» в имени зоны.
#  - Pixel: температура корпуса VIRTUAL-SKIN и статус троттлинга из Thermal HAL.
#  - Батарея из sysfs: ток, напряжение, мощность, износ, циклы.
#    Исправлены коды статуса (3 — это «разряжается», а не «полностью заряжена»).
#  - Отбрасываются заведомо битые показания датчиков (-40, -273 °C, пусто).

R="${CPU_SH_SYSROOT:-}"   # корень sysfs/procfs; меняется только для тестов
SYSCPU="$R/sys/devices/system/cpu"
SYSTH="$R/sys/class/thermal"
SYSPS="$R/sys/class/power_supply"

INTERVAL=2
ONCE=0
case "${1:-}" in
	--once|-1) ONCE=1 ;;
	-h|--help) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	'') ;;
	*[!0-9]*) echo "Интервал должен быть числом секунд"; exit 1 ;;
	0) echo "Интервал должен быть больше 0"; exit 1 ;;
	*) INTERVAL="$1" ;;
esac

# ==========================================
# ВСПОМОГАТЕЛЬНОЕ
# ==========================================

rd() { cat "$1" 2>/dev/null; }

# Буфер экрана: копим вывод и печатаем одним куском — без мерцания
BUF=""
out() { BUF="$BUF$*
"; }

# Миллиградусы → "51.5°C". Пусто, если показание битое.
fmt_mdeg() {
	_t="$1"
	case "$_t" in ''|*[!0-9-]*) return 1 ;; esac
	# Датчики без значения отдают -40, -273 °C и подобное
	[ "$_t" -lt -30000 ] || [ "$_t" -gt 150000 ] && return 1
	if [ "$_t" -lt 0 ]; then
		_t=$(( -_t )); printf -- '-%d.%d°C' $(( _t / 1000 )) $(( _t % 1000 / 100 ))
	else
		printf '%d.%d°C' $(( _t / 1000 )) $(( _t % 1000 / 100 ))
	fi
}

# Строка "41.26607" из HAL → "41.2°C"
fmt_float_c() {
	_w="${1%%.*}"
	case "$1" in *.*) _f="${1#*.}"; _f="${_f%"${_f#?}"}" ;; *) _f=0 ;; esac
	printf '%s.%s°C' "$_w" "${_f:-0}"
}

# Самая горячая из нескольких зон (пути через пробел), в миллиградусах
max_mdeg() {
	_max=""
	for _z in $1; do
		_v=$(rd "$_z/temp")
		case "$_v" in ''|*[!0-9-]*) continue ;; esac
		[ "$_v" -lt -30000 ] || [ "$_v" -gt 150000 ] && continue
		if [ -z "$_max" ] || [ "$_v" -gt "$_max" ]; then _max="$_v"; fi
	done
	[ -n "$_max" ] && echo "$_max"
}

zone_temp() { [ -n "$1" ] && fmt_mdeg "$(max_mdeg "$1")"; }

# ==========================================
# ИНВЕНТАРИЗАЦИЯ ДАТЧИКОВ (один раз при старте)
# ==========================================

# Список "type path" всех термозон
ZLIST=""
for _z in "$SYSTH"/thermal_zone*; do
	[ -d "$_z" ] || continue
	ZLIST="$ZLIST$(rd "$_z/type") $_z
"
done

# Все зоны, чьё имя совпадает с шаблоном (case-шаблон, например 'cpu-0-*-usr')
find_zones() {
	_res=""
	_IFS_SAVE="$IFS"; IFS='
'
	for _line in $ZLIST; do
		_t="${_line%% *}"; _p="${_line#* }"
		case "$_t" in $1) _res="$_res $_p" ;; esac
	done
	IFS="$_IFS_SAVE"
	echo "${_res# }"
}

# Ядра и кластеры
POSSIBLE=$(rd "$SYSCPU/possible")          # например "0-8"
LAST_CPU="${POSSIBLE##*-}"
case "$LAST_CPU" in ''|*[!0-9]*) LAST_CPU=7 ;; esac

POLICIES=""
for _p in "$SYSCPU"/cpufreq/policy*; do
	[ -d "$_p" ] && POLICIES="$POLICIES ${_p##*policy}"
done
# Сортировка номеров политик по возрастанию (policy10 после policy8)
POLICIES=$(for _n in $POLICIES; do echo "$_n"; done | sort -n | tr '\n' ' ')
NCLUSTERS=$(echo $POLICIES | wc -w | tr -d ' ')

# Профиль датчиков: Tensor (LITTLE/MID/BIG) или Qualcomm (cpu-N-M-usr)
PROFILE="generic"
if [ -n "$(find_zones 'BIG')" ] && [ -n "$(find_zones 'LITTLE')" ]; then
	PROFILE="tensor"
elif [ -n "$(find_zones 'cpu-0-*-usr')" ]; then
	PROFILE="qcom"
fi

# Имя и зоны кластера по его порядковому номеру (0, 1, 2...)
cluster_name() {
	case "$PROFILE:$NCLUSTERS:$1" in
		tensor:3:0) echo "LITTLE" ;; tensor:3:1) echo "MID" ;; tensor:3:2) echo "BIG" ;;
		*:3:0) echo "Silver" ;; *:3:1) echo "Gold" ;; *:3:2) echo "Prime" ;;
		*:2:0) echo "Little" ;; *:2:1) echo "Big" ;;
		*) echo "Кластер $1" ;;
	esac
}

cluster_zones() {
	case "$PROFILE" in
		tensor)
			case "$1" in
				0) find_zones 'LITTLE' ;;
				1) if [ "$NCLUSTERS" -ge 3 ]; then find_zones 'MID'; else find_zones 'BIG'; fi ;;
				*) find_zones 'BIG' ;;
			esac
			;;
		qcom)
			# На SM8250 у Gold и Prime общие датчики cpu-1-*: если своих
			# cpu-2-* нет — берём датчики предыдущего кластера
			_k="$1"
			while [ "$_k" -ge 0 ]; do
				_zz=$(find_zones "cpu-$_k-*-usr")
				[ -n "$_zz" ] && { echo "$_zz"; return; }
				_k=$(( _k - 1 ))
			done
			;;
	esac
}

# Заранее считаем зоны каждого кластера
_i=0
for _pol in $POLICIES; do
	eval "CZ_$_i=\"\$(cluster_zones $_i)\""
	eval "CN_$_i=\"\$(cluster_name $_i)\""
	_i=$(( _i + 1 ))
done

# GPU
GPU_KIND=""
KGSL="$R/sys/class/kgsl/kgsl-3d0"
MALI=""
if [ -d "$KGSL" ]; then
	GPU_KIND="adreno"
	GPU_ZONES="$(find_zones 'gpuss-*-usr')"
else
	for _m in "$R"/sys/devices/platform/*.mali; do
		[ -f "$_m/cur_freq" ] && { MALI="$_m"; GPU_KIND="mali"; break; }
	done
	GPU_ZONES="$(find_zones 'G3D')"
fi

# Прочие интересные датчики: "имя_зоны|подпись"
case "$PROFILE" in
	tensor) EXTRA="soc_therm|SoC (плата)
TPU|TPU (нейроблок)
charge_therm|Зарядка
usb_pwr_therm|USB-порт" ;;
	qcom) EXTRA="quiet_therm|Корпус (quiet)
conn_therm|Разъём
wifi_therm|Wi-Fi
charger_therm0|Зарядка
ddr-usr|Память DDR" ;;
	*) EXTRA="" ;;
esac

# Источник батареи
BATT="$SYSPS/battery"
[ -f "$BATT/uevent" ] || BATT=""
BMS="$SYSPS/bms"
[ -f "$BMS/uevent" ] || BMS=""

HAS_DUMPSYS=0
command -v dumpsys >/dev/null 2>&1 && HAS_DUMPSYS=1

# ==========================================
# СЕКЦИИ ЭКРАНА
# ==========================================

# /proc/stat → загрузка каждого ядра (разница с прошлым замером)
read_cpu_load() {
	TOTAL_LOAD_SUM=0
	TOTAL_LOAD_N=0
	while read -r _name _u _n _s _i _w _q _sq _st _rest; do
		case "$_name" in
			cpu[0-9]*) ;;
			*) continue ;;
		esac
		_c="${_name#cpu}"
		_tot=$(( _u + _n + _s + _i + _w + _q + _sq + ${_st:-0} ))
		_act=$(( _tot - _i - _w ))
		eval "_pt=\${PT_$_c:-0}; _pa=\${PA_$_c:-0}"
		_dt=$(( _tot - _pt ))
		_da=$(( _act - _pa ))
		if [ "$_pt" -gt 0 ] && [ "$_dt" -gt 0 ]; then
			_load=$(( 100 * _da / _dt ))
			TOTAL_LOAD_SUM=$(( TOTAL_LOAD_SUM + _load ))
			TOTAL_LOAD_N=$(( TOTAL_LOAD_N + 1 ))
		else
			_load=""
		fi
		eval "PT_$_c=$_tot; PA_$_c=$_act; LOAD_$_c=\"$_load\""
	done < "$R/proc/stat"
}

# Какие ядра входят в политику: "4 5 6 7"
policy_cpus() { rd "$SYSCPU/cpufreq/policy$1/related_cpus"; }

section_cpu() {
	_avg="—"
	[ "$TOTAL_LOAD_N" -gt 0 ] && _avg="$(( TOTAL_LOAD_SUM / TOTAL_LOAD_N ))%"
	out "CPU ($(( LAST_CPU + 1 )) ядер)               средняя нагрузка: $_avg"

	_i=0
	for _pol in $POLICIES; do
		_pd="$SYSCPU/cpufreq/policy$_pol"
		_cpus=$(policy_cpus "$_pol")
		eval "_cn=\$CN_$_i; _cz=\$CZ_$_i"
		_hw=$(rd "$_pd/cpuinfo_max_freq")
		_cap=$(rd "$_pd/scaling_max_freq")
		_t=$(zone_temp "$_cz")
		_line="  $_cn [${_cpus% }]"
		[ -n "$_t" ] && _line="$_line  $_t"
		if [ -n "$_hw" ] && [ -n "$_cap" ] && [ "$_cap" -lt "$_hw" ]; then
			_line="$_line  потолок $(( _cap / 1000 ))/$(( _hw / 1000 )) МГц ▼"
		elif [ -n "$_hw" ]; then
			_line="$_line  макс. $(( _hw / 1000 )) МГц"
		fi
		out "$_line"

		for _c in $_cpus; do
			_f=$(rd "$SYSCPU/cpu$_c/cpufreq/scaling_cur_freq")
			eval "_l=\${LOAD_$_c:-}"
			if [ "$(rd "$SYSCPU/cpu$_c/online")" = "0" ]; then
				out "$(printf '    cpu%-2s  выключено' "$_c")"
			else
				out "$(printf '    cpu%-2s %5s МГц  %4s' "$_c" "${_f:+$(( _f / 1000 ))}" "${_l:-—}${_l:+%}")"
			fi
		done
		_i=$(( _i + 1 ))
	done
}

section_gpu() {
	_t=$(zone_temp "$GPU_ZONES")
	case "$GPU_KIND" in
		adreno)
			_busy=$(rd "$KGSL/gpu_busy_percentage"); _busy="${_busy%% *}"
			_clk=$(rd "$KGSL/gpuclk")
			_cap=$(rd "$KGSL/max_gpuclk")
			_hw=$(rd "$KGSL/devfreq/max_freq")
			[ -z "$_t" ] && _t=$(fmt_mdeg "$(rd "$KGSL/temp")")
			_model=$(rd "$KGSL/gpu_model")
			_line="GPU  ${_model:-Adreno}  $(( ${_clk:-0} / 1000000 )) МГц  ${_busy:-?}%"
			[ -n "$_t" ] && _line="$_line  $_t"
			out "$_line"
			if [ -n "$_cap" ] && [ -n "$_hw" ] && [ "$_cap" -lt "$_hw" ]; then
				out "     потолок $(( _cap / 1000000 ))/$(( _hw / 1000000 )) МГц ▼"
			fi
			;;
		mali)
			_cur=$(rd "$MALI/cur_freq")
			_max=$(rd "$MALI/max_freq")
			_ut=$(rd "$MALI/utilization")
			_line="GPU  Mali  $(( ${_cur:-0} / 1000 ))/$(( ${_max:-0} / 1000 )) МГц  ${_ut:-?}%"
			[ -n "$_t" ] && _line="$_line  $_t"
			out "$_line"
			;;
		*)
			out "GPU  (не найден)"
			;;
	esac
}

section_battery() {
	[ -n "$BATT" ] || { out "БАТАРЕЯ  (нет /sys/class/power_supply/battery)"; return; }

	_cap=""; _st=""; _hl=""; _tmp=""; _uv=""; _ua=""; _full=""; _design=""; _cyc=""
	while IFS='=' read -r _k _v; do
		case "$_k" in
			POWER_SUPPLY_CAPACITY) _cap="$_v" ;;
			POWER_SUPPLY_STATUS) _st="$_v" ;;
			POWER_SUPPLY_HEALTH) _hl="$_v" ;;
			POWER_SUPPLY_TEMP) _tmp="$_v" ;;
			POWER_SUPPLY_VOLTAGE_NOW) _uv="$_v" ;;
			POWER_SUPPLY_CURRENT_NOW) _ua="$_v" ;;
			POWER_SUPPLY_CHARGE_FULL) _full="$_v" ;;
			POWER_SUPPLY_CHARGE_FULL_DESIGN) _design="$_v" ;;
			POWER_SUPPLY_CYCLE_COUNT) _cyc="$_v" ;;
		esac
	done < "$BATT/uevent"

	case "$_st" in
		Charging) _sts="Заряжается"; _sign="+" ;;
		Discharging) _sts="Разряжается"; _sign="−" ;;
		Full) _sts="Заряжена"; _sign="" ;;
		"Not charging") _sts="Не заряжается"; _sign="" ;;
		*) _sts="${_st:-?}"; _sign="" ;;
	esac
	case "$_hl" in
		Good) _hls="в норме" ;; Overheat) _hls="ПЕРЕГРЕВ" ;; Cold) _hls="переохлаждена" ;;
		Dead) _hls="неисправна" ;; "Over voltage") _hls="перенапряжение" ;;
		*) _hls="${_hl:-?}" ;;
	esac

	# TEMP в десятых долях градуса
	_tline=""
	case "$_tmp" in ''|*[!0-9-]*) ;; *) _tline="  $(( _tmp / 10 )).$(( (_tmp < 0 ? -_tmp : _tmp) % 10 ))°C" ;; esac
	out "БАТАРЕЯ  ${_cap:-?}%  $_sts$_tline  (${_hls})"

	# Ток: на Pixel при разряде он отрицательный, на Qualcomm — положительный.
	# Поэтому берём модуль, а направление — из статуса.
	if [ -n "$_ua" ] && [ -n "$_uv" ]; then
		[ "$_ua" -lt 0 ] && _ua=$(( -_ua ))
		_ma=$(( _ua / 1000 ))
		_mv=$(( _uv / 1000 ))
		_mw=$(( _mv * _ma / 1000 ))
		out "$(printf '     %s%d мА · %d.%02d В · %d.%02d Вт' "$_sign" "$_ma" \
			$(( _mv / 1000 )) $(( _mv % 1000 / 10 )) $(( _mw / 1000 )) $(( _mw % 1000 / 10 )))"
	fi

	if [ -n "$_full" ] && [ -n "$_design" ] && [ "$_design" -gt 0 ]; then
		_pct=$(( _full / 100 * 100 / (_design / 100) ))
		_line="     Ёмкость $(( _full / 1000 ))/$(( _design / 1000 )) мАч (${_pct}%)"
		[ -n "$_cyc" ] && _line="$_line · циклов: $_cyc"
		out "$_line"
		[ "$_pct" -gt 100 ] && out "     (выше паспортной — контроллер ещё калибрует ёмкость)"
	elif [ -n "$_cyc" ]; then
		out "     Циклов: $_cyc"
	fi

	# Qualcomm: контроллер батареи сам оценивает её состояние (SOH)
	if [ -n "$BMS" ]; then
		_soh=$(sed -n 's/^POWER_SUPPLY_SOH=//p' "$BMS/uevent" 2>/dev/null)
		case "$_soh" in ''|*[!0-9]*) ;; *) out "     SOH по оценке контроллера: ${_soh}%" ;; esac
	fi
}

section_sensors() {
	[ -n "$EXTRA" ] || return 0
	_shown=0
	# heredoc, а не пайп: цикл идёт в текущем шелле и out() пишет в общий буфер
	while IFS='|' read -r _zn _lbl; do
		[ -n "$_zn" ] || continue
		_t=$(zone_temp "$(find_zones "$_zn")")
		[ -n "$_t" ] || continue
		[ "$_shown" -eq 0 ] && out "ДАТЧИКИ"
		# Температура первой: printf считает ширину в байтах, а кириллица
		# занимает по 2 байта на букву — выравнивание по подписи поехало бы
		out "$(printf '  %-8s %s' "$_t" "$_lbl")"
		_shown=1
	done <<EOF_EXTRA
$EXTRA
EOF_EXTRA
}

# Thermal HAL (Pixel): корпус VIRTUAL-SKIN и статус троттлинга Android
section_thermal() {
	_hal_skin=""; _status=""
	if [ "$HAS_DUMPSYS" -eq 1 ]; then
		_ts=$(dumpsys thermalservice 2>/dev/null)
		case "$_ts" in
			*"HAL Ready: true"*)
				_status=$(printf '%s\n' "$_ts" | sed -n 's/^Thermal Status: \([0-9]\).*/\1/p' | head -n 1)
				_hal_skin=$(printf '%s\n' "$_ts" \
					| sed -n '/Current temperatures from HAL/,/Current cooling devices/p' \
					| sed -n 's/.*mValue=\([-0-9.]*\), mType=[-0-9]*, mName=VIRTUAL-SKIN,.*/\1/p' \
					| head -n 1)
				;;
		esac
	fi

	out "ТРОТТЛИНГ"
	[ -n "$_hal_skin" ] && out "  Корпус (VIRTUAL-SKIN): $(fmt_float_c "$_hal_skin")"
	if [ -n "$_status" ]; then
		case "$_status" in
			0) _sn="нет" ;; 1) _sn="лёгкий" ;; 2) _sn="умеренный" ;; 3) _sn="сильный" ;;
			4) _sn="критический" ;; 5) _sn="аварийный" ;; 6) _sn="отключение" ;; *) _sn="?" ;;
		esac
		out "  Статус Android: $_sn ($_status)"
	fi

	# Активные ограничители: cooling device с cur_state > 0.
	# Подсветка/яркость сюда не относятся — у них cur_state это просто уровень.
	_act=""
	for _cd in "$SYSTH"/cooling_device*; do
		[ -d "$_cd" ] || continue
		_ty=$(rd "$_cd/type")
		case "$_ty" in *backlight*|*brightness*) continue ;; esac
		_cur=$(rd "$_cd/cur_state"); _mx=$(rd "$_cd/max_state")
		case "$_cur" in ''|*[!0-9]*) continue ;; esac
		[ "$_cur" -gt 0 ] && _act="$_act $_ty($_cur/$_mx)"
	done

	if [ -n "$_act" ]; then
		out "  Активные ограничители:"
		# переносим по 2 на строку, чтобы влезало в экран телефона
		_n=0; _row=""
		for _a in $_act; do
			_row="$_row $_a"; _n=$(( _n + 1 ))
			[ "$_n" -eq 2 ] && { out "   $_row"; _row=""; _n=0; }
		done
		[ -n "$_row" ] && out "   $_row"
	else
		out "  Ограничителей нет ✓"
	fi
}

# ==========================================
# ОСНОВНОЙ ЦИКЛ
# ==========================================

DEV="$(getprop ro.product.model 2>/dev/null)"
SOC="$(getprop ro.soc.model 2>/dev/null)"

# Первый замер нагрузки — «нулевая точка», чтобы на первом экране уже были цифры
read_cpu_load
sleep 1

while true; do
	BUF=""
	read_cpu_load
	out "===== ${DEV:-Android} · ${SOC:-?} · $(date '+%H:%M:%S') ====="
	out ""
	section_cpu
	out ""
	section_gpu
	out ""
	section_battery
	out ""
	section_sensors
	[ -n "$EXTRA" ] && out ""
	section_thermal
	out ""

	if [ "$ONCE" -eq 1 ]; then
		printf '%s' "$BUF"
		exit 0
	fi
	out "Обновление каждые ${INTERVAL} с · Ctrl+C — выход"
	# \033[H\033[2J — курсор в начало и очистка экрана
	printf '\033[H\033[2J%s' "$BUF"
	sleep "$INTERVAL"
done

