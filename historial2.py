import MetaTrader5 as mt5
from datetime import datetime
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")

df = mt5.history_deals_get(datetime(2025,1,1), datetime.now())
print("=== DEPOSITOS/RETIROS/BALANCE ===")
for d in df:
    if d.type in (1, 2, 3, 4):
        print(f"{datetime.utcfromtimestamp(d.time):%Y-%m-%d %H:%M}  type={d.type}  ${d.profit:.2f}  {d.comment}")

# Resumen por mes de PnL de trades
positions = {}
for d in df:
    if d.entry in (0, 1):
        positions.setdefault(d.position_id, []).append(d)

print("\n=== PnL MENSUAL ===")
monthly = {}
for pos_id, ds in sorted(positions.items()):
    pnl = sum(d.profit for d in ds if d.profit != 0.0)
    if pnl == 0: continue
    t0 = min(d.time for d in ds)
    key = datetime.utcfromtimestamp(t0).strftime("%Y-%m")
    monthly.setdefault(key, [0.0, 0, 0.0, 0.0])
    monthly[key][0] += pnl
    monthly[key][1] += 1
    if pnl > 0: monthly[key][2] += 1
    else: monthly[key][3] += 1
for k in sorted(monthly):
    v = monthly[k]
    print(f"{k}: pnl={v[0]:>10.2f}  trades={v[1]:>3}  wins={v[2]:>3}  losses={v[3]:>3}  winrate={v[2]/v[1]*100:.0f}%")

# Distribucion por tamaño de lote (separar EA de manuales)
print("\n=== POR LOTE (EA vs manual) ===")
ea_pnl = manual_pnl = 0.0; ea_n = manual_n = 0
for pos_id, ds in positions.items():
    pnl = sum(d.profit for d in ds if d.profit != 0.0)
    if pnl == 0: continue
    vols = [d.volume for d in ds if d.profit != 0.0]
    vol = sum(vols)/len(vols) if vols else 0
    # comentarios del EA
    cmts = " ".join(d.comment for d in ds if d.profit != 0)
    if "NET_HEDGE" in cmts or "REC_" in cmts or "L1" in cmts or "L2" in cmts:
        ea_pnl += pnl; ea_n += 1
    else:
        manual_pnl += pnl; manual_n += 1
print(f"EA (netting/rec): {ea_n} trades, pnl={ea_pnl:.2f}")
print(f"MANUAL (sin comment): {manual_n} trades, pnl={manual_pnl:.2f}")

# Los grandes manuales de 10.00 lotes
print("\n=== TRADES >= 5 lotes (manuales grandes) ===")
for pos_id, ds in sorted(positions.items()):
    pnl = sum(d.profit for d in ds if d.profit != 0.0)
    vols = [d.volume for d in ds if d.profit != 0.0]
    if max(vols) >= 5.0:
        t0 = min(d.time for d in ds); t1 = max(d.time for d in ds)
        print(f"#{pos_id} {datetime.utcfromtimestamp(t0):%m-%d %H:%M}->{datetime.utcfromtimestamp(t1):%m-%d %H:%M} pnl={pnl:>9.2f} vol={vols} cmt={ds[0].comment[:30]}")
mt5.shutdown()
