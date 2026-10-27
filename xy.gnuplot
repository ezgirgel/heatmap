# ============================================================================
# xy.gnuplot — отрисовка одного кадра перемещений игрока (gnuplot >= 5.4)
#
# Все параметры передаются через gnuplot -e (см. heatmap.sh):
#   строковые: HM_DATA_FILE, HM_OUT_DIR, HM_NAME (слот), HM_EVERY,
#              HM_PALETTE_CUSTOM, HM_PALETTE_MIN_COLOR, HM_PALETTE_MAX_COLOR
#   числовые:  HM_FRAME, HM_MIN_X, HM_MAX_X, HM_MIN_Y, HM_MAX_Y,
#              HM_MIN_Z, HM_MAX_Z, HM_IMG_WIDTH, HM_IMG_HEIGHT,
#              HM_PADDING, HM_SCALING,
#              HM_PT_MOVE, HM_PT_DEATH,
#              HM_MIN_MARKER_SIZE, HM_MAX_MARKER_SIZE
#
# Ник игрока в gnuplot не передаётся (только слот pNNN) — защита от инъекций
# через кавычки/спецсимволы в нике (FR-20).
#
# Команда plot собирается в строку и исполняется через eval — это позволяет
# передавать произвольную every-клаузу (режимы interleave/chunks, 8.2/8.3).
# Зависимость от CWD устранена (D-13); флаг -p (persist) не используется.
# ============================================================================

# --- входные параметры ------------------------------------------------------

DATA_FILE = HM_DATA_FILE
OUT_DIR   = HM_OUT_DIR
NAME      = HM_NAME
FRAME     = int(HM_FRAME)
EVERY     = HM_EVERY

MIN_X = real(HM_MIN_X)
MAX_X = real(HM_MAX_X)
MIN_Y = real(HM_MIN_Y)
MAX_Y = real(HM_MAX_Y)
MIN_Z = real(HM_MIN_Z)
MAX_Z = real(HM_MAX_Z)

IMG_WIDTH  = int(HM_IMG_WIDTH)
IMG_HEIGHT = int(HM_IMG_HEIGHT)
PADDING    = real(HM_PADDING)
SCALING    = real(HM_SCALING)

# маркеры (7.3): тип события в колонке 4 данных не зависит от настроек
# (5 = движение, 2 = смерть); «фигурка» — явное тернарное выражение в
# using (FR-35). Размер маркера задаётся формулой высоты с настраиваемыми
# концами MIN_MARKER_SIZE/MAX_MARKER_SIZE из конфига (v1.0.9; дефолт
# 0.5..3.0); старые ключи MARKER_*_SIZE в конфиге по-прежнему игнорируются.
PT_MOVE  = int(HM_PT_MOVE)
PT_DEATH = int(HM_PT_DEATH)

PALETTE_CUSTOM    = HM_PALETTE_CUSTOM
PALETTE_MIN_COLOR = HM_PALETTE_MIN_COLOR
PALETTE_MAX_COLOR = HM_PALETTE_MAX_COLOR

MIN_MARKER_SIZE = real(HM_MIN_MARKER_SIZE)
MAX_MARKER_SIZE = real(HM_MAX_MARKER_SIZE)

# --- терминал и полотно ------------------------------------------------------

# прозрачный кадр; размер полотна = размеру подложки (наложение composite без -gravity)
set terminal pngcairo transparent size IMG_WIDTH,IMG_HEIGHT
set output sprintf("%s/%s%03d.png", OUT_DIR, NAME, FRAME)

unset key
unset tics
unset colorbox
set bmargin 0
set tmargin 0
set lmargin 0
set rmargin 0
set view map
set hidden3d
set pm3d

set xrange [MIN_X-PADDING:MAX_X+PADDING]
set yrange [MIN_Y-PADDING:MAX_Y+PADDING]
set cbrange [MIN_Z:MAX_Z]

# --- палитра из конфига (8.8.6) ----------------------------------------------
# PALETTE_CUSTOM непуст -> подставляется дословно после "set palette";
# иначе -> defined (MIN_Z "<цвет>", MAX_Z "<цвет>"), позиции MIN_Z/MAX_Z
# остаются gnuplot-переменными.
if (strlen(PALETTE_CUSTOM) > 0) {
    PCMD = "set palette " . PALETTE_CUSTOM
} else {
    PCMD = 'set palette defined (MIN_Z "' . PALETTE_MIN_COLOR . '", MAX_Z "' . PALETTE_MAX_COLOR . '")'
}
eval PCMD

# --- кадр (8.8.2) -------------------------------------------------------------
# колонки данных: 1=X 2=Y 3=Z 4=тип события (5 движение / 2 смерть)
#
# ВАЖНО (порядок переменных колонок, установлен экспериментально на gnuplot
# 5.4 patchlevel 1 — T-20): для "with points pointsize var pointtype var
# lt palette" дополнительные using-колонки потребляются как
#       x : y : pointTYPE : pointSIZE : colorbox
# Референсный xy.gnuplot (его команда: formula, $4, $3) написан под СТАРЫЙ
# gnuplot (порядок size:type:cb) и на 5.4 ломается — эталонные GIF сняты
# старой версией. Правильная раскладка для 5.4:
#       TYPE — тернарник из конфига (FR-35),
#       SIZE — формула высоты MIN_MARKER_SIZE + t*(MAX_MARKER_SIZE-
#             MIN_MARKER_SIZE), t=(z-MIN_Z)/(MAX_Z-MIN_Z) («чем ниже,
#             тем меньше»); концы настраиваются в heatmap.conf (v1.0.9,
#             дефолт 0.5..3.0; MARKER_*_SIZE устарели — см. heatmap.conf),
#       CB — сырой Z (при cbrange [MIN_Z:MAX_Z] палитра blue->red).
# История дефекта v1.0.x: порядок был верный, но содержимое слотов — нет:
# в SIZE попадала константа MARKER_*_SIZE (точки в ~5 раз крупнее), а в CB —
# нормированное значение 0.5..1.5 при cbrange [0:272] (градиент сжимался
# в синий). На схемах с PT≡PS (5/5 и 2/2) это не бросалось в глаза и не
# ловилось до реального прогона warfare (2026-10-27).
CMD = sprintf("plot '%s' %s using ($1/SCALING):($2/SCALING):(column(4)==5 ? PT_MOVE : PT_DEATH):(((column(3)-MIN_Z)/(MAX_Z-MIN_Z))*(MAX_MARKER_SIZE-MIN_MARKER_SIZE)+MIN_MARKER_SIZE):(column(3)) with points pointsize var pointtype var lt palette", DATA_FILE, EVERY)
eval CMD
