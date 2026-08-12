import MetaTrader5 as mt5
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
acc = mt5.account_info()
si = mt5.symbol_info("BTCUSDm")
print(f"Cuenta: {acc.login}  Balance: {acc.balance:.2f}  Lev: 1:{acc.leverage}")
print(f"trade_tick_value={si.trade_tick_value}  trade_tick_size={si.trade_tick_size}  contract={si.trade_contract_size}")
print(f"volume_min={si.volume_min}  volume_step={si.volume_step}  volume_max={si.volume_max}")
for lot in (0.5, 1.0, 2.0, 5.0, 10.0, 20.0):
    m = mt5.order_calc_margin(mt5.ORDER_TYPE_BUY, "BTCUSDm", lot, 80000.0)
    print(f"lote {lot}: margen {m:.0f} USD")
mt5.shutdown()
