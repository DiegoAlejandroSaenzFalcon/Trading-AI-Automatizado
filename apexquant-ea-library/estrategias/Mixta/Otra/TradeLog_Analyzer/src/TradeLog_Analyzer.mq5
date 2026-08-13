//+------------------------------------------------------------------+
//|                                           TradeLog_Analyzer.mq5  |
//|                        Copyright 2026, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property description "Analiza el fichero CSV de Futuro Gemini y muestra estadísticas en el gráfico."

#property script_show_inputs

input string InpLogFileName = "FuturoGemini_TradeLog.csv"; // Nombre del fichero de registro a analizar

//--- Estructura para almacenar estadísticas
struct TradeStats
  {
   int      totalTrades;
   int      winningTrades;
   int      losingTrades;
   double   grossProfit;
   double   grossLoss;
   double   totalNetProfit;
  };

//--- Variables globales para el panel
string   g_prefix = "LOG_ANALYZER_";
datetime g_lastFileModTime = 0;

//+------------------------------------------------------------------+
//| Script program start function                                    |
//+------------------------------------------------------------------+
void OnStart()
  {
   //--- Bucle principal para mantener el script activo y actualizando el panel
   while(!IsStopped())
     {
      long fileHandle = FileOpen(InpLogFileName, FILE_READ|FILE_CSV, ',');
      if(fileHandle == INVALID_HANDLE)
        {
         CreateDashboard("ERROR", "Fichero no encontrado: " + InpLogFileName, "", "", "", "", "");
         Sleep(5000); // Reintentar en 5 segundos
         continue;
        }

      datetime modTime = FileGetInteger(fileHandle, FILE_MODIFIED_TIME);
      FileClose(fileHandle);

      //--- Solo actualiza si el fichero ha cambiado
      if(modTime != g_lastFileModTime)
        {
         g_lastFileModTime = modTime;
         TradeStats stats;
         if(AnalyzeLogFile(stats))
           {
            UpdateDashboard(stats);
           }
        }

      Sleep(5000); // Esperar 5 segundos antes de la próxima comprobación
     }
  }
//+------------------------------------------------------------------+
//| Función para analizar el fichero de registro                     |
//+------------------------------------------------------------------+
bool AnalyzeLogFile(TradeStats &stats)
  {
   //--- Inicializar estadísticas
   stats.totalTrades = 0;
   stats.winningTrades = 0;
   stats.losingTrades = 0;
   stats.grossProfit = 0;
   stats.grossLoss = 0;
   stats.totalNetProfit = 0;

   int handle = FileOpen(InpLogFileName, FILE_READ|FILE_CSV, ',');
   if(handle == INVALID_HANDLE) return false;

   //--- Saltar la cabecera
   FileReadString(handle);

   while(!FileIsEnding(handle))
     {
      FileReadString(handle); // Timestamp
      FileReadString(handle); // PositionID
      FileReadString(handle); // Symbol
      string type = FileReadString(handle); // Type (BUY, SELL, CLOSE)

      if(type == "CLOSE")
        {
         //--- Es una línea de cierre, leemos el resultado
         FileReadDouble(handle); // Lots
         FileReadDouble(handle); // EntryPrice
         FileReadDouble(handle); // SL
         FileReadDouble(handle); // TP
         FileReadDouble(handle); // ATR
         FileReadDouble(handle); // Kalman_pLong
         FileReadString(handle); // UsedConfluence
         FileReadString(handle); // MacroFilterActive
         FileReadDouble(handle); // MacroValue
         FileReadDouble(handle); // KalmanPrice
         FileReadDouble(handle); // MarketPrice
         FileReadDouble(handle); // KalmanVelocity
         FileReadDouble(handle); // AdaptiveNoise_R
         double result = FileReadDouble(handle); // ResultUSD

         stats.totalTrades++;
         stats.totalNetProfit += result;

         if(result > 0)
           {
            stats.winningTrades++;
            stats.grossProfit += result;
           }
         else
           {
            stats.losingTrades++;
            stats.grossLoss += MathAbs(result);
           }
        }
      else
        {
         //--- Es una línea de entrada, simplemente la saltamos
         FileReadString(handle); // El resto de la línea
        }
     }

   FileClose(handle);
   return true;
  }
//+------------------------------------------------------------------+
//| Funciones para dibujar y actualizar el panel de estadísticas     |
//+------------------------------------------------------------------+
void CreateDashboard(string s1, string s2, string s3, string s4, string s5, string s6, string s7)
  {
   //--- Crear fondo
   ObjectCreate(0, g_prefix + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, g_prefix + "BG", OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, g_prefix + "BG", OBJPROP_YDISTANCE, 160);
   ObjectSetInteger(0, g_prefix + "BG", OBJPROP_XSIZE, 235);
   ObjectSetInteger(0, g_prefix + "BG", OBJPROP_YSIZE, 130);
   ObjectSetInteger(0, g_prefix + "BG", OBJPROP_BGCOLOR, C'25,20,20');
   ObjectSetInteger(0, g_prefix + "BG", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, g_prefix + "BG", OBJPROP_CORNER, CORNER_LEFT_UPPER);

   //--- Crear etiquetas de texto
   string labels[7] = {s1, s2, s3, s4, s5, s6, s7};
   for(int i = 0; i < 7; i++)
     {
      ObjectCreate(0, g_prefix + "LBL" + (string)i, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, g_prefix + "LBL" + (string)i, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, g_prefix + "LBL" + (string)i, OBJPROP_XDISTANCE, 20);
      ObjectSetInteger(0, g_prefix + "LBL" + (string)i, OBJPROP_YDISTANCE, 168 + i * 16);
      ObjectSetString(0, g_prefix + "LBL" + (string)i, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, g_prefix + "LBL" + (string)i, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, g_prefix + "LBL" + (string)i, OBJPROP_COLOR, clrWhite);
      ObjectSetString(0, g_prefix + "LBL" + (string)i, OBJPROP_TEXT, labels[i]);
     }
   ObjectSetInteger(0, g_prefix + "LBL0", OBJPROP_COLOR, clrGold);
  }

void UpdateDashboard(const TradeStats &stats)
  {
   double profitFactor = (stats.grossLoss > 0) ? stats.grossProfit / stats.grossLoss : 0;
   double winRate = (stats.totalTrades > 0) ? (double)stats.winningTrades / stats.totalTrades * 100.0 : 0;
   double avgWin = (stats.winningTrades > 0) ? stats.grossProfit / stats.winningTrades : 0;
   double avgLoss = (stats.losingTrades > 0) ? stats.grossLoss / stats.losingTrades : 0;
   double payoffRatio = (avgLoss > 0) ? avgWin / avgLoss : 0;
   double expectancy = (stats.totalTrades > 0) ? stats.totalNetProfit / stats.totalTrades : 0;

   string s1 = "--- ANALISIS DE RENDIMIENTO ---";
   string s2 = StringFormat("Profit Factor: %.2f", profitFactor);
   string s3 = StringFormat("Net Profit: %.2f USD", stats.totalNetProfit);
   string s4 = StringFormat("Win Rate: %d / %d (%.1f%%)", stats.winningTrades, stats.totalTrades, winRate);
   string s5 = StringFormat("Payoff Ratio: %.2f (%.2f/%.2f)", payoffRatio, avgWin, avgLoss);
   string s6 = StringFormat("Expectativa/Trade: %.2f USD", expectancy);
   string s7 = StringFormat("Fichero: %s", InpLogFileName);

   CreateDashboard(s1, s2, s3, s4, s5, s6, s7);
  }

void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, g_prefix);
  }
//+------------------------------------------------------------------+