import MetaTrader5 as mt5
from datetime import datetime
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")

df = mt5.history_deals_get(datetime(2025,1,1), datetime.now())
positions = {}
for d in df:
    if d.entry in (0, 1):
        positions.setdefault(d.position_id, []).append(d)

print("=== RESUMEN POR MAGIC ===")
by_magic = {}
for pos_id, ds in positions.items():
    pnl = sum(d.profit for d in ds if d.profit != 0.0)
    if pnl == 0: continue
    magic = ds[0].magic
    cmts = set(d.comment for d in ds)
    key = (magic, "|".join(sorted(cmts))[:50])
    by_magic.setdefault(key, [0.0, 0, 0, 0.0, 0.0, []])
    v = by_magic[key]
    v[0] += pnl; v[1] += 1
    if pnl > 0: v[2] += 1
    else: v[3] += 1
    v[4] = max(v[4], max((d.volume for d in ds if d.profit != 0), default=0))
    v[5].append((pos_id, pnl))
for (magic, cmt), v in sorted(by_magic.items(), key=lambda x: -x[1][0]):
    wr = v[2]/v[1]*100 if v[1] else 0
    print(f"magic={magic:>8}  trades={v[1]:>3}  pnl={v[0]:>10.2f}  win={wr:.0f}%  maxVol={v[4]:.2f}  cmt={cmt[:40]}")

mt5.shutdown()
