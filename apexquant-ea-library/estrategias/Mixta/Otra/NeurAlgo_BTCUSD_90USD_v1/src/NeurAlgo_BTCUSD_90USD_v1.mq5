//+------------------------------------------------------------------+
//|                                     NeurAlgo_BTCUSD_90USD_v1.mq5 |
//|                                     NeurAlgo_AI Quantitative Team|
//|                                     Soporte: Alejandro Saenz     |
//+------------------------------------------------------------------+
#property copyright "NeurAlgo_AI"
#property version   "9.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- PARÁMETROS OPERATIVOS (Ajustados para Cuenta Real de $90 USD)
input group "--- Gestión de Riesgo y Cuenta ---"
input double   InpMaxRiskPercent     = 5.0;       // Riesgo Máximo por Operación (% de la Cuenta)
input double   InpFixedLotSize       = 0.01;      // Lote por defecto si falla el cálculo dinámico
input bool     InpUseDynamicLot      = true;      // Habilitar Cálculo de Lote Dinámico por ATR

input group "--- Parámetros del Algoritmo ---"
input int      InpATRPeriod          = 14;        // Periodo ATR para Volatilidad
input double   InpTPMultiplier       = 1.5;       // Multiplicador Take Profit (Basado en ATR)
input double   InpSLMultiplier       = 3.5;       // Multiplicador Stop Loss (Basado en ATR)
input int      InpEMAPeriod          = 21;        // Filtro de Tendencia (Media Móvil Exponencial)

input group "--- Parámetros de Salida y Trailing ---"
input double   InpTrailingATRMult    = 1.0;       // Distancia del Trailing Stop (Multiplicador ATR)
input double   InpTrailingStepATRMult= 0.2;       // Paso Mínimo de Modificación (Multiplicador ATR)
input double   InpBEMultiplier       = 0.6;       // Activación de Break-Even (Multiplicador ATR)
input int      InpMinPointsProfit    = 100;       // Puntos a asegurar en BE (100 puntos = $1.00 USD en BTC)
input double   InpMaxSpreadATRRatio  = 0.4;       // Máximo spread tolerado (Porcentaje del ATR)

//--- Variables Globales de Control
int            handleATR;
int            handleEMA;
double         bufferATR[];
double         bufferEMA[];
ulong          magicNumber = 777100; // ID del bot en el mercado de BTC

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
    // Establecer Identificador de Órdenes
    trade.SetExpertMagicNumber(magicNumber);
    
    // Inicializar indicador ATR
    handleATR = iATR(_Symbol, _Period, InpATRPeriod);
    if(handleATR == INVALID_HANDLE) 
    {
        Print("[CRÍTICO] Error al inicializar handle del ATR en OnInit.");
        return(INIT_FAILED);
    }
    
    // Inicializar indicador EMA de Tendencia
    handleEMA = iMA(_Symbol, _Period, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
    if(handleEMA == INVALID_HANDLE)
    {
        Print("[CRÍTICO] Error al inicializar handle de la EMA en OnInit.");
        return(INIT_FAILED);
    }
    
    // Configurar buffers dinámicos como series (indexación de más reciente a más antiguo)
    ArraySetAsSeries(bufferATR, true);
    ArraySetAsSeries(bufferEMA, true);
    
    Print("[INICIALIZADO] NeurAlgo_AI cargado exitosamente. Monitoreando BTCUSD para cuenta de $90.00 USD.");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(handleATR);
    IndicatorRelease(handleEMA);
    Print("[DESCONECTADO] Recursos del sistema liberados. Razón de salida: ", reason);
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
    // 1. Validar sincronización de buffers de datos
    if(CopyBuffer(handleATR, 0, 0, 1, bufferATR) < 1 || 
       CopyBuffer(handleEMA, 0, 0, 2, bufferEMA) < 2) 
    {
        return; 
    }
    
    // 2. Extraer precios en milisegundos mediante MqlTick
    MqlTick currentTick;
    if(!SymbolInfoTick(_Symbol, currentTick)) return;
    
    double currentSpread = currentTick.ask - currentTick.bid;
    double atr = bufferATR[0];
    
    // 3. Filtro de Spread de Seguridad contra volatilidad del bróker
    bool isSpreadNormal = currentSpread <= (atr * InpMaxSpreadATRRatio);
    
    int totalPositions = CountPositions();
    
    if(totalPositions == 0)
    {
        if(isSpreadNormal)
        {
            ExecuteContinuousEntry(currentTick);
        }
    }
    else
    {
        ManageExitsAndProtection(currentTick);
    }
}

//+------------------------------------------------------------------+
//| Contar posiciones en mercado con direccionamiento seguro         |
//+------------------------------------------------------------------+
int CountPositions()
{
    int count = 0;
    int total = PositionsTotal();
    for(int i = total - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket > 0)
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
               PositionGetInteger(POSITION_MAGIC) == magicNumber)
            {
                count++;
            }
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| Cálculo Matemático de Lote y Margen Basado en Riesgo de Cuenta    |
//+------------------------------------------------------------------+
double CalculateSafeLot(double slDistanceInPrice, double currentPrice)
{
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmount = balance * (InpMaxRiskPercent / 100.0);
    
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    if(slDistanceInPrice <= 0 || tickValue <= 0 || tickSize <= 0) return InpFixedLotSize;
    
    // Cálculo de lote óptimo basado en la equivalencia de pérdida monetaria
    double pointsValue = slDistanceInPrice / tickSize;
    double calculatedLot = riskAmount / (pointsValue * tickValue);
    
    // Normalizar lote a las especificaciones del bróker
    calculatedLot = MathFloor(calculatedLot / lotStep) * lotStep;
    
    if(calculatedLot < minLot) 
    {
        // Alerta de sobre-riesgo si la cuenta de $90 exige un Stop Loss amplio
        double potentialLoss = (slDistanceInPrice / tickSize) * minLot * tickValue;
        if(potentialLoss > riskAmount)
        {
            Print("[ADVERTENCIA RIESGO] El lote mínimo (0.01) tiene un riesgo de $", potentialLoss, 
                  " USD. Excede el riesgo configurado de $", riskAmount, " USD.");
        }
        calculatedLot = minLot;
    }
    if(calculatedLot > maxLot) calculatedLot = maxLot;
    
    //--- VERIFICACIÓN DEL MARGEN DISPONIBLE ---
    double marginRequired = 0;
    if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, calculatedLot, currentPrice, marginRequired))
    {
        double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
        if(marginRequired > freeMargin)
        {
            Print("[CRÍTICO] Margen libre insuficiente para abrir operación. Requerido: $", marginRequired, 
                  " USD | Disponible: $", freeMargin, " USD. Orden bloqueada.");
            return 0.0; // Bloquea la entrada
        }
    }
    
    return calculatedLot;
}

//+------------------------------------------------------------------+
//| Entrada Estructurada (Micro-Tendencia + Paridad Dinámica)        |
//+------------------------------------------------------------------+
void ExecuteContinuousEntry(const MqlTick &tick)
{
    double atr = bufferATR[0];
    double ema = bufferEMA[0];
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
    
    // Paridad aritmética de precisión para alternancia de ticks
    long rawPoints = (long)MathRound(tick.ask / point);
    int decisionFactor = (int)(rawPoints % 2);
    
    bool trendIsUp   = tick.ask > ema;
    bool trendIsDown = tick.ask < ema;
    
    double slDistance = atr * InpSLMultiplier;
    double tpDistance = atr * InpTPMultiplier;
    
    // Filtrar contra los límites mínimos del bróker (Stop Levels)
    if(slDistance < stopLevel) slDistance = stopLevel + (50 * point);
    if(tpDistance < stopLevel) tpDistance = stopLevel + (50 * point);
    
    // 1. Ejecutar Lógica de Compra (Paridad Par sobre Tendencia Alcista)
    if(trendIsUp && decisionFactor == 0)
    {
        double calculatedLot = InpFixedLotSize;
        if(InpUseDynamicLot)
        {
            calculatedLot = CalculateSafeLot(slDistance, tick.ask);
            if(calculatedLot <= 0.0) return; // Margen o riesgo crítico bloqueado
        }
        
        double sl = tick.ask - slDistance;
        double tp = tick.ask + tpDistance;
        
        if(trade.Buy(calculatedLot, _Symbol, tick.ask, NormalizeDouble(sl, digits), NormalizeDouble(tp, digits), "BTC Razor BUY"))
        {
            if(trade.ResultRetcode() != TRADE_RETCODE_DONE && trade.ResultRetcode() != TRADE_RETCODE_PLACED)
            {
                Print("[ERROR COMPRA] Error al procesar. Código: ", trade.ResultRetcode(), " | Info: ", trade.ResultComment());
            }
        }
    }
    // 2. Ejecutar Lógica de Venta (Paridad Impar sobre Tendencia Bajista)
    else if(trendIsDown && decisionFactor != 0)
    {
        double calculatedLot = InpFixedLotSize;
        if(InpUseDynamicLot)
        {
            calculatedLot = CalculateSafeLot(slDistance, tick.bid);
            if(calculatedLot <= 0.0) return; // Margen o riesgo crítico bloqueado
        }
        
        double sl = tick.bid + slDistance;
        double tp = tick.bid - tpDistance;
        
        if(trade.Sell(calculatedLot, _Symbol, tick.bid, NormalizeDouble(sl, digits), NormalizeDouble(tp, digits), "BTC Razor SELL"))
        {
            if(trade.ResultRetcode() != TRADE_RETCODE_DONE && trade.ResultRetcode() != TRADE_RETCODE_PLACED)
            {
                Print("[ERROR VENTA] Error al procesar. Código: ", trade.ResultRetcode(), " | Info: ", trade.ResultComment());
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Gestión de Salidas con Protección de Volatilidad (ATR)           |
//+------------------------------------------------------------------+
void ManageExitsAndProtection(const MqlTick &tick)
{
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double atr = bufferATR[0];
    double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
    
    int total = PositionsTotal();

    for(int i = total - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket > 0)
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
               PositionGetInteger(POSITION_MAGIC) == magicNumber)
            {
                double open = PositionGetDouble(POSITION_PRICE_OPEN);
                double sl   = PositionGetDouble(POSITION_SL);
                double tp   = PositionGetDouble(POSITION_TP);
                
                if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                {
                    // A. Break-even Dinámico basado en ATR
                    if(tick.bid >= open + (atr * InpBEMultiplier))
                    {
                        double targetBE = open + (InpMinPointsProfit * point);
                        if(sl < targetBE)
                        {
                            if(tick.bid - targetBE >= stopLevel)
                            {
                                trade.PositionModify(ticket, NormalizeDouble(targetBE, digits), tp);
                            }
                        }
                    }
                    
                    // B. Trailing Stop Dinámico con filtro de "No-Spam" de Servidor
                    if(sl >= open)
                    {
                        double proposedSL = tick.bid - (atr * InpTrailingATRMult);
                        double minImprovement = atr * InpTrailingStepATRMult;
                        
                        if(proposedSL >= sl + minImprovement)
                        {
                            if(tick.bid - proposedSL >= stopLevel)
                            {
                                trade.PositionModify(ticket, NormalizeDouble(proposedSL, digits), tp);
                            }
                        }
                    }
                }
                else // POSITION_TYPE_SELL
                {
                    // A. Break-even Dinámico basado en ATR
                    if(tick.ask <= open - (atr * InpBEMultiplier))
                    {
                        double targetBE = open - (InpMinPointsProfit * point);
                        if(sl == 0 || sl > targetBE)
                        {
                            if(targetBE - tick.ask >= stopLevel)
                            {
                                trade.PositionModify(ticket, NormalizeDouble(targetBE, digits), tp);
                            }
                        }
                    }
                    
                    // B. Trailing Stop Dinámico con filtro de "No-Spam" de Servidor
                    if(sl > 0 && sl <= open)
                    {
                        double proposedSL = tick.ask + (atr * InpTrailingATRMult);
                        double minImprovement = atr * InpTrailingStepATRMult;
                        
                        // En posiciones cortas, el Stop Loss mejora al descender
                        if(proposedSL <= sl - minImprovement)
                        {
                            if(proposedSL - tick.ask >= stopLevel)
                            {
                                trade.PositionModify(ticket, NormalizeDouble(proposedSL, digits), tp);
                            }
                        }
                    }
                }
            }
        }
    }
}
