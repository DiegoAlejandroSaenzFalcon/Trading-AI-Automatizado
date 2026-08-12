import datetime
import numpy as np
import pandas as pd
import MetaTrader5 as mt5
from backtest_v2 import adx, rsi, kalman_velocity


def run(d, sl_a, tp_a, f_vwap, f_adx, f_rsi, f_kalman, start_h, end_h, adx_min, rsi_ranges, vwap_pct=0.0):
    d = d.copy()
    d["vwap"] = (d["tp"] * d["tv"]).groupby(d.index.date).cumsum() / d["tv"].groupby(d.index.date).cumsum()
    d["hour"] = d.index.hour
    dx, atr = adx(d["high"], d["low"], d["close"], 14)
    d["adx"] = dx
    d["atr"] = atr
    d["rsi"] = rsi(d["close"], 14)
    d["kvel"] = kalman_velocity(d["close"])[1]

    trades = []
    pos = None
    for i in range(200, len(d)):
        row = d.iloc[i]
        if pos is not None:
            ep = None
            if pos["side"] == 1:
                if row["low"] <= pos["sl"]:
                    ep = pos["sl"]
                elif row["high"] >= pos["tp"]:
                    ep = pos["tp"]
            else:
                if row["high"] >= pos["sl"]:
                    ep = pos["sl"]
                elif row["low"] <= pos["tp"]:
                    ep = pos["tp"]
            if ep is not None:
                p = (ep - pos["entry"]) * pos["lot"] if pos["side"] == 1 else (pos["entry"] - ep) * pos["lot"]
                p -= 15.0 * pos["lot"]
                trades.append({"pnl": p})
                pos = None
            continue
        if not (start_h <= row["hour"] < end_h):
            continue
        if f_adx and (np.isnan(row["adx"]) or row["adx"] < adx_min):
            continue
        if f_rsi and np.isnan(row["rsi"]):
            continue
        if f_kalman and np.isnan(row["kvel"]):
            continue
        if f_vwap and (np.isnan(row["vwap"]) or abs(row["close"] - row["vwap"]) < vwap_pct * row["vwap"]):
            continue

        above = row["close"] >= row["vwap"] * (1 + vwap_pct) if f_vwap else True
        below = row["close"] <= row["vwap"] * (1 - vwap_pct) if f_vwap else True
        side = None
        r = row["rsi"]
        if above and (not f_rsi or (rsi_ranges[0] <= r <= rsi_ranges[1])) and (not f_kalman or row["kvel"] > 0):
            side = 1
        elif below and (not f_rsi or (rsi_ranges[2] <= r <= rsi_ranges[3])) and (not f_kalman or row["kvel"] < 0):
            side = -1
        if side is None:
            continue
        sl_dist = sl_a * row["atr"]
        lot = min(0.25, 12.0 / sl_dist)
        lot = max(0.01, round(lot, 2))
        entry = row["close"]
        pos = {"side": side, "entry": entry,
               "sl": entry - sl_dist if side == 1 else entry + sl_dist,
               "tp": entry + tp_a * row["atr"] if side == 1 else entry - tp_a * row["atr"],
               "lot": lot}
    if not trades:
        return 0, 0, 0.0, 0.0
    df = pd.DataFrame(trades)
    wins = df[df["pnl"] > 0]
    cum = df["pnl"].cumsum()
    pf = wins["pnl"].sum() / abs(df[df["pnl"] < 0]["pnl"].sum()) if (df["pnl"] < 0).any() else np.inf
    return len(df), len(wins), df["pnl"].sum(), (cum - cum.cummax()).min()


def main():
    mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
    end = datetime.datetime.now()
    start = end - datetime.timedelta(days=120)
    rates = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_H1, start, end)
    mt5.shutdown()
    d = pd.DataFrame(rates)
    d["time"] = pd.to_datetime(d["time"], unit="s")
    d = d.set_index("time")
    d["tp"] = (d["high"] + d["low"] + d["close"]) / 3
    d["tv"] = 1.0

    cases = [
        ("BASE sin filtros (solo sesion)", dict(sl_a=1.0, tp_a=1.5, f_vwap=False, f_adx=False, f_rsi=False, f_kalman=False, start_h=0, end_h=24, adx_min=22, rsi_ranges=(40, 75, 25, 60))),
        ("+VWAP", dict(sl_a=1.0, tp_a=1.5, f_vwap=True, f_adx=False, f_rsi=False, f_kalman=False, start_h=0, end_h=24, adx_min=22, rsi_ranges=(40, 75, 25, 60))),
        ("+VWAP+ADX22", dict(sl_a=1.0, tp_a=1.5, f_vwap=True, f_adx=True, f_rsi=False, f_kalman=False, start_h=0, end_h=24, adx_min=22, rsi_ranges=(40, 75, 25, 60))),
        ("+VWAP+ADX+RSI", dict(sl_a=1.0, tp_a=1.5, f_vwap=True, f_adx=True, f_rsi=True, f_kalman=False, start_h=0, end_h=24, adx_min=22, rsi_ranges=(40, 75, 25, 60))),
        ("TODO + Kalman", dict(sl_a=1.0, tp_a=1.5, f_vwap=True, f_adx=True, f_rsi=True, f_kalman=True, start_h=0, end_h=24, adx_min=22, rsi_ranges=(40, 75, 25, 60))),
        ("TODO sesion NY 16-22", dict(sl_a=1.0, tp_a=1.5, f_vwap=True, f_adx=True, f_rsi=True, f_kalman=True, start_h=16, end_h=22, adx_min=22, rsi_ranges=(40, 75, 25, 60))),
        ("VWAP+ADX+RSI sesion NY", dict(sl_a=1.0, tp_a=1.5, f_vwap=True, f_adx=True, f_rsi=True, f_kalman=False, start_h=16, end_h=22, adx_min=22, rsi_ranges=(40, 75, 25, 60))),
        ("VWAP+ADX sesion NY SL2/TP4", dict(sl_a=2.0, tp_a=4.0, f_vwap=True, f_adx=True, f_rsi=False, f_kalman=False, start_h=16, end_h=22, adx_min=22, rsi_ranges=(40, 75, 25, 60))),
    ]
    for label, c in cases:
        n, w, p, dd = run(d, **c)
        print(f"{label:28s}: {n:4d} tr | wr {w/max(n,1)*100:3.0f}% | P&L {p:7.0f} | DD {dd:7.0f}")


if __name__ == "__main__":
    main()
