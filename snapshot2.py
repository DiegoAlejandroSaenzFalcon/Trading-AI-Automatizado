import MetaTrader5 as mt5
import pandas as pd
from datetime import datetime, timedelta

if not mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe"):
    print("MT5 init failed:", mt5.last_error())
    raise SystemExit

for sym in ["XAUUSDm", "XAUUSD", "XAUUSD.a", "BTCUSDm"]:
    rates = mt5.copy_rates_from_pos(sym, mt5.TIMEFRAME_M15, 0, 120)
    if rates is not None and len(rates) > 0:
        df = pd.DataFrame(rates)
        cur = df.iloc[-1]
        chg = (cur["close"] - df.iloc[-2]["close"]) * 100 / df.iloc[-2]["close"]
        ma20 = df["close"].tail(20).mean()
        print(f"{sym} M15: last={cur['close']:.2f} chg={chg:+.2f}% MA20={ma20:.2f} max120={df['high'].max():.2f} min120={df['low'].min():.2f}")
    else:
        print(f"{sym}: NO DISPONIBLE en API")

print("--- HISTORIAL DEALS (ultimos 3 dias) ---")
frm = datetime.now() - timedelta(days=3)
deals = mt5.history_deals_get(frm, datetime.now())
if deals:
    for d in sorted(deals, key=lambda x: x.time)[-15:]:
        dt = datetime.fromtimestamp(d.time).strftime("%m-%d %H:%M")
        t = {0:"BUY",1:"SELL"}.get(d.type, d.type)
        print(f"{dt} {d.symbol} {t} vol={d.volume} price={d.price:.2f} profit={d.profit:.2f} magic={d.magic} comment={d.comment}")
else:
    print("sin deals")

mt5.shutdown()
