import MetaTrader5 as mt5
if not mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe"):
    print("MT5 init failed:", mt5.last_error())
    raise SystemExit
acc = mt5.account_info()
print(f"Login: {acc.login}")
print(f"Server: {acc.server}")
print(f"Currency: {acc.currency}")
print(f"Balance: {acc.balance}")
print(f"Equity: {acc.equity}")
print(f"MargenLibre: {acc.margin_free}")
print(f"Flotante: {acc.profit}")
mt5.shutdown()
