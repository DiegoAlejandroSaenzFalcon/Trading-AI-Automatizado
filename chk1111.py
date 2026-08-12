import MetaTrader5 as mt5
if not mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe"):
    print("init failed", mt5.last_error())
    raise SystemExit
pos = mt5.positions_get()
total = 0.0
wins = losses = 0
print(f"Posiciones magic 1111: {len(pos) if pos else 0}")
if pos:
    for p in pos:
        side = "BUY" if p.type == 0 else "SELL"
        print(f"  {p.symbol} {side} lot={p.volume} entry={p.price_open:.2f} profit={p.profit:+.2f}")
        total += p.profit
    print(f"Flotante total 1111: {total:+.2f}")
from datetime import datetime, timedelta
frm = datetime.now() - timedelta(hours=6)
deals = mt5.history_deals_get(frm, datetime.now())
mag = [d for d in (deals or []) if d.magic == 1111]
pnl = sum(d.profit for d in mag if d.profit != 0)
closed = [d for d in mag if d.profit != 0]
print(f"Deals magic 1111 (6h): {len(mag)} | cerradas: {len(closed)} | P&L realizado: {pnl:+.2f}")
mt5.shutdown()
