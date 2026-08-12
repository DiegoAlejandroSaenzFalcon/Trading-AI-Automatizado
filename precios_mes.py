import pandas as pd
import numpy as np
import MetaTrader5 as mt5
import datetime as dtm

mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
SYM="XAUUSDm"; start=dtm.datetime(2026,3,1); end=dtm.datetime(2026,8,11)
r1=mt5.copy_rates_range(SYM,mt5.TIMEFRAME_M1,start,end)
mt5.shutdown()
df=pd.DataFrame(r1); df['time']=pd.to_datetime(df['time'],unit='s')
print("ultima vela:", df.iloc[-1]['time'], df.iloc[-1]['close'])
df['atr']=df['high'].ewm(alpha=1/14).mean()
# rango de precios por mes para entender el mercado
for m in df.groupby(df['time'].dt.to_period('M'))['close'].agg(['min','max','mean']).iterrows():
    print(m)
