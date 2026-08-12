import re
src = open(r"C:\Users\H2R\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\MQL5\Experts\Pure_Fractal_FVG_Fusion_BTCUSD_r30.mq5", encoding="utf-8", errors="replace").read()
lines = src.splitlines()
print(f"Total lineas: {len(lines)}")
# Buscar funciones clave
for i, l in enumerate(lines):
    if re.search(r"Kalman|kf|Signal|sigmo|probab|Bias", l, re.I) and ("double" in l or "bool" in l or "void" in l or "int" in l):
        print(f"{i+1}: {l.strip()[:120]}")
