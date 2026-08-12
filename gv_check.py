import MetaTrader5 as mt5
if not mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe"):
    print("init failed", mt5.last_error())
    raise SystemExit
gvs = mt5.global_variables_get()
print(f"Total GlobalVariables: {len(gvs) if gvs else 0}")
if gvs:
    for g in sorted(gvs, key=lambda x: x.name):
        print(f"{g.name} = {g.value:.4f}")
mt5.shutdown()
