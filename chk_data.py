import MetaTrader5 as mt5
from datetime import datetime
if not mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe"):
    print("init failed", mt5.last_error())
    raise SystemExit
frm = datetime(2026, 2, 1)
to = datetime(2026, 5, 13)
r2 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_M15, frm, to)
r1 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_H1, frm, to)
r0 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_M1, frm, to)
print(f"M15: {len(r2) if r2 is not None else 'N/A'} barras")
print(f"H1: {len(r1) if r1 is not None else 'N/A'} barras")
print(f"M1: {len(r0) if r0 is not None else 'N/A'} barras")
# ticks
t = mt5.copy_ticks_range("BTCUSDm", frm, to, mt5.COPY_TICKS_ALL)
print(f"Ticks: {len(t) if t is not None else 'N/A'}")
mt5.shutdown()
