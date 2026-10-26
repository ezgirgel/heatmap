#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_mapinfo.py — генератор mapinfo (blank_map/<map>.json) для heatmap.

Читает мировые границы карты из <map>.bsp (BSP29) и размеры из <map>.bmp,
формирует <map>.json с полями:
    bspName, minX, minY, maxX, maxY, width, height,
    imageWidth, imageHeight, padding, scaling

Использование:
    make_mapinfo.py <map>.bmp <map>.bsp [--padding N] [--scaling N]
                    [--output <path.json>] [--force]
    make_mapinfo.py --bounds <map>.bsp      # печать "minX minY maxX maxY"

Режим --bounds используется heatmap.sh для расчёта размера подложки
перед mogrify -resize (формула: W = floor(width/scaling) + 2*padding + 1).

Поддерживается только BSP29 (version == 29). Магии '2PSB'/'BSP2' (BSP2) и
прочие версии — ошибка с инструкцией по ручному созданию json.

Только stdlib (python3 >= 3.9). Выходные коды: 0 — успех; 1 — ошибка данных.
"""

import argparse
import json
import math
import os
import struct
import sys

BSP_HEADER_SIZE = 4          # int32 version
BSP_LUMP_ENTRY_SIZE = 8      # int32 fileofs, int32 filelen
# Каталог BSP29 — ровно 15 именованных lump'ов (канон: id Software,
# WinQuake/bspfile.h; подтверждено Unofficial Quake Spec 3.4 и реальными
# размерами lump'ов warfare.bsp: VERTEXES 43884=3657*12, FACES 52640=2632*20,
# EDGES 27016=6754*4, SURFEDGES 53640=26820*4):
#   0 ENTITIES, 1 PLANES, 2 TEXTURES, 3 VERTEXES, 4 VISIBILITY, 5 NODES,
#   6 TEXINFO, 7 FACES, 8 LIGHTING, 9 CLIPNODES, 10 LEAFS, 11 MARKSURFACES,
#   12 EDGES, 13 SURFEDGES, 14 MODELS; HEADER_LUMPS = 15.
# История дефекта (warfare.bsp, реальные прогоны 2026-10-26/27): ТЗ 8.7.2
# предписывало индекс 11 (= MARKSURFACES → float32-денормалы «0 0 0 0» →
# подложка 21x21); «фикс» v1.0.2 ставил 13 (= SURFEDGES → те же нули,
# валидация ofs/len при этом проходила). Канонический индекс MODELS — 14.
BSP_LUMP_MODELS = 14
BSP_LUMP_COUNT = 15

DMODEL_T_SIZE = 64           # sizeof(dmodel_t) BSP29 (см. bspfile.h)
DMODEL_BOUNDS_SIZE = 24      # float32 mins[3] + float32 maxs[3]

BSP2_MAGICS = (b"2PSB", b"BSP2")

MANUAL_JSON_HINT = (
    "Создайте json вручную: blank_map/<map>.json с полями "
    'bspName (путь .bsp), minX/minY/maxX/maxY (мировые границы), '
    "width/maxX-minX, height/maxY-minY, imageWidth/imageHeight "
    "(размер <map>.bmp), padding, scaling."
)


def warn(msg: str) -> None:
    print("WARN: %s" % msg, file=sys.stderr)


def fail(msg: str) -> "None":
    print("ERROR: %s" % msg, file=sys.stderr)
    sys.exit(1)


def parse_bsp29_bounds(bsp_path: str):
    """Возвращает (minX, minY, maxX, maxY) из dmodel[0] BSP29."""
    try:
        size = os.path.getsize(bsp_path)
        with open(bsp_path, "rb") as fh:
            head = fh.read(BSP_HEADER_SIZE + BSP_LUMP_COUNT * BSP_LUMP_ENTRY_SIZE)
    except OSError as exc:
        fail("не удалось прочитать BSP '%s': %s" % (bsp_path, exc))

    if len(head) < BSP_HEADER_SIZE + BSP_LUMP_COUNT * BSP_LUMP_ENTRY_SIZE:
        fail("BSP '%s' слишком мал для заголовка BSP29" % bsp_path)

    magic = head[:4]
    if magic in BSP2_MAGICS:
        # FR-13: не-BSP29 — ошибка с инструкцией по ручному созданию json
        fail(
            "BSP '%s' имеет формат %s (BSP2), а не BSP29. %s"
            % (bsp_path, magic.decode("ascii", "replace"), MANUAL_JSON_HINT)
        )

    (version,) = struct.unpack_from("<i", head, 0)
    if version != 29:
        fail(
            "BSP '%s' имеет version=%d, поддерживается только BSP29 (29). %s"
            % (bsp_path, version, MANUAL_JSON_HINT)
        )

    lump_ofs, lump_len = struct.unpack_from(
        "<ii", head, BSP_HEADER_SIZE + BSP_LUMP_MODELS * BSP_LUMP_ENTRY_SIZE
    )
    if lump_ofs <= 0 or lump_len < DMODEL_T_SIZE or lump_ofs + lump_len > size:
        fail(
            "BSP '%s': некорректный lump MODELS (ofs=%d, len=%d) — файл не "
            "похож на BSP29 или повреждён. %s"
            % (bsp_path, lump_ofs, lump_len, MANUAL_JSON_HINT)
        )
    if lump_len % DMODEL_T_SIZE != 0:
        fail(
            "BSP '%s': длина lump MODELS (%d) не кратна sizeof(dmodel_t)=%d "
            "— неверная версия формата. %s"
            % (bsp_path, lump_len, DMODEL_T_SIZE, MANUAL_JSON_HINT)
        )
    nummodels = lump_len // DMODEL_T_SIZE

    with open(bsp_path, "rb") as fh:
        fh.seek(lump_ofs)
        dmodel0 = fh.read(DMODEL_T_SIZE)
    if len(dmodel0) < DMODEL_T_SIZE:
        fail("BSP '%s': не удалось прочитать dmodel[0]" % bsp_path)

    mins = struct.unpack_from("<3f", dmodel0, 0)
    maxs = struct.unpack_from("<3f", dmodel0, 12)
    # dmodel_t после границ: float origin[3]; int headnode[4]; int visleafs,
    # firstface, numfaces (смещения 24/36/52; итого 64 байта)
    _origin = struct.unpack_from("<3f", dmodel0, 24)
    _headnode = struct.unpack_from("<4i", dmodel0, 36)
    visleafs, firstface, numfaces = struct.unpack_from("<3i", dmodel0, 52)

    # Структурная валидация dmodel[0] (урок warfare.bsp: неверный индекс
    # lump'а давал ПРАВДОПОДОБНЫЙ нулевой вывод вместо ошибки). Мировая
    # модель обязана иметь геометрию: numfaces > 0, firstface == 0 (мировая
    # модель всегда первая по списку face), visleafs >= 0.
    if numfaces <= 0 or firstface != 0 or visleafs < 0:
        fail(
            "BSP '%s': dmodel[0] не похож на мировую модель (numfaces=%d, "
            "firstface=%d, visleafs=%d, nummodels=%d) — вероятно, неверная "
            "версия формата или повреждён каталог. %s"
            % (bsp_path, numfaces, firstface, visleafs, nummodels,
               MANUAL_JSON_HINT)
        )

    # Вырожденные границы — тоже ошибка, а не «нули на доверие»
    if maxs[0] <= mins[0] or maxs[1] <= mins[1]:
        fail(
            "BSP '%s': вырожденные границы dmodel[0]: X[%g..%g] Y[%g..%g] "
            "— карта повреждена или dmodel[0] не мировая модель. %s"
            % (bsp_path, mins[0], maxs[0], mins[1], maxs[1], MANUAL_JSON_HINT)
        )

    def as_int(value: float) -> int:
        # мировые границы в BSP29 целые; устраняем погрешность float32
        r = round(value)
        return int(r) if abs(value - r) < 0.01 else value

    return as_int(mins[0]), as_int(mins[1]), as_int(maxs[0]), as_int(maxs[1])


def read_bmp_size(bmp_path: str):
    """Размеры BMP: int32 width/height (LE) по смещению 18."""
    try:
        with open(bmp_path, "rb") as fh:
            header = fh.read(26)
    except OSError as exc:
        fail("не удалось прочитать BMP '%s': %s" % (bmp_path, exc))
    if len(header) < 26 or header[:2] != b"BM":
        fail("'%s' не является BMP-файлом" % bmp_path)
    width, height = struct.unpack_from("<ii", header, 18)
    if width <= 0 or height == 0:
        fail("BMP '%s': некорректные размеры %dx%d" % (bmp_path, width, height))
    return width, abs(height)


def num(value):
    """int, если значение целое (для совпадения с существующими json)."""
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return value


def build_mapinfo(bmp_path: str, bsp_path: str, padding: int, scaling: int) -> dict:
    min_x, min_y, max_x, max_y = parse_bsp29_bounds(bsp_path)
    img_w, img_h = read_bmp_size(bmp_path)
    info = {
        "bspName": bsp_path,
        "minX": num(min_x),
        "minY": num(min_y),
        "maxX": num(max_x),
        "maxY": num(max_y),
        "width": num(max_x - min_x),
        "height": num(max_y - min_y),
        "imageWidth": img_w,
        "imageHeight": img_h,
        "padding": padding,
        "scaling": scaling,
    }
    # Самопроверка: imageWidth ~ floor(width/scaling) + 2*padding + 1 (допуск ±2)
    width = float(info["width"])
    height = float(info["height"])
    expected_w = math.floor(width / scaling) + 2 * padding + 1
    expected_h = math.floor(height / scaling) + 2 * padding + 1
    if abs(img_w - expected_w) > 2 or abs(img_h - expected_h) > 2:
        warn(
            "размер bmp %dx%d отличается от расчётного %dx%d "
            "(width/scaling + 2*padding + 1); проверьте scaling/padding "
            "и соответствие BSP2BMP_ARGS (-s%d)" % (img_w, img_h, expected_w, expected_h, scaling)
        )
    return info


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Генератор blank_map/<map>.json из <map>.bmp + <map>.bsp (BSP29)"
    )
    parser.add_argument("bmp", nargs="?", help="путь к <map>.bmp (размеры изображения)")
    parser.add_argument("bsp", nargs="?", help="путь к <map>.bsp (мировые границы)")
    parser.add_argument("--padding", type=int, default=10, help="padding (по умолчанию 10)")
    parser.add_argument("--scaling", type=int, default=4, help="scaling (по умолчанию 4)")
    parser.add_argument("--output", default=None, help="путь json (по умолчанию <bmp>.json)")
    parser.add_argument(
        "--force", action="store_true", help="перезаписать существующий json"
    )
    parser.add_argument(
        "--bounds",
        action="store_true",
        help="не создавать json; напечатать 'minX minY maxX maxY' из BSP",
    )
    args = parser.parse_args()

    if args.bounds:
        if not args.bsp:
            # допускаем 'make_mapinfo.py --bounds <bsp>' и '--bounds <bmp> <bsp>'
            if args.bmp:
                args.bsp = args.bmp
            else:
                parser.error("--bounds требует путь к .bsp")
        if not os.path.isfile(args.bsp):
            fail("BSP не найден: %s" % args.bsp)
        min_x, min_y, max_x, max_y = parse_bsp29_bounds(args.bsp)
        print("%s %s %s %s" % (num(min_x), num(min_y), num(max_x), num(max_y)))
        return 0

    if not args.bmp or not args.bsp:
        parser.error("требуются <map>.bmp и <map>.bsp (см. --help)")
    if not os.path.isfile(args.bmp):
        fail("BMP не найден: %s" % args.bmp)
    if not os.path.isfile(args.bsp):
        fail("BSP не найден: %s" % args.bsp)
    if args.scaling <= 0:
        fail("--scaling должен быть положительным")

    out_path = args.output or (os.path.splitext(args.bmp)[0] + ".json")

    if os.path.exists(out_path) and not args.force:
        print(
            "INFO: %s уже существует — не перезаписываю (используйте --force)"
            % out_path
        )
        return 0

    info = build_mapinfo(args.bmp, args.bsp, args.padding, args.scaling)

    try:
        with open(out_path, "w", encoding="utf-8") as fh:
            json.dump(info, fh, ensure_ascii=False, separators=(",", ":"))
            fh.write("\n")
    except OSError as exc:
        fail("не удалось записать '%s': %s" % (out_path, exc))

    print("INFO: создан %s" % out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
