import MetaTrader5 as mt5
import datetime as dtm
import numpy as np
import csv

mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")

def load(sym, frm, to):
    return mt5.copy_rates_range(sym, mt5.TIMEFRAME_M5, frm, to)

def wilder_atr(h, n=14):
    tr = np.maximum(h["high"][1:]-h["low"][1:], np.maximum(np.abs(h["high"][1:]-h["close"][:-1]), np.abs(h["low"][1:]-h["close"][:-1])))
    out = np.empty(len(h)); out[0] = tr[0]
    for i in range(1, len(tr)):
        out[i] = (out[i-1]*(n-1)+tr[i-1])/n
    out[len(tr):] = out[len(tr)-1]
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
    day_start = time - time % 86400
    for i in range(len(time)):
        m = day_start[:i+1] == day_start[i]
        out[i] = np.sum(typical[:i+1][m]) / max(1, int(m.sum()))
    return out

def simulate(m5, fr_from, fr_to, strat):
    n = len(m5)
    atr = wilder_atr(m5)
    closes = m5["close"].astype(float); highs = m5["high"].astype(float); lows = m5["low"].astype(float)
    times = m5["time"].astype(np.int64)
    ema10 = ema_arr(closes, 10); ema30 = ema_arr(closes, 30)
    r2 = rsi2(closes)
    vw = vwap_day(times, (highs+lows+closes)/3.0)
    trades = []
    pos = None
    for i in range(50, n):
        hour = (times[i] % 86400) // 3600
        if hour < fr_from or hour >= fr_to:
            continue
        at = atr[i]
        if pos is not None:
            d, e, sl, tp_l, ttl = pos
            if d == 1:
                if lows[i] <= sl: trades.append(-1.0); pos = None; continue
                if highs[i] >= tp_l: trades.append(2.0); pos = None; continue
            else:
                if highs[i] >= sl: trades.append(-1.0); pos = None; continue
                if lows[i] <= tp_l: trades.append(2.0); pos = None; continue
            if i >= ttl: trades.append(0.0); pos = None
            continue
        if at <= 0: continue
        sl_d = 0.8*at; tp_d = 2.0*sl_d
        sig = 0
        if strat == "FVG":
            if i >= 2 and lows[i] > highs[i-2] and closes[i] > closes[i-1] and lows[i] - highs[i-2] > 0.15*at:
                gap_bot = highs[i-2]; sig = 1
                for j in range(i+1, min(i+6, n)):
                    if lows[j] <= gap_bot <= highs[j]: sig = 1; break
                else: sig = 0
            elif i >= 2 and highs[i] < lows[i-2] and closes[i] < closes[i-1] and lows[i-2] - highs[i] > 0.15*at:
                gap_top = lows[i-2]; sig = -1
                for j in range(i+1, min(i+6, n)):
                    if lows[j] <= gap_top <= highs[j]: sig = -1; break
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
    if len(tr) < 10: return None
    a = np.array(tr)
    eq = np.cumsum(a); peak = np.maximum.accumulate(eq)
    dd = (eq - peak).min()
    w = (a > 0).sum()/len(a)*100
    wins = a[a > 0].sum(); losses = -a[a < 0].sum()
    pf = wins/losses if losses > 0 else 99.0
    return (len(a), round(a.sum(),1), round(w,1), round(pf,2), round(dd,1))

CAND = [
    ("XAUUSDm", 0, 2, "BREAK24"), ("XAUUSDm", 0, 2, "MOMEMA"),
    ("XAUUSDm", 2, 4, "MOMEMA"), ("XAUUSDm", 4, 6, "MOMEMA"),
    ("XAUUSDm", 4, 6, "VWAP"), ("XAUUSDm", 6, 8, "VWAP"),
    ("XAUUSDm", 14, 16, "VWAP"),
    ("BTCUSDm", 0, 2, "VWAP"), ("BTCUSDm", 2, 4, "BREAK24"),
    ("BTCUSDm", 4, 6, "MOMEMA"), ("BTCUSDm", 6, 8, "BREAK24"),
    ("BTCUSDm", 8, 10, "MOMEMA"), ("BTCUSDm", 10, 12, "VWAP"),
    ("BTCUSDm", 16, 18, "RSI2"), ("BTCUSDm", 18, 20, "VWAP"),
    ("BTCUSDm", 20, 22, "RSI2"),
]
PERIODS = [
    ("P1_24h2-25h1", dtm.datetime(2024,7,1), dtm.datetime(2025,6,30)),
    ("P2_25h2-26e", dtm.datetime(2025,7,1), dtm.datetime(2026,1,31)),
    ("P3_26f-26a", dtm.datetime(2026,2,1), dtm.datetime(2026,8,11)),
]
out = r"C:\Users\H2R\Documents\Default Project\walkforward.csv"
with open(out, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["activo","franja","estrat","periodo","n","pnlR","win","PF","DD"])
    f.flush()
    for sym, h1_, h2_, st in CAND:
        results = {}
        for pname, pfrm, pto in PERIODS:
            m5 = load(sym, pfrm, pto)
            tr = simulate(m5, h1_, h2_, st)
            s = stats(tr)
            results[pname] = s
            w.writerow([sym, f"{h1_:02d}-{h2_:02d}", st, pname] + (list(s) if s else [0,0,0,0,0]))
            f.flush()
        pfs = [results[pname][3] for pname, _, _ in PERIODS if results[pname]]
        ns = [results[pname][0] for pname, _, _ in PERIODS if results[pname]]
        ok = len(pfs) == 3 and all(p > 1.15 for p in pfs) and all(n >= 20 for n in ns)
        label = "PASA" if ok else "rechazada"
        print(f"{sym} {h1_:02d}-{h2_:02d} {st:8s}: " + " | ".join(f"{pname}: PF {results[pname][3] if results[pname] else 0} n={results[pname][0] if results[pname] else 0}" for pname, _, _ in PERIODS) + f"  -> {label}", flush=True)
mt5.shutdown()
print("WALK-FORWARD TERMINADO")
