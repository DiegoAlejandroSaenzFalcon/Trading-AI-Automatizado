import MetaTrader5 as mt5
from datetime import datetime
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")

df = mt5.history_deals_get(datetime(2025,1,1), datetime.now())
print("=== DEPOSITOS/RETIROS/OPERACIONES DE BALANCE ===")
bal = 0.0
for d in df:
    if d.type in (1, 2, 3, 4):  # balance, credit, charge, correction
        print(f"{datetime.utcfromtimestamp(d.time)}  type={d.type}  {d.comment}  ${d.profit:.2f}")
        bal += d.profit
print(f"total balance ops: {bal:.2f}")
print()
# Group by position for realized PnL
positions = {}
for d in df:
    if d.entry in (0, 1):  # in/out
        positions.setdefault(d.position_id, []).append(d)
print("=== TRADES CERRADOS (EA + manuales) ===")
total_pnl = 0.0
for pos_id, ds in sorted(positions.items()):
    pnl = sum(d.profit for d in ds if d.profit != 0.0)
    total_pnl += pnl
    t0 = min(d.time for d in ds)
    t1 = max(d.time for d in ds)
    vols = set(d.volume for d in ds if d.profit != 0)
    vol = sum(d.volume for d in ds if d.profit != 0)/max(1,len([d for d in ds if d.profit != 0]))
    comment = ds[0].comment if ds else ""
    print(f"#{pos_id} {datetime.utcfromtimestamp(t0):%m-%d %H:%M} -> {datetime.utcfromtimestamp(t1):%m-%d %H:%M}  pnl={pnl:>9.2f}  vol={vol:.2f}  {comment[:40]}")
print(f"\nTOTAL PnL: {total_pnl:.2f}")
mt5.shutdown()
