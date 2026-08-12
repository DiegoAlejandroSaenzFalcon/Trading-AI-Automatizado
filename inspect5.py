import re
path = r"C:\Users\H2R\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\Tester\logs\20260809.log"
with open(path, "r", encoding="utf-16-le", errors="replace") as f:
    lines = f.readlines()
ln = lines[41]
print(repr(ln))
m = re.search(r"testing of Experts\\([\w.]+)\.ex5 from (\S+) to (\S+)", ln)
print("match:", m)
if m:
    print(m.groups())
