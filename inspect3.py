path = r"C:\Users\H2R\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\Tester\logs\20260809.log"
with open(path, "r", encoding="utf-16-le", errors="replace") as f:
    data = f.read()
print("len:", len(data))
idx = data.find("testing of")
print("primer 'testing of' en:", idx)
print(repr(data[idx:idx+220]))
