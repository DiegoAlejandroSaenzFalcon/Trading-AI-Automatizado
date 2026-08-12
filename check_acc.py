import MetaTrader5 as mt5
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
a = mt5.account_info()
print("Login:", a.login, "Server:", a.server, "TradeMode:", a.trade_mode, "(0=demo,1=contest,2=real)")
print("Symbol BTCUSDm info:")
s = mt5.symbol_info("BTCUSDm")
print("  digits:", s.digits, "trade_mode:", s.trade_mode, "spread:", s.spread)
mt5.shutdown()
