#!/bin/sh
# shellcheck shell=dash
#
# XR1710G: загрузка образа в HTTP-рекавери U-Boot с ПК.
# Запускать, когда роутер уже в рекавери (http://192.168.255.1).
#
#   ./upload.sh                 -- залить новый загрузчик (target uboot)
#   ./upload.sh -t firmware -l 2.0 -f openwrt-...-sysupgrade.itb
#
set -eu

SCRIPT_VERSION="1.0"
HOST="192.168.255.1"
TARGET="uboot"
LAYOUT="2.0"
IMAGE=""
ASSUME_YES=0
WAIT_SECONDS=180
SLOT_IMAGE="xr1710g-chainloader-slot.bin"
SLOT_SHA256="deaefed37c13f25eb551d60951cec7077adfd01c6964174d0aa938288d27be30"
SLOT_URL="https://github.com/akorshun/xr1710g-uboot-recovery/raw/main/firmware/xr1710g-chainloader-slot.bin"
SLOT_MAX=1048576
WORKDIR=""

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
XR1710G: заливка образа в HTTP-рекавери (версия $SCRIPT_VERSION)

Использование: upload.sh [опции]

  -i <адрес>   адрес рекавери, по умолчанию $HOST
  -t <цель>    uboot (по умолчанию) или firmware
  -l <версия>  раскладка UBI для firmware: 2.0 (по умолчанию), 1.5 или 1.0
  -f <файл>    образ; без него берётся firmware/$SLOT_IMAGE
               из репозитория рядом со скриптом или скачивается с GitHub
  -w <сек>     сколько ждать появления рекавери, по умолчанию $WAIT_SECONDS
  -y           не спрашивать подтверждение
  -h           эта справка
USAGE
}

json_num() {
	sed -n 's/.*"'"$1"'":[[:space:]]*\([-0-9][0-9]*\).*/\1/p' | head -n 1
}

json_str() {
	sed -n 's/.*"'"$1"'":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

confirm() {
	if [ "$ASSUME_YES" = 1 ]; then
		return 0
	fi
	printf '%s [y/N]: ' "$1"
	if [ -t 0 ]; then
		read -r answer || answer=""
	elif (: < /dev/tty) 2>/dev/null; then
		read -r answer < /dev/tty || answer=""
	else
		printf '\n'
		die "нет терминала для подтверждения, запустите с -y"
	fi
	case "$answer" in
	y | Y | yes | YES | да | Да | ДА) return 0 ;;
	esac
	die "отменено пользователем"
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{ print $1 }'
	else
		echo ""
	fi
}

resolve_image() {
	if [ -n "$IMAGE" ]; then
		if [ ! -r "$IMAGE" ]; then
			die "файл $IMAGE не найден"
		fi
		return 0
	fi
	if [ "$TARGET" != "uboot" ]; then
		die "для цели firmware укажите образ через -f"
	fi
	script_dir=$(dirname "$0")
	if [ -r "$script_dir/firmware/$SLOT_IMAGE" ]; then
		IMAGE="$script_dir/firmware/$SLOT_IMAGE"
		return 0
	fi
	IMAGE="$WORKDIR/$SLOT_IMAGE"
	say "Скачиваю $SLOT_IMAGE ..."
	if ! curl -fsSL -o "$IMAGE" "$SLOT_URL"; then
		die "не удалось скачать $SLOT_URL"
	fi
}

check_image() {
	size=$(wc -c < "$IMAGE" | tr -d ' ')
	sum=$(sha256_of "$IMAGE")
	say "Образ:                 $IMAGE"
	say "  размер:              $size байт"
	if [ -n "$sum" ]; then
		say "  sha256:              $sum"
	fi
	if [ "$TARGET" = "uboot" ]; then
		if [ "$size" -gt "$SLOT_MAX" ]; then
			die "образ загрузчика больше 1 МиБ, рекавери его отвергнет"
		fi
		magic=$(dd if="$IMAGE" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d " \n")
		if [ "$magic" != "27051956" ]; then
			die "это не образ слота: нет legacy-заголовка uImage (magic $magic).
       Нужен xr1710g-chainloader-slot.bin, а не u-boot.bin или *.itb"
		fi
		if [ -n "$sum" ] && [ "$sum" = "$SLOT_SHA256" ]; then
			say "  проверка:            совпадает с xr1710g_260805 из YYH2913/http-uboot"
		elif [ -n "$sum" ]; then
			warn "образ не совпадает с известным xr1710g_260805, убедитесь в его происхождении"
		fi
	else
		if [ "$size" -lt 1048576 ]; then
			die "образ прошивки меньше 1 МиБ, это не sysupgrade.itb"
		fi
		say "  раскладка UBI:       $LAYOUT (должна совпадать с DTS образа!)"
	fi
}

wait_recovery() {
	say ""
	printf 'Жду рекавери на http://%s' "$HOST"
	waited=0
	while [ "$waited" -lt "$WAIT_SECONDS" ]; do
		if ABOUT=$(curl -fsS --max-time 3 "http://$HOST/about" 2>/dev/null); then
			printf '\n'
			return 0
		fi
		printf '.'
		sleep 2
		waited=$((waited + 2))
	done
	printf '\n'
	die "рекавери не ответило за $WAIT_SECONDS с.
       Проверьте: ПК в порту 10GbE, адрес получен по DHCP (192.168.255.2),
       роутер в рекавери (кнопка reset при включении или flash.sh на роутере)"
}

show_recovery() {
	uboot=$(printf '%s' "$ABOUT" | json_str u_boot)
	detected=$(printf '%s' "$ABOUT" | json_str detected_layout)
	UI_BUILD=$(printf '%s' "$ABOUT" | json_str ui_build)
	if [ -n "$uboot" ]; then
		say "Рекавери:              $uboot"
	fi
	if [ -n "$detected" ]; then
		say "Текущая раскладка:     $detected"
	fi
	if [ -n "$UI_BUILD" ]; then
		say "UI build:              $UI_BUILD"
	fi
}

build_url() {
	url="http://$HOST/upload/$TARGET"
	sep="?"
	if [ -n "$UI_BUILD" ]; then
		url="$url${sep}ui_build=$UI_BUILD"
		sep="&"
	fi
	if [ "$TARGET" = "firmware" ]; then
		url="$url${sep}layout=$LAYOUT"
	fi
	echo "$url"
}

post_image() {
	url=$(build_url)
	say ""
	say "POST $url"
	if curl -fsS --max-time 600 -X POST \
		-H "Content-Type: application/octet-stream" \
		--data-binary "@$IMAGE" "$url" > "$WORKDIR/post.out" 2>"$WORKDIR/post.err"; then
		say "Образ принят рекавери."
	else
		rc=$?
		sed 's/^/  /' "$WORKDIR/post.err" >&2 || true
		die "POST не удался (curl $rc). Флеш-память не изменена, если рекавери
       отвергло образ на проверке; проверьте состояние на http://$HOST"
	fi
	if [ -s "$WORKDIR/post.out" ]; then
		head -c 400 "$WORKDIR/post.out"
		printf '\n'
	fi
}

poll_status() {
	say ""
	say "Ход операции:"
	last=""
	tries=0
	generation=0
	while [ "$tries" -lt 150 ]; do
		tries=$((tries + 1))
		if ! st=$(curl -fsS --max-time 5 "http://$HOST/status" 2>/dev/null); then
			sleep 2
			continue
		fi
		erase_done=$(printf '%s' "$st" | json_num erase_done)
		erase_total=$(printf '%s' "$st" | json_num erase_total)
		write_done=$(printf '%s' "$st" | json_num write_done)
		write_total=$(printf '%s' "$st" | json_num write_total)
		in_progress=$(printf '%s' "$st" | json_num in_progress)
		ok=$(printf '%s' "$st" | json_num ok)
		err=$(printf '%s' "$st" | json_num error)
		line="  стирание ${erase_done:-0}/${erase_total:-0}, запись ${write_done:-0}/${write_total:-0}"
		if [ "$line" != "$last" ]; then
			say "$line"
			last="$line"
		fi
		if [ "${err:-0}" != "0" ]; then
			stage=$(printf '%s' "$st" | json_str error_stage)
			detail=$(printf '%s' "$st" | json_str validation_detail)
			die "рекавери вернуло ошибку (code ${err}, stage '${stage}', detail '${detail}')"
		fi
		if [ "${ok:-0}" = "1" ] && [ "${in_progress:-1}" = "0" ]; then
			generation=$(printf '%s' "$st" | json_num completion_generation)
			say "  готово"
			break
		fi
		sleep 2
	done
	if [ "${generation:-0}" -gt 0 ]; then
		curl -fsS --max-time 5 "http://$HOST/status-ack/$generation" >/dev/null 2>&1 || true
		say "Подтверждение отправлено, роутер перезагружается."
	else
		say "Роутер перезагрузится сам."
	fi
}

while getopts "i:t:l:f:w:yh" opt; do
	case "$opt" in
	i) HOST="$OPTARG" ;;
	t) TARGET="$OPTARG" ;;
	l) LAYOUT="$OPTARG" ;;
	f) IMAGE="$OPTARG" ;;
	w) WAIT_SECONDS="$OPTARG" ;;
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

case "$TARGET" in
uboot | firmware) ;;
*) die "неизвестная цель '$TARGET', допустимы uboot и firmware" ;;
esac
case "$LAYOUT" in
1.0 | 1.5 | 2.0) ;;
*) die "неизвестная раскладка '$LAYOUT', допустимы 2.0, 1.5 и 1.0" ;;
esac

if ! command -v curl >/dev/null 2>&1; then
	die "нужен curl"
fi

WORKDIR=$(mktemp -d 2>/dev/null || mktemp -d -t xr1710g)
ABOUT=""
UI_BUILD=""

say "=== XR1710G: заливка в HTTP-рекавери (upload.sh $SCRIPT_VERSION) ==="
resolve_image
check_image
wait_recovery
show_recovery

if [ "$TARGET" = "uboot" ]; then
	confirm "Записать этот образ в слот загрузчика (1 МиБ) на $HOST?"
else
	confirm "Перезаписать UBI ($LAYOUT) прошивкой на $HOST? Данные будут стёрты!"
fi

post_image
poll_status
