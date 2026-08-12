import MetaTrader5 as mt5
from datetime import datetime
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
frm = datetime(2026, 2, 1); to = datetime(2026, 5, 13)
m15 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_M15, frm, to)
def wilder_atr(rates, period):
    n = len(rates)
    tr = [0.0]*n
    for i in range(1,n):
        h,l,c = rates[i][1], rates[i][2], rates[i][3]
        pc = rates[i-1][3]
        tr[i] = max(h-l, abs(h-pc), abs(l-pc))
    atr = [0.0]*n
    if n <= period: return atr
    atr[period] = sum(tr[1:period+1])/period
    for i in range(period+1, n):
        atr[i] = (atr[i-1]*(period-1)+tr[i])/period
    return atr
atr = wilder_atr(m15, 14)
c1 = c2 = 0
for i in range(3, len(m15)):
    r3, r1 = m15[i-3], m15[i-1]
    minGap = atr[i] * 0.15
    if r3[1] < r1[2] and (r1[2]-r3[1]) >= minGap: c1 += 1
    if r3[2] > r1[1] and (r3[2]-r1[1]) >= minGap: c2 += 1
print(f"FVG buy posibles: {c1}, sell: {c2}, atr medio M15: {sum(atr)/len(atr):.0f}")
mt5.shutdown()
