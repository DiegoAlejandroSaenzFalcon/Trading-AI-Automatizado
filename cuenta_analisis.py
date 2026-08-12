import MetaTrader5 as mt5
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
info = mt5.account_info()
print("=== CUENTA ===")
print(f"login={info.login} balance={info.balance} equity={info.equity} margin={info.margin} free={info.margin_free}")
print(f"tipo={info.trade_mode} lev={info.leverage} server={info.server} currency={info.currency}")
# historial completo
from datetime import datetime, timedelta
print("\n=== HISTORIAL DE OPERACIONES ===")
for year in (2026, 2025):
    df = mt5.history_deals_get(datetime(year,1,1), datetime.now())
    if df:
        # agrupar por posicion
        trades = {}
        for d in df:
            t = d.ticket
            if not str(t).endswith("0") and d.type != 2: continue
            key = d.position_id
            trades.setdefault(key, []).append(d)
        orders_df = mt5.history_orders_get(datetime(year,1,1), datetime.now())
        print(f"--- {year}: {len(orders_df) if orders_df else 0} ordenes ---")
mt5.shutdown()
