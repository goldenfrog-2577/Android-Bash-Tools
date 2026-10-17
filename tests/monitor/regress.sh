#!/usr/bin/env bash
# regress.sh — сравнение выдачи двух версий monitor.sh на моках (для разработки на ПК).
#
#   BWK_AWK=/путь/к/one-true-awk tests/monitor/regress.sh СТАРЫЙ.sh НОВЫЙ.sh ФАЙЛ_СЦЕНАРИЕВ
#
# Сценарии — строки «имя|каталог-заглушек|корень|переменные|флаги» (см. scenarios.example).
# Каждый сценарий гоняется обеими версиями дважды: с awk из PATH и с BWK awk
# (One True AWK, как на Android), если задан BWK_AWK=/путь/к/awk.
# Сравниваются: код выхода, stderr (должен быть пустым) и stdout после
# выравнивания меняющихся полей (время, номер версии).
#
# Сами моки в репозиторий не входят: в них реальные дампы телефонов
# (сети Wi-Fi, NFC, статистика приложений). Путь к ним — в файле сценариев.
set -u
OLD=$1 NEW=$2 SC=${3:?нужен файл сценариев (см. scenarios.example)}
OUT=${OUT:-$(mktemp -d)}
[ -f "$SC" ] || { echo "нет файла сценариев: $SC" >&2; exit 3; }
fail=0 n=0

norm() {   # меняющиеся от запуска к запуску поля
	sed -E -e 's/v3\.[0-9]+(\.[0-9]+)?/vX/' \
		-e 's/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/DATE TIME/g' \
		-e 's/^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]/[TS]/' "$1"
}

run1() {   # run1 скрипт тег bin root env flags awkdir
	local s=$1 tag=$2 bin=$3 root=$4 envs=$5 flags=$6 awkd=$7 p
	p="$bin:$PATH"; [ -n "$awkd" ] && p="$awkd:$p"
	env -i HOME="$HOME" TERM=dumb PATH="$p" MONITOR_SYSROOT="$root" MONITOR_COLS="${MONITOR_COLS:-}" $envs \
		bash "$s" $flags > "$OUT/$tag.out" 2> "$OUT/$tag.err"
	echo $? > "$OUT/$tag.rc"
}

awkdir=""
if [ -n "${BWK_AWK:-}" ]; then awkdir="$OUT/bwk"; mkdir -p "$awkdir"; ln -sf "$BWK_AWK" "$awkdir/awk"; fi

while IFS='|' read -r name bin root envs flags; do
	case "$name" in ''|'#'*) continue ;; esac
	for a in sys ${awkdir:+bwk}; do
		ad=""; [ "$a" = bwk ] && ad=$awkdir
		t="${name}_$a"; n=$((n + 1))
		# по очереди: обе версии берут одну и ту же блокировку в /dev
		run1 "$OLD" "old_$t" "$bin" "$root" "$envs" "$flags" "$ad"
		run1 "$NEW" "new_$t" "$bin" "$root" "$envs" "$flags" "$ad"
		r="ок"
		if [ "$(cat "$OUT/old_$t.rc")" != "$(cat "$OUT/new_$t.rc")" ]; then r="КОД $(cat "$OUT/old_$t.rc")→$(cat "$OUT/new_$t.rc")"; fi
		[ -s "$OUT/new_$t.err" ] && r="$r · STDERR"
		# .diff пишется всегда (пустой — совпало), чтобы не оставалось старых
		diff <(norm "$OUT/old_$t.out") <(norm "$OUT/new_$t.out") > "$OUT/$t.diff" || r="$r · ВЫВОД"
		[ "$r" = "ок" ] || fail=$((fail + 1))
		printf '%-28s %s\n' "$t" "$r"
	done
done < "$SC"
echo "сценариев: $n · расхождений: $fail · файлы: $OUT"
[ "$fail" -eq 0 ]
