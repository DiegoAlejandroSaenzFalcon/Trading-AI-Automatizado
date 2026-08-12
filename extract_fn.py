import re
src = open(r"C:\Users\H2R\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\MQL5\Experts\Pure_Fractal_FVG_Fusion_BTCUSD_r30.mq5", encoding="utf-8", errors="replace").read()
lines = src.splitlines()
# extraer ComputeBiasProbability completa
start = None
for i, l in enumerate(lines):
    if "double ComputeBiasProbability" in l:
        start = i
        break
if start:
    depth = 0
    out = []
    for l in lines[start:start+120]:
        out.append(l)
        depth += l.count("{") - l.count("}")
        if depth <= 0 and out and l.strip().startswith("}"):
            break
    print("\n".join(out))
