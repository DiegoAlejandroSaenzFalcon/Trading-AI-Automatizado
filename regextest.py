import re

s = "testing of Experts\\Pure_Fractal_FVG_Fusion_BTCUSD_r30.ex5 from 2026.02.01 00:00 to 2026.05.13 00:00"
print("repr:", repr(s))
m = re.search(r"testing of Experts\\([\w.]+)\.ex5 from (\S+) to (\S+)", s)
print("match1:", m is not None, m.groups() if m else "")
m2 = re.search(r"testing of Experts\\([\w.]+)\.ex5 from (\S+) to (\S+)", s)
print("match2:", m2 is not None, m2.groups() if m2 else "")
