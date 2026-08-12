import MetaTrader5 as mt5
from datetime import datetime
import numpy as np
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
frm = datetime(2026, 2, 1); to = datetime(2026, 2, 2)
m1 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_M1, frm, to)
m15 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_M15, frm, to)
print("M1 dtype:", m1.dtype)
print("M1[0] time:", m1[0][4], "M1[1] time:", m1[1][4])
print("M15[0] time:", m15[0][4], "M15[1] time:", m15[1][4])
d1 = m1[1][4] - m1[0][4]
d15 = m15[1][4] - m15[0][4]
print(f"diff M1={d1}  diff M15={d15}")
mt5.shutdown()
