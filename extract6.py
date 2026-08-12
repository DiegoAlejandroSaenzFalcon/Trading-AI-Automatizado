src = open(r"C:\Users\H2R\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\MQL5\Experts\Pure_Fractal_FVG_Fusion_BTCUSD_r30.mq5", encoding="utf-8", errors="replace").read()
lines = src.splitlines()

def get(start_idx, max_lines=400):
    depth = 0
    out = []
    for l in lines[start_idx:start_idx+max_lines]:
        out.append(l)
        depth += l.count("{") - l.count("}")
        if depth <= 0 and "}" in l and len(out) > 2:
            break
    return "\n".join(out)

def find(name):
    for i, l in enumerate(lines):
        if l.strip().startswith(name):
            return i
    return None

for fn in ["void OnTick(", "void ExecuteBiasedEntry(", "void ManageExitsAndProtection(", "double ComputeAdaptiveSLTP(", "double CalcLotSizeForRisk(", "double NormalizeVolumeForRisk(", "bool IsBullishEngulfing(", "bool IsBearishPinBar("]:
    i = find(fn)
    print(f"===== {fn} (linea {i+1 if i is not None else 'N/A'}) =====")
    if i is not None:
        print(get(i, 400))
