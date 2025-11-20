//+------------------------------------------------------------------+
//|              FileSignalExecutor.mq5                              |
//|  Lee señales desde signal.txt y opera en base a RIESGO (%)       |
//|  - TradingView envía: id;symbol;side;risk%;entry;sl;tp1;tp2      |
//|  - EA abre 2 órdenes: 65% (TP1) y 35% (TP2)                      |
//|  - Al tocar TP1 -> SL a BE y activa trailing ATR en M15          |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

CTrade trade;

//---------------- INPUTS ----------------//
input string InpSignalFileName   = "signal.txt"; // Nombre del archivo en Common\Files
input double InpRiskPartTP1      = 0.65;        // % del riesgo para TP1
input double InpRiskPartTP2      = 0.35;        // % del riesgo para TP2

// Trailing ATR (M15), igual que en Pine
input int    InpATRPeriod        = 14;
input double InpATRMultiplier    = 2.0;

//---------------- ESTADO GLOBAL POR SÍMBOLO ----------------//
string last_signal_line = "";   // última línea procesada

double g_entryPrice  = 0.0;
double g_slPrice     = 0.0;
double g_tp1Price    = 0.0;
double g_tp2Price    = 0.0;
bool   g_isBuy       = true;
bool   g_beDone      = false;   // ¿ya movimos SL a BE?
bool   g_trailingOn  = false;   // ¿ya activamos trailing?

//+------------------------------------------------------------------+
//| Normaliza el volumen al step permitido del símbolo               |
//+------------------------------------------------------------------+
double NormalizeVolume(const string symbol, double vol)
{
   double minVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      step = 0.01; // fallback

   // recortamos por arriba
   if(vol > maxVol)
      vol = maxVol;

   // hacemos floor al múltiplo de step
   double steps = MathFloor(vol / step + 1e-8);
   double volAdj = steps * step;

   if(volAdj < minVol)
      return 0.0;

   int digits = (int)MathRound(-MathLog10(step));
   if(digits < 0)
      digits = 0;

   return NormalizeDouble(volAdj, digits);
}

//+------------------------------------------------------------------+
//| Abre 2 órdenes calculando riesgo con PRECIO ACTUAL DE MERCADO    |
//+------------------------------------------------------------------+
bool OpenTwoOrdersByRisk(const string symbol,
                         const bool isBuy,
                         const double riskPercent,
                         const double signalEntryPrice, // Solo referencial
                         const double slPrice,
                         const double tp1,
                         const double tp2)
{
   if(riskPercent <= 0.0) return false;

   // 1. Obtener precio ACTUAL de mercado para calcular distancia real
   double currentPrice = 0.0;
   if(isBuy) 
      currentPrice = SymbolInfoDouble(symbol, SYMBOL_ASK); // Compramos en Ask
   else      
      currentPrice = SymbolInfoDouble(symbol, SYMBOL_BID); // Vendemos en Bid

   // Validación de seguridad: ¿El precio ya cruzó el SL?
   if(isBuy && currentPrice <= slPrice) {
      Print("Error: El precio actual (", currentPrice, ") ya está debajo del SL (", slPrice, ")");
      return false;
   }
   if(!isBuy && currentPrice >= slPrice) {
      Print("Error: El precio actual (", currentPrice, ") ya está encima del SL (", slPrice, ")");
      return false;
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dist      = MathAbs(currentPrice - slPrice); // <--- USAMOS PRECIO REAL
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);

   // ... (Resto de validaciones de tickSize igual que antes) ...
   if(tickSize <= 0.0 || tickValue <= 0.0) return false;

   double ticks      = dist / tickSize;
   double lossPerLot = ticks * tickValue; 

   if(lossPerLot <= 0.0) return false;

   // Cálculo de lotes
   double riskMoneyTotal = equity * (riskPercent / 100.0);
   double riskMoneyTP1   = riskMoneyTotal * InpRiskPartTP1;
   double riskMoneyTP2   = riskMoneyTotal * InpRiskPartTP2;

   double lotsTotal = riskMoneyTotal / lossPerLot;
   double lotsTP1   = riskMoneyTP1   / lossPerLot;
   double lotsTP2   = riskMoneyTP2   / lossPerLot;

   lotsTP1 = NormalizeVolume(symbol, lotsTP1);
   lotsTP2 = NormalizeVolume(symbol, lotsTP2);

   PrintFormat("CALCULO RIESGO REAL: PrecioMercado=%.2f, SL=%.2f, Dist=%.2f, RiskMoney=%.2f -> LotesTP1=%.2f, LotesTP2=%.2f",
               currentPrice, slPrice, dist, riskMoneyTotal, lotsTP1, lotsTP2);

   // ... (Envío de órdenes igual que antes) ...
   bool ok = true;
   
   //--- Orden TP1
   if(lotsTP1 > 0.0) {
      if(isBuy) trade.Buy(lotsTP1, symbol, 0.0, slPrice, tp1, "Signal BUY TP1");
      else      trade.Sell(lotsTP1, symbol, 0.0, slPrice, tp1, "Signal SELL TP1");
   }
   //--- Orden TP2
   if(lotsTP2 > 0.0) {
      if(isBuy) trade.Buy(lotsTP2, symbol, 0.0, slPrice, tp2, "Signal BUY TP2");
      else      trade.Sell(lotsTP2, symbol, 0.0, slPrice, tp2, "Signal SELL TP2");
   }
   
   return ok;
}


//+------------------------------------------------------------------+
//| Lee y valida una nueva línea desde el archivo                    |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Lee y valida una nueva línea desde el archivo                    |
//+------------------------------------------------------------------+
bool ReadSignalFromFile(string &linea)
{
   // 1. ABRIR PARA LEER (Usando FILE_COMMON)
   int handle = FileOpen(
      InpSignalFileName,
      FILE_READ | FILE_TXT | FILE_COMMON | FILE_ANSI,
      0,
      CP_UTF8
   );
   
   if(handle == INVALID_HANDLE)
   {
      // Si el archivo no existe o Python lo está escribiendo justo ahora
      return false;
   }

   // Si el archivo existe pero está vacío, no hacemos nada
   if(FileSize(handle) == 0)
   {
      FileClose(handle);
      return false;
   }

   linea = FileReadString(handle);
   FileClose(handle);

   if(linea == "")
      return false;

   // Evitamos procesar la misma línea dos veces seguidas en memoria
   if(linea == last_signal_line)
   {
       // OJO: Si el archivo sigue lleno con la misma línea, hay que borrarlo
       // para que Python sepa que ya lo vimos.
   }
   else
   {
       last_signal_line = linea;
   }

   // 2. LIMPIAMOS ARCHIVO (AQUÍ FALTABA FILE_COMMON !!)
   // Al abrir con FILE_WRITE sin FILE_READ, se trunca el archivo a 0 bytes.
   int w = FileOpen(InpSignalFileName, FILE_WRITE | FILE_COMMON | FILE_ANSI); 
   
   if(w != INVALID_HANDLE)
   {
      FileClose(w); // Se cierra inmediatamente, dejando el archivo vacío
      // Print("Archivo limpiado correctamente."); // Debug opcional
   }
   else
   {
      Print("Error al intentar limpiar el archivo (Código: ", GetLastError(), ")");
   }

   return true;
}

//+------------------------------------------------------------------+
//| Procesa la señal: abre 2 órdenes y guarda estado para gestión    |
//+------------------------------------------------------------------+
void ExecuteSignal(const string &linea)
{
   Print("Procesando señal: '", linea, "'");

   string parts[];
   int n = StringSplit(linea, ';', parts);

   // Esperamos: id;symbol;side;riskPercent;entry;sl;tp1;tp2
   if(n != 8)
   {
      PrintFormat("Formato inválido: se esperaban 8 campos, se obtuvieron %d. Línea: '%s'", n, linea);
      return;
   }

   int    signal_id   = (int)StringToInteger(parts[0]);
   string symbol      = parts[1];
   string side   = parts[2];
   double riskPercent = StringToDouble(parts[3]);
   double entryPrice  = StringToDouble(parts[4]);
   double slPrice     = StringToDouble(parts[5]);
   double tp1         = StringToDouble(parts[6]);
   double tp2         = StringToDouble(parts[7]);  

   PrintFormat("Campos parseados -> id:%d, symbol:%s, side:%s, risk%%:%.2f, entry:%G, SL:%G, TP1:%G, TP2:%G",
               signal_id, symbol, side, riskPercent, entryPrice, slPrice, tp1, tp2);

   if(symbol != _Symbol)
   {
      PrintFormat("La señal es para %s, pero este EA está en %s. Se ignora.",
                  symbol, _Symbol);
      return;
   }

   if(riskPercent <= 0.0)
   {
      Print("RiskPercent <= 0, se ignora señal.");
      return;
   }

   bool isBuy;
   if(side == "BUY")
      isBuy = true;
   else if(side == "SELL")
      isBuy = false;
   else
   {
      int len = StringLen(side);
      PrintFormat("Acción desconocida (side): '%s'  len=%d", side, len);
   
      for(int i = 0; i < len; i++)
      {
         int ch = (int)StringGetCharacter(side, i);
         PrintFormat(" side[%d] = %d ('%c')", i, ch, ch);
      }
      return;
   }


   // Guardar estado de la última señal para este símbolo
   g_isBuy      = isBuy;
   g_entryPrice = entryPrice;
   g_slPrice    = slPrice;
   g_tp1Price   = tp1;
   g_tp2Price   = tp2;
   g_beDone     = false;
   g_trailingOn = false;

   bool ok = OpenTwoOrdersByRisk(symbol, isBuy, riskPercent, entryPrice, slPrice, tp1, tp2);

   if(!ok)
      Print("Hubo errores al abrir las órdenes para la señal ", signal_id);
}

//+------------------------------------------------------------------+
//| Gestiona BE + trailing ATR sobre posiciones abiertas             |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   string symbol = _Symbol;
   int total = PositionsTotal();
   if(total <= 0)
   {
      g_beDone     = false;
      g_trailingOn = false;
      return;
   }

   // Ver si hay al menos una posición "Signal ..." en este símbolo
   bool hasSignalPos = false;
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;

      string comment = PositionGetString(POSITION_COMMENT);
      if(StringFind(comment, "Signal", 0) == 0)
      {
         hasSignalPos = true;
         break;
      }
   }

   if(!hasSignalPos)
   {
     g_beDone     = false;
     g_trailingOn = false;
     return;
   }

   double priceBuy  = SymbolInfoDouble(symbol, SYMBOL_BID);
   double priceSell = SymbolInfoDouble(symbol, SYMBOL_ASK);

   //--- 1) Mover SL a BE cuando se toque TP1
   if(!g_beDone && g_tp1Price > 0.0)
   {
      if(g_isBuy)
      {
         if(priceBuy >= g_tp1Price)
         {
            PrintFormat("TP1 alcanzado (BUY). priceBid=%.2f >= TP1=%.2f -> mover SL a BE",
                        priceBuy, g_tp1Price);

            for(int i = total - 1; i >= 0; i--)
            {
               ulong ticket = PositionGetTicket(i);
               if(!PositionSelectByTicket(ticket))
                  continue;

               if(PositionGetString(POSITION_SYMBOL) != symbol)
                  continue;

               if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
                  continue;

               string comment = PositionGetString(POSITION_COMMENT);
               if(StringFind(comment, "Signal", 0) != 0)
                  continue;

               double entry = PositionGetDouble(POSITION_PRICE_OPEN);
               double tp    = PositionGetDouble(POSITION_TP);

               if(!trade.PositionModify(symbol, entry, tp))
               {
                  PrintFormat("Error al mover SL a BE para ticket %I64u. Retcode=%d (%s)",
                              ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
               }
               else
               {
                  PrintFormat("SL movido a BE (%.2f) para ticket %I64u", entry, ticket);
               }
            }

            g_beDone     = true;
            g_trailingOn = true;
         }
      }
      else // SELL
      {
         if(priceSell <= g_tp1Price)
         {
            PrintFormat("TP1 alcanzado (SELL). priceAsk=%.2f <= TP1=%.2f -> mover SL a BE",
                        priceSell, g_tp1Price);

            for(int i = total - 1; i >= 0; i--)
            {
               ulong ticket = PositionGetTicket(i);
               if(!PositionSelectByTicket(ticket))
                  continue;

               if(PositionGetString(POSITION_SYMBOL) != symbol)
                  continue;

               if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
                  continue;

               string comment = PositionGetString(POSITION_COMMENT);
               if(StringFind(comment, "Signal", 0) != 0)
                  continue;

               double entry = PositionGetDouble(POSITION_PRICE_OPEN);
               double tp    = PositionGetDouble(POSITION_TP);

               if(!trade.PositionModify(symbol, entry, tp))
               {
                  PrintFormat("Error al mover SL a BE para ticket %I64u. Retcode=%d (%s)",
                              ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
               }
               else
               {
                  PrintFormat("SL movido a BE (%.2f) para ticket %I64u", entry, ticket);
               }
            }

            g_beDone     = true;
            g_trailingOn = true;
         }
      }
   }

   //--- 2) Trailing ATR en M15 después de BE
   if(!g_trailingOn)
      return;

   double atr = iATR(symbol, PERIOD_M15, InpATRPeriod);
   if(atr <= 0.0)
      return;

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      string comment          = PositionGetString(POSITION_COMMENT);
      if(StringFind(comment, "Signal", 0) != 0)
         continue;

      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);

      if(type == POSITION_TYPE_BUY)
      {
         double newSL = priceBuy - InpATRMultiplier * atr;
         // Nunca bajamos SL (solo subirlo) y lo mantenemos por debajo del precio actual
         if(newSL > sl && newSL < priceBuy)
         {
            if(!trade.PositionModify(symbol, newSL, tp))
            {
               PrintFormat("Error en trailing BUY para ticket %I64u. Retcode=%d (%s)",
                           ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
            }
            else
            {
               PrintFormat("Trailing BUY: SL %.2f -> %.2f (precio=%.2f, ATR=%.2f)",
                           sl, newSL, priceBuy, atr);
            }
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double newSL = priceSell + InpATRMultiplier * atr;
         // Para SELL nunca subimos SL en contra (solo bajarlo hacia el precio)
         if((sl == 0.0 || newSL < sl) && newSL > priceSell)
         {
            if(!trade.PositionModify(symbol, newSL, tp))
            {
               PrintFormat("Error en trailing SELL para ticket %I64u. Retcode=%d (%s)",
                           ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
            }
            else
            {
               PrintFormat("Trailing SELL: SL %.2f -> %.2f (precio=%.2f, ATR=%.2f)",
                           sl, newSL, priceSell, atr);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| OnTick: lee señal nueva y gestiona posiciones                    |
//+------------------------------------------------------------------+
void OnTimer()
{
   string linea;
   // Intentamos leer. Si hay señal, se ejecuta y se borra el archivo rápido.
   if(ReadSignalFromFile(linea))
   {
      ExecuteSignal(linea);
   }
}

//+------------------------------------------------------------------+
//| OnTick: Se ejecuta con cada movimiento de precio (para Trailing) |
//+------------------------------------------------------------------+
void OnTick()
{
   // Solo gestionamos posiciones abiertas aquí
   ManageOpenPositions();
}

int OnInit()
{
   // Activa un temporizador que se ejecuta cada 1 segundo
   EventSetTimer(1); 
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   // Apagamos el temporizador al cerrar
   EventKillTimer();
}
