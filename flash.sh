#!/bin/sh
# shellcheck shell=dash
#
# XR1710G (Airoha AN7581): замена загрузчика в слоте chainloader прямо из
# работающей системы на сборку из https://github.com/YYH2913/http-uboot
#
# Слот закрыт на запись (в /sys/class/mtd/mtdN/flags нет MTD_WRITEABLE), поэтому
# скрипт временно снимает защиту модулем mtd-rw, пишет слот, проверяет запись
# обратным чтением и перезагружается. Модуль подходит потому, что vermagic этих
# ядер не содержит хеша конфигурации, а сам mtd-rw трогает только mtd->flags.
#
# Порядок работы:
#   * проверки модели, раздела и образа;
#   * резервная копия текущего слота в /root;
#   * снятие защиты (mtd-rw из системы, из репозитория или указанный через -m);
#   * mtd write + проверка sha256 обратным чтением (при несовпадении --
#     автоматический откат на копию);
#   * приведение сохранённого окружения U-Boot в соответствие новому загрузчику;
#   * rmmod и перезагрузка.
#
set -eu

SCRIPT_VERSION="2.0"
REPO_RAW="https://raw.githubusercontent.com/akorshun/xr1710g-uboot-recovery/main"
SLOT_NAME="chainloader"
SLOT_SIZE=1048576
RECOVERY_IP="192.168.255.1"
RECOVERY_MARK="HTTP recovery server listening"
UIMAGE_MAGIC="27051956"

IMAGE_NAME="xr1710g-chainloader-slot.bin"
IMAGE_SHA256="deaefed37c13f25eb551d60951cec7077adfd01c6964174d0aa938288d27be30"
MODULE_NAME="mtd-rw-6.18.41.ko"
MODULE_SHA256="afbe8712be475cdbf75375ab1d1b28264e9b0578f1a840b0267d52a3c5783a62"

# Тестовые хуки.
ROOT="${XR1710G_ROOT:-}"
BACKUP_DIR="${XR1710G_BACKUP_DIR:-$ROOT/root}"
PROC_MTD="$ROOT/proc/mtd"
FW_ENV_CONFIG="$ROOT/etc/fw_env.config"

MODE="flash"
DO_REBOOT=1
ASSUME_YES=0
IMAGE=""
MODULE=""
RESTORE_FILE=""
WORKDIR=""
SLOT_MTD=""
SLOT_DEV=""
BACKUP_FILE=""
LOADED_MODULE=0

say() { printf '%s\n' "$*"; }
warn() { printf 'ВНИМАНИЕ: %s\n' "$*" >&2; }
die() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }

cleanup() {
	if [ "$LOADED_MODULE" = 1 ]; then
		rmmod mtd_rw 2>/dev/null || rmmod mtd-rw 2>/dev/null || true
	fi
	if [ -n "$WORKDIR" ]; then
		rm -rf "$WORKDIR"
	fi
	return 0
}
trap cleanup EXIT HUP INT TERM

usage() {
	cat <<USAGE
XR1710G: прошивка загрузчика из работающей системы (версия $SCRIPT_VERSION)

Использование: flash.sh [опции]

  -i <файл>   образ слота (по умолчанию $IMAGE_NAME
              рядом со скриптом, из /tmp или скачивается с GitHub)
  -m <файл>   mtd-rw.ko, если в системе нет kmod-mtd-rw
  -r <файл>   откат: записать указанную копию слота обратно
  -b          ничего не писать: только проверки, копия слота и подсказки
  -n          не перезагружать после записи
  -y          не спрашивать подтверждение
  -h          эта справка
USAGE
}

confirm() {
	if [ "$ASSUME_YES" = 1 ]; then
		return 0
	fi
	if ! (: < /dev/tty) 2>/dev/null; then
		die "нет доступа к терминалу для подтверждения, перезапустите с -y"
	fi
	printf '%s [y/N]: ' "$1"
	read -r answer < /dev/tty || answer=""
	case "$answer" in
	y | Y | yes | YES | да | Да | ДА) return 0 ;;
	esac
	die "отменено пользователем"
}

check_tools() {
	missing=""
	for tool in dd strings sed awk grep sha256sum head mtd insmod fw_printenv; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			missing="$missing $tool"
		fi
	done
	if [ -n "$missing" ]; then
		die "в системе нет инструментов:$missing"
	fi
	if ! command -v hexdump >/dev/null 2>&1 && ! command -v od >/dev/null 2>&1; then
		die "нужен hexdump или od, чтобы проверить заголовок образа"
	fi
}

# Первые четыре байта файла в hex: на роутере есть hexdump, в других системах od.
first4_hex() {
	if command -v hexdump >/dev/null 2>&1; then
		dd if="$1" bs=4 count=1 2>/dev/null | hexdump -v -e '1/1 "%02x"'
	else
		dd if="$1" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'
	fi
}

check_board() {
	model=""
	if [ -r "$ROOT/tmp/sysinfo/board_name" ]; then
		model=$(cat "$ROOT/tmp/sysinfo/board_name")
	elif [ -r "$ROOT/proc/device-tree/compatible" ]; then
		model=$(tr -d '\000' < "$ROOT/proc/device-tree/compatible")
	fi
	if [ -z "$model" ]; then
		die "не удалось определить модель устройства"
	fi
	case "$model" in
	*xr1710g*) say "Устройство:            $model" ;;
	*) die "это не XR1710G, а '$model' -- скрипт рассчитан только на XR1710G" ;;
	esac
}

find_mtd() {
	if [ ! -r "$PROC_MTD" ]; then
		die "нет $PROC_MTD"
	fi
	awk -v want="\"$1\"" '$4 == want { sub(":", "", $1); print $1; exit }' "$PROC_MTD"
}

mtd_size() {
	awk -v want="$1:" '$1 == want { print $2; exit }' "$PROC_MTD"
}

# Раскладка UBI по адресу конца раздела ubi (как в селекторе рекавери).
detect_layout() {
	start=0
	end=0
	while read -r dev size _ name; do
		dev=${dev%:}
		case "$dev" in mtd*) ;; *) continue ;; esac
		if [ -z "$size" ]; then
			continue
		fi
		size=$((0x$size))
		if [ "$name" = '"ubi"' ]; then
			end=$((start + size))
			break
		fi
		start=$((start + size))
	done < "$PROC_MTD"
	if [ "$end" = "0" ]; then
		echo "не найдена"
	elif [ "$end" = "$((0x1be00000))" ]; then
		echo "UBI 2.0 (конец 0x1be00000)"
	elif [ "$end" = "$((0x1e0c0000))" ]; then
		echo "UBI 1.5 (конец 0x1e0c0000)"
	elif [ "$end" = "$((0x1fe00000))" ]; then
		echo "UBI 1.0 (конец 0x1fe00000)"
	else
		printf 'нестандартная (конец 0x%x)\n' "$end"
	fi
}

find_slot() {
	SLOT_MTD=$(find_mtd "$SLOT_NAME")
	if [ -z "$SLOT_MTD" ]; then
		die "в /proc/mtd нет раздела \"$SLOT_NAME\": такая раскладка не поддерживается,
       прошивайте загрузчик через UART/TFTP (см. README)"
	fi
	size=$(mtd_size "$SLOT_MTD")
	if [ "$((0x$size))" != "$SLOT_SIZE" ]; then
		die "раздел $SLOT_NAME имеет размер 0x$size, ожидался 0x100000"
	fi
	SLOT_DEV="$ROOT/dev/$SLOT_MTD"
	if [ ! -r "$SLOT_DEV" ]; then
		die "нет доступа к $SLOT_DEV"
	fi
	say "Слот загрузчика:       $SLOT_MTD ($SLOT_DEV), 1 МиБ"
}

sha_of() {
	sha256sum "$1" | awk '{ print $1 }'
}

# Версия U-Boot из файла или дампа слота.
uboot_version() {
	strings -n 8 "$1" | grep -E "^U-Boot 20[0-9][0-9]\." | head -n 1
}

show_current() {
	dump="$WORKDIR/slot.bin"
	dd if="$SLOT_DEV" of="$dump" bs=65536 count=16 2>/dev/null ||
		die "не удалось прочитать $SLOT_DEV"
	cur=$(uboot_version "$dump")
	if [ -z "$cur" ]; then
		cur="не определён"
	fi
	say "Текущий загрузчик:     $cur"
	CURRENT_DUMP="$dump"
}

backup_slot() {
	mkdir -p "$BACKUP_DIR"
	stamp=$(date "+%Y%m%d-%H%M%S")
	BACKUP_FILE="$BACKUP_DIR/xr1710g-chainloader-$stamp.bin"
	cp "$CURRENT_DUMP" "$BACKUP_FILE"
	say "Резервная копия:       $BACKUP_FILE"
	say "  sha256:              $(sha_of "$BACKUP_FILE")"
	say "  забрать на ПК:       scp root@<адрес роутера>:$BACKUP_FILE ."
}

# Ищем файл рядом со скриптом, в /tmp или качаем из репозитория.
resolve_file() {
	name="$1"
	sub="$2"
	script_dir=$(dirname "$0")
	for candidate in "$script_dir/$sub/$name" "$script_dir/$name" "$ROOT/tmp/$name"; do
		if [ -r "$candidate" ]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	target="$WORKDIR/$name"
	if ! wget -q -O "$target" "$REPO_RAW/$sub/$name" 2>/dev/null; then
		rm -f "$target"
		return 1
	fi
	printf '%s\n' "$target"
}

check_image() {
	if [ -z "$IMAGE" ]; then
		IMAGE=$(resolve_file "$IMAGE_NAME" firmware) || die "не нашёл $IMAGE_NAME рядом со скриптом и не смог скачать
       (у роутера нет интернета?). Положите файл в /tmp или укажите через -i"
	fi
	if [ ! -r "$IMAGE" ]; then
		die "файл $IMAGE не читается"
	fi
	size=$(wc -c < "$IMAGE" | tr -d ' ')
	sum=$(sha_of "$IMAGE")
	say "Новый образ:           $IMAGE"
	say "  размер:              $size байт"
	say "  sha256:              $sum"
	if [ "$size" -gt "$SLOT_SIZE" ]; then
		die "образ больше слота (1 МиБ)"
	fi
	magic=$(first4_hex "$IMAGE")
	if [ "$magic" != "$UIMAGE_MAGIC" ]; then
		die "это не образ слота: нет legacy-заголовка uImage (magic $magic).
       Нужен $IMAGE_NAME, а не u-boot.bin или *.itb"
	fi
	if [ "$sum" = "$IMAGE_SHA256" ]; then
		say "  проверка:            совпадает с релизом xr1710g_260805"
	else
		warn "образ не совпадает с известным релизом xr1710g_260805 -- убедитесь в его происхождении"
	fi
	ver=$(uboot_version "$IMAGE")
	if [ -n "$ver" ]; then
		say "  версия:              $ver"
	fi
	if ! strings -n 8 "$IMAGE" | grep -q "$RECOVERY_MARK"; then
		warn "в образе нет HTTP-рекавери: в него нельзя будет войти кнопкой reset"
		confirm "Всё равно прошить такой загрузчик?"
	fi
}

slot_is_writable() {
	flags_file="$ROOT/sys/class/mtd/$SLOT_MTD/flags"
	if [ ! -r "$flags_file" ]; then
		return 1
	fi
	flags=$(cat "$flags_file")
	case "$flags" in
	0x*) ;;
	*) flags="0x$flags" ;;
	esac
	if [ "$(( flags & 0x400 ))" -ne 0 ]; then
		return 0
	fi
	return 1
}

kernel_vermagic() {
	ko=$(find "$ROOT/lib/modules" -name "*.ko" 2>/dev/null | head -n 1)
	if [ -z "$ko" ]; then
		return 1
	fi
	strings -n 8 "$ko" | sed -n 's/^vermagic=//p' | head -n 1
}

module_vermagic() {
	strings -n 8 "$1" | sed -n 's/^vermagic=//p' | head -n 1
}

unlock_slot() {
	if slot_is_writable; then
		say "Защита раздела:        уже снята"
		return 0
	fi
	say "Защита раздела:        включена, снимаю модулем mtd-rw"
	if insmod mtd-rw i_want_a_brick=1 2>/dev/null; then
		LOADED_MODULE=1
	else
		if [ -z "$MODULE" ]; then
			MODULE=$(resolve_file "$MODULE_NAME" firmware) ||
				die "в системе нет kmod-mtd-rw, и я не нашёл $MODULE_NAME
       рядом со скриптом и не смог скачать. Возьмите его из репозитория
       (firmware/$MODULE_NAME) и укажите через -m"
		fi
		if [ ! -r "$MODULE" ]; then
			die "файл модуля $MODULE не читается"
		fi
		msum=$(sha_of "$MODULE")
		say "  модуль:              $MODULE"
		say "  sha256:              $msum"
		if [ "$msum" != "$MODULE_SHA256" ]; then
			warn "модуль не совпадает с проверенным из репозитория"
		fi
		kver=$(kernel_vermagic) || die "не удалось прочитать vermagic ядра"
		mver=$(module_vermagic "$MODULE")
		say "  vermagic ядра:       $kver"
		say "  vermagic модуля:     $mver"
		if [ "$kver" != "$mver" ]; then
			die "vermagic не совпадает: этот модуль собран для другого ядра.
       Возьмите kmod-mtd-rw из kmods-репозитория своей сборки"
		fi
		if ! insmod "$MODULE" i_want_a_brick=1; then
			die "insmod не отработал: модуль не загрузился"
		fi
		LOADED_MODULE=1
	fi
	if ! slot_is_writable; then
		die "модуль загрузился, но раздел так и не стал доступен для записи"
	fi
	say "  результат:           раздел открыт для записи"
}

# Проверка записи обратным чтением: сверяем ровно столько байт, сколько в образе.
verify_written() {
	file="$1"
	size=$(wc -c < "$file" | tr -d ' ')
	blocks=$(( (size + 4095) / 4096 ))
	got=$(dd if="$SLOT_DEV" bs=4096 count="$blocks" 2>/dev/null | head -c "$size" | sha256sum | awk '{ print $1 }')
	want=$(sha_of "$file")
	if [ "$got" != "$want" ]; then
		return 1
	fi
	return 0
}

write_slot() {
	file="$1"
	say ""
	say "Записываю $file в раздел $SLOT_NAME ..."
	if ! mtd write "$file" "$SLOT_NAME"; then
		die "mtd write не отработал. Слот мог остаться в промежуточном состоянии --
       не перезагружайтесь и повторите запись или верните копию:
       sh flash.sh -r $BACKUP_FILE"
	fi
	if verify_written "$file"; then
		say "Проверка чтением:      совпало ($(sha_of "$file"))"
		return 0
	fi
	warn "обратное чтение не совпало с образом, откатываюсь на резервную копию"
	if [ -n "$BACKUP_FILE" ] && [ -r "$BACKUP_FILE" ]; then
		if mtd write "$BACKUP_FILE" "$SLOT_NAME" && verify_written "$BACKUP_FILE"; then
			die "запись не удалась, но копия восстановлена и проверена -- роутер загрузится как раньше"
		fi
		die "запись не удалась И откат не подтвердился. НЕ перезагружайтесь,
       повторите: mtd write $BACKUP_FILE $SLOT_NAME"
	fi
	die "запись не удалась, резервной копии нет"
}

# Сохранённое окружение переопределяет встроенное целиком, поэтому bootcmd
# должен соответствовать новому загрузчику. Если окружение невалидно, оставляем
# как есть: загрузчик возьмёт свои значения по умолчанию.
fix_env() {
	if [ ! -r "$FW_ENV_CONFIG" ]; then
		say "Окружение U-Boot:      $FW_ENV_CONFIG отсутствует, не трогаю"
		return 0
	fi
	if fw_printenv 2>&1 >/dev/null | grep -qi "bad crc"; then
		say "Окружение U-Boot:      пустое (Bad CRC) -- загрузчик возьмёт свои значения"
		return 0
	fi
	cur=$(fw_printenv bootcmd 2>/dev/null | sed -n 's/^bootcmd=//p' | head -n 1)
	want=$(strings -n 3 "$IMAGE" | sed -n 's/^bootcmd=//p' | head -n 1)
	if [ -z "$want" ]; then
		warn "не нашёл bootcmd по умолчанию в новом образе, окружение не меняю"
		return 0
	fi
	if [ "$cur" = "$want" ]; then
		say "Окружение U-Boot:      bootcmd уже '$want'"
		return 0
	fi
	say "Окружение U-Boot:      bootcmd '$cur' -> '$want'"
	if ! fw_setenv bootcmd "$want"; then
		warn "не удалось поправить bootcmd: проверьте его вручную после перезагрузки"
		return 0
	fi
	got=$(fw_printenv bootcmd 2>/dev/null | sed -n 's/^bootcmd=//p' | head -n 1)
	if [ "$got" != "$want" ]; then
		warn "bootcmd после записи -- '$got', ожидалось '$want'"
	fi
}

next_steps() {
	cat <<STEPS

Готово. После перезагрузки:
  * система загрузится как обычно, но уже новым загрузчиком;
  * при неудачной загрузке он сам поднимет веб-рекавери на http://$RECOVERY_IP
    (ПК в порт 10GbE, сетевая карта в режиме DHCP);
  * войти в рекавери принудительно: выключить роутер, включить и держать reset,
    отпустить, когда индикатор состояния сменит ровный красный на "бегущий";
  * прошивку можно заливать тем же рекавери (upload.sh / upload.ps1 с ПК).

Откат на прежний загрузчик:
  sh flash.sh -r $BACKUP_FILE
STEPS
}

hints_only() {
	cat <<STEPS

Ничего не изменено. Возможные дальнейшие шаги:
  * прошить новый загрузчик:            sh flash.sh
  * вернуть прежний из копии:           sh flash.sh -r $BACKUP_FILE
  * войти в рекавери текущего загрузчика: выключить, включить и держать reset,
    затем открыть http://$RECOVERY_IP
STEPS
}

main() {
	if [ "$(id -u)" != "0" ]; then
		die "нужны права root"
	fi
	WORKDIR=$(mktemp -d 2>/dev/null || mktemp -d -t xr1710g)
	say "=== XR1710G: прошивка загрузчика (flash.sh $SCRIPT_VERSION) ==="
	check_tools
	check_board
	find_slot
	say "Раскладка UBI:         $(detect_layout)"
	show_current
	backup_slot

	case "$MODE" in
	hints)
		hints_only
		return 0
		;;
	restore)
		IMAGE="$RESTORE_FILE"
		check_image
		confirm "Записать $IMAGE обратно в слот загрузчика?"
		unlock_slot
		write_slot "$IMAGE"
		;;
	flash)
		check_image
		say ""
		say "Слот будет перезаписан: 1 МиБ по смещению 0x600000."
		say "Прошивка, настройки и данные не затрагиваются."
		confirm "Прошить новый загрузчик?"
		unlock_slot
		write_slot "$IMAGE"
		fix_env
		next_steps
		;;
	esac

	if [ "$DO_REBOOT" = 1 ]; then
		say ""
		confirm "Перезагрузить роутер сейчас?"
		say "Перезагрузка..."
		cleanup
		sync
		reboot
	else
		say ""
		say "Перезагрузка не выполнялась, новый загрузчик начнёт работать после reboot."
	fi
}

while getopts "i:m:r:bnyh" opt; do
	case "$opt" in
	i) IMAGE="$OPTARG" ;;
	m) MODULE="$OPTARG" ;;
	r)
		MODE="restore"
		RESTORE_FILE="$OPTARG"
		;;
	b)
		MODE="hints"
		DO_REBOOT=0
		;;
	n) DO_REBOOT=0 ;;
	y) ASSUME_YES=1 ;;
	h)
		usage
		exit 0
		;;
	*)
		usage >&2
		exit 1
		;;
	esac
done
shift $((OPTIND - 1))

main "$@"
