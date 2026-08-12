import MetaTrader5 as mt5
import pandas as pd

if not mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe"):
    print("MT5 init failed:", mt5.last_error())
    raise SystemExit

acc = mt5.account_info()
print("=== CUENTA ===")
print(f"Login: {acc.login} | Balance: {acc.balance} | Equity: {acc.equity} | MargenLibre: {acc.margin_free} | Profit: {acc.profit}")
print("")

print("=== POSICIONES ABIERTAS ===")
pos = mt5.positions_get()
if pos:
    for p in pos:
        side = "BUY" if p.type == 0 else "SELL"
        print(f"{p.symbol} {side} lot={p.volume} entry={p.price_open:.2f} sl={p.sl:.2f} tp={p.tp:.2f} profit={p.profit:.2f} magic={p.magic}")
else:
    print("Sin posiciones abiertas")

print("")
print("=== PRECIOS EN VIVO ===")
for sym, tf, tfn in [
    ("XAUUSD", mt5.TIMEFRAME_M15, "M15"),
    ("XAUUSD", mt5.TIMEFRAME_H1, "H1"),
    ("BTCUSDm", mt5.TIMEFRAME_M15, "M15"),
    ("BTCUSDm", mt5.TIMEFRAME_H1, "H1"),
]:
    rates = mt5.copy_rates_from_pos(sym, tf, 0, 120)
    if rates is None or len(rates) < 30:
        print(f"{sym} {tfn}: sin datos")
        continue
    df = pd.DataFrame(rates)
    cur = df.iloc[-1]
    prev = df.iloc[-2]
    chg = (cur["close"] - prev["close"]) * 100 / prev["close"]
    hi = df["high"].max()
    lo = df["low"].min()
    print(f"{sym} {tfn}: last={cur['close']:.2f} chg_vs_prev={chg:+.2f}% rango120={lo:.2f}-{hi:.2f} MA20={df['close'].tail(20).mean():.2f}")

print("")
print("=== DEALS RECIENTES (ultimas 10) ===")
deals = mt5.history_deals_get()
if deals:
    with open("C:/Users/H2R/Documents/Default Project/snapshot_deals.txt", "w", encoding="utf-8") as f:
        for d in reversed(deals[-10:]):
            f.write(f"{d.time} {d.symbol} {d.type} lot={d.volume} price={d.price:.2f} profit={d.profit:.2f} magic={d.magic} comment={d.comment}\n")
    print("guardado en snapshot_deals.txt")

mt5.shutdown()