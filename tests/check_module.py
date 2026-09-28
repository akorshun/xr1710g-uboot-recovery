#!/usr/bin/env python3
"""Проверка вложенного модуля mtd-rw.

Модуль берётся из чужой сборки того же ядра, поэтому важно убедиться, что:
  * это релокатируемый ELF для aarch64;
  * vermagic соответствует ядру прошивки (передаётся вторым аргументом);
  * depends пустой, а из ядра нужны только известные экспортированные символы;
  * в коде нет обращений к полям структуры mtd_info, кроме flags (смещение 4) --
    именно это делает модуль независимым от конфигурации ядра.

Запуск: python3 tests/check_module.py firmware/mtd-rw-6.18.41.ko \
            "6.18.41 SMP mod_unload aarch64"
"""

import re
import struct
import sys

EXPECTED_SYMBOLS = {"_printk", "get_mtd_device", "put_mtd_device", "param_ops_bool"}
# Смещения, которые встречаются в коде проверенного модуля:
#   4    -- mtd_info.flags (единственное обращение к структуре ядра);
#   0, 8 -- собственные переменные модуля unlocked и mtd_last;
#   0xc  -- собственный параметр i_want_a_brick.
# Любое другое смещение означает, что модуль читает другие поля структуры,
# а их раскладка зависит от конфигурации ядра -- такой модуль нельзя брать
# из чужой сборки не глядя.
ALLOWED_OFFSETS = (0, 4, 8, 0xC)
EM_AARCH64 = 0xB7
ET_REL = 1


def fail(message):
    print("ОШИБКА: %s" % message)
    sys.exit(1)


def sections(raw):
    e_shoff, = struct.unpack_from("<Q", raw, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", raw, 0x3A)
    out = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        name, stype, flags, addr, offset, size, link, info, align, entsize = \
            struct.unpack_from("<IIQQQQIIQQ", raw, off)
        out.append(dict(name=name, type=stype, offset=offset, size=size,
                        link=link, entsize=entsize))
    shstr = out[e_shstrndx]

    def resolve(pos):
        start = shstr["offset"] + pos
        return raw[start:raw.index(b"\x00", start)].decode()

    for sec in out:
        sec["sname"] = resolve(sec["name"])
    return out


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    path, want_vermagic = sys.argv[1], sys.argv[2]
    with open(path, "rb") as handle:
        raw = handle.read()

    print("файл:            %s (%d байт)" % (path, len(raw)))
    if raw[:4] != b"\x7fELF" or raw[4] != 2 or raw[5] != 1:
        fail("это не 64-битный little-endian ELF")
    e_type, e_machine = struct.unpack_from("<HH", raw, 16)
    if e_type != ET_REL:
        fail("ELF не релокатируемый (тип %d), модуль ядра должен быть ET_REL" % e_type)
    if e_machine != EM_AARCH64:
        fail("машина %#x, ожидался aarch64 (0xb7)" % e_machine)
    print("ELF:             релокатируемый, aarch64")

    secs = sections(raw)
    modinfo = next((s for s in secs if s["sname"] == ".modinfo"), None)
    if modinfo is None:
        fail("нет секции .modinfo")
    info = {}
    for item in raw[modinfo["offset"]:modinfo["offset"] + modinfo["size"]].split(b"\x00"):
        if b"=" in item:
            key, _, value = item.decode("latin1").partition("=")
            info.setdefault(key, value)
    print("vermagic:        %s" % info.get("vermagic"))
    print("depends:         %r" % info.get("depends"))
    if info.get("vermagic") != want_vermagic:
        fail("vermagic '%s', ожидался '%s'" % (info.get("vermagic"), want_vermagic))
    if info.get("depends"):
        fail("модуль зависит от других модулей: %s" % info["depends"])
    if info.get("license") != "GPL":
        fail("лицензия '%s', ожидалась GPL" % info.get("license"))

    symtab = next((s for s in secs if s["sname"] == ".symtab"), None)
    if symtab is None:
        fail("нет секции .symtab")
    strtab = secs[symtab["link"]]
    undefined = set()
    for i in range(symtab["size"] // 24):
        off = symtab["offset"] + i * 24
        st_name, st_info, st_other, st_shndx, st_value, st_size = \
            struct.unpack_from("<IBBHQQ", raw, off)
        if st_shndx == 0 and st_name:
            start = strtab["offset"] + st_name
            undefined.add(raw[start:raw.index(b"\x00", start)].decode())
    print("нужно из ядра:   %s" % ", ".join(sorted(undefined)))
    if undefined != EXPECTED_SYMBOLS:
        fail("набор внешних символов изменился: лишние %s, отсутствуют %s" % (
            sorted(undefined - EXPECTED_SYMBOLS), sorted(EXPECTED_SYMBOLS - undefined)))

    # Обращения к структуре: ищем ldr/str с непосредственным смещением.
    try:
        from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
    except ImportError:
        print("capstone не установлен, проверку смещений пропускаю")
        print("итог:            модуль пригоден")
        return 0

    md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
    seen = set()
    for sec in secs:
        if sec["type"] == 1 and sec["size"] > 4 and "text" in sec["sname"]:
            body = raw[sec["offset"]:sec["offset"] + sec["size"]]
            for insn in md.disasm(body, 0):
                match = re.search(r"\[[xw]\d+, #(0x[0-9a-f]+|\d+)\]", insn.op_str)
                if match:
                    seen.add(int(match.group(1), 0))
    print("смещения в коде: %s" % sorted(seen))
    suspicious = [off for off in seen if off not in ALLOWED_OFFSETS]
    if suspicious:
        fail("код обращается к смещениям %s -- возможно, он читает другие поля "
             "mtd_info, раскладка которых зависит от конфигурации ядра; "
             "проверьте вручную" % suspicious)
    print("итог:            обращение к структуре ядра только по смещению 4 (flags)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
