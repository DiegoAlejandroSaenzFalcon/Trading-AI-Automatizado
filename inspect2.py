path = r"C:\Users\H2R\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\Tester\logs\20260809.log"
with open(path, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()
print("total", len(lines))
for i, ln in enumerate(lines[:50]):
    print(i, repr(ln[:150]))
