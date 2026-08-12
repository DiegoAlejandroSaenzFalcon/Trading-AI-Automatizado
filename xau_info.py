import MetaTrader5 as mt5
import datetime as dtm
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
info = mt5.symbol_info("XAUUSDm")
print(f"XAUUSDm: tickValue={info.trade_tick_value} tickSize={info.trade_tick_size} volMin={info.volume_min} volMax={info.volume_max} volStep={info.volume_step} contract={info.trade_contract_size}")
print(f"spread actual={info.spread} pts, trade_mode={info.trade_mode}")
# rango de datos M1 disponible
r1 = mt5.copy_rates_range("XAUUSDm", mt5.TIMEFRAME_M1, dtm.datetime(2026,3,1), dtm.datetime(2026,8,11))
r2 = mt5.copy_rates_range("XAUUSDm", mt5.TIMEFRAME_H1, dtm.datetime(2026,3,1), dtm.datetime(2026,8,11))
print(f"M1 desde {dtm.datetime.utcfromtimestamp(r1[0][0]):%Y-%m-%d} hasta {dtm.datetime.utcfromtimestamp(r1[-1][0]):%Y-%m-%d}: {len(r1)} velas")
print(f"H1: {len(r2)} velas")
# margen para 0.05 lote
from mt5 import ORDER_TYPE_BUY
import struct
m = mt5.order_calc_margin(ORDER_TYPE_BUY, "XAUUSDm", 1.0, 2400.0)
print(f"margen 1.0 lote @2400 = {m}")
mt5.shutdown()
