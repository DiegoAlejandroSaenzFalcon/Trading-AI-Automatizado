import csv
from datetime import datetime, timezone

rows = list(csv.DictReader(open(r"C:\Users\H2R\Documents\Default Project\trades_r30_nosesion.csv")))
for r in rows:
    r["h"] = datetime.utcfromtimestamp(float(r["entry_time"])).hour
    r["pnl"] = float(r["pnl"])

def window(rows, h0, h1):
    tot, n, w = 0.0, 0, 0
    for r in rows:
        h = r["h"]
        inside = (h >= h0 and h < h1) if h0 < h1 else (h >= h0 or h < h1)
        if inside:
            tot += r["pnl"]
            n += 1
            if r["pnl"] > 0: w += 1
    return tot, n, (w/n*100 if n else 0)

print(f"{'Ventana':<14}{'PnL':>10}{'Trades':>8}{'Win%':>8}")
for h0 in range(24):
    for ln in (3, 4, 5):
        h1 = (h0 + ln) % 24
        tot, n, w = window(rows, h0, h1)
        label = f"{h0:02d}-{h1:02d}h"
        print(f"{label:<14}{tot:>10.1f}{n:>8}{w:>7.1f}%")
    print()
print("=== Ventana ACTUAL 16-19h ===")
tot, n, w = window(rows, 16, 19)
print(f"PnL: {tot:.1f}  Trades: {n}  Win%: {w:.1f}%")
print("=== Ventana actual +19h ===")
tot, n, w = window(rows, 16, 20)
print(f"PnL: {tot:.1f}  Trades: {n}  Win%: {w:.1f}%")
