import re, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-16-le", errors="replace") as f:
    lines = f.readlines()
ln = lines[41]
m = re.search(r"testing of Experts\\([\w.]+)\.ex5 from (\S+) to (\S+)", ln)
print("match:", m is not None, m.groups() if m else "")
