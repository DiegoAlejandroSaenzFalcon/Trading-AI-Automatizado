import MetaTrader5 as mt5
import datetime as dtm

mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
t = mt5.copy_rates_from("BTCUSDm", mt5.TIMEFRAME_M1, dtm.datetime.now(), 3)
if t is not None and len(t) > 0:
    last = dtm.datetime.fromtimestamp(t[-1]["time"])
    print("server last M1 bar:", last)
else:
    print("sin datos BTCUSDm", mt5.last_error())
try:
    t2 = mt5.copy_rates_from("XAUUSDm", mt5.TIMEFRAME_M1, dtm.datetime.now(), 3)
    if t2 is not None and len(t2) > 0:
        last2 = dtm.datetime.fromtimestamp(t2[-1]["time"])
        print("server last XAU M1 bar:", last2)
    else:
        print("sin datos XAUUSDm", mt5.last_error())
except Exception as e:
    print("err XAU", e)
print("local utc now:  ", dtm.datetime.utcnow())
mt5.shutdown()
