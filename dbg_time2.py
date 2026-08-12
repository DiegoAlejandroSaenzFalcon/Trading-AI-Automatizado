import MetaTrader5 as mt5
from datetime import datetime, timezone
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
frm = datetime(2026, 2, 1); to = datetime(2026, 2, 2)
m1 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_M1, frm, to)
for i in range(3):
    t = m1[i][4]
    print(f"M1[{i}] raw={t}  secs={t/1e6 if t>1e7 else t}  as_dt={datetime.fromtimestamp(t/1e6 if t>1e7 else t, tz=timezone.utc)}")
print("len:", len(m1))
mt5.shutdown()
