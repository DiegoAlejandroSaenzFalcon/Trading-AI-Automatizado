import MetaTrader5 as mt5
import datetime as dtm
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
for sym in ["XAUUSDm", "BTCUSDm"]:
    r = mt5.copy_rates_range(sym, mt5.TIMEFRAME_M5, dtm.datetime(2025,1,1), dtm.datetime(2026,8,11))
    if r is None or len(r) == 0:
        print(f"{sym}: sin datos desde 2025-01-01")
        r2 = mt5.copy_rates_from(sym, mt5.TIMEFRAME_M5, dtm.datetime(2026,1,1), 100)
        if r2 is not None and len(r2) > 0:
            print(f"   primer dato disponible: {dtm.datetime.fromtimestamp(r2[0]['time'])}")
        continue
    print(f"{sym}: {len(r)} velas M5 desde 2025-01-01 ({len(r)//288} dias aprox)")
    # probar mas profundo: 2024
    r3 = mt5.copy_rates_range(sym, mt5.TIMEFRAME_M5, dtm.datetime(2024,1,1), dtm.datetime(2024,2,1))
    print(f"   2024-01: {'disponible' if r3 is not None and len(r3)>0 else 'NO disponible'}")
mt5.shutdown()
