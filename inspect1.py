import re
path = r"C:\Users\H2R\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\Tester\logs\20260809.log"
with open(path, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()
# ver lineas de inicio de testing exactas
for ln in lines[:60]:
    if "testing of" in ln or "started with" in ln:
        print(repr(ln[:160]))
