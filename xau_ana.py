import MetaTrader5 as mt5
from datetime import datetime
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")

df = mt5.history_deals_get(datetime(2025,1,1), datetime.now())
positions = {}
for d in df:
    if d.entry in (0, 1):
        positions.setdefault(d.position_id, []).append(d)

print("=== SIMBOLOS OPERADOS ===")
by_sym = {}
for pos_id, ds in positions.items():
    pnl = sum(d.profit for d in ds if d.profit != 0.0)
    if pnl == 0: continue
    sym = ds[0].symbol
    magic = ds[0].magic
    netsym = "EA(magic 1111)" if magic == 1111 else "MANUAL/otro"
    by_sym.setdefault((sym, netsym), [0.0, 0, 0, 0])
    v = by_sym[(sym, netsym)]
    v[0] += pnl; v[1] += 1
    if pnl > 0: v[2] += 1
    else: v[3] += 1
for (sym, kind), v in sorted(by_sym.items(), key=lambda x: -x[1][0]):
    wr = v[2]/v[1]*100 if v[1] else 0
    print(f"  {sym:12s} {kind:18s} trades={v[1]:>3}  pnl={v[0]:>10.2f}  win={wr:.0f}%")

print("\n=== EA XAUUSD NeurAlgo M1 (magic 1111) — detalle por comentario ===")
by_cmt = {}
for pos_id, ds in positions.items():
    pnl = sum(d.profit for d in ds if d.profit != 0.0)
    if pnl == 0: continue
    if ds[0].symbol != "XAUUSD": continue
    cmts = sorted(set(d.comment for d in ds))
    key = "".join(c for c in cmts)[:30]
    by_cmt.setdefault(key, [0.0, 0, 0, 0])
    v = by_cmt[key]
    v[0] += pnl; v[1] += 1
    if pnl > 0: v[2] += 1
    else: v[3] += 1
for k, v in sorted(by_cmt.items(), key=lambda x: -x[1][0]):
    wr = v[2]/v[1]*100
    print(f"  {k:30s} trades={v[1]:>3}  pnl={v[0]:>9.2f}  win={wr:.0f}%")

print("\n=== MANUALES XAUUSD ===")
m_pnl = m_n = m_w = 0
for pos_id, ds in positions.items():
    pnl = sum(d.profit for d in ds if d.profit != 0.0)
    if pnl == 0 or ds[0].symbol != "XAUUSD" or ds[0].magic == 1111: continue
    m_pnl += pnl; m_n += 1
    if pnl > 0: m_w += 1
    t0 = min(d.time for d in ds); t1 = max(d.time for d in ds)
    vol = max((d.volume for d in ds), default=0)
    if abs(pnl) > 100:
        print(f"  #{pos_id} {datetime.utcfromtimestamp(t0):%m-%d %H:%M}->{datetime.utcfromtimestamp(t1):%m-%d %H:%M} pnl={pnl:>9.2f} vol={vol}")
print(f"  TOTAL manual XAUUSD: {m_n} trades, pnl={m_pnl:.2f}, win={m_w/m_n*100:.0f}%")
mt5.shutdown()
