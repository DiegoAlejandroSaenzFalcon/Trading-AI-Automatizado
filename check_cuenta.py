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
print(f"Flotante: {acc.profit:+.2f}")
print(f"Margen Libre: {acc.margin_free:.2f}")
print(f"Margen usado: {acc.margin:.2f}")
pos = mt5.positions_get()
print(f"Posiciones abiertas: {len(pos) if pos else 0}")
if pos:
    for p in pos:
        side = "BUY" if p.type == 0 else "SELL"
        print(f"  {p.symbol} {side} lot={p.volume} entry={p.price_open:.2f} profit={p.profit:+.2f} magic={p.magic}")
mt5.shutdown()
