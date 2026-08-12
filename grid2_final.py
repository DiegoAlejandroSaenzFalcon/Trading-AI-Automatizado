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

def rsi14(close):
    out = np.full(len(close), 50.0)
    g_avg = l_avg = 0.0
    for i in range(1, len(close)):
        d = close[i]-close[i-1]
        g = max(d, 0.0); l = max(-d, 0.0)
        if i <= 14:
            g_avg += g/14.0; l_avg += l/14.0
        else:
            g_avg = (g_avg*13+g)/14.0; l_avg = (l_avg*13+l)/14.0
        out[i] = 100.0 if l_avg == 0 else 100.0*g_avg/(g_avg+l_avg)
    return out

def vwap_day(time, typical):
    n = len(time)
    cs = np.cumsum(typical)
    out = np.full(n, np.nan)
    day0 = time[0] - time[0] % 86400
    start = 0
    for i in range(n):
        day = time[i] - time[i] % 86400
        if day != day0:
            start = i; day0 = day
        out[i] = (cs[i] - (cs[start-1] if start > 0 else 0.0)) / (i - start + 1)
    return out

def bb(close, atr_arr, n=20, mult=2.0):
    ma = ema_arr(close, n)
    sd = np.full(len(close), 0.0)
    for i in range(n, len(close)):
        sd[i] = close[i-n:i].std()
    return ma, ma + mult*sd, ma - mult*sd

def simulate(m5, fr_from, fr_to, strat):
    n = len(m5)
    atr = wilder_atr(m5)
    closes = m5["close"].astype(float); highs = m5["high"].astype(float); lows = m5["low"].astype(float)
    opens = m5["open"].astype(float)
    times = m5["time"].astype(np.int64)
    ema10 = ema_arr(closes, 10); ema30 = ema_arr(closes, 30)
    ema20 = ema_arr(closes, 20); ema60 = ema_arr(closes, 60)
    r2 = rsi2(closes); r14 = rsi14(closes)
    vw = vwap_day(times, (highs+lows+closes)/3.0)
    bbma, bbu, bbl = bb(closes, atr)
    trades = []
    pos = None
    for i in range(80, n):
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
            if i >= 2 and lows[i] > highs[i-2] and closes[i] > closes[i-1] and lows[i]-highs[i-2] > 0.15*at:
                gb = highs[i-2]; sig = 1
                for j in range(i+1, min(i+6, n)):
                    if lows[j] <= gb <= highs[j]: sig = 1; break
                else: sig = 0
            elif i >= 2 and highs[i] < lows[i-2] and closes[i] < closes[i-1] and lows[i-2]-highs[i] > 0.15*at:
                gt = lows[i-2]; sig = -1
                for j in range(i+1, min(i+6, n)):
                    if lows[j] <= gt <= highs[j]: sig = -1; break
                else: sig = 0
        elif strat == "BREAK24":
            mx = highs[i-24:i].max(); mn = lows[i-24:i].min()
            if closes[i] > mx: sig = 1
            elif closes[i] < mn: sig = -1
        elif strat == "BREAK48":
            mx = highs[i-48:i].max(); mn = lows[i-48:i].min()
            if closes[i] > mx: sig = 1
            elif closes[i] < mn: sig = -1
        elif strat == "RETEST24":
            mx = highs[i-24:i].max(); mn = lows[i-24:i].min()
            if highs[i] >= mx and closes[i] < mx - 0.1*at: sig = -1
            elif lows[i] <= mn and closes[i] > mn + 0.1*at: sig = 1
        elif strat == "RETEST48":
            mx = highs[i-48:i].max(); mn = lows[i-48:i].min()
            if highs[i] >= mx and closes[i] < mx - 0.1*at: sig = -1
            elif lows[i] <= mn and closes[i] > mn + 0.1*at: sig = 1
        elif strat == "MOMEMA":
            if closes[i] > ema30[i] and closes[i] > highs[i-3:i].max(): sig = 1
            elif closes[i] < ema30[i] and closes[i] < lows[i-3:i].min(): sig = -1
        elif strat == "EMACROSS":
            if ema20[i] > ema60[i] and ema20[i-1] <= ema60[i-1]: sig = 1
            elif ema20[i] < ema60[i] and ema20[i-1] >= ema60[i-1]: sig = -1
        elif strat == "RSI2":
            if r2[i] < 10 and closes[i] < lows[i-24:i].min(): sig = 1
            elif r2[i] > 90 and closes[i] > highs[i-24:i].max(): sig = -1
        elif strat == "RSI14DIP":
            if r14[i] < 35 and closes[i] > ema30[i]: sig = 1
            elif r14[i] > 65 and closes[i] < ema30[i]: sig = -1
        elif strat == "VWAP":
            if not np.isnan(vw[i]):
                if closes[i] > vw[i] and closes[i-1] <= vw[i-1]: sig = 1
                elif closes[i] < vw[i] and closes[i-1] >= vw[i-1]: sig = -1
        elif strat == "BBREV":
            if highs[i] >= bbu[i] and closes[i] < bbu[i]: sig = -1
            elif lows[i] <= bbl[i] and closes[i] > bbl[i]: sig = 1
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

STRATS = ["FVG","BREAK24","BREAK48","RETEST24","RETEST48","MOMEMA","EMACROSS","RSI2","RSI14DIP","VWAP","BBREV"]
FRANJAS = [(h, h+2) for h in range(0, 24, 2)]
PERIODS = [
    ("P1_24h2-25h1", dtm.datetime(2024,7,1), dtm.datetime(2025,6,30)),
    ("P2_25h2-26e", dtm.datetime(2025,7,1), dtm.datetime(2026,1,31)),
    ("P3_26f-26a", dtm.datetime(2026,2,1), dtm.datetime(2026,8,11)),
]
out = r"C:\Users\H2R\Documents\Default Project\grid2_final.csv"
with open(out, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["activo","franja","estrat","periodo","n","pnlR","win","PF","DD"])
    f.flush()
    for sym in ["XAUUSDm","BTCUSDm"]:
        print(f"--- {sym} ---", flush=True)
        for pname, pfrm, pto in PERIODS:
            m5 = load(sym, pfrm, pto)
            for (h1_, h2_) in FRANJAS:
                for st in STRATS:
                    tr = simulate(m5, h1_, h2_, st)
                    s = stats(tr)
                    w.writerow([sym, f"{h1_:02d}-{h2_:02d}", st, pname] + (list(s) if s else [0,0,0,0,0]))
                    f.flush()
            print(f"  {pname} listo", flush=True)
mt5.shutdown()
print("GRID2 TERMINADO")
