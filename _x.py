import warnings; warnings.filterwarnings("ignore")
src=open(r"C:\Users\H2R\Documents\Default Project\backtest_r30_xau.py",encoding="utf-8-sig").read()
src=src.replace("t_on, dbg_on = run(True)","pass").replace("t_on, dbg_on = run(False)","pass")
exec(compile(src,"backtest_r30_xau.py","exec"))
import importlib
m=importlib.import_module("backtest_r30_xau") if "backtest_r30_xau" in sys.modules else None
