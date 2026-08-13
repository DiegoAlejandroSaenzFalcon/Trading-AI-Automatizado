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

# slot = (startHour, endHour, strat, tpMult, ttlBars, altStrat)  altStrat=0 sin alternativa
def signal(st, i, closes, highs, lows, ema20, ema30, ema60, r2, vw, atr):
    if st == "BREAK48" or st == "BREAK24":
        n = 48 if st == "BREAK48" else 24
        mx = highs[i-n:i].max(); mn = lows[i-n:i].min()
        if closes[i] > mx: return 1
        if closes[i] < mn: return -1
    elif st == "MOMEMA":
        if closes[i] > ema30[i] and closes[i] > highs[i-3:i].max(): return 1
        if closes[i] < ema30[i] and closes[i] < lows[i-3:i].min(): return -1
    elif st == "EMACROSS":
        if ema20[i] > ema60[i] and ema20[i-1] <= ema60[i-1]: return 1
        if ema20[i] < ema60[i] and ema20[i-1] >= ema60[i-1]: return -1
    elif st == "RETEST48" or st == "RETEST24":
        n = 48 if st == "RETEST48" else 24
        hx = highs[i-n:i].max(); ln = lows[i-n:i].min()
        if highs[i] >= hx and closes[i] < hx - 0.1*atr: return -1
        if lows[i] <= ln and closes[i] > ln + 0.1*atr: return 1
    elif st == "RSI2":
        if r2[i] < 10 and closes[i] < lows[i-24:i].min(): return 1
        if r2[i] > 90 and closes[i] > highs[i-24:i].max(): return -1
    elif st == "VWAP":
        if not np.isnan(vw[i]):
            if closes[i] > vw[i] and closes[i-1] <= vw[i-1]: return 1
            if closes[i] < vw[i] and closes[i-1] >= vw[i-1]: return -1
    return 0

def simulate_full(sym, slots, risk_pct, daily_limit_R, start_capital, start_dt):
    m5 = load(sym, start_dt, dtm.datetime(2026, 8, 11))
    n = len(m5)
    atr = wilder_atr(m5)
    closes = m5["close"].astype(float); highs = m5["high"].astype(float); lows = m5["low"].astype(float)
    times = m5["time"].astype(np.int64)
    ema20 = ema_arr(closes, 20); ema30 = ema_arr(closes, 30); ema60 = ema_arr(closes, 60)
    r2 = rsi2(closes); vw = vwap_day(times, (highs+lows+closes)/3.0)
    pos = [None]*len(slots)
    equity = start_capital
    equity_curve = []          # (day, equity)
    daily_pl = 0.0; last_day = -1
    tot_trades = 0; wins = 0; total_R = 0.0
    dd_peak = start_capital; dd_max = 0.0
    for i in range(50, n):
        t = int(times[i])
        day = t - t % 86400
        if day != last_day:
            last_day = day; daily_pl = 0.0
            if len(equity_curve) == 0 or equity_curve[-1][0] != day:
                equity_curve.append((day, equity))
            dd = (equity - dd_peak)/dd_peak*100.0
            if dd < dd_max: dd_max = dd
            if equity > dd_peak: dd_peak = equity
        hour = (t % 86400)//3600
        blocked = daily_limit_R > 0 and daily_pl <= -daily_limit_R
        for k in range(len(slots)):
            if pos[k] is None: continue
            d, e, sl, tp_l, ttl, risk_usd = pos[k]
            closed = False; R = 0.0
            if d == 1:
                if lows[i] <= sl: R = -1.0; closed = True
                elif highs[i] >= tp_l: R = 2.0; closed = True
            else:
                if highs[i] >= sl: R = -1.0; closed = True
                elif lows[i] <= tp_l: R = 2.0; closed = True
            if closed:
                pnl = R * risk_usd
                equity += pnl
                daily_pl += R
                total_R += R
                tot_trades += 1
                if R > 0: wins += 1
                pos[k] = None
                continue
            if i >= ttl:
                pos[k] = None
                continue
        at = atr[i]
        if at > 0 and not blocked:
            for k, (h1_, h2_, st, tpMult, ttlBars, altSt) in enumerate(slots):
                if pos[k] is not None or not (h1_ <= hour < h2_): continue
                sig = signal(st, i, closes, highs, lows, ema20, ema30, ema60, r2, vw, at)
                if sig == 0 and altSt:
                    sig = signal(altSt, i, closes, highs, lows, ema20, ema30, ema60, r2, vw, at)
                if sig == 0: continue
                risk_usd = equity * risk_pct/100.0
                sl_d = 0.8*at; tp_d = tpMult*sl_d
                pos[k] = (sig, closes[i], closes[i]-sig*sl_d, closes[i]+sig*tp_d, i+ttlBars, risk_usd)
    # snapshots mensuales reales: equity del ultimo dia de cada mes calendario
    months = {}
    for day, eq in equity_curve:
        d = dtm.datetime.utcfromtimestamp(day)
        months[(d.year, d.month)] = eq
    return dict(equity=equity, dd_max=dd_max, trades=tot_trades, wins=wins,
                total_R=total_R, months=months)

def month_str(ym):
    return f"{ym[0]}-{ym[1]:02d}"

BTC_FINAL = [
    (0,2,"VWAP",2.0,24,0), (2,4,"BREAK24",2.0,24,0), (4,6,"MOMEMA",2.0,24,0),
    (6,8,"BREAK24",2.0,24,0), (8,10,"MOMEMA",2.0,24,0), (16,18,"RETEST48",2.0,24,0),
    (18,20,"VWAP",2.0,24,0), (20,22,"RSI2",2.0,24,0),
]
XAU_FINAL = [
    (0,2,"BREAK24",2.0,24,0), (0,2,"MOMEMA",2.0,24,0), (2,4,"MOMEMA",2.0,24,0),
    (4,6,"MOMEMA",2.0,24,0), (4,6,"VWAP",2.0,24,0), (6,8,"VWAP",2.0,24,0), (14,16,"VWAP",2.0,24,0),
]

print("=== RARRR... sim compuesta en marcha ===")
print("\n########## BTC 8 slots | 0.3% equity | breaker 5R | $10,000 ##########")
r = simulate_full("BTCUSDm", BTC_FINAL, 0.3, 5.0, 10000.0, dtm.datetime(2024,7,1))
print(f"Equity final: ${r['equity']:,.0f}  ({r['equity']/10000*100:.0f}%)")
print(f"Max DD: {r['dd_max']:.1f}%   trades: {r['trades']}  win: {r['wins']/r['trades']*100:.1f}%  total R: {r['total_R']:.0f}")
ms = sorted(r['months'].items())
prev = 10000.0
for m, eq in ms:
    print(f"  {month_str(m):<8} ${eq:>10,.0f}  ({eq/prev*100-100:+.1f}%/mes comp)")
    prev = eq
print("\n########## XAU 8 slots | 0.3% equity | breaker 8R | $10,000 ##########")
r2 = simulate_full("XAUUSDm", XAU_FINAL, 0.3, 8.0, 10000.0, dtm.datetime(2024,7,1))
print(f"Equity final: ${r2['equity']:,.0f}  ({r2['equity']/10000*100:.0f}%)")
print(f"Max DD: {r2['dd_max']:.1f}%   trades: {r2['trades']}  win: {r2['wins']/r2['trades']*100:.1f}%  total R: {r2['total_R']:.0f}")
ms = sorted(r2['months'].items())
prev = 10000.0
for m, eq in ms:
    print(f"  {month_str(m):<8} ${eq:>10,.0f}  ({eq/prev*100-100:+.1f}%/mes comp)")
    prev = eq
mt5.shutdown()