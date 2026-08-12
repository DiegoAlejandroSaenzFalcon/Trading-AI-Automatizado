import re
s = "Core 1\tBTCUSDm,H1: testing of Experts\\Pure_Fractal_FVG_Fusion_BTCUSD_r30.ex5 from 2026.02.01 00:00 to 2026.05.13 00:00 started with inputs:"
print(repr(s))
m = re.search(r"testing of Experts\\([\w.]+)\.ex5 from (\S+) to (\S+)", s)
print("match:", m is not None, m.groups() if m else "")
