import MetaTrader5 as mt5
if not mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe"):
    print("init failed", mt5.last_error())
    raise SystemExit
attrs = [a for a in dir(mt5) if "global" in a.lower() or "variable" in a.lower()]
print(attrs)
mt5.shutdown()
