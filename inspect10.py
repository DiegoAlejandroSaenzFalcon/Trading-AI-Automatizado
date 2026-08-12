import re
with open(r"C:\Users\H2R\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\Tester\logs\20260809.log", "r", encoding="utf-16-le", errors="replace") as f:
    lines = f.readlines()
ln = lines[41]
print(repr(ln[:150]))
i = ln.find("testing of")
print("pos:", i)
print([hex(ord(c)) for c in ln[i:i+30]])
