import re, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-16-le", errors="replace") as f:
    lines = f.readlines()
for i in [41, 42, 43]:
    ln = lines[i]
    m = re.search(r"testing of Experts\\\\([\w.]+)\.ex5 from (\S+) to (\S+)", ln)
    print(i, "match:", m is not None)
print("---- market lines sample ----")
cnt = 0
for i, ln in enumerate(lines):
    if "market buy" in ln or "market sell" in ln:
        print(i, repr(ln[:130]))
        cnt += 1
        if cnt >= 3: break
