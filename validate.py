import datetime
import numpy as np
import pandas as pd
import MetaTrader5 as mt5
from diag_filters import run


def load(tf, days):
    mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
    end = datetime.datetime.now()
    start = end - datetime.timedelta(days=days)
    rates = mt5.copy_rates_range("BTCUSDm", tf, start, end)
    mt5.shutdown()
    d = pd.DataFrame(rates)
    d["time"] = pd.to_datetime(d["time"], unit="s")
    d = d.set_index("time")
    d["tp"] = (d["high"] + d["low"] + d["close"]) / 3
    d["tv"] = 1.0
    return d


def report(d, label):
    n, w, p, dd = run(d, sl_a=2.0, tp_a=4.0, f_vwap=True, f_adx=True, f_rsi=False,
                      f_kalman=False, start_h=16, end_h=22, adx_min=22,
                      rsi_ranges=(40, 75, 25, 60))
    print(f"{label}: {n} tr | wr {w/max(n,1)*100:.0f}% | P&L {p:.0f} | DD {dd:.0f}")


full = load(mt5.TIMEFRAME_H1, 120)
first = full.loc[:full.index.min() + datetime.timedelta(days=60)]
second = full.loc[full.index.min() + datetime.timedelta(days=60):]
report(full, "120 días completo")
report(first, "60 días primera mitad")
report(second, "60 días segunda mitad")

for sl, tp in [(1.5, 3.0), (2.0, 3.0), (2.0, 4.0), (2.0, 5.0), (2.5, 5.0), (3.0, 6.0)]:
    n, w, p, dd = run(full, sl_a=sl, tp_a=tp, f_vwap=True, f_adx=True, f_rsi=False,
                      f_kalman=False, start_h=16, end_h=22, adx_min=22,
                      rsi_ranges=(40, 75, 25, 60))
    print(f"SL{sl}/TP{tp}: {n} tr | wr {w/max(n,1)*100:.0f}% | P&L {p:.0f} | DD {dd:.0f}")
