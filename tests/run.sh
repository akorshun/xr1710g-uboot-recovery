#!/bin/sh
# shellcheck shell=dash
#
# Тесты flash.sh и upload.sh на фальшивом роутере и мок-рекавери.
# Ничего настоящего не трогается: пути подменяются через XR1710G_ROOT, а mtd,
# insmod, fw_printenv/fw_setenv и reboot заменены заглушками, которые
# эмулируют запись в раздел и снятие защиты.
#
# Запуск:   sh tests/run.sh
#           SH="busybox sh" sh tests/run.sh
#
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
FLASH="${FLASH:-$REPO/flash.sh}"
UPLOAD="${UPLOAD:-$REPO/upload.sh}"
SLOT_IMAGE="$REPO/firmware/xr1710g-chainloader-slot.bin"
MODULE_FILE="$REPO/firmware/mtd-rw-6.18.41.ko"
VERMAGIC="6.18.41 SMP mod_unload aarch64"
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

empty_file() {
	if [ -s "$2" ]; then
		bad "$1 -- файл $2 не пуст: $(tr '\n' '; ' < "$2")"
	else
		ok "$1"
	fi
}

# Системный strings может оказаться несовместимым (Sysinternals на Windows).
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

# --- фальшивый роутер -------------------------------------------------------

# make_router <каталог> [модель] [размер_ubi] [есть_chainloader] [флаги_слота]
make_router() {
	dir="$1"
	board="${2:-econet,xr1710g-ubi}"
	ubi_size="${3:-1b700000}"
	slot_part="${4:-yes}"
	slot_flags="${5:-0x0}"

	mkdir -p "$dir/proc" "$dir/dev" "$dir/etc" "$dir/tmp/sysinfo" "$dir/root" \
		"$dir/bin" "$dir/lib/modules/6.18.41"
	for n in 0 1 2 3; do
		mkdir -p "$dir/sys/class/mtd/mtd$n"
	done

	{
		printf 'dev:    size   erasesize  name\n'
		printf 'mtd0: 00600000 00020000 "vendor"\n'
		if [ "$slot_part" = "yes" ]; then
			printf 'mtd1: 00100000 00020000 "chainloader"\n'
		else
			printf 'mtd1: 04000000 00020000 "tclinux"\n'
		fi
		printf 'mtd2: %s 00020000 "ubi"\n' "$ubi_size"
		printf 'mtd3: 04200000 00020000 "reserved_bmt"\n'
	} > "$dir/proc/mtd"

	printf '%s\n' "$slot_flags" > "$dir/sys/class/mtd/mtd0/flags"
	printf '%s\n' "$slot_flags" > "$dir/sys/class/mtd/mtd1/flags"
	printf '0x400\n' > "$dir/sys/class/mtd/mtd2/flags"
	printf '%s\n' "$slot_flags" > "$dir/sys/class/mtd/mtd3/flags"

	# «старый» загрузчик в слоте: legacy-заголовок uImage, версия, маркер рекавери
	{
		printf '\047\005\031\126'
		head -c 60 /dev/zero
		printf 'U-Boot 2026.07-xr1710g-wiro-recovery (Aug 31 2026 - 16:00:00 +0000)\000'
		printf 'HTTP recovery server listening on http://%%s/\000'
		printf 'bootcmd=run boot_ubi\000'
	} > "$dir/dev/mtd1"
	head -c 1048576 /dev/zero >> "$dir/dev/mtd1"
	dd if="$dir/dev/mtd1" of="$dir/dev/mtd1.1m" bs=65536 count=16 2>/dev/null
	mv "$dir/dev/mtd1.1m" "$dir/dev/mtd1"

	printf '%s' "$board" > "$dir/tmp/sysinfo/board_name"
	{
		printf '/dev/ubi0_1 0x0 0x4000 0x1f000 1\n'
		printf '/dev/ubi0_2 0x0 0x4000 0x1f000 1\n'
	} > "$dir/etc/fw_env.config"
	: > "$dir/dev/ubi0_1"
	: > "$dir/dev/ubi0_2"

	# модуль ядра в прошивке -- источник vermagic
	printf 'vermagic=%s\000' "$VERMAGIC" > "$dir/lib/modules/6.18.41/act_csum.ko"
	head -c 4096 /dev/zero >> "$dir/lib/modules/6.18.41/act_csum.ko"

	printf 'bootcmd=run distro_bootcmd\nbaudrate=115200\n' > "$dir/env.txt"
	: > "$dir/setenv.log"
	: > "$dir/reboot.log"
	: > "$dir/insmod.log"
	: > "$dir/mtd.log"

	cat > "$dir/bin/mtd" <<'STUB'
#!/bin/sh
writes=$(grep -c '^write ' "$FAKE_MTD_LOG" 2>/dev/null) || writes=0
printf '%s\n' "$*" >> "$FAKE_MTD_LOG"
if [ "$1" != "write" ]; then
	exit 0
fi
file="$2"
part="$3"
dev=$(awk -v w="\"$part\"" '$4 == w { sub(":", "", $1); print $1; exit }' "$XR1710G_ROOT/proc/mtd")
if [ -z "$dev" ]; then
	printf 'mtd: partition %s not found\n' "$part" >&2
	exit 1
fi
target="$XR1710G_ROOT/dev/$dev"
flags=$(cat "$XR1710G_ROOT/sys/class/mtd/$dev/flags")
case "$flags" in
*400*) ;;
*)
	printf 'mtd: could not open %s: Permission denied\n' "$target" >&2
	exit 1
	;;
esac
printf 'Unlocking %s ...\n' "$part"
printf 'Writing from %s to %s ...\n' "$file" "$part"
dd if="$file" of="$target" bs=4096 conv=notrunc 2>/dev/null
# FAKE_MTD_CORRUPT портит только первую запись (как сбой на флеше),
# FAKE_MTD_CORRUPT_ALL -- любую, чтобы проверить неудачный откат.
if [ -n "${FAKE_MTD_CORRUPT_ALL:-}" ] ||
	{ [ -n "${FAKE_MTD_CORRUPT:-}" ] && [ "$writes" -eq 0 ]; }; then
	printf 'X' | dd of="$target" bs=1 seek=1000 conv=notrunc 2>/dev/null
fi
STUB

	cat > "$dir/bin/insmod" <<'STUB'
#!/bin/sh
printf 'insmod %s\n' "$*" >> "$FAKE_INSMOD_LOG"
case "$1" in
mtd-rw | mtd_rw)
	if [ "${FAKE_SYS_MODULE:-0}" != "1" ]; then
		printf 'insmod: module mtd-rw not found\n' >&2
		exit 1
	fi
	;;
*)
	if [ ! -r "$1" ]; then
		printf 'insmod: cannot open %s\n' "$1" >&2
		exit 1
	fi
	;;
esac
for n in 0 1 3; do
	printf '0x400\n' > "$XR1710G_ROOT/sys/class/mtd/mtd$n/flags"
done
STUB

	cat > "$dir/bin/rmmod" <<'STUB'
#!/bin/sh
printf 'rmmod %s\n' "$*" >> "$FAKE_INSMOD_LOG"
STUB

	cat > "$dir/bin/fw_printenv" <<'STUB'
#!/bin/sh
if [ "${FAKE_ENV_VALID:-0}" != "1" ]; then
	printf 'Warning: Bad CRC, using default environment\n' >&2
	printf 'bootcmd=run distro_bootcmd\n'
	exit 0
fi
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
key="$1"
shift
grep -v "^$key=" "$env_file" > "$env_file.new" || true
if [ -n "$*" ]; then
	printf '%s=%s\n' "$key" "$*" >> "$env_file.new"
fi
mv "$env_file.new" "$env_file"
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

	cat > "$dir/bin/wget" <<'STUB'
#!/bin/sh
printf 'wget %s\n' "$*" >> "${FAKE_WGET_LOG:-/dev/null}"
exit 1
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
	--)
		shift
		break
		;;
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
		FAKE_REBOOT_LOG="$dir/reboot.log"
		FAKE_INSMOD_LOG="$dir/insmod.log"
		FAKE_MTD_LOG="$dir/mtd.log"
		FAKE_WGET_LOG="$dir/wget.log"
		# busybox со standalone-шеллом иначе возьмёт свои апплеты вместо заглушек
		BB_OVERRIDE_APPLETS="id reboot sync strings insmod rmmod wget"
		export XR1710G_ROOT XR1710G_BACKUP_DIR FAKE_ENV FAKE_SETENV_LOG \
			FAKE_REBOOT_LOG FAKE_INSMOD_LOG FAKE_MTD_LOG FAKE_WGET_LOG \
			BB_OVERRIDE_APPLETS
		$SH "$FLASH" "$@"
	) > "$dir/out.txt" 2>&1
	echo "$?" > "$dir/rc.txt"
}

slot_head_sum() {
	size=$(wc -c < "$2" | tr -d ' ')
	dd if="$1/dev/mtd1" bs=4096 count=$(( (size + 4095) / 4096 )) 2>/dev/null |
		head -c "$size" | sha256sum | awk '{ print $1 }'
}

image_sum=$(sha256sum "$SLOT_IMAGE" | awk '{ print $1 }')

printf '=== flash.sh (%s) ===\n' "$SH"

# 1. Штатная прошивка, mtd-rw есть в системе
D="$TMP/r1"
make_router "$D"
FAKE_SYS_MODULE=1 run_flash "$D" -y -i "$SLOT_IMAGE" || true
equals "штатная прошивка: код возврата 0" "$(cat "$D/rc.txt")" "0"
has "определил модель" "econet,xr1710g-ubi" "$D/out.txt"
has "нашёл слот" "mtd1" "$D/out.txt"
has "показал текущий загрузчик" "U-Boot 2026.07-xr1710g-wiro-recovery" "$D/out.txt"
has "определил раскладку" "UBI 2.0" "$D/out.txt"
has "сверил образ с релизом" "совпадает с релизом xr1710g_260805" "$D/out.txt"
has "показал версию нового загрузчика" "U-Boot 2026.07-00766-g53b73174c0fc" "$D/out.txt"
has "снял защиту" "раздел открыт для записи" "$D/out.txt"
has "использовал системный mtd-rw" "insmod mtd-rw i_want_a_brick=1" "$D/insmod.log"
has "вызвал mtd write" "write $SLOT_IMAGE chainloader" "$D/mtd.log"
has "проверил запись чтением" "Проверка чтением:      совпало" "$D/out.txt"
equals "в слоте лежит новый образ" "$(slot_head_sum "$D" "$SLOT_IMAGE")" "$image_sum"
has "выгрузил модуль" "rmmod" "$D/insmod.log"
has "перезагрузил роутер" "reboot" "$D/reboot.log"
equals "копия слота 1 МиБ" \
	"$(wc -c < "$(ls "$D"/root/xr1710g-chainloader-*.bin)" | tr -d ' ')" "1048576"
has "окружение не тронуто при Bad CRC" "пустое (Bad CRC)" "$D/out.txt"
empty_file "fw_setenv не вызывался" "$D/setenv.log"

# 2. Модуль из репозитория (в системе kmod-mtd-rw нет)
D="$TMP/r2"
make_router "$D"
run_flash "$D" -y -i "$SLOT_IMAGE" -m "$MODULE_FILE" || true
equals "модуль из файла: код возврата 0" "$(cat "$D/rc.txt")" "0"
has "проверил vermagic ядра" "vermagic ядра:       $VERMAGIC" "$D/out.txt"
has "проверил vermagic модуля" "vermagic модуля:     $VERMAGIC" "$D/out.txt"
has "загрузил модуль из файла" "$MODULE_FILE i_want_a_brick=1" "$D/insmod.log"
equals "в слоте лежит новый образ" "$(slot_head_sum "$D" "$SLOT_IMAGE")" "$image_sum"

# 3. Несовпадение vermagic
D="$TMP/r3"
make_router "$D"
printf 'vermagic=6.12.0 SMP mod_unload aarch64\000' > "$D/other.ko"
head -c 4096 /dev/zero >> "$D/other.ko"
run_flash "$D" -y -i "$SLOT_IMAGE" -m "$D/other.ko" || true
equals "чужой vermagic: ненулевой код" "$(cat "$D/rc.txt")" "1"
has "чужой vermagic: сообщение" "vermagic не совпадает" "$D/out.txt"
empty_file "чужой vermagic: запись не выполнялась" "$D/mtd.log"

# 4. Раздел уже открыт на запись
D="$TMP/r4"
make_router "$D" "econet,xr1710g-ubi" "1b700000" yes "0x400"
run_flash "$D" -y -i "$SLOT_IMAGE" || true
equals "уже писабельный: код возврата 0" "$(cat "$D/rc.txt")" "0"
has "уже писабельный: сообщение" "уже снята" "$D/out.txt"
empty_file "уже писабельный: insmod не вызывался" "$D/insmod.log"
equals "уже писабельный: образ записан" "$(slot_head_sum "$D" "$SLOT_IMAGE")" "$image_sum"

# 5. Чужая модель
D="$TMP/r5"
make_router "$D" "glinet,gl-be14000"
FAKE_SYS_MODULE=1 run_flash "$D" -y -i "$SLOT_IMAGE" || true
equals "чужая модель: ненулевой код" "$(cat "$D/rc.txt")" "1"
has "чужая модель: сообщение" "это не XR1710G" "$D/out.txt"
empty_file "чужая модель: запись не выполнялась" "$D/mtd.log"

# 6. Нет раздела chainloader
D="$TMP/r6"
make_router "$D" "econet,xr1710g-ubi" "1b700000" no
FAKE_SYS_MODULE=1 run_flash "$D" -y -i "$SLOT_IMAGE" || true
equals "нет chainloader: ненулевой код" "$(cat "$D/rc.txt")" "1"
has "нет chainloader: сообщение" "нет раздела" "$D/out.txt"

# 7. Не тот образ (нет legacy-заголовка)
D="$TMP/r7"
make_router "$D"
printf 'not a slot image at all' > "$D/bogus.bin"
FAKE_SYS_MODULE=1 run_flash "$D" -y -i "$D/bogus.bin" || true
equals "чужой файл: ненулевой код" "$(cat "$D/rc.txt")" "1"
has "чужой файл: сообщение" "это не образ слота" "$D/out.txt"
empty_file "чужой файл: защита не снималась" "$D/insmod.log"

# 8. Образ больше слота
D="$TMP/r8"
make_router "$D"
{
	printf '\047\005\031\126'
	head -c 2097152 /dev/zero
} > "$D/big.bin"
FAKE_SYS_MODULE=1 run_flash "$D" -y -i "$D/big.bin" || true
equals "большой образ: ненулевой код" "$(cat "$D/rc.txt")" "1"
has "большой образ: сообщение" "больше слота" "$D/out.txt"

# 9. Порча при записи -> откат на копию
D="$TMP/r9"
make_router "$D"
before_sum=$(sha256sum "$D/dev/mtd1" | awk '{ print $1 }')
FAKE_SYS_MODULE=1 FAKE_MTD_CORRUPT=1 run_flash "$D" -y -i "$SLOT_IMAGE" || true
equals "порча записи: ненулевой код" "$(cat "$D/rc.txt")" "1"
has "порча записи: сообщил о несовпадении" "обратное чтение не совпало" "$D/out.txt"
has "порча записи: откатился" "копия восстановлена" "$D/out.txt"
empty_file "порча записи: без перезагрузки" "$D/reboot.log"
equals "порча записи: слот вернулся в исходное состояние" \
	"$(sha256sum "$D/dev/mtd1" | awk '{ print $1 }')" "$before_sum"

# 9b. Порча и при откате -> громкое предупреждение, без перезагрузки
D="$TMP/r9b"
make_router "$D"
FAKE_SYS_MODULE=1 FAKE_MTD_CORRUPT_ALL=1 run_flash "$D" -y -i "$SLOT_IMAGE" || true
equals "неудачный откат: ненулевой код" "$(cat "$D/rc.txt")" "1"
has "неудачный откат: предупреждение" "НЕ перезагружайтесь" "$D/out.txt"
empty_file "неудачный откат: без перезагрузки" "$D/reboot.log"

# 10. Валидное окружение с чужим bootcmd -> правим
D="$TMP/r10"
make_router "$D"
printf 'bootcmd=http_recovery\nbaudrate=115200\n' > "$D/env.txt"
FAKE_SYS_MODULE=1 FAKE_ENV_VALID=1 run_flash "$D" -y -i "$SLOT_IMAGE" || true
equals "правка bootcmd: код возврата 0" "$(cat "$D/rc.txt")" "0"
has "правка bootcmd: сообщение" "bootcmd 'http_recovery' -> 'run boot_ubi || http_recovery'" "$D/out.txt"
has "правка bootcmd: записано" "bootcmd=run boot_ubi || http_recovery" "$D/env.txt"
has "правка bootcmd: вызван fw_setenv" "bootcmd run boot_ubi || http_recovery" "$D/setenv.log"

# 11. Режим подсказок: ничего не менять
D="$TMP/r11"
make_router "$D"
FAKE_SYS_MODULE=1 run_flash "$D" -y -b || true
equals "-b: код возврата 0" "$(cat "$D/rc.txt")" "0"
has "-b: копия сделана" "Резервная копия" "$D/out.txt"
has "-b: подсказки выведены" "Ничего не изменено" "$D/out.txt"
empty_file "-b: запись не выполнялась" "$D/mtd.log"
empty_file "-b: защита не снималась" "$D/insmod.log"
empty_file "-b: без перезагрузки" "$D/reboot.log"

# 12. Откат на указанную копию
D="$TMP/r12"
make_router "$D"
cp "$D/dev/mtd1" "$D/old-slot.bin"
FAKE_SYS_MODULE=1 run_flash "$D" -y -i "$SLOT_IMAGE" || true
FAKE_SYS_MODULE=1 run_flash "$D" -y -r "$D/old-slot.bin" || true
equals "-r: код возврата 0" "$(cat "$D/rc.txt")" "0"
has "-r: записал копию" "write $D/old-slot.bin chainloader" "$D/mtd.log"
equals "-r: в слоте снова старый загрузчик" \
	"$(sha256sum "$D/dev/mtd1" | awk '{ print $1 }')" \
	"$(sha256sum "$D/old-slot.bin" | awk '{ print $1 }')"

# 13. Без перезагрузки
D="$TMP/r13"
make_router "$D"
FAKE_SYS_MODULE=1 run_flash "$D" -y -n -i "$SLOT_IMAGE" || true
equals "-n: код возврата 0" "$(cat "$D/rc.txt")" "0"
empty_file "-n: без перезагрузки" "$D/reboot.log"
has "-n: предупредил про reboot" "начнёт работать после reboot" "$D/out.txt"

# 14. Другая раскладка UBI
D="$TMP/r14"
make_router "$D" "econet,xr1710g-ubi" "1d9c0000"
FAKE_SYS_MODULE=1 run_flash "$D" -y -n -i "$SLOT_IMAGE" || true
has "раскладка 1.5 распознана" "UBI 1.5" "$D/out.txt"

# 15. Образа нет и скачать нечем
D="$TMP/r15"
make_router "$D"
FAKE_SYS_MODULE=1 run_flash "$D" -y -i "$D/missing.bin" || true
equals "нет образа: ненулевой код" "$(cat "$D/rc.txt")" "1"
has "нет образа: сообщение" "не читается" "$D/out.txt"

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

	# 16. Штатная заливка загрузчика в рекавери wiro
	if start_mock --flavor wiro; then
		$SH "$UPLOAD" -i "127.0.0.1:$PORT" -y -w 20 > "$TMP/u1.txt" 2>&1 || true
		has "upload: увидел рекавери" "Рекавери:" "$TMP/u1.txt"
		has "upload: проверил sha256" "совпадает с xr1710g_260805" "$TMP/u1.txt"
		has "upload: образ принят" "Образ принят рекавери" "$TMP/u1.txt"
		has "upload: дождался конца" "готово" "$TMP/u1.txt"
		has "upload: подтвердил завершение" "Подтверждение отправлено" "$TMP/u1.txt"
		has "upload: передал ui_build" "ui_build=xr1710g-wiro-recovery" "$TMP/queries"
		has "upload: адресовал /upload/uboot" "/upload/uboot" "$TMP/queries"
		equals "upload: файл дошёл без искажений" \
			"$(sha256sum "$TMP/received.bin" | awk '{ print $1 }')" "$image_sum"
		stop_mock
	fi

	# 17. Рекавери без ui_build (сборка YYH2913)
	if start_mock --flavor new; then
		$SH "$UPLOAD" -i "127.0.0.1:$PORT" -y -w 20 > "$TMP/u2.txt" 2>&1 || true
		has "upload(new): образ принят" "Образ принят рекавери" "$TMP/u2.txt"
		hasnt "upload(new): без ui_build в URL" "ui_build" "$TMP/queries"
		has "upload(new): сам перезагрузится" "перезагрузится сам" "$TMP/u2.txt"
		stop_mock
	fi

	# 18. Не тот файл
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

	# 19. Слишком большой образ
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

	# 20. firmware без файла и отказ рекавери
	$SH "$UPLOAD" -t firmware -y -w 5 > "$TMP/u5.txt" 2>&1 || true
	has "upload: firmware требует -f" "укажите образ через -f" "$TMP/u5.txt"

	if start_mock --flavor wiro --fail; then
		$SH "$UPLOAD" -i "127.0.0.1:$PORT" -y -w 20 > "$TMP/u6.txt" 2>&1 || true
		has "upload: сообщил об отказе рекавери" "POST не удался" "$TMP/u6.txt"
		stop_mock
	fi

	# 21. Рекавери не отвечает
	$SH "$UPLOAD" -i "127.0.0.1:1" -y -w 2 > "$TMP/u7.txt" 2>&1 || true
	has "upload: сообщил про недоступное рекавери" "рекавери не ответило" "$TMP/u7.txt"
fi

printf '\n=== итог: PASS %d, FAIL %d ===\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
	exit 1
fi
