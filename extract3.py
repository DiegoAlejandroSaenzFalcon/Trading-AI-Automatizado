import re
src = open(r"C:\Users\H2R\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\MQL5\Experts\Pure_Fractal_FVG_Fusion_BTCUSD_r30.mq5", encoding="utf-8", errors="replace").read()
lines = src.splitlines()

def extract(name_search, max_lines=400):
    start = None
    for i, l in enumerate(lines):
        if name_search in l and "//" not in l.split(name_search)[0]:
            start = i
            break
    if start is None:
        return "NOT FOUND"
    depth = 0
    out = []
    for l in lines[start:start+max_lines]:
        out.append(l)
        depth += l.count("{") - l.count("}")
        if depth <= 0 and "}" in l and len(out) > 2:
            break
    return "\n".join(out)

print("=== UPDATEPAACTIONFVGBIAS ===")
print(extract("UpdatePriceActionFVGBias"))
