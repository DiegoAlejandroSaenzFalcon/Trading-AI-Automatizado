import MetaTrader5 as mt5
from datetime import datetime
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")

df = mt5.history_deals_get(datetime(2025,1,1), datetime.now())
positions = {}
for d in df:
    if d.entry in (0, 1):
        positions.setdefault(d.position_id, []).append(d)

SYM = "XAUUSDm"
print("=== EA (magic 1111) detalle por comentario ===")
by_cmt = {}
for pos_id, ds in positions.items():
    pnl = sum(d.profit for d in ds if d.profit != 0.0)
    if pnl == 0 or ds[0].symbol != SYM or ds[0].magic != 1111: continue
    cmts = sorted(set(d.comment for d in ds))
    key = ",".join(c for c in cmts if c)[:40]
    by_cmt.setdefault(key, [0.0, 0, 0, 0])
    v = by_cmt[key]
    v[0] += pnl; v[1] += 1
    if pnl > 0: v[2] += 1
    else: v[3] += 1
for k, v in sorted(by_cmt.items(), key=lambda x: -x[1][0]):
    wr = v[2]/v[1]*100
    print(f"  {k:40s} trades={v[1]:>3}  pnl={v[0]:>9.2f}  win={wr:.0f}%")
ea_total = sum(v[0] for v in by_cmt.values())
print(f"  TOTAL EA: {ea_total:.2f}")

print("\n=== MANUALES grandes y fechas EA ===")
m_pnl = m_n = m_w = 0
for pos_id, ds in positions.items():
    pnl = sum(d.profit for d in ds if d.profit != 0.0)
    if pnl == 0 or ds[0].symbol != SYM: continue
    if ds[0].magic == 1111: continue
    m_pnl += pnl; m_n += 1
    if pnl > 0: m_w += 1
    t0 = min(d.time for d in ds); t1 = max(d.time for d in ds)
    vol = max((d.volume for d in ds), default=0)
    if abs(pnl) > 100:
        print(f"  #{pos_id} {datetime.utcfromtimestamp(t0):%m-%d %H:%M}->{datetime.utcfromtimestamp(t1):%m-%d %H:%M} pnl={pnl:>9.2f} vol={vol}")
print(f"  TOTAL manual: {m_n} trades, pnl={m_pnl:.2f}, win={m_w/m_n*100:.0f}%")

# horas de operacion del EA
print("\n=== Horas apertura EA (server) ===")
from collections import Counter
hours = Counter()
for pos_id, ds in positions.items():
    pnl = sum(d.profit for d in ds if d.profit != 0.0)
    if pnl == 0: continue
    if ds[0].symbol != SYM or ds[0].magic != 1111: continue
    import struct
    # hora del broker desde timestamp deal
    t0 = min(d.time for d in ds)
    from datetime import timezone
    hours[datetime.fromtimestamp(t0, timezone.utc).hour] += 1
for h in sorted(hours): print(f"  {h:02d}h: {hours[h]}")
mt5.shutdown()
