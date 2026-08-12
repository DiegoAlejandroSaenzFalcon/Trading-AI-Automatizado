import MetaTrader5 as mt5
import datetime as dtm
import numpy as np
import csv, sys

mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
FRANJAS = [(h, h+2) for h in range(0, 24, 2)]

def load(symbol, frm, to):
    m5 = mt5.copy_rates_range(symbol, mt5.TIMEFRAME_M5, frm, to)
    h1 = mt5.copy_rates_range(symbol, mt5.TIMEFRAME_H1, frm, to)
    return m5, h1

def wilder_atr(h, n=14):
    tr = np.maximum(h["high"][1:]-h["low"][1:], np.maximum(np.abs(h["high"][1:]-h["close"][:-1]), np.abs(h["low"][1:]-h["close"][:-1])))
    a = np.empty(len(h)); a[0] = tr[0]; a[1:] = tr
    out = np.empty(len(h)); out[0] = tr[0]
    for i in range(1, len(h)):
        out[i] = (out[i-1]*(n-1) + tr[i-1])/n if i < len(tr)+1 else out[i-1]
    for i in range(1, len(tr)):
        out[i] = (out[i-1]*(n-1)+tr[i-1])/n
    return out

def ema_arr(v, n):
    a = np.empty(len(v)); a[0] = v[0]
    k = 2.0/(n+1)
    for i in range(1, len(v)):
        a[i] = v[i]*k + a[i-1]*(1-k)
    return a

def rsi2(close):
    out = np.full(len(close), 50.0)
    for i in range(1, len(close)):
        d = close[i]-close[i-1]
        g = max(d, 0.0); l = max(-d, 0.0)
        if l == 0: out[i] = 100.0 if g > 0 else out[i-1]
        else: out[i] = 100.0*g/(g+l)
    return out

def vwap_day(time, typical):
    out = np.full(len(time), np.nan)
    for i in range(len(time)):
        day = time[i] - time[i] % 86400
        mask = time[:i+1] >= day
        out[i] = np.sum(typical[:i+1][mask]) / max(1, mask.sum())
    return out

STRATS = ["FVG", "BREAK24", "RETEST24", "MOMEMA", "RSI2", "VWAP"]

def simulate(m5, h1, fr_from, fr_to, strat):
    n = len(m5)
    atr = wilder_atr(m5)
    closes = m5["close"].astype(float); highs = m5["high"].astype(float); lows = m5["low"].astype(float)
    opens = m5["open"].astype(float); times = m5["time"].astype(np.int64)
    ema10 = ema_arr(closes, 10); ema30 = ema_arr(closes, 30)
    r2 = rsi2(closes)
    tp = (highs+lows+closes)/3.0
    vw = vwap_day(times, tp)
    trades = []
    pos = None  # (dir, entry, sl, tp, ttl, extra)
    for i in range(50, n):
        hour = (times[i] % 86400) // 3600
        if hour < fr_from or hour >= fr_to:
            continue
        at = atr[i]
        if pos is not None:
            d, e, sl, tp_l, ttl = pos
            if d == 1:
                if lows[i] <= sl:
                    trades.append(-1.0); pos = None; continue
                if highs[i] >= tp_l:
                    trades.append(2.0); pos = None; continue
            else:
                if highs[i] >= sl:
                    trades.append(-1.0); pos = None; continue
                if lows[i] <= tp_l:
                    trades.append(2.0); pos = None; continue
            if i >= ttl:
                trades.append(0.0); pos = None
            continue
        if at <= 0: continue
        sl_d = 0.8*at; tp_d = 2.0*sl_d
        sig = 0
        if strat == "FVG":
            if i >= 2 and lows[i] > highs[i-2] and closes[i] > closes[i-1] and lows[i] - highs[i-2] > 0.15*at:
                gap_bot = highs[i-2]; sig = 1
                for j in range(i+1, min(i+6, n)):
                    if lows[j] <= gap_bot <= highs[j]:
                        sig = 1; break
                else: sig = 0
            elif i >= 2 and highs[i] < lows[i-2] and closes[i] < closes[i-1] and lows[i-2] - highs[i] > 0.15*at:
                gap_top = lows[i-2]; sig = -1
                for j in range(i+1, min(i+6, n)):
                    if lows[j] <= gap_top <= highs[j]:
                        sig = -1; break
                else: sig = 0
        elif strat == "BREAK24":
            mx = highs[i-24:i].max(); mn = lows[i-24:i].min()
            if closes[i] > mx: sig = 1
            elif closes[i] < mn: sig = -1
        elif strat == "RETEST24":
            mx = highs[i-24:i].max(); mn = lows[i-24:i].min()
            if highs[i] >= mx and closes[i] < mx - 0.1*at: sig = -1
            elif lows[i] <= mn and closes[i] > mn + 0.1*at: sig = 1
        elif strat == "MOMEMA":
            if closes[i] > ema30[i] and closes[i] > highs[i-3:i].max(): sig = 1
            elif closes[i] < ema30[i] and closes[i] < lows[i-3:i].min(): sig = -1
        elif strat == "RSI2":
            if r2[i] < 10 and closes[i] < lows[i-24:i].min(): sig = 1
            elif r2[i] > 90 and closes[i] > highs[i-24:i].max(): sig = -1
        elif strat == "VWAP":
            if not np.isnan(vw[i]):
                if closes[i] > vw[i] and closes[i-1] <= vw[i-1]: sig = 1
                elif closes[i] < vw[i] and closes[i-1] >= vw[i-1]: sig = -1
        if sig != 0:
            pos = (sig, closes[i], closes[i]-sig*sl_d, closes[i]+sig*tp_d, i+24)
    return trades

def stats(tr):
    if len(tr) < 5: return None
    a = np.array(tr)
    eq = np.cumsum(a); peak = np.maximum.accumulate(eq)
    dd = (eq - peak).min()
    w = (a > 0).sum()/len(a)*100
    wins = a[a > 0].sum(); losses = -a[a < 0].sum()
    pf = wins/losses if losses > 0 else 99.0
    return (len(a), round(a.sum(),1), round(w,1), round(pf,2), round(dd,1))

frm1 = dtm.datetime(2026, 2, 1); to1 = dtm.datetime(2026, 5, 13)
frm2 = dtm.datetime(2026, 5, 14); to2 = dtm.datetime(2026, 8, 11)
out = r"C:\Users\H2R\Documents\Default Project\grid_multiestrategia.csv"
with open(out, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["activo","franja","estrategia","IS_n","IS_pnlR","IS_win","IS_PF","IS_DD","OOS_n","OOS_pnlR","OOS_win","OOS_PF","OOS_DD"])
    f.flush()
    for sym in ["XAUUSDm", "BTCUSDm"]:
        m5a, h1a = load(sym, frm1, to1)
        m5b, h1b = load(sym, frm2, to2)
        for (h1_, h2_) in FRANJAS:
            for st in STRATS:
                tr_is = simulate(m5a, h1a, h1_, h2_, st)
                tr_os = simulate(m5b, h1b, h1_, h2_, st)
                s1 = stats(tr_is); s2 = stats(tr_os)
                row = [sym, f"{h1_:02d}-{h2_:02d}", st]
                row += list(s1) if s1 else [0,0,0,0,0]
                row += list(s2) if s2 else [0,0,0,0,0]
                w.writerow(row); f.flush()
                if s2 and s2[3] > 1.15 and s2[0] >= 10:
                    print(f"{sym} {h1_:02d}-{h2_:02d} {st}: IS {s1[3] if s1 else 0} / OOS {s2[3]} (n={s2[0]})", flush=True)
mt5.shutdown()
print("GRID TERMINADO")
