#!/bin/sh
# shellcheck shell=dash
#
# Тесты flash.sh и upload.sh на фальшивом роутере и мок-рекавери.
# Ничего настоящего не трогается: все пути подменяются через XR1710G_ROOT,
# а mtd-раздел, fw_printenv/fw_setenv и reboot заменены заглушками.
#
# Запуск:   sh tests/run.sh
#           SH="busybox sh" sh tests/run.sh
#
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
FLASH="${FLASH:-$REPO/flash.sh}"
UPLOAD="${UPLOAD:-$REPO/upload.sh}"
SH="${SH:-sh}"
PYTHON="${PYTHON:-python3}"

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t xr1710gtests)
PASS=0
FAIL=0
MOCK_PID=""

cleanup() {
	if [ -n "$MOCK_PID" ]; then
		kill "$MOCK_PID" 2>/dev/null || true
	fi
	rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM

ok() {
	PASS=$((PASS + 1))
	printf 'PASS %s\n' "$1"
}

bad() {
	FAIL=$((FAIL + 1))
	printf 'FAIL %s\n' "$1"
}

has() {
	if grep -qF -e "$2" "$3"; then
		ok "$1"
	else
		bad "$1 -- нет '$2' в $3"
		sed 's/^/     | /' "$3"
	fi
}

hasnt() {
	if grep -qF -e "$2" "$3"; then
		bad "$1 -- найдено '$2' в $3"
	else
		ok "$1"
	fi
}

equals() {
	if [ "$2" = "$3" ]; then
		ok "$1"
	else
		bad "$1 -- получено '$2', ожидалось '$3'"
	fi
}

# --- фальшивый роутер -------------------------------------------------------

# Проверяем, годится ли системный strings (на Windows в PATH может оказаться
# Sysinternals Strings с другим интерфейсом). Если нет -- подкладываем заглушку.
STRINGS_STUB=0
printf 'probe-string-value\000' > "$TMP/probe.bin"
if command -v timeout >/dev/null 2>&1; then
	probe_out=$(timeout 5 strings -n 4 "$TMP/probe.bin" < /dev/null 2>/dev/null || true)
else
	probe_out=$(strings -n 4 "$TMP/probe.bin" < /dev/null 2>/dev/null || true)
fi
case "$probe_out" in
*probe-string-value*) ;;
*)
	STRINGS_STUB=1
	printf 'Системный strings не подходит, использую заглушку\n'
	;;
esac

# make_slot <файл> <есть_рекавери: yes|no> <bootcmd>
# В окружении U-Boot ${...} должны остаться буквальными, поэтому одинарные кавычки.
# shellcheck disable=SC2016
make_slot() {
	out="$1"
	marker="$2"
	slot_bootcmd="$3"
	{
		printf 'U-Boot 2026.07-xr1710g-wiro-recovery (Aug 31 2026 - 16:00:00 +0000)\000'
		if [ "$marker" = "yes" ]; then
			printf 'HTTP recovery server listening on http://%%s/\000'
		fi
		printf 'baudrate=115200\000loadaddr=0x81800000\000mtdids=\000mtdparts=\000'
		printf 'boot_production=run ubi_read_production && bootm ${loadaddr}#${bootconf}\000'
		printf 'boot_ubi=ubi part ubi && run boot_production\000'
		printf 'bootargs=console=ttyS0,115200 earlycon ubi.block=0,fit root=/dev/fit0 rootwait\000'
		printf 'bootcmd=%s\000' "$slot_bootcmd"
		printf 'bootconf=config-1\000recovery_addr=0x81800000\000recovery_mtd=fit\000'
		printf 'recovery_size_uboot=0x100000\000recovery_ubi_part=ubi\000'
		printf 'ubi_read_production=ubi read ${loadaddr} fit\000uboot_ofs=0x600000\000'
		printf 'wiro_env_magic=XR1710G-WIRO\000wiro_env_schema=1\000'
		printf 'wiro_env_generation=2026090202\000'
	} > "$out"
	head -c 1048576 /dev/zero >> "$out"
}

# make_router <каталог> [есть_рекавери] [bootcmd] [модель] [размер_ubi] [есть_chainloader]
make_router() {
	dir="$1"
	marker="${2:-yes}"
	slot_bootcmd="${3:-run boot_ubi}"
	board="${4:-econet,xr1710g-ubi}"
	ubi_size="${5:-1b700000}"
	slot_part="${6:-yes}"

	mkdir -p "$dir/proc" "$dir/dev" "$dir/etc" "$dir/tmp/sysinfo" "$dir/root" "$dir/bin"

	{
		printf 'dev:    size   erasesize  name\n'
		printf 'mtd0: 00600000 00020000 "vendor"\n'
		if [ "$slot_part" = "yes" ]; then
			printf 'mtd1: 00100000 00020000 "chainloader"\n'
		else
			printf 'mtd1: 00100000 00020000 "tclinux"\n'
		fi
		printf 'mtd2: %s 00020000 "ubi"\n' "$ubi_size"
		printf 'mtd3: 04200000 00020000 "reserved_bmt"\n'
	} > "$dir/proc/mtd"

	make_slot "$dir/dev/mtd1" "$marker" "$slot_bootcmd"
	: > "$dir/dev/ubi0_1"
	: > "$dir/dev/ubi0_2"
	printf '%s' "$board" > "$dir/tmp/sysinfo/board_name"
	{
		printf '/dev/ubi0_1 0x0 0x4000 0x1f000 1\n'
		printf '/dev/ubi0_2 0x0 0x4000 0x1f000 1\n'
	} > "$dir/etc/fw_env.config"

	# состояние окружения: как на живом роутере -- пустое, fw_printenv отдаёт
	# встроенный по умолчанию bootcmd
	printf 'bootcmd=run distro_bootcmd\nbaudrate=115200\n' > "$dir/env.txt"
	: > "$dir/setenv.log"
	: > "$dir/reboot.log"

	cat > "$dir/bin/fw_printenv" <<'STUB'
#!/bin/sh
env_file="$FAKE_ENV"
if [ "$#" -eq 0 ]; then
	cat "$env_file"
	exit 0
fi
for var in "$@"; do
	grep "^$var=" "$env_file" || true
done
exit 0
STUB

	cat > "$dir/bin/fw_setenv" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "--help" ]; then
	printf ' -s, --script         batch mode to minimize writes\n'
	exit 0
fi
printf '%s\n' "$*" >> "$FAKE_SETENV_LOG"
env_file="$FAKE_ENV"
apply() {
	key="$1"
	value="$2"
	grep -v "^$key=" "$env_file" > "$env_file.new" || true
	if [ -n "$value" ]; then
		printf '%s=%s\n' "$key" "$value" >> "$env_file.new"
	fi
	mv "$env_file.new" "$env_file"
}
if [ "${1:-}" = "-s" ] || [ "${1:-}" = "--script" ]; then
	cp "$2" "$FAKE_SETENV_SCRIPT"
	while read -r key value; do
		case "$key" in "" | "#"*) continue ;; esac
		apply "$key" "$value"
	done < "$2"
	exit 0
fi
key="$1"
shift
apply "$key" "$*"
STUB

	cat > "$dir/bin/reboot" <<'STUB'
#!/bin/sh
printf 'reboot\n' >> "$FAKE_REBOOT_LOG"
STUB

	cat > "$dir/bin/id" <<'STUB'
#!/bin/sh
printf '0\n'
STUB

	cat > "$dir/bin/sync" <<'STUB'
#!/bin/sh
exit 0
STUB

	if [ "$STRINGS_STUB" = "1" ]; then
		cat > "$dir/bin/strings" <<'STUB'
#!/bin/sh
min=4
while [ "$#" -gt 0 ]; do
	case "$1" in
	-n)
		min="$2"
		shift 2
		;;
	-n*)
		min="${1#-n}"
		shift
		;;
	--) shift; break ;;
	-*) shift ;;
	*) break ;;
	esac
done
tr -cs '[:print:]' '\n' < "$1" | awk -v n="$min" 'length($0) >= n'
STUB
	fi

	chmod +x "$dir/bin"/*
}

# run_flash <каталог> [аргументы...]
run_flash() {
	dir="$1"
	shift
	(
		PATH="$dir/bin:$PATH"
		export PATH
		XR1710G_ROOT="$dir"
		XR1710G_BACKUP_DIR="$dir/root"
		FAKE_ENV="$dir/env.txt"
		FAKE_SETENV_LOG="$dir/setenv.log"
		FAKE_SETENV_SCRIPT="$dir/setenv-script.txt"
		FAKE_REBOOT_LOG="$dir/reboot.log"
		# busybox со standalone-шеллом иначе возьмёт свои апплеты вместо заглушек
		BB_OVERRIDE_APPLETS="id reboot sync strings"
		export XR1710G_ROOT XR1710G_BACKUP_DIR FAKE_ENV FAKE_SETENV_LOG \
			FAKE_SETENV_SCRIPT FAKE_REBOOT_LOG BB_OVERRIDE_APPLETS
		$SH "$FLASH" "$@"
	) > "$dir/out.txt" 2>&1
	echo "$?" > "$dir/rc.txt"
}

printf '=== flash.sh (%s) ===\n' "$SH"

# 1. Штатный сценарий
D="$TMP/r1"
make_router "$D"
run_flash "$D" -y || true
equals "штатный сценарий: код возврата 0" "$(cat "$D/rc.txt")" "0"
has "определил модель" "econet,xr1710g-ubi" "$D/out.txt"
has "нашёл слот" "mtd1" "$D/out.txt"
has "показал текущий загрузчик" "U-Boot 2026.07-xr1710g-wiro-recovery" "$D/out.txt"
has "определил раскладку" "UBI 2.0" "$D/out.txt"
has "прочитал заводской bootcmd" "Заводской bootcmd:     run boot_ubi" "$D/out.txt"
has "проверил запись" "Проверка:              bootcmd=http_recovery" "$D/out.txt"
has "записал bootcmd" "bootcmd=http_recovery" "$D/env.txt"
has "сохранил boot_ubi" "boot_ubi=ubi part ubi && run boot_production" "$D/env.txt"
has "сохранил boot_production" "boot_production=run ubi_read_production" "$D/env.txt"
has "сохранил bootargs" "bootargs=console=ttyS0,115200" "$D/env.txt"
has "сохранил recovery_mtd" "recovery_mtd=fit" "$D/env.txt"
hasnt "не трогает wiro_env_magic" "wiro_env_magic" "$D/env.txt"
hasnt "не трогает mtdparts" "mtdparts" "$D/env.txt"
has "один пакетный вызов fw_setenv" "-s " "$D/setenv.log"
equals "ровно один вызов fw_setenv" "$(wc -l < "$D/setenv.log" | tr -d ' ')" "1"
has "перезагрузил роутер" "reboot" "$D/reboot.log"
equals "резервная копия 1 МиБ" \
	"$(wc -c < "$(ls "$D"/root/xr1710g-chainloader-*.bin)" | tr -d ' ')" "1048576"
has "подсказал про upload.sh" "upload.sh" "$D/out.txt"
has "дал адрес рекавери" "http://192.168.255.1" "$D/out.txt"

# 2. Без перезагрузки
D="$TMP/r2"
make_router "$D"
run_flash "$D" -y -n || true
equals "-n: код возврата 0" "$(cat "$D/rc.txt")" "0"
has "-n: окружение записано" "bootcmd=http_recovery" "$D/env.txt"
equals "-n: без перезагрузки" "$(wc -c < "$D/reboot.log" | tr -d ' ')" "0"

# 3. Режим кнопки: флеш не трогаем
D="$TMP/r3"
make_router "$D"
run_flash "$D" -y -b || true
equals "-b: код возврата 0" "$(cat "$D/rc.txt")" "0"
has "-b: инструкция про reset" "нажмите и держите reset" "$D/out.txt"
equals "-b: fw_setenv не вызывался" "$(wc -c < "$D/setenv.log" | tr -d ' ')" "0"
hasnt "-b: bootcmd не изменён" "http_recovery" "$D/env.txt"
equals "-b: без перезагрузки" "$(wc -c < "$D/reboot.log" | tr -d ' ')" "0"
has "-b: копия слота всё равно сделана" "Резервная копия" "$D/out.txt"

# 4. Восстановление
D="$TMP/r4"
make_router "$D"
run_flash "$D" -y -n || true
run_flash "$D" -y -n -r || true
equals "-r: код возврата 0" "$(cat "$D/rc.txt")" "0"
has "-r: вернул заводской bootcmd" "bootcmd=run boot_ubi" "$D/env.txt"
hasnt "-r: http_recovery убран" "bootcmd=http_recovery" "$D/env.txt"

# 5. Чужая модель
D="$TMP/r5"
make_router "$D" yes "run boot_ubi" "glinet,gl-be14000"
run_flash "$D" -y || true
equals "чужая модель: ненулевой код" "$(cat "$D/rc.txt")" "1"
has "чужая модель: сообщение" "это не XR1710G" "$D/out.txt"
equals "чужая модель: окружение не тронуто" "$(wc -c < "$D/setenv.log" | tr -d ' ')" "0"

# 6. Загрузчик без HTTP-рекавери
D="$TMP/r6"
make_router "$D" no
run_flash "$D" -y || true
equals "нет рекавери: ненулевой код" "$(cat "$D/rc.txt")" "1"
has "нет рекавери: сообщение" "нет HTTP-рекавери" "$D/out.txt"
equals "нет рекавери: окружение не тронуто" "$(wc -c < "$D/setenv.log" | tr -d ' ')" "0"

# 7. Нет раздела chainloader (заводская раскладка tclinux)
D="$TMP/r7"
make_router "$D" yes "run boot_ubi" "econet,xr1710g-ubi" "1b700000" no
run_flash "$D" -y || true
equals "нет chainloader: ненулевой код" "$(cat "$D/rc.txt")" "1"
has "нет chainloader: сообщение" "нет раздела" "$D/out.txt"

# 8. Нет fw_env.config
D="$TMP/r8"
make_router "$D"
rm -f "$D/etc/fw_env.config"
run_flash "$D" -y || true
equals "нет fw_env.config: ненулевой код" "$(cat "$D/rc.txt")" "1"
has "нет fw_env.config: сообщение" "окружение U-Boot не настроено" "$D/out.txt"

# 9. Раздел окружения отсутствует
D="$TMP/r9"
make_router "$D"
rm -f "$D/dev/ubi0_2"
run_flash "$D" -y || true
equals "нет ubi0_2: ненулевой код" "$(cat "$D/rc.txt")" "1"
has "нет ubi0_2: сообщение" "которого нет в системе" "$D/out.txt"

# 10. Другая раскладка UBI
D="$TMP/r10"
make_router "$D" yes "run boot_ubi" "econet,xr1710g-ubi" "1d9c0000"
run_flash "$D" -y -n || true
has "раскладка 1.5 распознана" "UBI 1.5" "$D/out.txt"

# --- upload.sh --------------------------------------------------------------

if ! command -v curl >/dev/null 2>&1 || ! command -v "$PYTHON" >/dev/null 2>&1; then
	printf '\nПропускаю тесты upload.sh: нет curl или %s\n' "$PYTHON"
else
	printf '\n=== upload.sh (%s) ===\n' "$SH"

	start_mock() {
		rm -f "$TMP/port" "$TMP/received.bin" "$TMP/queries"
		"$PYTHON" "$HERE/mock_recovery.py" --port 0 --port-file "$TMP/port" \
			--out "$TMP/received.bin" --query-log "$TMP/queries" "$@" \
			> "$TMP/mock.log" 2>&1 &
		MOCK_PID=$!
		waited=0
		while [ ! -s "$TMP/port" ] && [ "$waited" -lt 100 ]; do
			sleep 0.2 2>/dev/null || sleep 1
			waited=$((waited + 1))
		done
		if [ ! -s "$TMP/port" ]; then
			bad "мок-рекавери не запустилось"
			return 1
		fi
		PORT=$(cat "$TMP/port")
	}

	stop_mock() {
		if [ -n "$MOCK_PID" ]; then
			kill "$MOCK_PID" 2>/dev/null || true
			MOCK_PID=""
		fi
	}

	SLOT="$REPO/firmware/xr1710g-chainloader-slot.bin"

	# 11. Штатная заливка загрузчика в рекавери wiro
	if start_mock --flavor wiro; then
		$SH "$UPLOAD" -i "127.0.0.1:$PORT" -y -w 20 > "$TMP/u1.txt" 2>&1 || true
		has "upload: увидел рекавери" "Рекавери:" "$TMP/u1.txt"
		has "upload: проверил sha256" "совпадает с xr1710g_260805" "$TMP/u1.txt"
		has "upload: образ принят" "Образ принят рекавери" "$TMP/u1.txt"
		has "upload: дождался конца" "готово" "$TMP/u1.txt"
		has "upload: подтвердил завершение" "Подтверждение отправлено" "$TMP/u1.txt"
		has "upload: передал ui_build" "ui_build=xr1710g-wiro-recovery" "$TMP/queries"
		has "upload: адресовал /upload/uboot" "/upload/uboot" "$TMP/queries"
		if command -v sha256sum >/dev/null 2>&1; then
			equals "upload: файл дошёл без искажений" \
				"$(sha256sum "$TMP/received.bin" | awk '{ print $1 }')" \
				"$(sha256sum "$SLOT" | awk '{ print $1 }')"
		fi
		stop_mock
	fi

	# 12. Рекавери без ui_build (сборка YYH2913)
	if start_mock --flavor new; then
		$SH "$UPLOAD" -i "127.0.0.1:$PORT" -y -w 20 > "$TMP/u2.txt" 2>&1 || true
		has "upload(new): образ принят" "Образ принят рекавери" "$TMP/u2.txt"
		hasnt "upload(new): без ui_build в URL" "ui_build" "$TMP/queries"
		has "upload(new): сам перезагрузится" "перезагрузится сам" "$TMP/u2.txt"
		stop_mock
	fi

	# 13. Не тот файл: нет legacy-заголовка
	if start_mock --flavor wiro; then
		printf 'not a slot image' > "$TMP/bogus.bin"
		$SH "$UPLOAD" -i "127.0.0.1:$PORT" -y -w 5 -f "$TMP/bogus.bin" \
			> "$TMP/u3.txt" 2>&1 || true
		has "upload: отверг чужой файл" "это не образ слота" "$TMP/u3.txt"
		if [ -f "$TMP/received.bin" ]; then
			bad "upload: чужой файл не должен уходить на роутер"
		else
			ok "upload: чужой файл не ушёл на роутер"
		fi
		stop_mock
	fi

	# 14. Слишком большой образ загрузчика
	if start_mock --flavor wiro; then
		{
			printf '\047\005\031\126'
			head -c 2097152 /dev/zero
		} > "$TMP/big.bin"
		$SH "$UPLOAD" -i "127.0.0.1:$PORT" -y -w 5 -f "$TMP/big.bin" \
			> "$TMP/u4.txt" 2>&1 || true
		has "upload: отверг образ >1 МиБ" "больше 1 МиБ" "$TMP/u4.txt"
		stop_mock
	fi

	# 15. firmware без файла и ошибка записи
	$SH "$UPLOAD" -t firmware -y -w 5 > "$TMP/u5.txt" 2>&1 || true
	has "upload: firmware требует -f" "укажите образ через -f" "$TMP/u5.txt"

	if start_mock --flavor wiro --fail; then
		$SH "$UPLOAD" -i "127.0.0.1:$PORT" -y -w 20 > "$TMP/u6.txt" 2>&1 || true
		has "upload: сообщил об отказе рекавери" "POST не удался" "$TMP/u6.txt"
		stop_mock
	fi

	# 16. Рекавери не отвечает
	$SH "$UPLOAD" -i "127.0.0.1:1" -y -w 2 > "$TMP/u7.txt" 2>&1 || true
	has "upload: сообщил про недоступное рекавери" "рекавери не ответило" "$TMP/u7.txt"
fi

printf '\n=== итог: PASS %d, FAIL %d ===\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
	exit 1
fi
