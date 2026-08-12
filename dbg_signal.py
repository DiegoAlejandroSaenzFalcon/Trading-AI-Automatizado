import sys, importlib.util
spec = importlib.util.spec_from_file_location("br", r"C:\Users\H2R\Documents\Default Project\backtest_r30.py")
br = importlib.util.module_from_spec(spec)
spec.loader.exec_module(br)
import MetaTrader5 as mt5
from datetime import datetime
import math
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
frm = datetime(2026, 2, 1); to = datetime(2026, 5, 13)
m1 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_M1, frm, to)
m15 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_M15, frm, to)
h4 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_H4, frm, to)
atr_m1 = br.wilder_atr(m1, 14)
br.reset()
pl = []
for k in range(len(m1)):
    r = m1[k]; now = r[4]
    mid = (r[1]+r[2])/2.0
    dt = 60.0 if k>0 else 0.1
    br.s.smoothedDt = br.s.smoothedDt + 0.20*(dt - br.s.smoothedDt)
    atr = atr_m1[k] if k>0 else 0.0
    br.kalman_update(mid, dt)
    br.update_adaptive_noise(mid, 15.0)
    p = br.compute_bias_probability(mid, atr, 3600)
    if k % 300 == 0:
        print(f"k={k} mid={mid:.0f} v={br.s.kxV:.5f} vNorm={br.s.kxV*3600/atr if atr>0 else 0:.3f} dNorm={(mid-br.s.kxP)/atr if atr>0 else 0:.3f} EVel={br.s.sigEVel:.3f} p={p:.3f} kR={br.s.kR:.2e}")
mt5.shutdown()
