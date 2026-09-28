#!/usr/bin/env python3
"""Проверка образа слота chainloader для XR1710G.

Рекавери перед записью проверяет legacy-заголовок uImage и его CRC, поэтому
образ в репозитории должен быть корректным. Скрипт проверяет то же самое:
  * размер не больше 1 МиБ (размер слота);
  * magic 0x27051956, CRC заголовка и CRC данных;
  * внутри есть FIT (по нему рекавери и загрузчик находят вторую ступень);
  * печатает найденную версию U-Boot.

Запуск: python3 tests/check_slot.py firmware/xr1710g-chainloader-slot.bin
"""

import re
import struct
import sys
import zlib

SLOT_MAX = 1024 * 1024
UIMAGE_MAGIC = 0x27051956
FDT_MAGIC = b"\xd0\x0d\xfe\xed"


def fail(message):
    print("ОШИБКА: %s" % message)
    sys.exit(1)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    with open(path, "rb") as handle:
        data = handle.read()

    print("файл:            %s" % path)
    print("размер:          %d байт" % len(data))
    if len(data) > SLOT_MAX:
        fail("образ больше 1 МиБ, в слот не поместится")
    if len(data) < 64:
        fail("образ слишком мал для заголовка uImage")

    header = bytearray(data[:64])
    magic, hcrc, _, size, load, entry, dcrc = struct.unpack(">IIIIIII", header[:28])
    name = header[32:64].split(b"\x00")[0].decode("latin1")
    if magic != UIMAGE_MAGIC:
        fail("нет legacy-заголовка uImage (magic %#x)" % magic)

    header[4:8] = b"\x00\x00\x00\x00"
    calc_hcrc = zlib.crc32(bytes(header)) & 0xFFFFFFFF
    if calc_hcrc != hcrc:
        fail("CRC заголовка %#010x, посчитано %#010x" % (hcrc, calc_hcrc))

    payload = data[64:64 + size]
    if len(payload) != size:
        fail("в файле %d байт данных, в заголовке заявлено %d" % (len(payload), size))
    calc_dcrc = zlib.crc32(payload) & 0xFFFFFFFF
    if calc_dcrc != dcrc:
        fail("CRC данных %#010x, посчитано %#010x" % (dcrc, calc_dcrc))

    print("заголовок:       '%s', load %#x, entry %#x, данных %d байт" % (name, load, entry, size))
    print("CRC:             заголовок %#010x, данные %#010x -- совпадают" % (hcrc, dcrc))

    fit_offset = data.find(FDT_MAGIC)
    if fit_offset < 0:
        fail("внутри образа нет FIT, вторая ступень не найдётся")
    print("FIT:             смещение %#x" % fit_offset)

    versions = sorted(set(re.findall(rb"U-Boot 20[0-9][0-9]\.[0-9][0-9][^\x00\n]{0,80}", data)))
    if not versions:
        fail("в образе нет строки версии U-Boot")
    for version in versions[:4]:
        print("версия:          %s" % version.decode("latin1"))

    if b"HTTP recovery server listening" not in data:
        fail("в образе нет HTTP-рекавери -- это не та сборка")
    print("HTTP-рекавери:   есть")
    print("итог:            образ пригоден для заливки в слот chainloader")
    return 0


if __name__ == "__main__":
    sys.exit(main())
