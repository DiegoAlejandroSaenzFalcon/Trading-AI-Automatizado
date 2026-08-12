import MetaTrader5 as mt5
import datetime as dtm
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
for sym, start in [("XAUUSDm", dtm.datetime(2024,1,1)), ("BTCUSDm", dtm.datetime(2024,1,1))]:
    r = mt5.copy_rates_from(sym, mt5.TIMEFRAME_M5, start, 1)
    if r is not None and len(r) > 0:
        print(f"{sym}: primera vela M5 = {dtm.datetime.fromtimestamp(r[0]['time'])}")
    else:
        print(f"{sym}: sin datos en 2024-01")
    r2 = mt5.copy_rates_range(sym, mt5.TIMEFRAME_M5, dtm.datetime(2025,1,1), dtm.datetime(2026,8,11))
    print(f"   M5 2025-01-01..2026-08-11: {len(r2)} velas")
mt5.shutdown()
