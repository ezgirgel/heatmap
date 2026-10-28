#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
extract_items.py — извлечение точек спавна оружия/брони из entity lump карты.

Читает <map>.bsp (BSP29 / BSP2 / 2PSB) и пишет blank_map/<map>.items —
построчный файл для gnuplot:
    X Y Z ГРУППА МЕТКА
где ГРУППА: 1 = оружие, 2 = броня; МЕТКА — краткое имя предмета
(SG SS NG SNG GL RL LG / GA YA RA). Координаты — мировые (как в демке),
gnuplot делит X/Y на SCALING так же, как данные игроков.

Кэш: heatmap.sh вызывает экстрактор только если <map>.items отсутствует
или .bsp новее кэша. Пустая карта (нет подходящих entity) — пустой файл,
код возврата 0.

Поддерживаемые classnames (QuakeWorld, id1):
    weapon_shotgun weapon_supershotgun weapon_nailgun weapon_supernailgun
    weapon_grenadelauncher weapon_rocketlauncher weapon_lightning
    item_armor1 (зелёная) item_armor2 (жёлтая) item_armor3 (красная)

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
    "item_armor3":             ("RA",  2),
}

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


def parse_items(entities_text: str, bsp_path: str):
    """Извлекает (x, y, z, группа, метка) из entity-блоков. Порядок файлов."""
    items = []
    for block in re.findall(r"\{([^{}]*)\}", entities_text):
        m_cls = re.search(r'"classname"\s+"([^"]*)"', block)
        if not m_cls:
            continue
        classname = m_cls.group(1).strip().lower()
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
            for x, y, z, group, label in items:
                fh.write("%g %g %g %d %s\n" % (x, y, z, group, label))
    except OSError as exc:
        fail("не удалось записать '%s': %s" % (out_path, exc))

    weapons = sum(1 for it in items if it[3] == 1)
    armor = len(items) - weapons
    print("INFO: %s: предметов %d (оружие %d, броня %d)" % (out_path, len(items), weapons, armor))
    return 0


if __name__ == "__main__":
    sys.exit(main())
