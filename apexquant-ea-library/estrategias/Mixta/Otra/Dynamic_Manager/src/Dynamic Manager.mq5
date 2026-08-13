//+------------------------------------------------------------------+
//|                                     Pure_Fractal_Pure_v6.mq5     |
//|                                          Asistente de Programación|
//+------------------------------------------------------------------+
#property copyright "Asistente de Programación"
#property version   "6.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Parámetros de Entrada
input double   InpLotSize         = 0.01;      // Tamaño del Lote
input int      InpATRPeriod       = 14;        // Periodo ATR para medir el impulso
input double   InpTPMultiplier    = 0.8;       // Multiplicador de TP (Corto y rápido)
input double   InpSLMultiplier    = 3.0;       // Paracaídas de Emergencia (Multiplicador de ATR)
input int      InpTrailingPoints  = 10;        // Puntos para el Trailing Stop activo
input int      InpMinPointsProfit = 2;         // Puntos mínimos por encima de la entrada para el BE

//--- Variables Globales
int            handleATR;
double         bufferATR[];
ulong          magicNumber = 777;

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(magicNumber);
    
    // Inicializar indicador de impulso (ATR)
    handleATR = iATR(_Symbol, _Period, InpATRPeriod);
    if(handleATR == INVALID_HANDLE) return(INIT_FAILED);
    
    ArraySetAsSeries(bufferATR, true);
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(handleATR);
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
    // Asegurar que los buffers tengan datos
    if(CopyBuffer(handleATR, 0, 0, 1, bufferATR) < 1) return;
    
    int totalPositions = CountPositions();
    
    // Si no hay posiciones, abrir una inmediatamente basada en el impulso actual
    if(totalPositions == 0)
    {
        ExecuteContinuousEntry();
    }
    else
    {
        ManageExitsAndProtection();
    }
}

//+------------------------------------------------------------------+
//| Contar posiciones abiertas por este EA                          |
//+------------------------------------------------------------------+
int CountPositions()
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == magicNumber)
        {
            count++;
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| Entrada Continua (Sin Estrategia de Indicadores)                 |
//+------------------------------------------------------------------+
void ExecuteContinuousEntry()
{
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double atr = bufferATR[0];
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    
    // Para decidir la dirección de forma continua, miramos la dirección del tick/precio actual
    // Alternancia dinámica: Si el precio ask tiene decimal par, compra; si es impar, vende.
    // Esto simula una entrada totalmente libre de estrategia direccional fija.
    int decisionFactor = (int)(ask * MathPow(10, digits)) % 2;
    
    if(decisionFactor == 0) // Lógica de Compra
    {
        double sl = ask - (atr * InpSLMultiplier); // Paracaídas de emergencia amplio
        double tp = ask + (atr * InpTPMultiplier); // TP corto basado en el impulso en tiempo real
        
        trade.Buy(InpLotSize, _Symbol, ask, NormalizeDouble(sl, digits), NormalizeDouble(tp, digits), "Pure Buy v6");
    }
    else // Lógica de Venta
    {
        double sl = bid + (atr * InpSLMultiplier);
        double tp = bid - (atr * InpTPMultiplier);
        
        trade.Sell(InpLotSize, _Symbol, bid, NormalizeDouble(sl, digits), NormalizeDouble(tp, digits), "Pure Sell v6");
    }
}

//+------------------------------------------------------------------+
//| Gestión de Break-even y Trailing Stop en tiempo real             |
//+------------------------------------------------------------------+
void ManageExitsAndProtection()
{
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double atr = bufferATR[0];

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == magicNumber)
        {
            ulong  ticket = PositionGetTicket(i);
            double open   = PositionGetDouble(POSITION_PRICE_OPEN);
            double sl     = PositionGetDouble(POSITION_SL);
            double tp     = PositionGetDouble(POSITION_TP);
            double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
            {
                // 1. Lógica de Break-even Inteligente: Se activa tras un recorrido a favor de 0.5 * ATR
                if(bid >= open + (atr * 0.5))
                {
                    double targetBE = open + (InpMinPointsProfit * point);
                    if(sl < targetBE)
                    {
                        trade.PositionModify(ticket, NormalizeDouble(targetBE, digits), tp);
                    }
                }
                
                // 2. Trailing Stop Agresivo (Persigue de cerca solo si ya estamos protegidos en BE)
                if(sl >= open)
                {
                    double newSL = NormalizeDouble(bid - (InpTrailingPoints * point), digits);
                    if(newSL > sl)
                    {
                        trade.PositionModify(ticket, newSL, tp);
                    }
                }
            }
            else // POSITION_TYPE_SELL
            {
                // 1. Lógica de Break-even Inteligente
                if(ask <= open - (atr * 0.5))
                {
                    double targetBE = open - (InpMinPointsProfit * point);
                    if(sl == 0 || sl > targetBE)
                    {
                        trade.PositionModify(ticket, NormalizeDouble(targetBE, digits), tp);
                    }
                }
                
                // 2. Trailing Stop Agresivo
                if(sl > 0 && sl <= open)
                {
                    double newSL = NormalizeDouble(ask + (InpTrailingPoints * point), digits);
                    if(newSL < sl)
                    {
                        trade.PositionModify(ticket, newSL, tp);
                    }
                }
            }
        }
    }
  }