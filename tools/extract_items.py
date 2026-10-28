#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
extract_items.py — извлечение точек спавна оружия/брони/мегахелса из entity
lump карты.

Читает <map>.bsp (BSP29 / BSP2 / 2PSB) и пишет blank_map/<map>.items —
построчный файл для gnuplot:
    # heatmap-items-cache v2      <- заголовок-маркер версии формата (строка 1)
    X Y Z ГРУППА МЕТКА
где ГРУППА: 1 = оружие, 2 = броня, 3 = мегахелс; МЕТКА — краткое имя
предмета (SG SS NG SNG GL RL LG / GA YA RA / MH). Координаты — мировые
(как в демке), gnuplot делит X/Y на SCALING так же, как данные игроков.
Заголовок-маркер позволяет heatmap.sh отследить кэш старого формата
(v1.0.12 без заголовка/мегахелса/исправленного RA) и перегенерировать его.

Кэш: heatmap.sh вызывает экстрактор только если <map>.items отсутствует,
.bsp новее кэша или первая строка кэша не совпадает с маркером версии.
Пустая карта (нет подходящих entity) — файл только с заголовком,
код возврата 0.

Поддерживаемые classnames (QuakeWorld, id1 — совпадает со спавн-функциями
KTX src/items.c):
    weapon_shotgun weapon_supershotgun weapon_nailgun weapon_supernailgun
    weapon_grenadelauncher weapon_rocketlauncher weapon_lightning
    item_armor1 (зелёная GA) item_armor2 (жёлтая YA) item_armorInv (красная RA)
    item_health со spawnflags&2 (мегахелс MH); spawnflags&1 (гнилая еда)
    и обычные аптечки не рисуются.

    ВНИМАНИЕ: classname "item_armor3" НЕ существует ни в ванильном Quake,
    ни в KTX (проверено по исходникам KTX) — красная броня всегда
    item_armorInv. В v1.0.12 экстрактор ошибочно искал item_armor3, из-за
    чего RA не отображалась ни на одной карте (в т.ч. baldm6). Несуществующий
    classname намеренно НЕ поддержан: такой entity не спавнится сервером,
    и иконка была бы ложной.

Форматы BSP:
    BSP29  — version int32 == 29, каталог: 15 lump'ов (int32 ofs, int32 len)
             с оффсета 4; ENTITIES = lump 0.
    BSP2   — магии 'BSP2'/'2PSB', каталог: 15 lump'ов (int64 ofs, int64 len)
             с оффсета 4, сразу после магии; ENTITIES = lump 0. Геометрия не читается — экстрактору
             нужен только текст entity lump.

Только stdlib (python3 >= 3.9). Выходные коды: 0 — успех (в том числе 0
предметов); 1 — ошибка данных (файл не читается / формат не опознан).
"""

import argparse
import os
import re
import struct
import sys

# classname (lowercase) -> (метка, группа)
ITEM_CLASSES = {
    "weapon_shotgun":          ("SG",  1),
    "weapon_supershotgun":     ("SS",  1),
    "weapon_nailgun":          ("NG",  1),
    "weapon_supernailgun":     ("SNG", 1),
    "weapon_grenadelauncher":  ("GL",  1),
    "weapon_rocketlauncher":   ("RL",  1),
    "weapon_lightning":        ("LG",  1),
    "item_armor1":             ("GA",  2),
    "item_armor2":             ("YA",  2),
    "item_armorinv":           ("RA",  2),
}

# item_health: биты spawnflags (items.qc / KTX src/items.c: гнилая еда
# проверяется ПЕРВОЙ — "spawnflags 3" означает гнилую, не мегахелс)
HEALTH_ROTTEN = 1
HEALTH_MEGA = 2

# маркер версии формата кэша — первая строка файла (см. шапку модуля)
CACHE_HEADER = "# heatmap-items-cache v2"

BSP2_MAGICS = (b"BSP2", b"2PSB")
BSP29_VERSION = 29
BSP_LUMP_COUNT = 15
# dheader2_t: int32-магия + 15 x lump2_t(int64 ofs, int64 len) — таблица
# начинается сразу после магии, с оффсета 4 (DarkPlaces bspfile.h)
BSP2_LUMP_TABLE_OFFSET = 4
BSP29_LUMP_TABLE_OFFSET = 4    # int32 version, затем 15 x (int32 ofs, int32 len)


def warn(msg: str) -> None:
    print("WARN: %s" % msg, file=sys.stderr)


def fail(msg: str) -> None:
    print("ERROR: %s" % msg, file=sys.stderr)
    sys.exit(1)


def read_entities_lump(bsp_path: str) -> str:
    """Возвращает текст entity lump; формат файла определяется автоматически."""
    try:
        size = os.path.getsize(bsp_path)
        with open(bsp_path, "rb") as fh:
            head = fh.read(8)
    except OSError as exc:
        fail("не удалось прочитать BSP '%s': %s" % (bsp_path, exc))
    if len(head) < 8:
        fail("BSP '%s' слишком мал для заголовка" % bsp_path)

    magic = head[:4]
    if magic in BSP2_MAGICS:
        # каталог BSP2: 15 x (int64 ofs, int64 len) с оффсета 4
        need = BSP2_LUMP_TABLE_OFFSET + BSP_LUMP_COUNT * 16
        try:
            with open(bsp_path, "rb") as fh:
                head = fh.read(need)
        except OSError as exc:
            fail("не удалось прочитать заголовок '%s': %s" % (bsp_path, exc))
        if len(head) < need:
            fail("BSP2 '%s' слишком мал для каталога lump'ов" % bsp_path)
        ofs, ln = struct.unpack_from("<2q", head, BSP2_LUMP_TABLE_OFFSET)
    else:
        (version,) = struct.unpack_from("<i", head, 0)
        if version != BSP29_VERSION:
            fail(
                "BSP '%s': version=%d не поддерживается (BSP29 или BSP2/2PSB)"
                % (bsp_path, version)
            )
        need = BSP29_LUMP_TABLE_OFFSET + BSP_LUMP_COUNT * 8
        try:
            with open(bsp_path, "rb") as fh:
                head = fh.read(need)
        except OSError as exc:
            fail("не удалось прочитать заголовок '%s': %s" % (bsp_path, exc))
        if len(head) < need:
            fail("BSP29 '%s' слишком мал для каталога lump'ов" % bsp_path)
        ofs, ln = struct.unpack_from("<2i", head, BSP29_LUMP_TABLE_OFFSET)

    if ofs < 0 or ln < 0 or ofs + ln > size:
        fail(
            "BSP '%s': некорректный lump ENTITIES (ofs=%d, len=%d, размер файла %d)"
            % (bsp_path, ofs, ln, size)
        )
    try:
        with open(bsp_path, "rb") as fh:
            fh.seek(ofs)
            data = fh.read(ln)
    except OSError as exc:
        fail("не удалось прочитать ENTITIES из '%s': %s" % (bsp_path, exc))
    # entity-текст Quake — ASCII; latin-1 читает любой байт без исключений
    return data.decode("latin-1")


def parse_spawnflags(block: str, bsp_path: str, classname: str) -> int:
    """spawnflags entity (int; отсутствует/битый -> 0 с WARN для битого)."""
    m_sf = re.search(r'"spawnflags"\s+"([^"]*)"', block)
    if not m_sf:
        return 0
    try:
        return int(m_sf.group(1).strip())
    except ValueError:
        warn(
            "%s: '%s' spawnflags '%s' — не число, считается 0"
            % (os.path.basename(bsp_path), classname, m_sf.group(1))
        )
        return 0


def parse_items(entities_text: str, bsp_path: str):
    """Извлекает (x, y, z, группа, метка) из entity-блоков. Порядок файлов."""
    items = []
    for block in re.findall(r"\{([^{}]*)\}", entities_text):
        m_cls = re.search(r'"classname"\s+"([^"]*)"', block)
        if not m_cls:
            continue
        classname = m_cls.group(1).strip().lower()
        if classname == "item_health":
            # мегахелс: spawnflags&2 (гнилая еда — spawnflags&1 — проверяется
            # первой, как в items.qc/KTX); обычные аптечки не рисуются
            sf = parse_spawnflags(block, bsp_path, classname)
            if sf & HEALTH_ROTTEN:
                continue
            if not sf & HEALTH_MEGA:
                continue
            label, group = "MH", 3
        else:
            if classname not in ITEM_CLASSES:
                continue
            label, group = ITEM_CLASSES[classname]
        m_org = re.search(r'"origin"\s+"([^"]*)"', block)
        if not m_org:
            warn(
                "%s: '%s' без ключа origin — пропущен"
                % (os.path.basename(bsp_path), classname)
            )
            continue
        parts = m_org.group(1).split()
        if len(parts) != 3:
            warn(
                "%s: '%s' origin '%s' — ожидались 3 координаты, пропущен"
                % (os.path.basename(bsp_path), classname, m_org.group(1))
            )
            continue
        try:
            x, y, z = (float(p) for p in parts)
        except ValueError:
            warn(
                "%s: '%s' origin '%s' — не числа, пропущен"
                % (os.path.basename(bsp_path), classname, m_org.group(1))
            )
            continue
        items.append((x, y, z, group, label))
    return items


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Извлечение точек спавна оружия/брони из <map>.bsp (BSP29/BSP2/2PSB)"
    )
    parser.add_argument("bsp", help="путь к <map>.bsp")
    parser.add_argument(
        "--output",
        default=None,
        help="путь результата (по умолчанию <bsp-каталог>/<map>.items)",
    )
    args = parser.parse_args()

    if not os.path.isfile(args.bsp):
        fail("BSP не найден: %s" % args.bsp)

    out_path = args.output or (os.path.splitext(args.bsp)[0] + ".items")

    entities = read_entities_lump(args.bsp)
    items = parse_items(entities, args.bsp)

    try:
        with open(out_path, "w", encoding="ascii") as fh:
            fh.write(CACHE_HEADER + "\n")
            for x, y, z, group, label in items:
                fh.write("%g %g %g %d %s\n" % (x, y, z, group, label))
    except OSError as exc:
        fail("не удалось записать '%s': %s" % (out_path, exc))

    weapons = sum(1 for it in items if it[3] == 1)
    armor = sum(1 for it in items if it[3] == 2)
    mega = sum(1 for it in items if it[3] == 3)
    print(
        "INFO: %s: предметов %d (оружие %d, броня %d, мегахелс %d)"
        % (out_path, len(items), weapons, armor, mega)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
