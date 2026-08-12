import re
src = open(r"C:\Users\H2R\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\MQL5\Experts\Pure_Fractal_FVG_Fusion_BTCUSD_r30.mq5", encoding="utf-8", errors="replace").read()
lines = src.splitlines()
# buscar definiciones de funciones con su nombre exacto
for i, l in enumerate(lines):
    s = l.strip()
    if re.match(r"^(void|bool|double|int|ENUM|ulong)\s+\w+\s*\([^;]*\)\s*$", s) or (re.match(r"^(void|bool|double|int|ulong)\s+\w+\s*\(", s) and ";" not in s):
        print(i+1, ":", s[:100])
