import sys
import datetime
import numpy as np
import pandas as pd
import MetaTrader5 as mt5
from backtest_v2 import run_backtest

mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
for tf, name in [(mt5.TIMEFRAME_M15, "M15"), (mt5.TIMEFRAME_H1, "H1"), (mt5.TIMEFRAME_H4, "H4")]:
    end = datetime.datetime.now()
    start = end - datetime.timedelta(days=120)
    rates = mt5.copy_rates_range("BTCUSDm", tf, start, end)
    if rates is None or len(rates) == 0:
        print(name, "sin datos")
        continue
    d = pd.DataFrame(rates)
    d["time"] = pd.to_datetime(d["time"], unit="s")
    d = d.set_index("time")
    d["tp"] = (d["high"] + d["low"] + d["close"]) / 3
    d["tv"] = 1.0
    print(f"== {name} | {len(d)} velas ==")
    for sl_a, tp_a in [(1.0, 1.5), (1.0, 2.0), (1.5, 2.0), (2.0, 4.0), (2.0, 6.0)]:
        t = run_backtest(d, sl_a, tp_a, use_trail=True)
        if not t:
            print(f"  SL{sl_a} TP{tp_a}: sin trades")
            continue
        df = pd.DataFrame(t)
        wins = df[df["pnl"] > 0]
        pf = wins["pnl"].sum() / abs(df[df["pnl"] < 0]["pnl"].sum()) if (df["pnl"] < 0).any() else np.inf
        cum = df["pnl"].cumsum()
        dd = (cum - cum.cummax()).min()
        print(f"  SL{sl_a} TP{tp_a}: {len(df)} tr | wr {len(wins)/len(df)*100:.0f}% | P&L {df['pnl'].sum():.0f} | PF {pf:.2f} | DD {dd:.0f}")
mt5.shutdown()