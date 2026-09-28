#!/bin/sh
# shellcheck shell=dash
#
# XR1710G (Airoha AN7581) -- перевод роутера в HTTP-рекавери загрузчика,
# чтобы заменить заводской/сторонний U-Boot на сборку из
# https://github.com/YYH2913/http-uboot
#
# Раздел chainloader в работающей системе доступен только для чтения
# (в /proc/mtd у него flags=0x0), а модуль mtd-rw для этого ядра недоступен,
# поэтому записать загрузчик прямо из Linux нельзя. Скрипт делает то, что
# возможно и безопасно:
#   * проверяет модель, разделы и то, что текущий загрузчик умеет HTTP-рекавери;
#   * сохраняет копию слота chainloader в /root;
#   * прописывает в сохранённое окружение U-Boot bootcmd=http_recovery;
#   * перезагружает роутер -- он поднимает рекавери на http://192.168.255.1
#     со встроенным DHCP-сервером.
# Новый загрузчик заливается туда по сети (POST /upload/uboot), и после успешной
# записи рекавери само очищает ubootenv/ubootenv2, поэтому bootcmd возвращается
# к заводскому значению.
#
set -eu

SCRIPT_VERSION="1.0"
RECOVERY_IP="192.168.255.1"
SLOT_NAME="chainloader"
SLOT_SIZE=1048576
SLOT_IMAGE="xr1710g-chainloader-slot.bin"
RECOVERY_BOOTCMD="http_recovery"
RECOVERY_MARK="HTTP recovery server listening"
ENV_KEEP='^(baudrate|loadaddr|bootargs|bootconf|boot_ubi|boot_production|ubi_read_production|uboot_ofs|recovery_[a-z_]+)='

# Тестовые хуки: префикс корня и каталог резервных копий.
ROOT="${XR1710G_ROOT:-}"
BACKUP_DIR="${XR1710G_BACKUP_DIR:-$ROOT/root}"
PROC_MTD="$ROOT/proc/mtd"
FW_ENV_CONFIG="$ROOT/etc/fw_env.config"

MODE="recovery"
DO_REBOOT=1
ASSUME_YES=0
WORKDIR=""
BACKUP_FILE=""
SLOT_DUMP=""
DEF_ENV=""
DEF_BOOTCMD=""

say() { printf '%s\n' "$*"; }
warn() { printf 'ВНИМАНИЕ: %s\n' "$*" >&2; }
die() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }

cleanup() {
	if [ -n "$WORKDIR" ]; then
		rm -rf "$WORKDIR"
	fi
	return 0
}
trap cleanup EXIT HUP INT TERM

usage() {
	cat <<USAGE
XR1710G: вход в HTTP-рекавери U-Boot (версия $SCRIPT_VERSION)

Использование: flash.sh [опции]

  -y   не спрашивать подтверждение
  -n   только подготовка: записать окружение, но не перезагружать
  -b   ничего не менять во флеш-памяти: только проверки, резервная копия
       слота и инструкция по входу в рекавери кнопкой reset
  -r   восстановить заводское значение bootcmd (отмена, обычная загрузка)
  -h   эта справка
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
	for tool in dd strings sed awk grep sha256sum fw_printenv fw_setenv; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			missing="$missing $tool"
		fi
	done
	if [ -n "$missing" ]; then
		die "в системе нет инструментов:$missing"
	fi
	if ! fw_setenv --help 2>&1 | grep -q -- "-s, --script"; then
		die "fw_setenv не поддерживает пакетный режим (-s), обновите uboot-envtools"
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

# Номер mtd-раздела по имени из /proc/mtd.
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

read_slot() {
	slot_mtd=$(find_mtd "$SLOT_NAME")
	if [ -z "$slot_mtd" ]; then
		die "в /proc/mtd нет раздела \"$SLOT_NAME\" -- такая раскладка не поддерживается"
	fi
	size=$(mtd_size "$slot_mtd")
	if [ "$((0x$size))" != "$SLOT_SIZE" ]; then
		die "раздел $SLOT_NAME имеет размер 0x$size, ожидался 0x100000"
	fi
	slot_dev="$ROOT/dev/$slot_mtd"
	if [ ! -r "$slot_dev" ]; then
		die "нет доступа к $slot_dev"
	fi
	SLOT_DUMP="$WORKDIR/slot.bin"
	if ! dd if="$slot_dev" of="$SLOT_DUMP" bs=65536 count=16 2>/dev/null; then
		die "не удалось прочитать $slot_dev"
	fi
	say "Слот загрузчика:       $slot_mtd ($slot_dev), 1 МиБ"
}

check_slot() {
	cur_uboot=$(strings -n 8 "$SLOT_DUMP" | grep -E "^U-Boot 20[0-9][0-9]\..*\(.*\)$" | head -n 1)
	if [ -z "$cur_uboot" ]; then
		cur_uboot="не определён"
	fi
	say "Текущий загрузчик:     $cur_uboot"
	if ! strings -n 8 "$SLOT_DUMP" | grep -q "$RECOVERY_MARK"; then
		die "в текущем загрузчике нет HTTP-рекавери, перезагрузка не даст веб-интерфейса;
       прошивайте новый загрузчик через UART/TFTP или nandwrite, см. README"
	fi
	DEF_ENV=$(strings -n 3 "$SLOT_DUMP" |
		grep -E "^[a-z][a-z0-9_]*=" |
		grep -Ev "^(mtdids|mtdparts|wiro_env_)" |
		grep -v "=$" | sort -u)
	DEF_BOOTCMD=$(printf '%s\n' "$DEF_ENV" | sed -n 's/^bootcmd=//p' | head -n 1)
	if [ -n "$DEF_BOOTCMD" ]; then
		say "Заводской bootcmd:     $DEF_BOOTCMD"
	else
		warn "в загрузчике не найден bootcmd по умолчанию"
	fi
}

check_env() {
	if [ ! -r "$FW_ENV_CONFIG" ]; then
		die "нет $FW_ENV_CONFIG -- окружение U-Boot не настроено"
	fi
	envdevs=$(grep -v "^[[:space:]]*#" "$FW_ENV_CONFIG" | awk 'NF { print $1 }')
	if [ -z "$envdevs" ]; then
		die "$FW_ENV_CONFIG пуст"
	fi
	for dev in $envdevs; do
		if [ ! -e "$ROOT$dev" ]; then
			die "в $FW_ENV_CONFIG указан $dev, которого нет в системе"
		fi
	done
	say "Окружение U-Boot:      $(echo "$envdevs" | tr '\n' ' ')"
	if ! fw_printenv >/dev/null 2>&1; then
		die "fw_printenv не смог прочитать окружение"
	fi
}

backup_slot() {
	mkdir -p "$BACKUP_DIR"
	stamp=$(date "+%Y%m%d-%H%M%S")
	BACKUP_FILE="$BACKUP_DIR/xr1710g-chainloader-$stamp.bin"
	cp "$SLOT_DUMP" "$BACKUP_FILE"
	sum=$(sha256sum "$BACKUP_FILE" | awk '{ print $1 }')
	say "Резервная копия:       $BACKUP_FILE"
	say "  sha256:              $sum"
	say "  забрать на ПК:       scp root@<адрес роутера>:$BACKUP_FILE ."
}

write_env() {
	target_bootcmd="$1"
	env_script="$WORKDIR/env.txt"
	{
		printf '# flash.sh %s, %s\n' "$SCRIPT_VERSION" "$(date "+%Y-%m-%d %H:%M:%S")"
		printf 'bootcmd %s\n' "$target_bootcmd"
		printf '%s\n' "$DEF_ENV" | grep -E "$ENV_KEEP" | sed 's/^\([^=]*\)=/\1 /'
	} > "$env_script"
	say ""
	say "Записываю окружение U-Boot:"
	sed 's/^/  /' "$env_script"
	if ! fw_setenv -s "$env_script"; then
		die "fw_setenv не смог записать окружение"
	fi
	got=$(fw_printenv bootcmd 2>/dev/null | sed -n 's/^bootcmd=//p' | head -n 1)
	if [ "$got" != "$target_bootcmd" ]; then
		die "проверка не прошла: bootcmd='$got', ожидалось '$target_bootcmd'"
	fi
	say "Проверка:              bootcmd=$got"
}

next_steps_recovery() {
	cat <<STEPS

Дальше:
  1. Подключите ПК к порту 10GbE, сетевая карта -- в режиме DHCP
     (рекавери само выдаёт адрес 192.168.255.2).
  2. После перезагрузки откройте http://$RECOVERY_IP и в разделе обновления
     U-Boot залейте $SLOT_IMAGE, либо одной командой с ПК:

     curl -X POST --data-binary @$SLOT_IMAGE \\
       -H "Content-Type: application/octet-stream" \\
       http://$RECOVERY_IP/upload/uboot

     Готовые скрипты: upload.sh (Linux/macOS/Git Bash) и upload.ps1 (Windows)
     из репозитория -- они сами скачают образ, проверят sha256 и покажут прогресс.
  3. Рекавери запишет слот, очистит ubootenv/ubootenv2 и перезагрузится.
     Прошивка и данные не затрагиваются: роутер снова загрузит текущую систему,
     но уже новым загрузчиком.
  4. В новое рекавери вход такой же: кнопка reset при включении, адрес тот же.

Если что-то пойдёт не так: в том же рекавери залейте обратно резервную копию
слота ($BACKUP_FILE) -- это тоже очистит окружение и вернёт обычную загрузку.
STEPS
}

next_steps_button() {
	cat <<STEPS

Вход в рекавери кнопкой (флеш-память не изменялась):
  1. Подключите ПК к порту 10GbE, сетевая карта -- в режиме DHCP.
  2. Выключите роутер, включите и, когда замигает индикатор порта 10GbE,
     нажмите и держите reset. Отпустите, когда индикатор состояния сменит
     ровный красный на "бегущий" рекавери-режим.
  3. Откройте http://$RECOVERY_IP и залейте $SLOT_IMAGE в раздел обновления
     U-Boot (или запустите upload.sh / upload.ps1 с ПК).
STEPS
}

main() {
	if [ "$(id -u)" != "0" ]; then
		die "нужны права root"
	fi
	WORKDIR=$(mktemp -d 2>/dev/null || mktemp -d -t xr1710g)
	say "=== XR1710G: HTTP-рекавери U-Boot (flash.sh $SCRIPT_VERSION) ==="
	check_tools
	check_board
	read_slot
	check_slot
	say "Раскладка UBI:         $(detect_layout)"
	check_env
	backup_slot

	case "$MODE" in
	button)
		next_steps_button
		;;
	restore)
		if [ -z "$DEF_BOOTCMD" ]; then
			die "заводской bootcmd не прочитан из слота, восстановление невозможно"
		fi
		confirm "Вернуть bootcmd='$DEF_BOOTCMD' (обычная загрузка системы)?"
		write_env "$DEF_BOOTCMD"
		say ""
		say "Готово: следующая загрузка -- обычная."
		;;
	recovery)
		say ""
		say "Будет записано bootcmd=$RECOVERY_BOOTCMD: после перезагрузки роутер"
		say "поднимет веб-рекавери на http://$RECOVERY_IP вместо загрузки системы."
		say "Прошивка и данные при этом не стираются."
		confirm "Продолжить?"
		write_env "$RECOVERY_BOOTCMD"
		next_steps_recovery
		;;
	esac

	if [ "$DO_REBOOT" = 1 ]; then
		say ""
		confirm "Перезагрузить роутер сейчас?"
		say "Перезагрузка..."
		sync
		reboot
	else
		say ""
		say "Перезагрузка не выполнялась, изменения вступят в силу после reboot."
	fi
}

while getopts "ynbrh" opt; do
	case "$opt" in
	y) ASSUME_YES=1 ;;
	n) DO_REBOOT=0 ;;
	b)
		MODE="button"
		DO_REBOOT=0
		;;
	r) MODE="restore" ;;
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
