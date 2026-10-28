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
#   строковые: HM_ITEMS_FILE — файл точек предметов (пустая строка = иконки
#              не рисуются; SHOW_ITEMS в heatmap.conf)
#
# Ник игрока в gnuplot не передаётся (только слот pNNN) — защита от инъекций
# через кавычки/спецсимволы в нике (FR-20).
#
# Команда plot собирается в строку и исполняется через eval — это позволяет
# передавать произвольную every-клаузу кадра (8.2: каждый NUM-й замер).
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
# концами MIN_MARKER_SIZE/MAX_MARKER_SIZE из конфига (дефолт 0.7..1.5).
PT_MOVE  = int(HM_PT_MOVE)
PT_DEATH = int(HM_PT_DEATH)

PALETTE_CUSTOM    = HM_PALETTE_CUSTOM
PALETTE_MIN_COLOR = HM_PALETTE_MIN_COLOR
PALETTE_MAX_COLOR = HM_PALETTE_MAX_COLOR

MIN_MARKER_SIZE = real(HM_MIN_MARKER_SIZE)
MAX_MARKER_SIZE = real(HM_MAX_MARKER_SIZE)

# отсутствующий HM_ITEMS_FILE (прямые вызовы xy.gnuplot старыми тестами/
# утилитами) — иконки просто не рисуются; heatmap.sh передаёт его всегда
ITEMS_FILE = (exists("HM_ITEMS_FILE") ? HM_ITEMS_FILE : "")

# --- иконки предметов (SHOW_ITEMS, v1.0.12) ----------------------------------
# blank_map/<map>.items, колонки: 1=X 2=Y 3=Z 4=группа (1 оружие / 2 броня) 5=метка.
# Цвета и масштаб меток — константы (намеренно БЕЗ ключей конфига):
ITEM_COLOR_WEAPON = 45056       # 0x00B000 зелёный — оружие (SG..LG)
ITEM_COLOR_ARMOR  = 14721024    # 0xE0A000 янтарный — броня (GA/YA/RA)
# Метка крупнее маркера («чуть больше»): диаметр точки в pngcairo ≈ 7.3 ×
# pointsize px, высота глифа ≈ 1.04 × pt; 1.3 × 7.3 ≈ 9.5 pt на единицу
# pointsize маркера.
ITEM_FONT_SCALE   = 9.5
# Размер метки — та же формула высоты, что у маркеров, с клэмпом t в [0:1]
# (предмет за пределами шкалы партии получает размер края шкалы).
ITEM_T(z)    = (z - MIN_Z) / (MAX_Z - MIN_Z)
ITEM_CLAMP(z) = (ITEM_T(z) < 0 ? 0 : (ITEM_T(z) > 1 ? 1 : ITEM_T(z)))
# нижняя граница 4pt — защита от {/=0} при экстремально малых MIN_MARKER_SIZE
# (max() в сборке gnuplot 5.4.1 отсутствует — тернарник)
ITEM_FONT(z) = (int((MIN_MARKER_SIZE + ITEM_CLAMP(z) * (MAX_MARKER_SIZE - MIN_MARKER_SIZE)) * ITEM_FONT_SCALE + 0.5) < 4 ? 4 : int((MIN_MARKER_SIZE + ITEM_CLAMP(z) * (MAX_MARKER_SIZE - MIN_MARKER_SIZE)) * ITEM_FONT_SCALE + 0.5))

# --- терминал и полотно ------------------------------------------------------

# прозрачный кадр; размер полотна = размеру подложки (наложение composite без
# -gravity); enhanced — обязателен для меток предметов ({/=N} внутри using)
set terminal pngcairo transparent enhanced size IMG_WIDTH,IMG_HEIGHT
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
# ВАЖНО (порядок переменных колонок в gnuplot 5.4, установлен
# экспериментально — T-20): для "with points pointsize var pointtype var
# lt palette" дополнительные using-колонки потребляются как
#       x : y : pointTYPE : pointSIZE : colorbox
# (референсный xy.gnuplot написан под старый gnuplot с порядком
# size:type:cb и на 5.4 ломается). Раскладка:
#       TYPE — тернарник из конфига (FR-35),
#       SIZE — формула высоты MIN_MARKER_SIZE + t*(MAX_MARKER_SIZE-
#             MIN_MARKER_SIZE), t=(z-MIN_Z)/(MAX_Z-MIN_Z) («чем ниже,
#             тем меньше»); концы настраиваются в heatmap.conf,
#       CB — сырой Z (при cbrange [MIN_Z:MAX_Z] палитра blue->red).
CMD = sprintf("plot '%s' %s using ($1/SCALING):($2/SCALING):(column(4)==5 ? PT_MOVE : PT_DEATH):(((column(3)-MIN_Z)/(MAX_Z-MIN_Z))*(MAX_MARKER_SIZE-MIN_MARKER_SIZE)+MIN_MARKER_SIZE):(column(3)) with points pointsize var pointtype var lt palette", DATA_FILE, EVERY)
# --- иконки предметов: вторым источником того же plot -> рисуются ПОВЕРХ
# маркеров (передний план). Текст через enhanced {/=pt} — покадровый размер
# шрифта; цвет — колонка-тернарник группы (tc rgb var).
if (strlen(ITEMS_FILE) > 0) {
    CMD = CMD . sprintf(", '%s' using ($1/SCALING):($2/SCALING):(sprintf('{/=%d %s}', ITEM_FONT(column(3)), strcol(5))):(column(4)==1 ? ITEM_COLOR_WEAPON : ITEM_COLOR_ARMOR) with labels tc rgb var center", ITEMS_FILE)
}
eval CMD
