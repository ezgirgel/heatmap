#!/bin/bash
# ============================================================================
# heatmap.sh — GIF-карты перемещений игроков (QuakeWorld / mvdsv)
#
# Точка входа пост-обработки партии: вызывается mvdsv после матча без
# аргументов (вся информация о партии — в demoinfo-файле). По каждому игроку
# строит анимированный GIF перемещений на фоне подложки карты.
#
# Вызов:  heatmap.sh [путь-к-demoinfo]
#         $1 (опционально) перекрывает DEMOINFO_FILE из конфига.
#
# Коды возврата (FR-3):
#   0 — успех (в том числе при частичных WARN по отдельным игрокам)
#   1 — конфигурация/окружение
#   2 — входные данные (demoinfo/демка)
#   3 — сбой внешнего инструмента (bsp2bmp, mvdparser, gnuplot, make_mapinfo)
#   4 — таймаут блокировки (flock)
#
# Все пути и параметры — в heatmap.conf (раздел 7 ТЗ). Зашитых абсолютных
# путей в коде нет (T-13).
#
# Окружение: bash >= 5.1, gnuplot >= 5.4 (pngcairo), ImageMagick 6 (синтаксис
# IM6, совместим с IM7), jq >= 1.6, python3 >= 3.9 (только stdlib).
# ============================================================================

set -euo pipefail
umask 022
export LC_ALL=C

# ----------------------------------------------------------------------------
# Служебные функции, доступные до инициализации лога
# ----------------------------------------------------------------------------

# дату/время для сообщений до инициализации лога
_now() { date +%Y-%m-%dT%H:%M:%S%z; }

_prelog() { printf '%s [%s] %s\n' "$(_now)" "$1" "$2" >&2; }

# Фатальный выход: сообщение в stderr (лог ещё может быть не инициализирован)
_die_early() {
    local code="$1"; shift
    _prelog "ERROR" "$*"
    exit "$code"
}

# ----------------------------------------------------------------------------
# FR-2: собственный каталог определяется по BASH_SOURCE, работает из любого CWD
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
export SCRIPT_DIR

ORIG_ARGS=("$@")

# ----------------------------------------------------------------------------
# FR-5: конфиг обязателен
# ----------------------------------------------------------------------------
CONFIG="${SCRIPT_DIR}/heatmap.conf"
if [[ ! -r "$CONFIG" ]]; then
    _die_early 1 "конфиг не найден или не читается: ${CONFIG} (FR-5)"
fi
# shellcheck source=heatmap.conf
source "$CONFIG"

# ----------------------------------------------------------------------------
# Раскладка инструментов: бинарники поставки лежат в tools/. Для
# совместимости со старыми установками (файлы в корне рядом со скриптом)
# путь выбирается по факту наличия файла: tools/ приоритетен, корень — фолбэк.
# Явно заданные в конфиге/окружении MVDPARSER_BIN/BSP2BMP_BIN приоритетнее.
# ----------------------------------------------------------------------------
_hm_tool_path() {
    local _name="$1"
    if [[ -e "${SCRIPT_DIR}/tools/${_name}" ]]; then
        printf '%s\n' "${SCRIPT_DIR}/tools/${_name}"
    else
        printf '%s\n' "${SCRIPT_DIR}/${_name}"
    fi
}

# ----------------------------------------------------------------------------
# Дефолты раздела 7 (FR-7): запуск без части ключей не падает, если ключ
# не обязателен. Обязательные: QW_MAP_DIR, DEMO_DIR, DEMOINFO_FILE.
# ----------------------------------------------------------------------------
: "${QW_MAP_DIR:=}"
: "${DEMO_DIR:=}"
: "${DEMOINFO_FILE:=}"
: "${BLANK_MAP_DIR:=${SCRIPT_DIR}/blank_map}"
: "${RESULT_DIR:=${SCRIPT_DIR}/result}"
: "${LOG_DIR:=${SCRIPT_DIR}/logs}"
: "${TMP_BASE:=${SCRIPT_DIR}/tmp}"
: "${TOOLS_DIR:=${SCRIPT_DIR}/tools}"
: "${MVDPARSER_BIN:=$(_hm_tool_path mvdparser)}"
: "${FRAGFILE:=${SCRIPT_DIR}/fragfile.dat}"
: "${TEMPLATE_TPL:=${SCRIPT_DIR}/template.tpl}"
: "${GNUPLOT_SCRIPT:=${SCRIPT_DIR}/xy.gnuplot}"
: "${BSP2BMP_BIN:=$(_hm_tool_path bsp2bmp_3800)}"
: "${BSP2BMP_ARGS:=-s4 -z0 -p0 -e -c+Z}"
: "${LOCK_FILE:=${TMP_BASE}/heatmap.lock}"

# кадры GIF — interleave (8.2): кадр f содержит каждый NUM-й замер партии
: "${MAX_FRAMES:=20}"
: "${MIN_DATA_LINES:=10}"
: "${GIF_DELAY_CS:=5}"
: "${GIF_LOOP:=0}"
: "${GIF_OPTIMIZE_FUZZ:=10}"

: "${PALETTE_MIN_COLOR:=blue}"
: "${PALETTE_MAX_COLOR:=red}"
: "${PALETTE_CUSTOM:=}"
: "${MARKER_MOVE_TYPE:=5}"
: "${MARKER_DEATH_TYPE:=2}"
# концы формулы высоты для размера маркера:
#   size = MIN_MARKER_SIZE + t*(MAX_MARKER_SIZE-MIN_MARKER_SIZE),
#   t = (z-MIN_Z)/(MAX_Z-MIN_Z)
: "${MIN_MARKER_SIZE:=0.7}"
: "${MAX_MARKER_SIZE:=1.5}"
# иконки предметов: точки спавна оружия/брони из entity lump карты (v1.0.12)
: "${SHOW_ITEMS:=true}"
# v1.0.13: какие ОРУЖИЯ рисовать — список через запятую из
# SG SS NG SNG GL RL LG (регистр/пробелы игнорируются); пусто — оружие
# не рисуется. Броня (GA YA RA) и мегахелс (MH) управляются только SHOW_ITEMS.
# ВАЖНО: ${VAR-default} (а не :=) — пустая строка в конфиге НЕ заменяется
# дефолтом, а означает «оружие не рисовать»
: "${SHOW_WEAPONS-RL,LG}"
# v1.0.13: скрывать предметы, перекрывающиеся на виде сверху: в радиусе 32
# мировых единиц по X/Y (габарит предмета Quake 32x32) остаётся только
# ВЕРХНИЙ (максимальный Z; при равенстве Z — первый в кэше)
: "${HIDE_OVERLAPPED_ITEMS-false}"
# v1.0.13: цвет метки каждого предмета — имя цвета ImageMagick/X11
# (orange, gray, red, yellow, green, skyblue, …) или #RRGGBB / 0xRRGGBB.
# Имя РЕЗОЛВИТСЯ в 0xRRGGBB при старте (gnuplot с строковым цветом молча
# НЕ рисует метку — проверено на 5.4.1; резолв заодно и валидация FR-6).
: "${ITEM_COLOR_SG-green}"
: "${ITEM_COLOR_SS-green}"
: "${ITEM_COLOR_NG-green}"
: "${ITEM_COLOR_SNG-green}"
: "${ITEM_COLOR_GL-green}"
: "${ITEM_COLOR_RL-orange}"
: "${ITEM_COLOR_LG-gray}"
: "${ITEM_COLOR_GA-green}"
: "${ITEM_COLOR_YA-yellow}"
: "${ITEM_COLOR_RA-red}"
: "${ITEM_COLOR_MH-skyblue}"
: "${BLANK_MAP_NEGATE:=false}"
: "${Z_OUTLIER_MIN_COUNT:=10}"
: "${MAPINFO_PADDING:=10}"
: "${MAPINFO_SCALING:=4}"

: "${RETENTION_MAX_AGE_DAYS:=90}"
: "${RETENTION_MAX_DIRS:=200}"
: "${LOG_RETENTION_DAYS:=30}"
: "${LOCK_WAIT_SEC:=1800}"
: "${KEEP_TMP_ON_FAIL:=true}"
# класть ли копию demoinfo.json в каталог результата (провенанс)
: "${RESULT_COPY_DEMOINFO:=false}"
: "${NICE_LEVEL:=}"

# ----------------------------------------------------------------------------
# Валидация конфига (FR-6)
# ----------------------------------------------------------------------------
is_int()   { [[ "$1" =~ ^[0-9]+$ ]]; }
is_num()   { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

validate_conf() {
    local key
    # обязательные ключи
    for key in QW_MAP_DIR DEMO_DIR DEMOINFO_FILE; do
        if [[ -z "${!key}" ]]; then
            _die_early 1 "конфиг: обязательный ключ ${key} пуст (FR-6)"
        fi
    done
    # числовые ключи
    local int_keys=(
        MAX_FRAMES MIN_DATA_LINES
        GIF_DELAY_CS GIF_LOOP GIF_OPTIMIZE_FUZZ
        Z_OUTLIER_MIN_COUNT MAPINFO_PADDING MAPINFO_SCALING
        RETENTION_MAX_AGE_DAYS RETENTION_MAX_DIRS LOG_RETENTION_DAYS
        LOCK_WAIT_SEC
    )
    for key in "${int_keys[@]}"; do
        if [[ -n "${!key}" ]] && ! is_int "${!key}"; then
            _die_early 1 "конфиг: ключ ${key}='${!key}' не является целым числом (FR-6)"
        fi
    done
    # логические ключи
    local bool_keys=(BLANK_MAP_NEGATE KEEP_TMP_ON_FAIL RESULT_COPY_DEMOINFO SHOW_ITEMS HIDE_OVERLAPPED_ITEMS)
    for key in "${bool_keys[@]}"; do
        local v="${!key,,}"
        if [[ "$v" != "true" && "$v" != "false" ]]; then
            _die_early 1 "конфиг: ключ ${key}='${!key}' — допустимо true|false (FR-6)"
        fi
        printf -v "$key" '%s' "$v"
    done
    # SHOW_WEAPONS (v1.0.13): список оружий через запятую. Нормализация:
    # пробелы срезаются, регистр — верхний; пусто = оружие не рисуется.
    SHOW_WEAPONS_NORM=""
    local _w="${SHOW_WEAPONS//[[:space:]]/}"
    _w="${_w^^}"
    if [[ -n "$_w" ]]; then
        local _tok
        local IFS=,
        for _tok in $_w; do
            case "$_tok" in
                SG|SS|NG|SNG|GL|RL|LG) ;;
                *) _die_early 1 "конфиг: SHOW_WEAPONS='${SHOW_WEAPONS}' — неизвестное оружие '${_tok}' (допустимо SG SS NG SNG GL RL LG; пусто = оружие не рисуется) (FR-6)" ;;
            esac
            SHOW_WEAPONS_NORM+="${_tok},"
        done
        SHOW_WEAPONS_NORM="${SHOW_WEAPONS_NORM%,}"
    fi
    # ITEM_COLOR_* (v1.0.13): грубая проверка формата (имя/#RRGGBB/0xRRGGBB);
    # полная валидация имени — через ImageMagick при старте рендера
    local color_re='^[A-Za-z0-9#._-]+$'
    local color_keys=(ITEM_COLOR_SG ITEM_COLOR_SS ITEM_COLOR_NG ITEM_COLOR_SNG
                      ITEM_COLOR_GL ITEM_COLOR_RL ITEM_COLOR_LG
                      ITEM_COLOR_GA ITEM_COLOR_YA ITEM_COLOR_RA ITEM_COLOR_MH)
    for key in "${color_keys[@]}"; do
        if [[ ! "${!key}" =~ $color_re ]]; then
            _die_early 1 "конфиг: ключ ${key}='${!key}' — не похоже на цвет (имя gnuplot/X11, #RRGGBB или 0xRRGGBB) (FR-6)"
        fi
    done
    # маркеры: *_TYPE — целое 1..15; *_SIZE — число > 0 (7.3, FR-6)
    for key in MARKER_MOVE_TYPE MARKER_DEATH_TYPE; do
        if ! is_int "${!key}" || (( 10#${!key} < 1 || 10#${!key} > 15 )); then
            _die_early 1 "конфиг: ключ ${key}='${!key}' — целое 1..15 (pointtype gnuplot, FR-6)"
        fi
    done
    # концы формулы высоты — числа > 0, MIN <= MAX (7.3, FR-6)
    for key in MIN_MARKER_SIZE MAX_MARKER_SIZE; do
        if ! is_num "${!key}" || ! awk -v v="${!key}" 'BEGIN{exit !(v > 0)}'; then
            _die_early 1 "конфиг: ключ ${key}='${!key}' — число > 0 (pointsize, FR-6)"
        fi
    done
    if ! awk -v a="$MIN_MARKER_SIZE" -v b="$MAX_MARKER_SIZE" 'BEGIN{exit !(a <= b)}'; then
        _die_early 1 "конфиг: MIN_MARKER_SIZE=${MIN_MARKER_SIZE} > MAX_MARKER_SIZE=${MAX_MARKER_SIZE} (FR-6)"
    fi
    # NICE_LEVEL: пусто или 0..19
    if [[ -n "$NICE_LEVEL" ]] && { ! is_int "$NICE_LEVEL" || (( 10#$NICE_LEVEL > 19 )); }; then
        _die_early 1 "конфиг: NICE_LEVEL='${NICE_LEVEL}' — пусто или целое 0..19 (FR-6)"
    fi
}

# неизвестные ключи — WARN (защита от опечаток).
# Подход «diff»: список переменных до и после source конфига — иммунитет
# к служебным переменным bash (BASH_*, SHELLOPTS и т.п.) на любой версии.
# Diff сам по себе выдаёт ВСЕ ключи конфига, поэтому результат фильтруется
# по ассоциативному массиву известных ключей раздела 7 ТЗ: WARN получают
# только действительно неизвестные (служебные переменные bash вида
# PIPESTATUS, затесавшиеся в diff, тоже отсекаются).
check_unknown_keys() {
    local base full k
    local -A known=()
    local known_keys=(
        QW_MAP_DIR DEMO_DIR DEMOINFO_FILE
        BLANK_MAP_DIR BLANK_MAP_NEGATE
        MVDPARSER_BIN FRAGFILE TEMPLATE_TPL GNUPLOT_SCRIPT
        BSP2BMP_BIN BSP2BMP_ARGS
        RESULT_DIR LOG_DIR TMP_BASE LOCK_FILE TOOLS_DIR
        MAX_FRAMES MIN_DATA_LINES
        GIF_DELAY_CS GIF_LOOP GIF_OPTIMIZE_FUZZ
        PALETTE_CUSTOM PALETTE_MIN_COLOR PALETTE_MAX_COLOR
        MARKER_MOVE_TYPE MARKER_DEATH_TYPE
        MIN_MARKER_SIZE MAX_MARKER_SIZE RESULT_COPY_DEMOINFO
        SHOW_ITEMS SHOW_WEAPONS HIDE_OVERLAPPED_ITEMS
        ITEM_COLOR_SG ITEM_COLOR_SS ITEM_COLOR_NG ITEM_COLOR_SNG ITEM_COLOR_GL
        ITEM_COLOR_RL ITEM_COLOR_LG ITEM_COLOR_GA ITEM_COLOR_YA ITEM_COLOR_RA
        ITEM_COLOR_MH
        Z_OUTLIER_MIN_COUNT MAPINFO_PADDING MAPINFO_SCALING
        RETENTION_MAX_AGE_DAYS RETENTION_MAX_DIRS LOG_RETENTION_DAYS
        LOCK_WAIT_SEC KEEP_TMP_ON_FAIL RESULT_COPY_DEMOINFO NICE_LEVEL
    )
    for k in "${known_keys[@]}"; do known["$k"]=1; done
    # «base» исполняет такой же однотактный пайплайн, как source в «full» —
    # иначе спецпеременные bash (PIPESTATUS и т.п.), выставляемые пайплайном
    # перед compgen, попадали бы в diff и давали ложный WARN на каждом прогоне.
    base="$(env -i PATH="$PATH" HOME="${HOME:-/root}" SCRIPT_DIR="$SCRIPT_DIR" \
        bash -c ': >/dev/null 2>&1; compgen -v' 2>/dev/null | sort -u || true)"
    full="$(env -i PATH="$PATH" HOME="${HOME:-/root}" SCRIPT_DIR="$SCRIPT_DIR" \
        bash -c 'source "$1" >/dev/null 2>&1; compgen -v' _ "$CONFIG" 2>/dev/null | sort -u || true)"
    if [[ -z "$full" ]]; then
        log "WARN" "конфиг: не удалось автоматически проверить неизвестные ключи (FR-6)"
        return 0
    fi
    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        [[ -n "${known[$k]:-}" ]] && continue
        log "WARN" "конфиг: неизвестный ключ '${k}' — проверьте опечатки (FR-6)"
    done < <(comm -13 <(printf '%s\n' "$base") <(printf '%s\n' "$full"))
}

validate_conf

# ----------------------------------------------------------------------------
# Инициализация лога (FR-32): logs/heatmap-YYYY-MM-DD.log, append + stdout
# ----------------------------------------------------------------------------
mkdir -p "$LOG_DIR" 2>/dev/null || _die_early 1 "не удалось создать каталог логов: ${LOG_DIR}"
LOG_FILE="${LOG_DIR}/heatmap-$(date +%F).log"
touch "$LOG_FILE" 2>/dev/null || _die_early 1 "не удалось открыть лог: ${LOG_FILE}"

# nice-перезапуск (FR-4) исполняет скрипт повторно; флаг-хранец делает
# инициализацию одноразовой (иначе выстраивается цепочка tee->tee и каждая
# строка лога дублируется). Повторный проход наследует установленный редирект.
if [[ "${_HM_LOG_TEE:-0}" != "1" ]]; then
    exec &> >(tee -a "$LOG_FILE")
    export _HM_LOG_TEE=1
fi

log() {
    local level="$1"; shift
    printf '%s [%s] %s\n' "$(_now)" "$level" "$*"
}

die() {
    local code="$1"; shift
    log ERROR "$*"
    exit "$code"
}

log INFO "=== heatmap: старт (pid $$, log ${LOG_FILE}) ==="

# FR-6: неизвестные ключи — WARN. Проверка идёт ПОСЛЕ инициализации лога,
# чтобы WARN попал в файл лога при любом NICE_LEVEL (без nice второго прохода
# нет, а prelog в stderr до редиректа в лог не попадает). Флаг-хранец —
# однократность: во втором проходе nice-перезапуска (FR-4) проверка не
# повторяется, иначе WARN задваивался бы.
if [[ "${_HM_UNK_CHECKED:-0}" != "1" ]]; then
    export _HM_UNK_CHECKED=1
    check_unknown_keys
fi

# ----------------------------------------------------------------------------
# FR-4: перезапуск через nice (до flock, с сохранением аргументов)
# ----------------------------------------------------------------------------
if [[ -n "$NICE_LEVEL" && "${_HM_NICE_DONE:-0}" != "1" ]]; then
    log INFO "перезапуск через nice -n ${NICE_LEVEL} (FR-4)"
    export _HM_NICE_DONE=1
    exec nice -n "$NICE_LEVEL" bash "$SCRIPT_DIR/heatmap.sh" "${ORIG_ARGS[@]}"
fi

# ----------------------------------------------------------------------------
# Окружение: наличие инструментов (код 1)
# ----------------------------------------------------------------------------
need_bin=(jq gnuplot convert composite mogrify identify flock python3 awk sed basename stat du find date tee realpath)
for cmd in "${need_bin[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die 1 "не найден необходимый инструмент: ${cmd} (код 1)"
    fi
done
if [[ ! -x "$MVDPARSER_BIN" ]]; then die 1 "mvdparser не найден или не исполняем: ${MVDPARSER_BIN}"; fi
if [[ ! -x "$BSP2BMP_BIN" ]]; then die 1 "bsp2bmp не найден или не исполняем: ${BSP2BMP_BIN}"; fi
if [[ ! -r "$FRAGFILE" ]]; then die 1 "fragfile не найден: ${FRAGFILE}"; fi
if [[ ! -r "$TEMPLATE_TPL" ]]; then die 1 "template.tpl не найден: ${TEMPLATE_TPL}"; fi
if [[ ! -r "$GNUPLOT_SCRIPT" ]]; then die 1 "xy.gnuplot не найден: ${GNUPLOT_SCRIPT}"; fi

# ----------------------------------------------------------------------------
# Санитизация имён (8.5): вне A-Za-z0-9._- -> '_'; схлопнуть '_'; срезать края;
# обрезать до 64; пусто -> '' (вызывающий подставит player_<слот>)
# ----------------------------------------------------------------------------
sanitize_name() {
    local s="$1"
    s="$(printf '%s' "$s" | tr -c 'A-Za-z0-9._-' '_')"
    s="${s//__*/_}"
    # схлопывание подряд идущих '_' и срезка краёв
    while [[ "$s" == *'__'* ]]; do s="${s//__/_}"; done
    while [[ "$s" == _* ]]; do s="${s#_}"; done
    while [[ "$s" == *_ ]]; do s="${s%_}"; done
    if (( ${#s} > 64 )); then
        s="${s:0:64}"
        while [[ "$s" == *_ ]]; do s="${s%_}"; done
    fi
    printf '%s' "$s"
}

# Экранирование строкового значения для gnuplot -e (двойные кавычки gnuplot)
gp_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}

# ----------------------------------------------------------------------------
# Резолв ITEM_COLOR_* в числа для gnuplot (v1.0.13): tc rgb var принимает
# только ЧИСЛОВОЙ цвет — строковое имя молча НЕ РИСУЕТ метку (проверено на
# 5.4.1). Имя цвета -> 0xRRGGBB через ImageMagick (заодно валидация FR-6:
# неизвестное имя — фатально, gnuplot сам бы промолчал). #RRGGBB/0xRRGGBB
# проходят без IM. Результат — ITEM_COLOR_<МЕТКА>_HEX="0xRRGGBB".
# Вызывать ПОСЛЕ need_bin (нужен convert), ДО GNUPLOT_ITEM_COLORS — всегда
# (не только при SHOW_ITEMS=true: проба рисует метки при любом SHOW_ITEMS).
# ----------------------------------------------------------------------------
_rgb_from_im() { # $1 = имя цвета -> "RRGGBB" (rc 1 = не распознано)
    local out
    out="$(convert -size 1x1 "xc:$1" -format '%[pixel:u.p{0,0}]' info: 2>/dev/null)" || return 1
    if [[ "$out" =~ ^srgba?\(([0-9]+),([0-9]+),([0-9]+) ]]; then
        printf '%02X%02X%02X' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        return 0
    fi
    if [[ "$out" =~ ^gray\(([0-9]+)\) ]]; then
        printf '%02X%02X%02X' "${BASH_REMATCH[1]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$out" =~ ^#?([0-9A-Fa-f]{6})$ ]]; then
        printf '%s' "${BASH_REMATCH[1]^}"
        return 0
    fi
    return 1
}

hm_resolve_item_colors() {
    local key color hex
    local color_keys=(ITEM_COLOR_SG ITEM_COLOR_SS ITEM_COLOR_NG ITEM_COLOR_SNG
                      ITEM_COLOR_GL ITEM_COLOR_RL ITEM_COLOR_LG
                      ITEM_COLOR_GA ITEM_COLOR_YA ITEM_COLOR_RA ITEM_COLOR_MH)
    for key in "${color_keys[@]}"; do
        color="${!key}"
        case "$color" in
            \#*) hex="${color#\#}" ;;
            0[xX]*) hex="${color:2}" ;;
            *) hex="$(_rgb_from_im "$color")" \
                || die 1 "конфиг: ключ ${key}='${color}' — ImageMagick не знает такой цвет (допустимо имя IM/X11, #RRGGBB или 0xRRGGBB) (FR-6)" ;;
        esac
        hex="$(printf '%s' "$hex" | tr 'a-f' 'A-F')"
        if [[ ! "$hex" =~ ^[0-9A-F]{6}$ ]]; then
            die 1 "конфиг: ключ ${key}='${color}' — не похоже на цвет (имя IM/X11, #RRGGBB или 0xRRGGBB) (FR-6)"
        fi
        printf -v "${key}_HEX" '%s' "0x${hex}"
    done
}

# ----------------------------------------------------------------------------
# Фильтр иконок предметов (v1.0.13): (1) оружие проходит только если его
# метка в SHOW_WEAPONS_NORM (броня и мегахелс — всегда); (2) при
# HIDE_OVERLAPPED_ITEMS=true из предметов, перекрывающихся на виде сверху
# (расстояние по X/Y < ITEMS_OVERLAP_RADIUS мировых единиц), остаётся только
# ВЕРХНИЙ — с максимальным Z (при равенстве Z — первый в файле; правило
# детерминировано и не зависит от сортировки).
# ----------------------------------------------------------------------------
filter_items_awk() { # $1 = источник (кэш), $2 = приёмник (файл для gnuplot)
    awk -v W="${SHOW_WEAPONS_NORM}" \
        -v DEDUP="$([[ "$HIDE_OVERLAPPED_ITEMS" == "true" ]] && echo 1 || echo 0)" \
        -v R="${ITEMS_OVERLAP_RADIUS}" '
        BEGIN {
            R2 = R * R
            nw = split(W, wa, ",")
            for (i = 1; i <= nw; i++) if (wa[i] != "") want[wa[i]] = 1
        }
        /^#/ { next }
        NF >= 5 {
            g = $4 + 0
            if (g == 1 && !($5 in want)) next
            n++; ax[n] = $1 + 0; ay[n] = $2 + 0; az[n] = $3 + 0
            ag[n] = g; al[n] = $5
        }
        END {
            if (DEDUP == 1) {
                for (i = 1; i <= n; i++)
                    for (j = 1; j <= n; j++) {
                        if (j == i) continue
                        dx = ax[j] - ax[i]; dy = ay[j] - ay[i]
                        if (dx * dx + dy * dy >= R2) continue
                        if (az[j] > az[i] || (az[j] == az[i] && j < i)) { hidden[i] = 1; break }
                    }
            }
            for (i = 1; i <= n; i++)
                if (!(i in hidden))
                    printf "%g %g %g %d %s\n", ax[i], ay[i], az[i], ag[i], al[i]
        }
    ' "$1" > "$2"
}

# ----------------------------------------------------------------------------
# Trap выхода: уборка run-каталога (FR-30). При сбое KEEP_TMP_ON_FAIL=true
# сохраняет run-каталог только если в нём есть файлы (есть что разбирать);
# пустой каталог (сбой до парсинга/рендера) удаляется всегда — пустые
# frames/XY_data/stage в tmp не копятся.
# ----------------------------------------------------------------------------
RUN_DIR=""
hm_on_exit() {
    local rc="$1" || true
    if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
        if [[ "$KEEP_TMP_ON_FAIL" == "true" && "$rc" != "0" ]] \
           && [[ -n "$(find "$RUN_DIR" -type f -print -quit 2>/dev/null)" ]]; then
            log INFO "run-каталог сохранён для разбора (KEEP_TMP_ON_FAIL=true): ${RUN_DIR}"
        else
            rm -rf -- "$RUN_DIR" 2>/dev/null || true
            log INFO "run-каталог удалён: ${RUN_DIR}"
        fi
    fi
    log INFO "=== heatmap: финиш (код возврата: ${rc}) ==="
}
trap 'hm_on_exit $?' EXIT

# ----------------------------------------------------------------------------
# FR-31: flock на LOCK_FILE; таймаут — код 4
# ----------------------------------------------------------------------------
mkdir -p "$TMP_BASE" || die 1 "не удалось создать ${TMP_BASE}"
exec 9>"$LOCK_FILE" || die 1 "не удалось открыть lock-файл: ${LOCK_FILE}"
if ! flock -w "$LOCK_WAIT_SEC" 9; then
    log ERROR "предыдущий запуск ещё работает — лок ${LOCK_FILE} не освобождён за ${LOCK_WAIT_SEC} с"
    exit 4
fi
log INFO "лок получен: ${LOCK_FILE}"

# ----------------------------------------------------------------------------
# FR-30: мусор после сбоев — run-каталоги старше 24 часов
# ----------------------------------------------------------------------------
while IFS= read -r stale; do
    [[ -z "$stale" ]] && continue
    log INFO "удаляю run-каталог старше 24 ч: ${stale}"
    rm -rf -- "$stale" 2>/dev/null || true
done < <(find "$TMP_BASE" -mindepth 1 -maxdepth 1 -type d -name 'run-*' -mmin +1440 -print 2>/dev/null)

# ----------------------------------------------------------------------------
# Run-каталог текущего запуска (FR-15)
# ----------------------------------------------------------------------------
RUN_DIR="${TMP_BASE}/run-$(date +%Y%m%d-%H%M%S)-$$"
XY_DATA_DIR="${RUN_DIR}/XY_data"
FRAMES_DIR="${RUN_DIR}/frames"
STAGE_DIR="${RUN_DIR}/stage"
mkdir -p "$XY_DATA_DIR" "$FRAMES_DIR" "$STAGE_DIR" || die 1 "не удалось создать run-каталог: ${RUN_DIR}"
log INFO "run-каталог: ${RUN_DIR}"

# ----------------------------------------------------------------------------
# Входные данные: demoinfo (FR-8) + демка (FR-9) + DATE (FR-10)
# ----------------------------------------------------------------------------
if (( ${#ORIG_ARGS[@]} > 1 )); then
    log WARN "лишние аргументы (ожидался максимум 1 — путь к demoinfo): ${ORIG_ARGS[*]:1}"
fi

DEMOINFO_SRC="${ORIG_ARGS[0]:-${DEMOINFO_FILE}}"
if [[ -z "$DEMOINFO_SRC" ]]; then
    die 1 "не задан demoinfo: ни аргумент \$1, ни ключ DEMOINFO_FILE в конфиге"
fi
if [[ ! -r "$DEMOINFO_SRC" ]]; then
    die 2 "demoinfo не найден или не читается: ${DEMOINFO_SRC} (FR-8)"
fi

# FR-8: валидность JSON и типы обязательных полей — проверяем в основном
# контексте (не внутри $()), чтобы сообщение об ошибке не терялось
for _field in map mode demo date; do
    if ! jq -e ".${_field} | select(type==\"string\")" "$DEMOINFO_SRC" >/dev/null 2>&1; then
        die 2 "demoinfo ${DEMOINFO_SRC}: нет обязательного строкового поля '${_field}' или JSON повреждён (FR-8)"
    fi
done

RAW_MAP="$(jq -er '.map' "$DEMOINFO_SRC")" || die 2 "demoinfo: не удалось прочитать .map (FR-8)"
RAW_MODE="$(jq -er '.mode' "$DEMOINFO_SRC")" || die 2 "demoinfo: не удалось прочитать .mode (FR-8)"
DEMO="$(jq -er '.demo' "$DEMOINFO_SRC")" || die 2 "demoinfo: не удалось прочитать .demo (FR-8)"
RAW_DATE="$(jq -er '.date' "$DEMOINFO_SRC")" || die 2 "demoinfo: не удалось прочитать .date (FR-8)"

DURATION="$(jq -er '.duration | select(type=="number")' "$DEMOINFO_SRC" 2>/dev/null || true)"
if [[ -n "$DURATION" ]]; then
    DURATION="${DURATION%%.*}"           # floor на случай дробного значения
    is_int "$DURATION" || DURATION=0
else
    DURATION=0
fi

if [[ "$DEMO" != "$(basename -- "$DEMO")" || -z "$DEMO" ]]; then
    die 2 "demoinfo: некорректное имя демки '${DEMO}' (FR-9)"
fi
DEMO_PATH="${DEMO_DIR}/${DEMO}"
if [[ ! -f "$DEMO_PATH" ]]; then
    die 2 "файл демки не найден: ${DEMO_PATH} (FR-9)"
fi

DATE="$(date +%F_%T -d "$RAW_DATE" 2>/dev/null)" || {
    die 2 "не удалось разобрать дату партии '${RAW_DATE}' (FR-10)"
}

log INFO "партия: map='${RAW_MAP}' mode='${RAW_MODE}' demo='${DEMO}' date='${RAW_DATE}' duration=${DURATION}s"
log INFO "demoinfo: ${DEMOINFO_SRC}; демка: ${DEMO_PATH}; DATE=${DATE}"

# ----------------------------------------------------------------------------
# Санитизация map/mode (FR-11) и имя каталога результата (FR-27)
# ----------------------------------------------------------------------------
MAP="$(sanitize_name "$RAW_MAP")"
MODE="$(sanitize_name "$RAW_MODE")"
[[ -z "$MAP" ]] && MAP="unknown_map"
[[ -z "$MODE" ]] && MODE="unknown_mode"
BASENAME_R="${DATE}_${MODE}_${MAP}"
RNAME="$BASENAME_R"
_n=2
while [[ -e "${RESULT_DIR}/${RNAME}" || -L "${RESULT_DIR}/${RNAME}" ]]; do
    RNAME="${BASENAME_R}-${_n}"
    _n=$((_n + 1))
done
log INFO "имя каталога результата: ${RNAME}"

# ----------------------------------------------------------------------------
# Ремонт заголовка BMP (8.7.2): у вывода bsp2bmp bfSize считается по
# непаддированной строке и biSizeImage=0 — ImageMagick 6 отвечает
# LengthAndFilesizeDoNotMatch (identify/mogrify дают rc≠0). Переписываем
# bfSize на фактический размер файла и biSizeImage на фактический объём
# данных: изображение не меняется, файл читается IM6 строго. Идемпотентно.
# ----------------------------------------------------------------------------
fix_bmp_header() {
    local f="$1"
    [[ -s "$f" ]] || return 0
    python3 - "$f" <<'PYFIX' || return 1
import os, struct, sys
path = sys.argv[1]
size = os.path.getsize(path)
with open(path, "r+b") as fh:
    head = fh.read(54)
    if len(head) < 54 or head[:2] != b"BM":
        sys.exit(0)  # не BMP — не трогаем
    bf_size = struct.unpack_from("<I", head, 2)[0]
    off_bits = struct.unpack_from("<I", head, 10)[0]
    bi_size = struct.unpack_from("<I", head, 34)[0]
    want_bf = size
    want_bi = (size - off_bits) if 0 < off_bits < size else 0
    if bf_size == want_bf and bi_size == want_bi:
        sys.exit(0)
    fh.seek(2)
    fh.write(struct.pack("<I", want_bf))
    fh.seek(34)
    fh.write(struct.pack("<I", want_bi))
    print("bfSize %d -> %d, biSizeImage %d -> %d" % (bf_size, want_bf, bi_size, want_bi))
PYFIX
}

# ----------------------------------------------------------------------------
# Подложка и mapinfo (FR-12/13/14, алгоритм 8.7)
# ----------------------------------------------------------------------------
BMP_PATH="${BLANK_MAP_DIR}/${MAP}.bmp"
JSON_PATH="${BLANK_MAP_DIR}/${MAP}.json"
BSP_PATH="${QW_MAP_DIR}/${MAP}.bsp"
TOOLS_DIR="${TOOLS_DIR:-${SCRIPT_DIR}/tools}"
MAKE_MAPINFO="${TOOLS_DIR}/make_mapinfo.py"

# Расчётный размер подложки из границ BSP (8.7.3): W = floor(width/scaling)
# + 2*padding + 1. Устанавливает глобальные _RW/_RH. Вызывать ТОЛЬКО в
# основном контексте (не внутри $( ) — die внутри под-оболочки не завершит
# скрипт, ошибка будет молча проглочена).
map_backdrop_dims() {
    (( ${_G_DIMS_DONE:-0} == 1 )) && return 0
    local _bounds _bminx _bminy _bmaxx _bmaxy
    _bounds="$(python3 "$MAKE_MAPINFO" --bounds "$BSP_PATH")" || {
        die 3 "make_mapinfo --bounds не удался: BSP не BSP29? инструкции по ручному созданию json — в сообщении выше и в README (FR-13)"
    }
    # мусорный/пустой вывод --bounds нельзя отдавать в bash-арифметику молча —
    # пустые значения она считает нулями. Жёсткая проверка формата.
    if [[ ! "$_bounds" =~ ^-?[0-9]+[[:space:]]+-?[0-9]+[[:space:]]+-?[0-9]+[[:space:]]+-?[0-9]+$ ]]; then
        die 3 "make_mapinfo --bounds вернул неожиданный вывод: '${_bounds}' — ожидалось 'minX minY maxX maxY' (FR-13)"
    fi
    read -r _bminx _bminy _bmaxx _bmaxy <<< "$_bounds"
    if (( _bmaxx <= _bminx || _bmaxy <= _bminy )); then
        die 3 "границы BSP некорректны: X[$_bminx..$_bmaxx] Y[$_bminy..$_bmaxy] — проверьте карту и MAPINFO_SCALING (FR-13)"
    fi
    log INFO "границы карты из вершин BSP (bbox VERTEXES): X[$_bminx..$_bmaxx] Y[$_bminy..$_bmaxy]"
    # Границы наружу (глобальные) — для кросс-проверки с Bounds bsp2bmp
    _G_BXMIN="$_bminx"; _G_BYMIN="$_bminy"; _G_BXMAX="$_bmaxx"; _G_BYMAX="$_bmaxy"
    _RW=$(( ( _bmaxx - _bminx ) / MAPINFO_SCALING + 2 * MAPINFO_PADDING + 1 ))
    _RH=$(( ( _bmaxy - _bminy ) / MAPINFO_SCALING + 2 * MAPINFO_PADDING + 1 ))
    if (( _RW < 1 || _RH < 1 )); then
        die 3 "вычислен некорректный размер подложки ${_RW}x${_RH} (проверьте MAPINFO_SCALING/границы BSP)"
    fi
    _G_DIMS_DONE=1
}

# ----------------------------------------------------------------------------
# Посадка контента подложки на канву расчётного размера (8.7.3).
# bsp2bmp пишет буфер фиксированного размера 1903x1903, внутри которого
# контент (floor(dX/sc)+3 x floor(dY/sc)+3) размещён от мирового нуля.
# Поэтому ВЕСЬ буфер ужать нельзя — bbox контента вырезается (convert -trim,
# «%@») и сажается в центр канвы расчётного размера (-gravity center
# -extent); фон канвы — цвет угла (0,0) исходного буфера (после -negate
# это белый). Вызывать ПОСЛЕ map_backdrop_dims (нужны _RW/_RH и _G_B*) и
# в основном контексте (die внутри $( ) не завершит скрипт).
# ----------------------------------------------------------------------------
map_backdrop_fit() {
    local _bbox _cw _ch _ox _oy _bg _ex _ey
    _bbox="$(convert "$BMP_PATH" -format "%@" info: 2>/dev/null)" || {
        die 3 "не удалось измерить bbox контента подложки (convert -trim) — 8.7.3"
    }
    if [[ ! "$_bbox" =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]]; then
        die 3 "неожиданный ответ trim '${_bbox}' — 8.7.3"
    fi
    _cw=${BASH_REMATCH[1]}; _ch=${BASH_REMATCH[2]}
    _ox=${BASH_REMATCH[3]}; _oy=${BASH_REMATCH[4]}
    # физические границы контента: не меньше bbox вершин (округление растра)
    # и не больше канвы; выход за них — аномалия рендера
    _ex=$(( ( _G_BXMAX - _G_BXMIN ) / MAPINFO_SCALING ))
    _ey=$(( ( _G_BYMAX - _G_BYMIN ) / MAPINFO_SCALING ))
    if (( _cw < _ex - 2 || _ch < _ey - 2 || _cw > _RW || _ch > _RH )); then
        die 3 "bbox контента подложки ${_cw}x${_ch} вне ожиданий (вершины ~${_ex}x${_ey}, канва ${_RW}x${_RH}) — 8.7.3"
    fi
    _bg="$(convert "$BMP_PATH" -format "%[pixel:p{0,0}]" info: 2>/dev/null)" || _bg=""
    if [[ -z "$_bg" ]]; then
        if [[ "$BLANK_MAP_NEGATE" == "true" ]]; then _bg="white"; else _bg="black"; fi
    fi
    convert "$BMP_PATH" -crop "${_cw}x${_ch}+${_ox}+${_oy}" +repage \
            -background "$_bg" -gravity center -extent "${_RW}x${_RH}" "$BMP_PATH" || {
        die 3 "посадка контента подложки на канву ${_RW}x${_RH} не удалась — 8.7.3"
    }
    log INFO "подложка: контент ${_cw}x${_ch} вырезан из буфера bsp2bmp и посажен на канву ${_RW}x${_RH} (фон ${_bg}) — 8.7.3"
}

# ----------------------------------------------------------------------------
# Контент-проверка существующей подложки: bbox контента должен
# соответствовать ожидаемому floor(dX/sc)+3 x floor(dY/sc)+3 (допуск ±6 на
# растеризацию линий/дробные вершины). Ловит чужие/повреждённые/ужатые
# подложки. 1 = не соответствует.
# ----------------------------------------------------------------------------
map_backdrop_content_ok() {
    local _bbox _cw _ch
    _G_EW=$(( ( _G_BXMAX - _G_BXMIN ) / MAPINFO_SCALING + 3 ))
    _G_EH=$(( ( _G_BYMAX - _G_BYMIN ) / MAPINFO_SCALING + 3 ))
    _bbox="$(convert "$BMP_PATH" -format "%@" info: 2>/dev/null)" || return 1
    [[ "$_bbox" =~ ^([0-9]+)x([0-9]+)\+ ]] || return 1
    _cw=${BASH_REMATCH[1]}; _ch=${BASH_REMATCH[2]}
    _G_CBB="$_bbox"
    (( _cw >= _G_EW - 6 && _cw <= _G_EW + 6 && _ch >= _G_EH - 6 && _ch <= _G_EH + 6 ))
}

generate_backdrop() {
    if [[ ! -f "$BSP_PATH" ]]; then
        die 3 "нет ни подложки ${BMP_PATH}, ни исходника карты ${BSP_PATH} (FR-12)"
    fi
    log INFO "генерация подложки: bsp2bmp -> ${BMP_PATH}"
    mkdir -p "$BLANK_MAP_DIR" || die 3 "не удалось создать ${BLANK_MAP_DIR}"
    # shellcheck disable=SC2086 — BSP2BMP_ARGS намеренно разбивается на слова
    # Вывод захватывается: строка Bounds нужна кросс-проверке границ;
    # сам вывод полностью печатается в лог.
    _bspout="$("$BSP2BMP_BIN" $BSP2BMP_ARGS "$BSP_PATH" "$BMP_PATH" 2>&1)" || {
        printf '%s\n' "${_bspout:-<нет вывода>}" >&2
        die 3 "bsp2bmp завершился с ошибкой (FR-12)"
    }
    printf '%s\n' "$_bspout" >&2
    # Bounds из вывода bsp2bmp (считает по вершинам VERTEXES — путь,
    # независимый от каталога lump'ов). Формат: «Bounds: X [-480.0000 ..
    # 928.0000] …» + строка продолжения «        Y [-752.0000 .. 832.0000] …».
    # Ось Y в выводе bsp2bmp — ИЗОБРАЖЕНИЯ (вниз), т.е. инвертирована
    # относительно мировых координат: проверено на эталонных json прода
    # (utressor: bsp2bmp Y[-528..416] ↔ json minY/maxY -416/528; travelert6
    # аналогично), поэтому мировые границы = (-y_max, -y_min).
    _bsp_bounds="$(printf '%s\n' "$_bspout" | awk '
        /^Bounds:/ { for (i = 2; i <= NF; i++) if ($i == "X") {
            x1 = $(i+1); x2 = $(i+3); gsub(/[\[\]]/, "", x1); gsub(/[\[\]]/, "", x2) }
        }
        /^[[:space:]]*Y[[:space:]]*\[/ { y1 = $2; y2 = $4;
            gsub(/[\[\]]/, "", y1); gsub(/[\[\]]/, "", y2) }
        END { if (x1 != "" && x2 != "" && y1 != "" && y2 != "")
            printf "%.0f %.0f %.0f %.0f\n", x1, x2, -y2, -y1 }
    ')"
    # Ремонт заголовка ДО любых операций IM (см. fix_bmp_header):
    # свежий вывод bsp2bmp IM6 иначе не читает (mogrify -negate/-resize — rc≠0).
    _fixr="$(fix_bmp_header "$BMP_PATH")" || die 3 "ремонт заголовка BMP не удался: ${BMP_PATH} (8.7.2)"
    [[ -n "$_fixr" ]] && log INFO "заголовок BMP исправлен (${_fixr}) — 8.7.2"
    if [[ "$BLANK_MAP_NEGATE" == "true" ]]; then
        mogrify -negate "$BMP_PATH" || die 3 "mogrify -negate не удался (FR-12/FR-37)"
        log INFO "подложка инвертирована (mogrify -negate, BLANK_MAP_NEGATE=true)"
    fi
    # Кросс-проверка границ: bbox вершин BSP (make_mapinfo, VERTEXES-ламп)
    # против Bounds из вывода bsp2bmp — это ОДИН И ТОТ ЖЕ набор вершин
    # (bsp2bmp рендерит по всем рёбрам всех моделей), поэтому совпадение
    # ОБЯЗАТЕЛЬНО, а расхождение означает сбой захвата вывода или инверсии
    # Y (в Bounds bsp2bmp ось Y — изображения: мировые Y = (-y_max, -y_min)).
    # Допуск ±1 — на округление %.0f. Границы карты берутся только из
    # вершин; dmodel[0] — структурная проверка + WARN внутри make_mapinfo.py.
    if [[ -n "${_bsp_bounds:-}" ]]; then
        read -r _bb_xmin _bb_xmax _bb_ymin _bb_ymax <<< "$_bsp_bounds"
        if (( _bb_xmin < _G_BXMIN - 1 || _bb_xmin > _G_BXMIN + 1 ||
              _bb_xmax < _G_BXMAX - 1 || _bb_xmax > _G_BXMAX + 1 ||
              _bb_ymin < _G_BYMIN - 1 || _bb_ymin > _G_BYMIN + 1 ||
              _bb_ymax < _G_BYMAX - 1 || _bb_ymax > _G_BYMAX + 1 )); then
            die 3 "кросс-проверка границ не сошлась: вершины BSP X[$_G_BXMIN..$_G_BXMAX] Y[$_G_BYMIN..$_G_BYMAX] против рендера bsp2bmp X[$_bb_xmin..$_bb_xmax] Y[$_bb_ymin..$_bb_ymax] — сбой захвата вывода или инверсии Y, привязка координат была бы неверной (FR-13)"
        fi
        log INFO "кросс-проверка границ: вершины BSP == рендер bsp2bmp, X[$_G_BXMIN..$_G_BXMAX] Y[$_G_BYMIN..$_G_BYMAX] — OK (FR-13)"
    else
        log WARN "Bounds не найдены в выводе bsp2bmp — кросс-проверка границ пропущена (FR-13)"
    fi
    map_backdrop_fit
    _G_BMP_FRESH=1
}

# ----------------------------------------------------------------------------
# Выбор: сгенерировать подложку или проверить существующую.
# Легаси-режим «готовые bmp+json без .bsp» сохранён: без BSP не делаем ни
# проверок границ, ни перегенерации — только идемпотентный ремонт заголовка.
# Иначе границы считаются ВСЕГДА (один python-парс), а существующая подложка
# проверяется по размеру И по контенту; не прошедшие проверку подложки
# перегенерируются автоматически.
# ----------------------------------------------------------------------------
_G_DIMS_DONE=0
_G_BMP_FRESH=0
if [[ -f "$BMP_PATH" && ! -f "$BSP_PATH" ]]; then
    _fixr="$(fix_bmp_header "$BMP_PATH")" || die 3 "ремонт заголовка BMP не удался: ${BMP_PATH} (8.7.2)"
    [[ -n "$_fixr" ]] && log INFO "заголовок существующей подложки исправлен (${_fixr}) — 8.7.2"
else
    map_backdrop_dims
    if [[ ! -f "$BMP_PATH" ]]; then
        generate_backdrop
    else
        _dims="$(identify -format '%w %h' "$BMP_PATH" 2>/dev/null)" || _dims=""
        _dims="${_dims// /x}"
        if [[ "$_dims" != "${_RW}x${_RH}" ]]; then
            log WARN "размер существующей подложки ${_dims:-неизвестен} не совпадает с расчётным ${_RW}x${_RH} — перегенерирую из ${BSP_PATH} (8.7.3)"
            generate_backdrop
        elif ! map_backdrop_content_ok; then
            log WARN "контент существующей подложки (${_G_CBB:-неизвестен}) не соответствует ожидаемому ~${_G_EW}x${_G_EH} — перегенерирую из ${BSP_PATH} (8.7.3)"
            generate_backdrop
        else
            _fixr="$(fix_bmp_header "$BMP_PATH")" || die 3 "ремонт заголовка BMP не удался: ${BMP_PATH} (8.7.2)"
            [[ -n "$_fixr" ]] && log INFO "заголовок существующей подложки исправлен (${_fixr}) — 8.7.2"
        fi
    fi
fi

if [[ ! -f "$JSON_PATH" ]]; then
    if [[ ! -f "$BSP_PATH" ]]; then
        die 3 "нет mapinfo ${JSON_PATH} и исходника карты ${BSP_PATH} — json не сгенерировать (FR-13)"
    fi
    log INFO "генерация mapinfo: ${JSON_PATH}"
    python3 "$MAKE_MAPINFO" "$BMP_PATH" "$BSP_PATH" \
        --padding "$MAPINFO_PADDING" --scaling "$MAPINFO_SCALING" \
        --output "$JSON_PATH" || {
        die 3 "make_mapinfo.py не удался — если BSP не BSP29, создайте json вручную (инструкция в README, FR-13)"
    }
fi

# ----------------------------------------------------------------------------
# Иконки предметов (SHOW_ITEMS, v1.0.12; оружие/цвета/перекрытия v1.0.13):
# точки спавна оружия/брони/мегахелса из entity lump карты. Кэш
# blank_map/<map>.items (строка 1 — маркер версии формата, далее
# «X Y Z группа метка»): генерируется при отсутствии, когда .bsp новее кэша
# ИЛИ маркер версии не совпадает (кэш старого v1.0.12 — без RA/мегахелса).
# Затем кэш фильтруется: оружие по SHOW_WEAPONS, перекрытия по
# HIDE_OVERLAPPED_ITEMS. Любая проблема (нет .bsp, сбой экстрактора) —
# только WARN: иконки — украшение, партия рендерится без них. Пустой кэш
# (на карте нет подходящих предметов) — норма: рисуются только маркеры.
# ----------------------------------------------------------------------------
ITEMS_CACHE_HEADER="# heatmap-items-cache v2"
# радиус перекрытия иконок по X/Y, мировых единиц (габарит предмета Quake
# 32x32; два предмета ближе этого расстояния на виде сверху сливаются)
ITEMS_OVERLAP_RADIUS=32
ITEMS_GNUPLOT=""
hm_resolve_item_colors
if [[ "$SHOW_ITEMS" == "true" ]]; then
    ITEMS_PATH="${BLANK_MAP_DIR}/${MAP}.items"
    EXTRACT_ITEMS="${TOOLS_DIR}/extract_items.py"
    NEED_GEN=0
    if [[ ! -f "$BSP_PATH" ]]; then
        log WARN "иконки предметов: нет исходника карты ${BSP_PATH} — иконки не рисуются"
    elif [[ ! -f "$EXTRACT_ITEMS" ]]; then
        log WARN "иконки предметов: экстрактор не найден: ${EXTRACT_ITEMS} — иконки не рисуются"
    elif [[ ! -f "$ITEMS_PATH" ]]; then
        NEED_GEN=1
    elif [[ "$BSP_PATH" -nt "$ITEMS_PATH" ]]; then
        NEED_GEN=1
    elif [[ "$(head -n 1 "$ITEMS_PATH" 2>/dev/null)" != "$ITEMS_CACHE_HEADER" ]]; then
        log INFO "кэш точек предметов старого формата (v1.0.12: без RA/мегахелса) — регенерация (v1.0.13)"
        NEED_GEN=1
    fi
    if (( NEED_GEN == 1 )); then
        log INFO "генерация точек предметов: ${BSP_PATH} -> ${ITEMS_PATH}"
        if ! python3 "$EXTRACT_ITEMS" "$BSP_PATH" --output "$ITEMS_PATH"; then
            log WARN "extract_items.py не удался — иконки не рисуются"
        fi
    elif [[ -f "$ITEMS_PATH" ]]; then
        log INFO "иконки предметов: кэш ${ITEMS_PATH} актуален"
    fi
    # старый кэш без .bsp (легаси) используем как есть, но предупреждаем:
    # в нём нет мегахелса и красной брони
    if [[ -f "$ITEMS_PATH" && ! -f "$BSP_PATH" ]] \
       && [[ "$(head -n 1 "$ITEMS_PATH" 2>/dev/null)" != "$ITEMS_CACHE_HEADER" ]]; then
        log WARN "кэш точек предметов старого формата (v1.0.12) без .bsp — метки RA/MH могут отсутствовать; для регенерации нужен исходник карты"
    fi
    if [[ -s "${ITEMS_PATH:-}" ]]; then
        ITEMS_RAW_COUNT="$(grep -vc '^#' "$ITEMS_PATH" 2>/dev/null || true)"
        ITEMS_RAW_COUNT="${ITEMS_RAW_COUNT:-0}"
        ITEMS_FILTERED="${RUN_DIR}/items.filtered"
        filter_items_awk "$ITEMS_PATH" "$ITEMS_FILTERED"
        ITEM_COUNT="$(wc -l < "$ITEMS_FILTERED" | tr -d ' ')"
        if (( ITEM_COUNT > 0 )); then
            ITEMS_GNUPLOT="$ITEMS_FILTERED"
            log INFO "иконки предметов: в кэше ${ITEMS_RAW_COUNT} шт., к рендеру ${ITEM_COUNT} шт. (оружие: ${SHOW_WEAPONS_NORM:-нет}; перекрытия: $([[ "$HIDE_OVERLAPPED_ITEMS" == "true" ]] && echo "скрывать" || echo "показывать"); скрыто: $((ITEMS_RAW_COUNT - ITEM_COUNT)))"
        else
            log INFO "иконки предметов: 0 шт. — рисуются только маркеры"
        fi
    else
        log INFO "иконки предметов: 0 шт. — рисуются только маркеры"
    fi
else
    log INFO "SHOW_ITEMS=false — иконки предметов отключены"
fi

# FR-14: проверка согласованности размеров bmp и json
BMP_W="$(identify -format '%w' "$BMP_PATH" 2>/dev/null || true)"
BMP_H="$(identify -format '%h' "$BMP_PATH" 2>/dev/null || true)"
IMG_WIDTH="$(jq -er '.imageWidth | select(type=="number")' "$JSON_PATH" 2>/dev/null)" || die 3 "mapinfo ${JSON_PATH}: нет поля imageWidth"
IMG_HEIGHT="$(jq -er '.imageHeight | select(type=="number")' "$JSON_PATH" 2>/dev/null)" || die 3 "mapinfo ${JSON_PATH}: нет поля imageHeight"
if [[ -n "$BMP_W" && "$BMP_W" != "$IMG_WIDTH" ]] || [[ -n "$BMP_H" && "$BMP_H" != "$IMG_HEIGHT" ]]; then
    log WARN "размеры bmp ${BMP_W}x${BMP_H} не совпадают с mapinfo ${IMG_WIDTH}x${IMG_HEIGHT} — продолжаю с размерами json (FR-14)"
fi
if identify "$BMP_PATH" >/dev/null 2>&1; then BMP_QUIRK=0; else BMP_QUIRK=1; fi
if (( BMP_QUIRK == 1 )); then
    log INFO "bmp имеет некорректное поле размера в заголовке (известная особенность исходных подложек); IM6 при этом возвращает ненулевой код — принимаю кадры по факту создания файла"
fi

# параметры рендера из mapinfo (8.1.7). Ось Y — ПРЯМАЯ:
# MIN_Y = minY/scaling, MAX_Y = maxY/scaling — как и для X. Данные демки
# и json живут в координатах ФАЙЛА BSP; «зеркалить» Y (как в референсе)
# нельзя — Bounds Y в отчёте bsp2bmp выражены в координатах ИЗОБРАЖЕНИЯ,
# а не файла (эррата референса — см. историю v1.0.8 в README).
PADDING="$(jq -er '.padding | select(type=="number")' "$JSON_PATH" 2>/dev/null)" || die 3 "mapinfo ${JSON_PATH}: нет поля padding"
SCALING="$(jq -er '.scaling | select(type=="number")' "$JSON_PATH" 2>/dev/null)" || die 3 "mapinfo ${JSON_PATH}: нет поля scaling"
MIN_X="$(jq -r '.minX/.scaling' "$JSON_PATH")"
MAX_X="$(jq -r '.maxX/.scaling' "$JSON_PATH")"
MIN_Y="$(jq -r '.minY/.scaling' "$JSON_PATH")"
MAX_Y="$(jq -r '.maxY/.scaling' "$JSON_PATH")"
if ! is_num "$PADDING"; then die 3 "mapinfo: padding='${PADDING}' не число"; fi
if ! is_num "$SCALING"; then die 3 "mapinfo: scaling='${SCALING}' не число"; fi
if ! awk -v s="$SCALING" 'BEGIN{exit !(s>0)}'; then die 3 "mapinfo: scaling должен быть > 0"; fi
log INFO "рендер: ${IMG_WIDTH}x${IMG_HEIGHT}, padding=${PADDING}, scaling=${SCALING}, X[${MIN_X}:${MAX_X}] Y[${MIN_Y}:${MAX_Y}]"

# ----------------------------------------------------------------------------
# Цвета иконок предметов -> gnuplot (v1.0.13): ЧИСЛА 0xRRGGBB, резолвнутые
# hm_resolve_item_colors из строк конфига (tc rgb var со строкой молча не
# рисует метку). Строка GNUPLOT_ITEM_COLORS добавляется в пробу и в базу.
# ----------------------------------------------------------------------------
GNUPLOT_ITEM_COLORS="; HM_ITEM_COLOR_SG=${ITEM_COLOR_SG_HEX}"
GNUPLOT_ITEM_COLORS+="; HM_ITEM_COLOR_SS=${ITEM_COLOR_SS_HEX}"
GNUPLOT_ITEM_COLORS+="; HM_ITEM_COLOR_NG=${ITEM_COLOR_NG_HEX}"
GNUPLOT_ITEM_COLORS+="; HM_ITEM_COLOR_SNG=${ITEM_COLOR_SNG_HEX}"
GNUPLOT_ITEM_COLORS+="; HM_ITEM_COLOR_GL=${ITEM_COLOR_GL_HEX}"
GNUPLOT_ITEM_COLORS+="; HM_ITEM_COLOR_RL=${ITEM_COLOR_RL_HEX}"
GNUPLOT_ITEM_COLORS+="; HM_ITEM_COLOR_LG=${ITEM_COLOR_LG_HEX}"
GNUPLOT_ITEM_COLORS+="; HM_ITEM_COLOR_GA=${ITEM_COLOR_GA_HEX}"
GNUPLOT_ITEM_COLORS+="; HM_ITEM_COLOR_YA=${ITEM_COLOR_YA_HEX}"
GNUPLOT_ITEM_COLORS+="; HM_ITEM_COLOR_RA=${ITEM_COLOR_RA_HEX}"
GNUPLOT_ITEM_COLORS+="; HM_ITEM_COLOR_MH=${ITEM_COLOR_MH_HEX}"

# ----------------------------------------------------------------------------
# Стартовая gnuplot-проба (FR-36): мини-рендер с настроенной палитрой/маркерами
# и метками предметов — пробный items-файл содержит ВСЕ 11 меток, поэтому
# каждый запуск проверяет синтаксис items-plot и все строки цветов (имена
# проверены выше через ImageMagick; gnuplot получает их как есть)
# ----------------------------------------------------------------------------
PROBE_DIR="${RUN_DIR}/probe"
mkdir -p "$PROBE_DIR"
printf '0 0 0 5\n10 0 0 2\n-10 0 0 5\n' > "${PROBE_DIR}/probe.data"
cat > "${PROBE_DIR}/probe.items" <<'EOF'
5 5 0 1 SG
-5 5 0 1 SS
5 -5 0 1 NG
-5 -5 0 1 SNG
8 8 0 1 GL
-8 8 0 1 RL
8 -8 0 1 LG
-8 -8 0 2 GA
6 6 0 2 YA
-6 6 0 2 RA
6 -6 0 3 MH
EOF
_GNUPLOT_VARS="HM_DATA_FILE=$(gp_str "${PROBE_DIR}/probe.data")"
_GNUPLOT_VARS+="; HM_OUT_DIR=$(gp_str "$PROBE_DIR")"
_GNUPLOT_VARS+="; HM_NAME=$(gp_str "probe"); HM_FRAME=0; HM_EVERY=\"\""
_GNUPLOT_VARS+="; HM_MIN_X=-20; HM_MAX_X=20; HM_MIN_Y=-20; HM_MAX_Y=20"
_GNUPLOT_VARS+="; HM_MIN_Z=-1; HM_MAX_Z=1; HM_IMG_WIDTH=64; HM_IMG_HEIGHT=64"
_GNUPLOT_VARS+="; HM_PADDING=1; HM_SCALING=1"
_GNUPLOT_VARS+="; HM_MIN_MARKER_SIZE=${MIN_MARKER_SIZE}; HM_MAX_MARKER_SIZE=${MAX_MARKER_SIZE}"
_GNUPLOT_VARS+="; HM_PT_MOVE=${MARKER_MOVE_TYPE}; HM_PT_DEATH=${MARKER_DEATH_TYPE}"
_GNUPLOT_VARS+="; HM_PALETTE_CUSTOM=$(gp_str "$PALETTE_CUSTOM")"
_GNUPLOT_VARS+="; HM_PALETTE_MIN_COLOR=$(gp_str "$PALETTE_MIN_COLOR")"
_GNUPLOT_VARS+="; HM_PALETTE_MAX_COLOR=$(gp_str "$PALETTE_MAX_COLOR")"
_GNUPLOT_VARS+="; HM_ITEMS_FILE=$(gp_str "${PROBE_DIR}/probe.items")"
_GNUPLOT_VARS+="${GNUPLOT_ITEM_COLORS}"
if ! gnuplot -e "$_GNUPLOT_VARS" "$GNUPLOT_SCRIPT" 2> "${PROBE_DIR}/probe.err"; then
    log ERROR "стартовая gnuplot-проба не прошла — проверьте PALETTE_*/MARKER_* в конфиге (FR-36):"
    sed 's/^/    /' "${PROBE_DIR}/probe.err" 2>/dev/null || true
    die 1 "невалидная палитра/маркеры в конфиге (FR-36, код 1)"
fi
log INFO "стартовая gnuplot-проба: OK (палитра и маркеры валидны)"

# ----------------------------------------------------------------------------
# Парсинг демки (FR-15/16/17) — таймер этапа "парсинг"
# ----------------------------------------------------------------------------
T_START=$(date +%s)
T_PARSE_MS=0; T_FRAMES_MS=0; T_GIF_MS=0
_t0=$(date +%s%3N)

TEMPLATE_DAT="${RUN_DIR}/template.dat"
sed "s|@@XY_DATA_DIR@@|${XY_DATA_DIR}|g" "$TEMPLATE_TPL" > "$TEMPLATE_DAT" || {
    die 3 "не удалось сгенерировать template.dat из ${TEMPLATE_TPL} (FR-16)"
}
if grep -q '@@XY_DATA_DIR@@' "$TEMPLATE_DAT"; then
    die 3 "template.dat: плейсхолдер @@XY_DATA_DIR@@ не заменён (FR-16)"
fi
log INFO "template.dat сгенерирован: ${TEMPLATE_DAT}"

# симлинк демки (или копия при ошибке линковки)
ln -s -- "$DEMO_PATH" "${RUN_DIR}/last.mvd" 2>/dev/null || {
    cp -- "$DEMO_PATH" "${RUN_DIR}/last.mvd" || die 3 "не удалось линковать/скопировать демку (FR-15)"
}

# mvdparser пишет по абсолютному пути из template.dat (8.6).
# ВАЖНО (подводный камень, проверено на бинарнике): mvdparser молча НЕ
# открывает демку по абсолютному пути — работает только относительный.
# Поэтому запускаем из SCRIPT_DIR с относительными путями всех аргументов.
REL_DEMO="$(realpath --relative-to="$SCRIPT_DIR" "${RUN_DIR}/last.mvd")"
REL_FRAG="$(realpath --relative-to="$SCRIPT_DIR" "$FRAGFILE")"
REL_TPL="$(realpath --relative-to="$SCRIPT_DIR" "$TEMPLATE_DAT")"
REL_BIN="$(realpath --relative-to="$SCRIPT_DIR" "$MVDPARSER_BIN")"
[[ "$REL_BIN" == */* ]] || REL_BIN="./${REL_BIN}"
( cd "$SCRIPT_DIR" && \
    "$REL_BIN" -f "$REL_FRAG" -t "$REL_TPL" "$REL_DEMO" ) || {
    die 3 "mvdparser завершился с ошибкой (FR-17)"
}

shopt -s nullglob
data_files=("${XY_DATA_DIR}"/*.data)
shopt -u nullglob
if (( ${#data_files[@]} == 0 )); then
    die 3 "mvdparser не создал ни одного .data в ${XY_DATA_DIR} (FR-17)"
fi
log INFO "mvdparser: ${#data_files[@]} файл(ов) координат"

_t1=$(date +%s%3N); T_PARSE_MS=$((_t1 - _t0))

# ----------------------------------------------------------------------------
# MIN_Z / MAX_Z (8.4): общая шкала высоты. Значения ЛЮБОГО знака
# (эррата референса — см. историю v1.0.9 в README):
#   * выживает значение (любого знака) со счётчиком >= Z_OUTLIER_MIN_COUNT
#     (10 -> счётчик двузначный и более);
#   * если после фильтра пусто — сырой диапазон всех значений (8.4.3);
#   * MIN == MAX -> расширить на 1 (8.4.4).
# ----------------------------------------------------------------------------
z_range_awk() {
    # $1 = MINC (Z_OUTLIER_MIN_COUNT); $2.. = файлы .data
    awk -v MINC="$1" '
        {
            z = $3
            if (match(z, /^[-]?[0-9]+/)) { z = substr(z, RSTART, RLENGTH) } else { next }
            n = z + 0
            if (!all_set) { all_min = n; all_max = n; all_set = 1 }
            else { if (n < all_min) all_min = n; if (n > all_max) all_max = n }
            # значения любого знака (эррата референса 8.4)
            cnt[n]++
        }
        END {
            if (!all_set) { print "ERR"; exit }
            mn = ""; mx = ""
            for (k in cnt) {
                if (cnt[k] < MINC) continue
                v = k + 0
                if (mn == "" || v < mn) mn = v
                if (mx == "" || v > mx) mx = v
            }
            if (mn == "") { mn = all_min; mx = all_max }   # 8.4.3
            if (mn == mx) { mn = mn - 1; mx = mx + 1 }      # 8.4.4
            printf "%s %s\n", mn, mx
        }
    ' "${@:2}"
}

ZRANGE="$(z_range_awk "${Z_OUTLIER_MIN_COUNT:-10}" ${data_files[@]+"${data_files[@]}"})"
if [[ "$ZRANGE" == "ERR" || -z "$ZRANGE" ]]; then
    die 3 "не удалось вычислить MIN_Z/MAX_Z: нет корректных Z-значений в .data (8.4)"
fi
read -r MIN_Z MAX_Z <<< "$ZRANGE"
log INFO "шкала высот: MIN_Z=${MIN_Z} MAX_Z=${MAX_Z} (Z_OUTLIER_MIN_COUNT=${Z_OUTLIER_MIN_COUNT})"

# ----------------------------------------------------------------------------
# Передача параметров в gnuplot (8.8.1): только слоты и числа (FR-20)
# ----------------------------------------------------------------------------
GNUPLOT_BASE="HM_MIN_X=${MIN_X}; HM_MAX_X=${MAX_X}; HM_MIN_Y=${MIN_Y}; HM_MAX_Y=${MAX_Y}"
GNUPLOT_BASE+="; HM_MIN_Z=${MIN_Z}; HM_MAX_Z=${MAX_Z}"
GNUPLOT_BASE+="; HM_IMG_WIDTH=${IMG_WIDTH}; HM_IMG_HEIGHT=${IMG_HEIGHT}"
GNUPLOT_BASE+="; HM_PADDING=${PADDING}; HM_SCALING=${SCALING}"
GNUPLOT_BASE+="; HM_MIN_MARKER_SIZE=${MIN_MARKER_SIZE}; HM_MAX_MARKER_SIZE=${MAX_MARKER_SIZE}"
GNUPLOT_BASE+="; HM_PT_MOVE=${MARKER_MOVE_TYPE}; HM_PT_DEATH=${MARKER_DEATH_TYPE}"
GNUPLOT_BASE+="; HM_PALETTE_CUSTOM=$(gp_str "$PALETTE_CUSTOM")"
GNUPLOT_BASE+="; HM_PALETTE_MIN_COLOR=$(gp_str "$PALETTE_MIN_COLOR")"
GNUPLOT_BASE+="; HM_PALETTE_MAX_COLOR=$(gp_str "$PALETTE_MAX_COLOR")"
# иконки предметов: пустая строка = xy.gnuplot рисует только маркеры
GNUPLOT_BASE+="; HM_ITEMS_FILE=$(gp_str "$ITEMS_GNUPLOT")"
GNUPLOT_BASE+="${GNUPLOT_ITEM_COLORS}"

# ----------------------------------------------------------------------------
# Обработка игроков (FR-18..25) — таймеры этапов "кадры" и "сборка GIF"
# ----------------------------------------------------------------------------
: > "${RUN_DIR}/players.txt"   # внутренний журнал, в результат не публикуется
declare -A USED_NAMES=()
SLOT_NUM=0
GIF_COUNT=0

for DATA_FILE in ${data_files[@]+"${data_files[@]}"}; do
    RAW_NICK="$(basename -- "$DATA_FILE" .data)"
    SLOT_NUM=$((SLOT_NUM + 1))
    SLOT="$(printf 'p%03d' "$SLOT_NUM")"

    # санитизация ника (8.5) + пусто -> player_<слот>
    NICK_S="$(sanitize_name "$RAW_NICK")"
    if [[ -z "$NICK_S" ]]; then NICK_S="player_${SLOT}"; fi
    # коллизии имён внутри партии (8.5.5 / FR-25)
    CAND="$NICK_S"; _k=2
    while [[ -n "${USED_NAMES[$CAND]:-}" ]]; do
        CAND="${NICK_S}_${_k}"
        _k=$((_k + 1))
    done
    NICK_S="$CAND"
    USED_NAMES["$NICK_S"]=1

    log INFO "игрок ${SLOT}: ник '${RAW_NICK}' -> имя результата '${NICK_S}'"

    # FR-19: минимум строк
    LINES_ALL="$(awk 'END{print NR}' "$DATA_FILE")"
    if (( LINES_ALL < MIN_DATA_LINES )); then
        log WARN "игрок ${SLOT} ('${RAW_NICK}'): строк ${LINES_ALL} < MIN_DATA_LINES=${MIN_DATA_LINES} — пропущен (FR-19)"
        continue
    fi
    # L — число точек данных, как их нумерует gnuplot every (пустые строки
    # и мусорные строки точками не являются — проверено на gnuplot 5.4)
    L="$(awk '$1 ~ /^[-+]?[0-9]/ {c++} END{print c+0}' "$DATA_FILE")"
    if (( L == 0 )); then
        log WARN "игрок ${SLOT} ('${RAW_NICK}'): нет строк данных — пропущен (FR-19)"
        continue
    fi

    # число кадров (8.2): interleave — каждый NUM-й замер партии
    NUM=$MAX_FRAMES
    if (( NUM > L )); then NUM=$L; fi
    if (( NUM < 1 )); then
        log WARN "игрок ${SLOT} ('${RAW_NICK}'): 0 кадров — пропущен"
        continue
    fi
    log INFO "игрок ${SLOT}: строк данных L=${L}, кадров NUM=${NUM}"

    PDIR="${FRAMES_DIR}/${SLOT}"
    mkdir -p "$PDIR"
    FRAME_OK=0
    _pf0=$(date +%s%3N)

    for (( f = 0; f < NUM; f++ )); do
        EVERY="every ${NUM}::${f}"
        FRAME_BASE="${PDIR}/${SLOT}$(printf '%03d' "$f")"

        _GV="${GNUPLOT_BASE}; HM_DATA_FILE=$(gp_str "$DATA_FILE")"
        _GV+="; HM_OUT_DIR=$(gp_str "$PDIR")"
        _GV+="; HM_NAME=$(gp_str "$SLOT"); HM_FRAME=${f}; HM_EVERY=$(gp_str "$EVERY")"

        if ! gnuplot -e "$_GV" "$GNUPLOT_SCRIPT" 2> "${PDIR}/gnuplot.err"; then
            log WARN "игрок ${SLOT}: кадр $((f + 1))/${NUM} — сбой gnuplot, кадр пропущен (FR-24)"
            continue
        fi
        if [[ ! -s "${FRAME_BASE}.png" ]]; then
            log WARN "игрок ${SLOT}: кадр $((f + 1))/${NUM} — gnuplot не создал файл, кадр пропущен (FR-24)"
            continue
        fi
        # FR-22: наложение без -trim (кадры обязаны иметь одинаковое полотно)
        composite "${FRAME_BASE}.png" "$BMP_PATH" "${FRAME_BASE}_map.png" 2>> "${PDIR}/composite.err" || true
        if [[ ! -s "${FRAME_BASE}_map.png" ]]; then
            log WARN "игрок ${SLOT}: кадр $((f + 1))/${NUM} — сбой composite, кадр пропущен (FR-24)"
            continue
        fi
        FRAME_OK=$((FRAME_OK + 1))
    done

    _pf1=$(date +%s%3N); T_FRAMES_MS=$((T_FRAMES_MS + _pf1 - _pf0))

    # FR-24: успешно менее половины кадров — GIF не собирается
    if (( FRAME_OK * 2 < NUM )); then
        log WARN "игрок ${SLOT} ('${RAW_NICK}'): успешных кадров ${FRAME_OK} из ${NUM} (< половины) — GIF не собирается (FR-24)"
        continue
    fi

    _pg0=$(date +%s%3N)
    GIF_NAME="${NICK_S}.gif"
    # FR-23: сборка GIF (лексикографический порядок кадров — 3-значный паддинг)
    if ! convert -delay "$GIF_DELAY_CS" -loop "$GIF_LOOP" \
            "${PDIR}/${SLOT}"*"_map.png" "${STAGE_DIR}/${GIF_NAME}" 2>> "${PDIR}/convert.err"; then
        if [[ ! -s "${STAGE_DIR}/${GIF_NAME}" ]]; then
            log WARN "игрок ${SLOT} ('${RAW_NICK}'): сбой convert — GIF пропущен (FR-24)"
            rm -f -- "${STAGE_DIR}/${GIF_NAME}"
            continue
        fi
        log INFO "convert вернул ненулевой код, GIF создан — принят"
    fi
    # оптимизация GIF (FR-23); сбой оптимизации не фатален
    if ! mogrify -layers 'optimize' -fuzz "${GIF_OPTIMIZE_FUZZ}%" "${STAGE_DIR}/${GIF_NAME}" 2>> "${PDIR}/convert.err"; then
        log WARN "игрок ${SLOT}: сбой mogrify -layers optimize — оставляю GIF без оптимизации"
    fi
    _pg1=$(date +%s%3N); T_GIF_MS=$((T_GIF_MS + _pg1 - _pg0))

    GSIZE="$(stat -c%s "${STAGE_DIR}/${GIF_NAME}" 2>/dev/null || echo 0)"
    printf '%s\t%s\t%s\n' "$SLOT" "$RAW_NICK" "$GIF_NAME" >> "${RUN_DIR}/players.txt"
    GIF_COUNT=$((GIF_COUNT + 1))
    log INFO "игрок ${SLOT}: GIF готов: ${GIF_NAME} (${GSIZE} байт, кадров ${FRAME_OK}/${NUM}, время $(( (_pg1 - _pf0 + 500) / 1000 )) с)"
done

if (( GIF_COUNT == 0 )); then
    log ERROR "ни для одного игрока не построен GIF — публикация не выполняется"
    log INFO "тайминги: парсинг $((T_PARSE_MS / 1000)).$(((T_PARSE_MS % 1000) / 100))с, кадры $((T_FRAMES_MS / 1000)).$(((T_FRAMES_MS % 1000) / 100))с, сборка GIF $((T_GIF_MS / 1000)).$(((T_GIF_MS % 1000) / 100))с"
    exit 3
fi

# ----------------------------------------------------------------------------
# Публикация (FR-26/27): атомарный mv staging -> result/
# ----------------------------------------------------------------------------
# копия demoinfo для провенанса (управляется RESULT_COPY_DEMOINFO)
if [[ "${RESULT_COPY_DEMOINFO,,}" == "true" ]]; then
    cp -- "$DEMOINFO_SRC" "${STAGE_DIR}/demoinfo.json" || die 3 "не удалось скопировать demoinfo в staging (FR-26)"
else
    log INFO "RESULT_COPY_DEMOINFO=false — копия demoinfo.json в результат не добавляется"
fi

mkdir -p "$RESULT_DIR" || die 3 "не удалось создать ${RESULT_DIR}"
# повторная проверка уникальности имени непосредственно перед публикацией
RNAME="$BASENAME_R"
_n=2
while [[ -e "${RESULT_DIR}/${RNAME}" || -L "${RESULT_DIR}/${RNAME}" ]]; do
    RNAME="${BASENAME_R}-${_n}"
    _n=$((_n + 1))
done
if ! mv -- "${STAGE_DIR}" "${RESULT_DIR}/${RNAME}"; then
    die 3 "публикация не удалась: mv ${STAGE_DIR} -> ${RESULT_DIR}/${RNAME} (FR-26)"
fi
TOTAL_SIZE="$(du -sb "${RESULT_DIR}/${RNAME}" 2>/dev/null | awk '{print $1}')"
PLAYER_LINES="$(wc -l < "${RUN_DIR}/players.txt" 2>/dev/null || echo 0)"
log INFO "опубликован каталог результата: result/${RNAME} (${TOTAL_SIZE} байт, GIF: ${GIF_COUNT}, players: ${PLAYER_LINES})"

# ----------------------------------------------------------------------------
# Ретеншн результатов (FR-28) и логов (FR-29)
# ----------------------------------------------------------------------------
RESULT_PAT='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]:[0-9][0-9]:[0-9][0-9]_.+'

# (а) по возрасту mtime
while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    log INFO "ретеншн: удаляю каталог результата (возраст > ${RETENTION_MAX_AGE_DAYS} сут): ${d}"
    rm -rf -- "$d" 2>/dev/null || log WARN "ретеншн: не удалось удалить ${d}"
done < <(find "$RESULT_DIR" -mindepth 1 -maxdepth 1 -type d \
            -regextype posix-extended -regex ".*/${RESULT_PAT}" \
            -mtime "+${RETENTION_MAX_AGE_DAYS}" -print 2>/dev/null)

# (б) по количеству: удаляются старейшие, пока не уложимся в RETENTION_MAX_DIRS
_dir_count="$(find "$RESULT_DIR" -mindepth 1 -maxdepth 1 -type d \
                  -regextype posix-extended -regex ".*/${RESULT_PAT}" -print 2>/dev/null | wc -l)"
if (( _dir_count > RETENTION_MAX_DIRS )); then
    _excess=$((_dir_count - RETENTION_MAX_DIRS))
    log INFO "ретеншн: каталогов результата ${_dir_count} > RETENTION_MAX_DIRS=${RETENTION_MAX_DIRS} — удаляю старейшие (${_excess} шт.)"
    while IFS= read -r d; do
        if (( _excess <= 0 )); then break; fi
        log INFO "ретеншн: удаляю старейший каталог результата: ${d}"
        rm -rf -- "$d" 2>/dev/null || log WARN "ретеншн: не удалось удалить ${d}"
        _excess=$((_excess - 1))
    done < <(find "$RESULT_DIR" -mindepth 1 -maxdepth 1 -type d \
                 -regextype posix-extended -regex ".*/${RESULT_PAT}" \
                 -printf '%T@ %p\n' 2>/dev/null | sort -n | cut -d' ' -f2-)
fi

# логи старше LOG_RETENTION_DAYS суток
while IFS= read -r lf; do
    [[ -z "$lf" ]] && continue
    log INFO "ретеншн: удаляю старый лог (${LOG_RETENTION_DAYS} сут): ${lf}"
    rm -f -- "$lf" 2>/dev/null || true
done < <(find "$LOG_DIR" -mindepth 1 -maxdepth 1 -type f -name 'heatmap-*.log' \
             -mtime "+${LOG_RETENTION_DAYS}" -print 2>/dev/null)

# ----------------------------------------------------------------------------
# Финиш (FR-33): общее время и поэтапные тайминги
# ----------------------------------------------------------------------------
T_END=$(date +%s)
_fmt_ms() { echo "$(($1 / 1000)).$(($1 % 1000 / 100))"; }
log INFO "тайминги: всего $((T_END - T_START)) с; парсинг $( _fmt_ms "$T_PARSE_MS")с; кадры $( _fmt_ms "$T_FRAMES_MS")с; сборка GIF $( _fmt_ms "$T_GIF_MS")с"
log INFO "итог: результат result/${RNAME}, GIF ${GIF_COUNT}, игроков обработано ${SLOT_NUM}"

exit 0

