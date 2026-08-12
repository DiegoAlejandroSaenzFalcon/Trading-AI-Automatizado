import MetaTrader5 as mt5
import pandas as pd
from datetime import datetime, timedelta

if not mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe"):
    print("MT5 init failed:", mt5.last_error())
    raise SystemExit

acc = mt5.account_info()
print("=== CUENTA ===")
print(f"Login: {acc.login} | {acc.server} | {acc.currency}")
print(f"Balance: {acc.balance} | Equity: {acc.equity} | Flotante: {acc.profit:+.2f} | MargenLibre: {acc.margin_free:.2f}")

print("")
print("=== POSICIONES ABIERTAS ===")
pos = mt5.positions_get()
if pos:
    for p in pos:
        side = "BUY" if p.type == 0 else "SELL"
        print(f"{p.symbol} {side} lot={p.volume} entry={p.price_open:.2f} sl={p.sl:.2f} tp={p.tp:.2f} profit={p.profit:+.2f} magic={p.magic}")
else:
    print("Sin posiciones")

print("")
print("=== DEALS DE HOY ===")
frm = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
deals = mt5.history_deals_get(frm, datetime.now())
by_magic = {}
total_today = 0.0
if deals:
    for d in sorted(deals, key=lambda x: x.time):
        dt = datetime.fromtimestamp(d.time).strftime("%H:%M")
        t = {0:"BUY",1:"SELL"}.get(d.type, d.type)
        print(f"{dt} {d.symbol} {t} vol={d.volume} price={d.price:.2f} profit={d.profit:+.2f} magic={d.magic} comment={d.comment}")
        total_today += d.profit
        by_magic.setdefault(d.magic, 0.0)
        by_magic[d.magic] += d.profit
    print(f"P&L REALIZADO HOY: {total_today:+.2f}")
    print(f"POR MAGIC: {by_magic}")
else:
    print("Sin deals hoy")

print("")
print("=== PRECIOS LIVE ===")
for sym in ["BTCUSDm", "XAUUSDm"]:
    rates = mt5.copy_rates_from_pos(sym, mt5.TIMEFRAME_M15, 0, 96)
    if rates is not None and len(rates) > 0:
        df = pd.DataFrame(rates)
        cur = df.iloc[-1]
        prevd = df.iloc[-96] if len(df) > 95 else df.iloc[0]
        chg = (cur["close"] - prevd["close"]) * 100 / prevd["close"]
        print(f"{sym}: {cur['close']:.2f} ({(chg):+.2f}% vs hace 24h | rango 24h: {df['low'].min():.2f}-{df['high'].max():.2f})")

mt5.shutdown()
