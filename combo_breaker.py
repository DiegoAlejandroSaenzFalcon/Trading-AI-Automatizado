import MetaTrader5 as mt5
import datetime as dtm
import numpy as np

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
        out[i] = 100.0*g/(g+l) if l > 0 else (100.0 if g > 0 else out[i-1])
    return out

def vwap_day(time, typical):
    out = np.full(len(time), np.nan)
    day_start = time - time % 86400
    _, idx, cnt = np.unique(day_start, return_index=True, return_counts=True)
    for ix, c in zip(idx, cnt):
        seg = typical[ix:ix+c]
        out[ix:ix+c] = np.cumsum(seg) / np.arange(1, c+1)
    return out

def simulate_combined(m5, slots, n_slots, daily_limit_R=0.0):
    n = len(m5)
    atr = wilder_atr(m5)
    closes = m5["close"].astype(float); highs = m5["high"].astype(float); lows = m5["low"].astype(float)
    times = m5["time"].astype(np.int64)
    ema30 = ema_arr(closes, 30)
    r2 = rsi2(closes)
    vw = vwap_day(times, (highs+lows+closes)/3.0)
    eq = []
    pos = [None]*n_slots
    daily_pl = 0.0; last_day = -1
    for i in range(50, n):
        t = int(times[i])
        day = t - t % 86400
        if day != last_day:
            last_day = day; daily_pl = 0.0
        inc = 0.0
        blocked = daily_limit_R > 0 and daily_pl <= -daily_limit_R
        for k in range(n_slots):
            if pos[k] is None: continue
            d, e, sl, tp_l, ttl = pos[k]
            if d == 1:
                if lows[i] <= sl: inc += -1.0; pos[k] = None; daily_pl += -1.0; continue
                if highs[i] >= tp_l: inc += 2.0; pos[k] = None; daily_pl += 2.0; continue
            else:
                if highs[i] >= sl: inc += -1.0; pos[k] = None; daily_pl += -1.0; continue
                if lows[i] <= tp_l: inc += 2.0; pos[k] = None; daily_pl += 2.0; continue
            if i >= ttl: inc += 0.0; pos[k] = None
        at = atr[i]
        if at > 0 and not blocked:
            sl_d = 0.8*at; tp_d = 2.0*sl_d
            for k, (h1_, h2_, st) in enumerate(slots):
                if pos[k] is not None or not (h1_ <= (t % 86400)//3600 < h2_): continue
                sig = 0
                if st == "BREAK24":
                    mx = highs[i-24:i].max(); mn = lows[i-24:i].min()
                    if closes[i] > mx: sig = 1
                    elif closes[i] < mn: sig = -1
                elif st == "MOMEMA":
                    if closes[i] > ema30[i] and closes[i] > highs[i-3:i].max(): sig = 1
                    elif closes[i] < ema30[i] and closes[i] < lows[i-3:i].min(): sig = -1
                elif st == "RSI2":
                    if r2[i] < 10 and closes[i] < lows[i-24:i].min(): sig = 1
                    elif r2[i] > 90 and closes[i] > highs[i-24:i].max(): sig = -1
                elif st == "VWAP":
                    if not np.isnan(vw[i]):
                        if closes[i] > vw[i] and closes[i-1] <= vw[i-1]: sig = 1
                        elif closes[i] < vw[i] and closes[i-1] >= vw[i-1]: sig = -1
                if sig != 0:
                    pos[k] = (sig, closes[i], closes[i]-sig*sl_d, closes[i]+sig*tp_d, i+24)
        eq.append(inc)
    return eq

def stats(a):
    b = np.array(a, dtype=float)
    eq = np.cumsum(b); peak = np.maximum.accumulate(eq)
    dd = (eq - peak).min()
    wins = b[b > 0].sum(); losses = -b[b < 0].sum()
    n = (b != 0).sum()
    pf = wins/losses if losses > 0 else 99.0
    return (n, round(b.sum(),1), round(pf,2), round(dd,1))

BTC_SLOTS = [(0,2,"VWAP"),(2,4,"BREAK24"),(4,6,"MOMEMA"),(6,8,"BREAK24"),(8,10,"MOMEMA"),(10,12,"VWAP"),(16,18,"RSI2"),(18,20,"VWAP"),(20,22,"RSI2")]
XAU_SLOTS = [(0,2,"BREAK24"),(0,2,"MOMEMA"),(2,4,"MOMEMA"),(4,6,"MOMEMA"),(4,6,"VWAP"),(6,8,"VWAP"),(14,16,"VWAP")]
PERIODS = [("P1", dtm.datetime(2024,7,1), dtm.datetime(2025,6,30)), ("P2", dtm.datetime(2025,7,1), dtm.datetime(2026,1,31)), ("P3", dtm.datetime(2026,2,1), dtm.datetime(2026,8,11))]

for name, slots in [("BTC", BTC_SLOTS), ("XAU", XAU_SLOTS)]:
    for lim in [0.0, 5.0, 8.0]:
        print(f"===== {name} | limite diario: {('OFF' if lim==0 else str(int(lim))+'R')} =====")
        for pname, pfrm, pto in PERIODS:
            m5 = load("BTCUSDm" if name=="BTC" else "XAUUSDm", pfrm, pto)
            s = stats(simulate_combined(m5, slots, len(slots), lim))
            meses = (pto - pfrm).days/30.4
            print(f"  {pname}: trades={s[0]} pnlR={s[1]} PF={s[2]} DD={s[3]}  -> {s[1]/meses:.1f} R/mes")
mt5.shutdown()