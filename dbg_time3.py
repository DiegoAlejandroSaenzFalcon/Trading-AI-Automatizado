import MetaTrader5 as mt5
from datetime import datetime, timezone
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
frm = datetime(2026, 2, 1); to = datetime(2026, 2, 2)
m1 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_M1, frm, to)
print("dtype:", m1.dtype)
print("campo time dtype:", m1["time"].dtype)
t0 = m1["time"][0]
print("t0 repr:", repr(t0))
print("t0 int:", int(t0))
print("as_us:", int(t0)/1e6, "as_ms:", int(t0)/1e3)
print("as datetime(s):", datetime.fromtimestamp(int(t0)/1e6 if int(t0)>1e12 else int(t0), tz=timezone.utc))
mt5.shutdown()
