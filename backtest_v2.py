import datetime
import numpy as np
import pandas as pd
import MetaTrader5 as mt5

SYMBOL = "BTCUSDm"
SPREAD_PRICE = 15.0
SLIPPAGE_PRICE = 5.0
RISK_USD = 12.0
DAILY_LIMIT_USD = 48.0
MAX_LOT = 0.25
ATR_N = 14
ADX_N = 14
RSI_N = 14
ADX_MIN = 22.0
RSI_LONG_LO, RSI_LONG_HI = 45.0, 72.0
RSI_SHORT_LO, RSI_SHORT_HI = 28.0, 55.0
SL_ATR = 2.5
TP_ATR = 5.0
BE_TRIGGER_ATR = 1.0
TRAIL_ATR = 1.5
SESSION_START, SESSION_END = 16, 19
DAYS = 120


def adx(high, low, close, n=14):
    up = high.diff()
    dn = -low.diff()
    plus_dm = np.where((up > dn) & (up > 0), up, 0.0)
    minus_dm = np.where((dn > up) & (dn > 0), dn, 0.0)
    tr = pd.concat([(high - low), (high - close.shift()).abs(), (low - close.shift()).abs()], axis=1).max(axis=1)
    atr = tr.ewm(alpha=1 / n, min_periods=n).mean()
    plus_di = 100 * pd.Series(plus_dm, index=high.index).ewm(alpha=1 / n, min_periods=n).mean() / atr
    minus_di = 100 * pd.Series(minus_dm, index=high.index).ewm(alpha=1 / n, min_periods=n).mean() / atr
    dx = 100 * (plus_di - minus_di).abs() / (plus_di + minus_di).replace(0, np.nan)
    return dx.ewm(alpha=1 / n, min_periods=n).mean(), atr


def rsi(close, n=14):
    d = close.diff()
    gain = d.clip(lower=0).ewm(alpha=1 / n, min_periods=n).mean()
    loss = (-d.clip(upper=0)).ewm(alpha=1 / n, min_periods=n).mean()
    return 100 - 100 / (1 + gain / loss.replace(0, np.nan))


def kalman_velocity(close, q_pos=1e-4, q_vel=1e-2, r=1e-3):
    x = np.zeros(len(close)); v = np.zeros(len(close))
    p00, p11, p01 = 1.0, 1.0, 0.0
    x[0] = close.iloc[0]
    dt = 1.0
    for i in range(1, len(close)):
        xp = x[i-1] + dt * v[i-1]
        vp = v[i-1]
        p00p = p00 + dt * p01 * 2 + dt * dt * p11 + q_pos
        p01p = p01 + dt * p11
        p11p = p11 + q_vel
        s = p00p + r
        k0 = p00p / s
        k1 = p01p / s
        y = close.iloc[i] - xp
        x[i] = xp + k0 * y
        v[i] = vp + k1 * y
        p00 = (1 - k0) * p00p
        p01 = (1 - k0) * p01p
        p11 = p11p - k1 * p01p
    return pd.Series(x, index=close.index), pd.Series(v, index=close.index)


def run_backtest(df, sl_atr, tp_atr, use_trail=True, risk_usd=RISK_USD, verbose=False):
    d = df.copy()
    d["vwap"] = (d["tp"] * d["tv"]).groupby(d.index.date).cumsum() / d["tv"].groupby(d.index.date).cumsum()
    d["hour"] = d.index.hour
    dx, atr = adx(d["high"], d["low"], d["close"], ADX_N)
    d["adx"] = dx
    d["atr"] = atr
    d["rsi"] = rsi(d["close"], RSI_N)
    d["kvel"] = kalman_velocity(d["close"])[1]
    d["in_session"] = ((d["hour"] >= SESSION_START) & (d["hour"] < SESSION_END)).astype(bool)

    trades = []
    pos = None
    day_pl = 0.0
    last_day = None
    for i in range(200, len(d)):
        row = d.iloc[i]
        day = row.name.date()
        if day != last_day:
            day_pl = 0.0
            last_day = day
        if day_pl <= -DAILY_LIMIT_USD:
            continue

        if pos is not None:
            exit_price = None
            exit_reason = ""
            if pos["side"] == 1:
                if row["low"] <= pos["sl"]:
                    exit_price, exit_reason = pos["sl"] - SLIPPAGE_PRICE, "SL"
                elif row["high"] >= pos["tp"]:
                    exit_price, exit_reason = pos["tp"] - SLIPPAGE_PRICE, "TP"
                elif use_trail and row["close"] >= pos["be_trig"] and pos["sl"] < pos["entry"]:
                    pos["sl"] = pos["entry"] + SPREAD_PRICE
                    pos["be_trig"] = np.inf
                    if row["low"] <= pos["sl"]:
                        exit_price, exit_reason = pos["sl"] - SLIPPAGE_PRICE, "BE"
            else:
                if row["high"] >= pos["sl"]:
                    exit_price, exit_reason = pos["sl"] + SLIPPAGE_PRICE, "SL"
                elif row["low"] <= pos["tp"]:
                    exit_price, exit_reason = pos["tp"] + SLIPPAGE_PRICE, "TP"
                elif use_trail and row["close"] <= pos["be_trig"] and (pos["sl"] == 0 or pos["sl"] > pos["entry"]):
                    pos["sl"] = pos["entry"] - SPREAD_PRICE
                    pos["be_trig"] = -np.inf
                    if row["high"] >= pos["sl"]:
                        exit_price, exit_reason = pos["sl"] + SLIPPAGE_PRICE, "BE"
            if exit_price is None and pos["sl"] > 0 and row["close"] is not None:
                if pos["side"] == 1 and row["low"] <= pos["sl"]:
                    exit_price, exit_reason = pos["sl"] - SLIPPAGE_PRICE, "SL"
                elif pos["side"] == -1 and row["high"] >= pos["sl"]:
                    exit_price, exit_reason = pos["sl"] + SLIPPAGE_PRICE, "SL"
            if exit_price is not None:
                pnl = (exit_price - pos["entry"]) * pos["lot"] if pos["side"] == 1 else (pos["entry"] - exit_price) * pos["lot"]
                pnl -= SPREAD_PRICE * pos["lot"]
                trades.append({**pos, "exit": exit_price, "exit_time": row.name, "pnl": pnl, "reason": exit_reason})
                day_pl += pnl
                pos = None
            continue

        if not row["in_session"]:
            continue
        if np.isnan(row["adx"]) or row["adx"] < ADX_MIN:
            continue
        if np.isnan(row["rsi"]) or np.isnan(row["atr"]) or row["atr"] <= 0:
            continue
        if np.isnan(row["kvel"]):
            continue

        side = None
        if row["close"] > row["vwap"] and RSI_LONG_LO <= row["rsi"] <= RSI_LONG_HI and row["kvel"] > 0:
            side = 1
        elif row["close"] < row["vwap"] and RSI_SHORT_LO <= row["rsi"] <= RSI_SHORT_HI and row["kvel"] < 0:
            side = -1
        if side is None:
            continue

        sl_dist = sl_atr * row["atr"]
        lot = min(MAX_LOT, risk_usd / sl_dist)
        lot = max(0.01, round(lot, 2))
        entry = row["close"]
        sl = entry - sl_dist if side == 1 else entry + sl_dist
        tp = entry + tp_atr * row["atr"] if side == 1 else entry - tp_atr * row["atr"]
        pos = {
            "side": side, "entry": entry, "sl": sl, "tp": tp, "lot": lot,
            "entry_time": row.name,
            "be_trig": entry + BE_TRIGGER_ATR * row["atr"] if side == 1 else entry - BE_TRIGGER_ATR * row["atr"],
        }
    return trades


def run_sweep(d):
    results = []
    for sl_a, tp_a in [(1.0, 1.5), (1.0, 2.0), (1.5, 2.0), (1.5, 3.0), (2.0, 3.0), (2.0, 4.0), (0.8, 1.2), (0.8, 2.0)]:
        t = run_backtest(d, sl_a, tp_a, use_trail=True)
        if not t:
            continue
        df = pd.DataFrame(t)
        wins = df[df["pnl"] > 0]
        gross = df["pnl"].sum()
        losses = df[df["pnl"] < 0]["pnl"].sum()
        pf = wins["pnl"].sum() / abs(losses) if losses != 0 else np.inf
        cum = df["pnl"].cumsum()
        max_dd = (cum - cum.cummax()).min()
        print(f"SL {sl_a}x | TP {tp_a}x: {len(df)} tr | wr {len(wins)/len(df)*100:.0f}% | "
              f"P&L {gross:.0f} | PF {pf:.2f} | DD {max_dd:.0f}")
    return results


def summarize(trades, label):
    if not trades:
        print(f"{label}: SIN TRADES")
        return
    df = pd.DataFrame(trades)
    wins = df[df["pnl"] > 0]
    gross = df["pnl"].sum()
    pf = wins["pnl"].sum() / abs(df[df["pnl"] < 0]["pnl"].sum()) if (df["pnl"] < 0).any() else np.inf
    cum = df["pnl"].cumsum()
    max_dd = (cum - cum.cummax()).min()
    print(f"{label}: {len(df)} trades | winrate {len(wins)/len(df)*100:.0f}% | "
          f"P&L {gross:.0f} USD | PF {pf:.2f} | maxDD {max_dd:.0f} | "
          f"días {df['entry_time'].dt.date.nunique()} | avg {gross/len(df):.2f}/trade")


def main():
    mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
    end = datetime.datetime.now()
    start = end - datetime.timedelta(days=DAYS)
    rates = mt5.copy_rates_range(SYMBOL, mt5.TIMEFRAME_M1, start, end)
    mt5.shutdown()
    if rates is None or len(rates) == 0:
        print("Sin datos")
        return
    d = pd.DataFrame(rates)
    d["time"] = pd.to_datetime(d["time"], unit="s")
    d = d.set_index("time")
    d["tp"] = (d["high"] + d["low"] + d["close"]) / 3
    if "real_volume" in d.columns and d["real_volume"].sum() > 0:
        d["tv"] = d["real_volume"]
    else:
        d["tv"] = 1.0
    print(f"Datos: {len(d)} velas M1 | {d.index.min()} → {d.index.max()}")

    run_sweep(d)


if __name__ == "__main__":
    main()
