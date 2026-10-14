//+------------------------------------------------------------------+
//| XAUUSD_Bot.mq5                                                   |
//| XAUUSD. Une ouverture seulement si tout est validé.              |
//+------------------------------------------------------------------+
#property copyright   "XAUUSD Bot"
#property version     "0.6.0"
#property description "XAUUSD petit compte. Ouverture seulement si signal, risque et protections passent."

//+------------------------------------------------------------------+
//| Ouverture au marché uniquement après signal, lot, SL, TP 1:2,    |
//| spread, volatilité, annonces USD majeures et protections.        |
//| Une référence du jour déjà enregistrée n'est jamais remplacée.   |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Paramètres configurables.                                        |
//+------------------------------------------------------------------+
input group "Symbole"
input string InpSymbol = "XAUUSD"; // Symbole autorisé

input group "Signal"
input double InpMaxSpreadPrice   = 0.50; // Spread maximum, en prix
input int    InpSwingLookback    = 20;   // Bougies M15 pour les swings
input double InpMaxLevelDistance = 1.50; // Distance max au niveau, en prix
input double InpMinBodyRatio     = 0.50; // Corps minimum / hauteur
input double InpMaxAtrPrice      = 5.0;  // ATR M15 maximum, en prix
input int    InpNewsMinutes      = 30;   // Minutes autour d'une annonce USD majeure

input group "Risque"
input double RiskPercent       = 1.0; // Risque par trade, en % de l'equity
input double AtrStopMultiplier = 1.0; // Marge du Stop Loss, en ATR
input double RewardRiskRatio   = 2.0; // Rapport Take Profit / Stop Loss

input group "Protections"
input ulong  MagicNumber           = 260101; // Magic Number de ce robot
input double MaxDailyLossPercent   = 3.0;    // Perte quotidienne max, en %
input int    MaxConsecutiveLosses  = 2;      // Pertes consécutives avant arrêt
input double AtrTrailMultiplier    = 1.0;    // Distance du trailing, en ATR

input group "Exécution"
input int InpDeviationPoints = 30; // Écart maximum accepté, en points

//+------------------------------------------------------------------+
//| Constantes, indicateurs et état du robot.                        |
//+------------------------------------------------------------------+
const int EMA_M15_FAST_PERIOD  = 20;
const int EMA_M15_SLOW_PERIOD  = 50;
const int EMA_H1_TREND_PERIOD  = 200;
const int RSI_M15_PERIOD       = 14;
const int ATR_M15_PERIOD       = 14;

// État technique de la dernière bougie M15 analysée.
// ENTRY_BUY et ENTRY_SELL décrivent le signal. L'ordre part ensuite
// seulement si le risque et les protections passent encore.
enum ENUM_ENTRY_SIGNAL
  {
   ENTRY_NONE = 0,
   ENTRY_BUY  = 1,
   ENTRY_SELL = 2
  };

struct SEntryPlan
  {
   double volume;
   double entry;
   double stopLoss;
   double takeProfit;
   double estimatedLoss;
  };

int g_handleEma20M15 = INVALID_HANDLE;
int g_handleEma50M15 = INVALID_HANDLE;
int g_handleRsiM15   = INVALID_HANDLE;
int g_handleAtrM15   = INVALID_HANDLE;
int g_handleEma200H1 = INVALID_HANDLE;

double g_ema20M15 = 0.0;
double g_ema50M15 = 0.0;
double g_rsiM15   = 0.0;
double g_atrM15   = 0.0;
double g_ema200H1 = 0.0;

bool     g_dataMissingLogged = false;
bool     g_dataReadyLogged   = false;
datetime g_contextMissingBar = 0;
datetime g_lastEvaluatedBar  = 0;
ENUM_ENTRY_SIGNAL g_entrySignal = ENTRY_NONE;
string   g_lastDecision      = "En attente d'une bougie M15 clôturée";
bool     g_entryBlocked      = false;
string   g_blockReason       = "";
string   g_blockCode         = "";
bool     g_anchorWarningLogged = false;

//+------------------------------------------------------------------+
//| Vérifie les paramètres avant de créer les indicateurs.           |
//+------------------------------------------------------------------+
bool ParametersAreValid(void)
  {
   if(StringLen(InpSymbol) == 0)
     {
      Print("[XAUUSD_Bot][ERROR] Le symbole configuré est vide.");
      return false;
     }

   if(InpMaxSpreadPrice <= 0.0)
     {
      Print("[XAUUSD_Bot][ERROR] Le spread maximum doit être supérieur à 0.");
      return false;
     }

   if(InpSwingLookback < 5)
     {
      Print("[XAUUSD_Bot][ERROR] Le nombre de bougies pour les swings doit être au moins 5.");
      return false;
     }

   if(InpMaxLevelDistance <= 0.0)
     {
      Print("[XAUUSD_Bot][ERROR] La distance maximale au niveau doit être supérieure à 0.");
      return false;
     }

   if(InpMinBodyRatio <= 0.0 || InpMinBodyRatio > 1.0)
     {
      Print("[XAUUSD_Bot][ERROR] Le rapport du corps doit être supérieur à 0 et inférieur ou égal à 1.");
      return false;
     }

   if(InpMaxAtrPrice <= 0.0)
     {
      Print("[XAUUSD_Bot][ERROR] L'ATR maximum doit être supérieur à 0.");
      return false;
     }

   if(InpNewsMinutes < 1 || InpNewsMinutes > 240)
     {
      Print("[XAUUSD_Bot][ERROR] La fenêtre d'annonce doit être comprise entre 1 et 240 minutes.");
      return false;
     }

   if(RiskPercent <= 0.0 || RiskPercent > 100.0)
     {
      Print("[XAUUSD_Bot][ERROR] Le risque doit être supérieur à 0 et inférieur ou égal à 100.");
      return false;
     }

   if(AtrStopMultiplier <= 0.0)
     {
      Print("[XAUUSD_Bot][ERROR] La marge ATR du Stop Loss doit être supérieure à 0.");
      return false;
     }

   if(RewardRiskRatio < 2.0)
     {
      Print("[XAUUSD_Bot][ERROR] Le rapport Take Profit / Stop Loss doit être au moins 2.");
      return false;
     }

   if(MagicNumber == 0)
     {
      Print("[XAUUSD_Bot][ERROR] Le Magic Number doit être supérieur à 0.");
      return false;
     }

   if(MaxDailyLossPercent <= 0.0 || MaxDailyLossPercent > 100.0)
     {
      Print("[XAUUSD_Bot][ERROR] La perte quotidienne maximale doit être supérieure à 0 et inférieure ou égale à 100.");
      return false;
     }

   if(MaxConsecutiveLosses < 1)
     {
      Print("[XAUUSD_Bot][ERROR] Le nombre de pertes consécutives doit être au moins 1.");
      return false;
     }

   if(AtrTrailMultiplier <= 0.0)
     {
      Print("[XAUUSD_Bot][ERROR] Le multiplicateur du trailing stop doit être supérieur à 0.");
      return false;
     }

   if(InpDeviationPoints < 0 || InpDeviationPoints > 500)
     {
      Print("[XAUUSD_Bot][ERROR] L'écart de prix doit être compris entre 0 et 500 points.");
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Indicateurs et lecture du marché.                                |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Signale un handle non créé.                                      |
//+------------------------------------------------------------------+
bool IndicatorHandleIsValid(const int handle, const string name)
  {
   if(handle != INVALID_HANDLE)
      return true;

   Print("[XAUUSD_Bot][ERROR] ", name, " : handle invalide. Code ", GetLastError(), ".");
   return false;
  }

//+------------------------------------------------------------------+
//| Libère chaque handle encore ouvert.                              |
//+------------------------------------------------------------------+
void ReleaseIndicators(void)
  {
   if(g_handleEma20M15 != INVALID_HANDLE)
     {
      IndicatorRelease(g_handleEma20M15);
      g_handleEma20M15 = INVALID_HANDLE;
     }

   if(g_handleEma50M15 != INVALID_HANDLE)
     {
      IndicatorRelease(g_handleEma50M15);
      g_handleEma50M15 = INVALID_HANDLE;
     }

   if(g_handleRsiM15 != INVALID_HANDLE)
     {
      IndicatorRelease(g_handleRsiM15);
      g_handleRsiM15 = INVALID_HANDLE;
     }

   if(g_handleAtrM15 != INVALID_HANDLE)
     {
      IndicatorRelease(g_handleAtrM15);
      g_handleAtrM15 = INVALID_HANDLE;
     }

   if(g_handleEma200H1 != INVALID_HANDLE)
     {
      IndicatorRelease(g_handleEma200H1);
      g_handleEma200H1 = INVALID_HANDLE;
     }
  }

//+------------------------------------------------------------------+
//| Lit la dernière bougie clôturée (index 1, bougie 0 ignorée).     |
//+------------------------------------------------------------------+
bool ReadClosedValue(const int handle, double &value)
  {
   if(handle == INVALID_HANDLE)
      return false;

   if(BarsCalculated(handle) < 2)
      return false;

   double data[];
   const int copied = CopyBuffer(handle, 0, 1, 1, data);
   if(copied != 1)
      return false;

   if(data[0] == EMPTY_VALUE)
      return false;

   value = data[0];
   return true;
  }

//+------------------------------------------------------------------+
//| Récupère les cinq valeurs, ou n'en retient aucune.               |
//+------------------------------------------------------------------+
bool ReadIndicators(void)
  {
   double ema20M15 = 0.0;
   double ema50M15 = 0.0;
   double rsiM15   = 0.0;
   double atrM15   = 0.0;
   double ema200H1 = 0.0;

   if(!ReadClosedValue(g_handleEma20M15, ema20M15) ||
      !ReadClosedValue(g_handleEma50M15, ema50M15) ||
      !ReadClosedValue(g_handleRsiM15, rsiM15) ||
      !ReadClosedValue(g_handleAtrM15, atrM15) ||
      !ReadClosedValue(g_handleEma200H1, ema200H1))
      return false;

   g_ema20M15 = ema20M15;
   g_ema50M15 = ema50M15;
   g_rsiM15   = rsiM15;
   g_atrM15   = atrM15;
   g_ema200H1 = ema200H1;
   return true;
  }

//+------------------------------------------------------------------+
//| Classe les bougies M15 de la plus récente à la plus ancienne.    |
//| L'index 0 est la bougie de confirmation.                         |
//+------------------------------------------------------------------+
bool CopyClosedM15Bars(MqlRates &bars[])
  {
   const int count = InpSwingLookback + 2;
   MqlRates raw[];
   const int copied = CopyRates(InpSymbol, PERIOD_M15, 1, count, raw);
   if(copied != count)
      return false;

   const datetime closedTime = iTime(InpSymbol, PERIOD_M15, 1);
   if(closedTime <= 0)
      return false;

   ArrayResize(bars, count);

   if(raw[0].time == closedTime)
     {
      for(int i = 0; i < count; i++)
         bars[i] = raw[i];
     }
   else if(raw[count - 1].time == closedTime)
     {
      for(int i = 0; i < count; i++)
         bars[i] = raw[count - 1 - i];
     }
   else
      return false;

   if(bars[1].time >= bars[0].time)
      return false;

   return true;
  }

//+------------------------------------------------------------------+
//| Lit la clôture de la dernière bougie H1 terminée.                |
//+------------------------------------------------------------------+
bool ReadClosedH1(double &closePrice)
  {
   MqlRates h1[];
   if(CopyRates(InpSymbol, PERIOD_H1, 1, 1, h1) != 1)
      return false;

   const datetime closedTime = iTime(InpSymbol, PERIOD_H1, 1);
   if(closedTime <= 0 || h1[0].time != closedTime)
      return false;

   if(h1[0].close <= 0.0)
      return false;

   closePrice = h1[0].close;
   return true;
  }

//+------------------------------------------------------------------+
//| Mesure le spread réel : prix d'achat moins prix de vente.        |
//+------------------------------------------------------------------+
bool ReadSpread(double &spreadPrice, long &spreadPoints)
  {
   const double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0 || ask < bid)
      return false;

   spreadPrice = ask - bid;
   spreadPoints = SymbolInfoInteger(InpSymbol, SYMBOL_SPREAD);
   return true;
  }

//+------------------------------------------------------------------+
//| Détection du signal sur la bougie M15 clôturée.                  |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Swing bas le plus proche, situé sous la clôture ou au même prix. |
//+------------------------------------------------------------------+
bool FindNearestSupport(MqlRates &bars[], const double closePrice, double &level)
  {
   if(ArraySize(bars) <= InpSwingLookback + 1)
      return false;

   bool found = false;
   double nearest = 0.0;

   for(int i = 2; i <= InpSwingLookback; i++)
     {
      if(bars[i].low < bars[i - 1].low &&
         bars[i].low < bars[i + 1].low &&
         bars[i].low <= closePrice)
        {
         if(!found || bars[i].low > nearest)
           {
            nearest = bars[i].low;
            found = true;
           }
        }
     }

   if(!found)
      return false;

   level = nearest;
   return true;
  }

//+------------------------------------------------------------------+
//| Swing haut le plus proche, situé au-dessus ou au même prix.      |
//+------------------------------------------------------------------+
bool FindNearestResistance(MqlRates &bars[], const double closePrice, double &level)
  {
   if(ArraySize(bars) <= InpSwingLookback + 1)
      return false;

   bool found = false;
   double nearest = 0.0;

   for(int i = 2; i <= InpSwingLookback; i++)
     {
      if(bars[i].high > bars[i - 1].high &&
         bars[i].high > bars[i + 1].high &&
         bars[i].high >= closePrice)
        {
         if(!found || bars[i].high < nearest)
           {
            nearest = bars[i].high;
            found = true;
           }
        }
     }

   if(!found)
      return false;

   level = nearest;
   return true;
  }

//+------------------------------------------------------------------+
//| Bougie haussière dont le corps couvre assez de la hauteur.       |
//+------------------------------------------------------------------+
bool IsBullishConfirmation(const MqlRates &bar, string &reason)
  {
   const double range = bar.high - bar.low;
   if(range <= 0.0)
     {
      reason = "bougie M15 sans hauteur";
      return false;
     }

   if(bar.close <= bar.open)
     {
      reason = "bougie M15 non haussière";
      return false;
     }

   const double body = bar.close - bar.open;
   if((body / range) < InpMinBodyRatio)
     {
      reason = "corps haussier trop faible";
      return false;
     }

   reason = "";
   return true;
  }

//+------------------------------------------------------------------+
//| Bougie baissière dont le corps couvre assez de la hauteur.       |
//+------------------------------------------------------------------+
bool IsBearishConfirmation(const MqlRates &bar, string &reason)
  {
   const double range = bar.high - bar.low;
   if(range <= 0.0)
     {
      reason = "bougie M15 sans hauteur";
      return false;
     }

   if(bar.close >= bar.open)
     {
      reason = "bougie M15 non baissière";
      return false;
     }

   const double body = bar.open - bar.close;
   if((body / range) < InpMinBodyRatio)
     {
      reason = "corps baissier trop faible";
      return false;
     }

   reason = "";
   return true;
  }

//+------------------------------------------------------------------+
//| Risque, Stop Loss et Take Profit.                                 |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Aligne un prix vers le bas, sur le pas de cotation.              |
//+------------------------------------------------------------------+
double FloorToTick(const double price, const double tickSize, const int digits)
  {
   const double steps = MathFloor((price / tickSize) + 0.00000001);
   return NormalizeDouble(steps * tickSize, digits);
  }

//+------------------------------------------------------------------+
//| Aligne un prix vers le haut, sur le pas de cotation.             |
//+------------------------------------------------------------------+
double CeilToTick(const double price, const double tickSize, const int digits)
  {
   const double steps = MathCeil((price / tickSize) - 0.00000001);
   return NormalizeDouble(steps * tickSize, digits);
  }

//+------------------------------------------------------------------+
//| Nombre de décimales correspondant au pas de volume.              |
//+------------------------------------------------------------------+
int VolumeDigits(const double step)
  {
   int digits = 0;
   double value = step;

   while(digits < 8 && MathAbs(value - MathRound(value)) > 0.00000001)
     {
      value *= 10.0;
      digits++;
     }

   return digits;
  }

//+------------------------------------------------------------------+
//| Arrondit un volume vers le bas, sur le pas autorisé.             |
//+------------------------------------------------------------------+
double FloorToStep(const double volume, const double step, const int digits)
  {
   const double steps = MathFloor((volume / step) + 0.00000001);
   return NormalizeDouble(steps * step, digits);
  }

//+------------------------------------------------------------------+
//| Perte estimée, en devise du compte, si le prix atteint le SL.    |
//+------------------------------------------------------------------+
bool LossAtStop(const ENUM_ORDER_TYPE orderType,
                const double volume,
                const double entry,
                const double stopLoss,
                double &loss)
  {
   double profit = 0.0;
   if(!OrderCalcProfit(orderType, InpSymbol, volume, entry, stopLoss, profit))
      return false;

   if(profit >= 0.0)
      return false;

   loss = -profit;
   return true;
  }

//+------------------------------------------------------------------+
//| Stop Loss au-delà du niveau, avec la marge ATR.                  |
//+------------------------------------------------------------------+
bool BuildStopLoss(const ENUM_ORDER_TYPE orderType,
                   const double level,
                   const double entry,
                   const double bid,
                   const double ask,
                   const double tickSize,
                   const int digits,
                   double &stopLoss,
                   string &reason)
  {
   if(g_atrM15 <= 0.0 || AtrStopMultiplier <= 0.0)
     {
      reason = "ATR invalide";
      return false;
     }

   const double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   const long stopsLevel = SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(point <= 0.0 || stopsLevel < 0)
     {
      reason = "distance minimale du courtier indisponible";
      return false;
     }

   const double margin = g_atrM15 * AtrStopMultiplier;
   const double minDistance = (double)stopsLevel * point;

   if(orderType == ORDER_TYPE_BUY)
     {
      const double raw = level - margin;
      if(raw <= 0.0)
        {
         reason = "Stop Loss invalide";
         return false;
        }

      stopLoss = FloorToTick(raw, tickSize, digits);
      if(stopLoss <= 0.0 || stopLoss >= entry || stopLoss >= level || stopLoss >= bid)
        {
         reason = "Stop Loss du mauvais côté de l'entrée";
         return false;
        }

      if((bid - stopLoss) < minDistance)
        {
         reason = "Stop Loss plus proche que la distance minimale du courtier";
         return false;
        }

      return true;
     }

   const double raw = level + margin;
   stopLoss = CeilToTick(raw, tickSize, digits);
   if(stopLoss <= entry || stopLoss <= level || stopLoss <= ask)
     {
      reason = "Stop Loss du mauvais côté de l'entrée";
      return false;
     }

   if((stopLoss - ask) < minDistance)
     {
      reason = "Stop Loss plus proche que la distance minimale du courtier";
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Take Profit à la distance demandée, du bon côté de l'entrée.     |
//+------------------------------------------------------------------+
bool BuildTakeProfit(const ENUM_ORDER_TYPE orderType,
                     const double entry,
                     const double bid,
                     const double ask,
                     const double stopLoss,
                     const double tickSize,
                     const int digits,
                     double &takeProfit,
                     string &reason)
  {
   const double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   const long stopsLevel = SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(point <= 0.0 || stopsLevel < 0)
     {
      reason = "distance minimale du courtier indisponible";
      return false;
     }

   const double minDistance = (double)stopsLevel * point;
   const double riskDistance = (orderType == ORDER_TYPE_BUY) ? (entry - stopLoss) : (stopLoss - entry);
   if(riskDistance <= 0.0)
     {
      reason = "distance de Stop Loss invalide";
      return false;
     }

   const double targetDistance = riskDistance * RewardRiskRatio;

   if(orderType == ORDER_TYPE_BUY)
     {
      takeProfit = CeilToTick(entry + targetDistance, tickSize, digits);
      if(takeProfit <= entry || (takeProfit - entry) + (tickSize * 0.5) < targetDistance)
        {
         reason = "Take Profit inférieur au rapport demandé";
         return false;
        }

      if((takeProfit - ask) < minDistance)
        {
         reason = "Take Profit plus proche que la distance minimale du courtier";
         return false;
        }

      return true;
     }

   takeProfit = FloorToTick(entry - targetDistance, tickSize, digits);
   if(takeProfit <= 0.0 || takeProfit >= entry || (entry - takeProfit) + (tickSize * 0.5) < targetDistance)
     {
      reason = "Take Profit inférieur au rapport demandé";
      return false;
     }

   if((bid - takeProfit) < minDistance)
     {
      reason = "Take Profit plus proche que la distance minimale du courtier";
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Volume arrondi vers le bas. Le lot minimal ne force pas le risque.|
//+------------------------------------------------------------------+
bool CalculateVolume(const ENUM_ORDER_TYPE orderType,
                     const double entry,
                     const double stopLoss,
                     double &volume,
                     double &estimatedLoss,
                     string &reason)
  {
   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0)
     {
      reason = "equity indisponible";
      return false;
     }

   const double riskMoney = equity * RiskPercent / 100.0;
   if(riskMoney <= 0.0)
     {
      reason = "montant de risque invalide";
      return false;
     }

   const double volumeMin = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN);
   const double volumeMax = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MAX);
   const double volumeStep = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP);
   if(volumeMin <= 0.0 || volumeMax < volumeMin || volumeStep <= 0.0)
     {
      reason = "contraintes de volume indisponibles";
      return false;
     }

   double lossAtMinimum = 0.0;
   if(!LossAtStop(orderType, volumeMin, entry, stopLoss, lossAtMinimum))
     {
      reason = "estimation de perte impossible";
      return false;
     }

   if(lossAtMinimum > riskMoney)
     {
      reason = "volume minimal supérieur au risque autorisé";
      return false;
     }

   const int digits = VolumeDigits(volumeStep);
   double sized = FloorToStep(volumeMin * (riskMoney / lossAtMinimum), volumeStep, digits);
   const double maxAligned = FloorToStep(volumeMax, volumeStep, digits);
   if(sized > maxAligned)
      sized = maxAligned;

   if(sized < volumeMin)
     {
      reason = "volume minimal supérieur au risque autorisé";
      return false;
     }

   double loss = 0.0;
   for(int guard = 0; guard < 100000; guard++)
     {
      if(!LossAtStop(orderType, sized, entry, stopLoss, loss))
        {
         reason = "estimation de perte impossible";
         return false;
        }

      if(loss <= riskMoney)
         break;

      sized = NormalizeDouble(sized - volumeStep, digits);
      if(sized < volumeMin)
        {
         reason = "volume minimal supérieur au risque autorisé";
         return false;
        }
     }

   if(loss > riskMoney || sized < volumeMin || sized > volumeMax)
     {
      reason = "perte estimée supérieure au risque autorisé";
      return false;
     }

   if(sized < 0.01)
     {
      reason = "volume inférieur au minimum 0.01";
      return false;
     }

   volume = sized;
   estimatedLoss = loss;
   return true;
  }

//+------------------------------------------------------------------+
//| Prépare SL, TP et volume. N'envoie pas l'ordre.                  |
//+------------------------------------------------------------------+
bool PrepareRisk(const ENUM_ORDER_TYPE orderType,
                 const double level,
                 SEntryPlan &plan,
                 string &detail)
  {
   plan.volume = 0.0;
   plan.entry = 0.0;
   plan.stopLoss = 0.0;
   plan.takeProfit = 0.0;
   plan.estimatedLoss = 0.0;
   if(orderType != ORDER_TYPE_BUY && orderType != ORDER_TYPE_SELL)
     {
      detail = "type d'ordre inconnu";
      return false;
     }

   if(level <= 0.0)
     {
      detail = "niveau de Stop Loss invalide";
      return false;
     }

   const double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0 || ask < bid)
     {
      detail = "prix d'entrée indisponible";
      return false;
     }

   double tickSize = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0)
      tickSize = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);

   const int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
   if(tickSize <= 0.0 || digits < 0)
     {
      detail = "pas de cotation indisponible";
      return false;
     }

   const double entry = (orderType == ORDER_TYPE_BUY) ? ask : bid;
   double stopLoss = 0.0;
   double takeProfit = 0.0;
   string reason = "";

   if(!BuildStopLoss(orderType, level, entry, bid, ask, tickSize, digits, stopLoss, reason))
     {
      detail = reason;
      return false;
     }

   if(!BuildTakeProfit(orderType, entry, bid, ask, stopLoss, tickSize, digits, takeProfit, reason))
     {
      detail = reason;
      return false;
     }

   double volume = 0.0;
   double estimatedLoss = 0.0;
   if(!CalculateVolume(orderType, entry, stopLoss, volume, estimatedLoss, reason))
     {
      detail = reason;
      return false;
     }

   const int volumeDigits = VolumeDigits(SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP));
   const string currency = AccountInfoString(ACCOUNT_CURRENCY);
   plan.volume = volume;
   plan.entry = entry;
   plan.stopLoss = stopLoss;
   plan.takeProfit = takeProfit;
   plan.estimatedLoss = estimatedLoss;
   detail = "Volume " + DoubleToString(volume, volumeDigits)
            + ", entrée " + DoubleToString(entry, digits)
            + ", SL " + DoubleToString(stopLoss, digits)
            + ", TP " + DoubleToString(takeProfit, digits)
            + ", perte estimée " + DoubleToString(estimatedLoss, 2)
            + " " + currency + ".";
   return true;
  }

//+------------------------------------------------------------------+
//| Mode de remplissage accepté par le symbole.                      |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING OrderFilling(void)
  {
   const long flags = SymbolInfoInteger(InpSymbol, SYMBOL_FILLING_MODE);
   if((flags & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((flags & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

//+------------------------------------------------------------------+
//| Le terminal, le compte et le symbole autorisent un ordre.        |
//+------------------------------------------------------------------+
bool TradingIsAllowed(const ENUM_ORDER_TYPE orderType, string &reason)
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
     {
      reason = "terminal non connecté au courtier";
      return false;
     }

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      reason = "trading désactivé dans le terminal";
      return false;
     }

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      reason = "algo trading désactivé";
      return false;
     }

   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     {
      reason = "trading désactivé sur le compte";
      return false;
     }

   const long mode = SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY)
     {
      reason = "symbole non négociable";
      return false;
     }

   if(orderType == ORDER_TYPE_BUY && mode == SYMBOL_TRADE_MODE_SHORTONLY)
     {
      reason = "achat interdit sur ce symbole";
      return false;
     }

   if(orderType == ORDER_TYPE_SELL && mode == SYMBOL_TRADE_MODE_LONGONLY)
     {
      reason = "vente interdite sur ce symbole";
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Pose le Stop Loss et le Take Profit. true si le courtier accepte.|
//+------------------------------------------------------------------+
bool SetPositionStops(const ulong ticket, const double newStop, const double newTakeProfit)
  {
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol = InpSymbol;
   request.magic = MagicNumber;
   request.sl = newStop;
   request.tp = newTakeProfit;

   if(!OrderSend(request, result))
      return false;

   return result.retcode == TRADE_RETCODE_DONE ||
          result.retcode == TRADE_RETCODE_PLACED ||
          result.retcode == TRADE_RETCODE_NO_CHANGES;
  }

//+------------------------------------------------------------------+
//| Ferme uniquement la position de ce robot.                        |
//+------------------------------------------------------------------+
bool CloseOwnPosition(const ulong ticket, string &reason)
  {
   if(!PositionSelectByTicket(ticket))
     {
      reason = "position introuvable";
      return false;
     }

   if(PositionGetString(POSITION_SYMBOL) != InpSymbol ||
      (ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
     {
      reason = "position hors du robot";
      return false;
     }

   const long positionType = PositionGetInteger(POSITION_TYPE);
   const double volume = PositionGetDouble(POSITION_VOLUME);
   const double price = (positionType == POSITION_TYPE_BUY)
                        ? SymbolInfoDouble(InpSymbol, SYMBOL_BID)
                        : SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   if(volume <= 0.0 || price <= 0.0)
     {
      reason = "fermeture impossible";
      return false;
     }

   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = InpSymbol;
   request.magic = MagicNumber;
   request.volume = volume;
   request.type = (positionType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price = price;
   request.deviation = (ulong)InpDeviationPoints;
   request.type_filling = OrderFilling();
   request.type_time = ORDER_TIME_GTC;

   if(!OrderSend(request, result))
     {
      reason = "fermeture refusée, code " + IntegerToString(GetLastError());
      return false;
     }

   if(result.retcode != TRADE_RETCODE_DONE &&
      result.retcode != TRADE_RETCODE_PLACED &&
      result.retcode != TRADE_RETCODE_DONE_PARTIAL)
     {
      reason = "fermeture refusée, retour " + IntegerToString((int)result.retcode);
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Vérifie SL et TP. Ferme la position s'ils ne tiennent pas.       |
//+------------------------------------------------------------------+
bool EnsurePositionProtected(const ulong ticket, const SEntryPlan &plan, string &reason)
  {
   if(!PositionSelectByTicket(ticket))
     {
      reason = "position introuvable après l'envoi";
      return false;
     }

   if(PositionGetDouble(POSITION_SL) > 0.0 && PositionGetDouble(POSITION_TP) > 0.0)
      return true;

   if(!SetPositionStops(ticket, plan.stopLoss, plan.takeProfit) ||
      !PositionSelectByTicket(ticket) ||
      PositionGetDouble(POSITION_SL) <= 0.0 ||
      PositionGetDouble(POSITION_TP) <= 0.0)
     {
      string closeReason = "";
      if(!CloseOwnPosition(ticket, closeReason))
        {
         reason = "Stop Loss absent et fermeture impossible";
         return false;
        }

      reason = "Stop Loss ou Take Profit absent, position fermée";
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Envoie un seul ordre au marché, avec SL et TP.                   |
//+------------------------------------------------------------------+
bool OpenTrade(const ENUM_ORDER_TYPE orderType, const SEntryPlan &plan, string &detail)
  {
   string reason = "";
   if(g_entryBlocked)
     {
      detail = g_blockReason;
      return false;
     }

   if(orderType != ORDER_TYPE_BUY && orderType != ORDER_TYPE_SELL)
     {
      detail = "type d'ordre inconnu";
      return false;
     }

   if(!TradingIsAllowed(orderType, reason))
     {
      detail = reason;
      return false;
     }

   string exposure = "";
   if(HasOwnExposure(exposure))
     {
      detail = exposure;
      return false;
     }

   double spreadPrice = 0.0;
   long spreadPoints = 0;
   if(!ReadSpread(spreadPrice, spreadPoints))
     {
      detail = "spread indisponible";
      return false;
     }

   if(spreadPrice > InpMaxSpreadPrice)
     {
      detail = "spread trop élevé au moment de l'envoi, "
               + IntegerToString(spreadPoints) + " points";
      return false;
     }

   if(g_atrM15 <= 0.0 || g_atrM15 > InpMaxAtrPrice)
     {
      detail = "volatilité trop élevée au moment de l'envoi";
      return false;
     }

   if(plan.volume < 0.01 || plan.stopLoss <= 0.0 || plan.takeProfit <= 0.0 || plan.entry <= 0.0)
     {
      detail = "volume, Stop Loss ou Take Profit invalide";
      return false;
     }

   const double riskDistance = (orderType == ORDER_TYPE_BUY)
                               ? (plan.entry - plan.stopLoss)
                               : (plan.stopLoss - plan.entry);
   const double rewardDistance = (orderType == ORDER_TYPE_BUY)
                                 ? (plan.takeProfit - plan.entry)
                                 : (plan.entry - plan.takeProfit);
   if(riskDistance <= 0.0 || rewardDistance + 0.0000001 < riskDistance * RewardRiskRatio)
     {
      detail = "rapport Take Profit / Stop Loss inférieur à 2";
      return false;
     }

   const double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   if(orderType == ORDER_TYPE_BUY && (plan.stopLoss >= bid || plan.takeProfit <= ask))
     {
      detail = "Stop Loss ou Take Profit du mauvais côté";
      return false;
     }
   if(orderType == ORDER_TYPE_SELL && (plan.stopLoss <= ask || plan.takeProfit >= bid))
     {
      detail = "Stop Loss ou Take Profit du mauvais côté";
      return false;
     }

   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action = TRADE_ACTION_DEAL;
   request.symbol = InpSymbol;
   request.magic = MagicNumber;
   request.volume = plan.volume;
   request.type = orderType;
   request.price = plan.entry;
   request.sl = plan.stopLoss;
   request.tp = plan.takeProfit;
   request.deviation = (ulong)InpDeviationPoints;
   request.type_filling = OrderFilling();
   request.type_time = ORDER_TIME_GTC;

   ResetLastError();
   if(!OrderSend(request, result))
     {
      detail = "envoi refusé, code " + IntegerToString(GetLastError());
      return false;
     }

   if(result.retcode != TRADE_RETCODE_DONE &&
      result.retcode != TRADE_RETCODE_PLACED &&
      result.retcode != TRADE_RETCODE_DONE_PARTIAL)
     {
      detail = "retour courtier " + IntegerToString((int)result.retcode);
      return false;
     }

   ulong ticket = 0;
   int owned = 0;
   const int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      const ulong candidate = PositionGetTicket(i);
      if(candidate == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      ticket = candidate;
      owned++;
     }

   if(owned > 1)
     {
      detail = "plusieurs positions du robot";
      return false;
     }

   if(owned == 1 && !EnsurePositionProtected(ticket, plan, reason))
     {
      detail = reason;
      return false;
     }

   const int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
   const int volumeDigits = VolumeDigits(SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP));
   detail = "volume " + DoubleToString(plan.volume, volumeDigits)
            + ", prix " + DoubleToString(plan.entry, digits)
            + ", SL " + DoubleToString(plan.stopLoss, digits)
            + ", TP " + DoubleToString(plan.takeProfit, digits)
            + ", perte estimée " + DoubleToString(plan.estimatedLoss, 2)
            + " " + AccountInfoString(ACCOUNT_CURRENCY)
            + ", ticket " + IntegerToString((long)result.order);
   return true;
  }

//+------------------------------------------------------------------+
//| Piste d'achat. La première condition manquante devient la raison.|
//+------------------------------------------------------------------+
bool EvaluateBuy(MqlRates &bars[], const double closePrice, const int digits, string &line)
  {
   if(g_ema20M15 <= g_ema50M15)
     {
      line = "SIGNAL REJECTED : EMA 20 M15 inférieure ou égale à l'EMA 50.";
      return true;
     }

   if(g_rsiM15 <= 50.0)
     {
      line = "SIGNAL REJECTED : RSI M15 inférieur ou égal à 50.";
      return true;
     }

   double support = 0.0;
   if(!FindNearestSupport(bars, closePrice, support))
     {
      line = "SIGNAL REJECTED : support non identifié.";
      return true;
     }

   const double distance = closePrice - support;
   if(distance > InpMaxLevelDistance)
     {
      line = "SIGNAL REJECTED : prix trop loin du support. Distance "
             + DoubleToString(distance, digits) + ", maximum "
             + DoubleToString(InpMaxLevelDistance, digits) + ".";
      return true;
     }

   string candleReason = "";
   if(!IsBullishConfirmation(bars[0], candleReason))
     {
      line = "SIGNAL REJECTED : " + candleReason + ".";
      return true;
     }

   g_entrySignal = ENTRY_BUY;

   SEntryPlan plan;
   string riskDetail = "";
   if(!PrepareRisk(ORDER_TYPE_BUY, support, plan, riskDetail))
     {
      line = "SIGNAL BUY DETECTED. RISK REJECTED : " + riskDetail + ".";
      return true;
     }

   if(g_entryBlocked)
     {
      line = "SIGNAL BUY DETECTED. ENTRY BLOCKED : " + g_blockReason + ".";
      return true;
     }

   string orderDetail = "";
   if(!OpenTrade(ORDER_TYPE_BUY, plan, orderDetail))
     {
      line = "SIGNAL BUY DETECTED. ORDER REJECTED : " + orderDetail + ".";
      return true;
     }

   line = "SIGNAL BUY DETECTED. ORDER SENT : " + orderDetail + ".";
   return true;
  }

//+------------------------------------------------------------------+
//| Piste de vente. La première condition manquante devient la raison.|
//+------------------------------------------------------------------+
bool EvaluateSell(MqlRates &bars[], const double closePrice, const int digits, string &line)
  {
   if(g_ema20M15 >= g_ema50M15)
     {
      line = "SIGNAL REJECTED : EMA 20 M15 supérieure ou égale à l'EMA 50.";
      return true;
     }

   if(g_rsiM15 >= 50.0)
     {
      line = "SIGNAL REJECTED : RSI M15 supérieur ou égal à 50.";
      return true;
     }

   double resistance = 0.0;
   if(!FindNearestResistance(bars, closePrice, resistance))
     {
      line = "SIGNAL REJECTED : résistance non identifiée.";
      return true;
     }

   const double distance = resistance - closePrice;
   if(distance > InpMaxLevelDistance)
     {
      line = "SIGNAL REJECTED : prix trop loin de la résistance. Distance "
             + DoubleToString(distance, digits) + ", maximum "
             + DoubleToString(InpMaxLevelDistance, digits) + ".";
      return true;
     }

   string candleReason = "";
   if(!IsBearishConfirmation(bars[0], candleReason))
     {
      line = "SIGNAL REJECTED : " + candleReason + ".";
      return true;
     }

   g_entrySignal = ENTRY_SELL;

   SEntryPlan plan;
   string riskDetail = "";
   if(!PrepareRisk(ORDER_TYPE_SELL, resistance, plan, riskDetail))
     {
      line = "SIGNAL SELL DETECTED. RISK REJECTED : " + riskDetail + ".";
      return true;
     }

   if(g_entryBlocked)
     {
      line = "SIGNAL SELL DETECTED. ENTRY BLOCKED : " + g_blockReason + ".";
      return true;
     }

   string orderDetail = "";
   if(!OpenTrade(ORDER_TYPE_SELL, plan, orderDetail))
     {
      line = "SIGNAL SELL DETECTED. ORDER REJECTED : " + orderDetail + ".";
      return true;
     }

   line = "SIGNAL SELL DETECTED. ORDER SENT : " + orderDetail + ".";
   return true;
  }

//+------------------------------------------------------------------+
//| Évalue la bougie M15 clôturée. false : données encore absentes.  |
//+------------------------------------------------------------------+
bool EvaluateClosedBar(string &line)
  {
   MqlRates m15Bars[];
   if(!CopyClosedM15Bars(m15Bars))
      return false;

   double h1Close = 0.0;
   if(!ReadClosedH1(h1Close))
      return false;

   double spreadPrice = 0.0;
   long spreadPoints = 0;
   if(!ReadSpread(spreadPrice, spreadPoints))
      return false;

   const int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);

   if(spreadPrice > InpMaxSpreadPrice)
     {
      line = "SIGNAL REJECTED : spread "
             + DoubleToString(spreadPrice, digits) + " ("
             + IntegerToString(spreadPoints) + " points) supérieur au maximum "
             + DoubleToString(InpMaxSpreadPrice, digits) + ".";
      return true;
     }

   if(g_atrM15 <= 0.0 || g_atrM15 > InpMaxAtrPrice)
     {
      line = "SIGNAL REJECTED : ATR trop élevé. ATR "
             + DoubleToString(g_atrM15, digits) + ", maximum "
             + DoubleToString(InpMaxAtrPrice, digits) + ".";
      return true;
     }

   if(h1Close > g_ema200H1)
      return EvaluateBuy(m15Bars, m15Bars[0].close, digits, line);

   if(h1Close < g_ema200H1)
      return EvaluateSell(m15Bars, m15Bars[0].close, digits, line);

   line = "SIGNAL REJECTED : clôture H1 égale à l'EMA 200.";
   return true;
  }

//+------------------------------------------------------------------+
//| Protections du compte et positions déjà ouvertes.                |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Nom stable d'une variable globale de ce Magic Number.            |
//+------------------------------------------------------------------+
string GvName(const string suffix)
  {
   return "XAUUSD_Bot_" + IntegerToString((long)MagicNumber) + "_" + suffix;
  }

//+------------------------------------------------------------------+
//| Enregistre une valeur qui doit survivre à un redémarrage.        |
//+------------------------------------------------------------------+
bool SaveGv(const string suffix, const double value)
  {
   return GlobalVariableSet(GvName(suffix), value) != 0;
  }

//+------------------------------------------------------------------+
//| Heure du serveur du courtier.                                    |
//+------------------------------------------------------------------+
datetime ServerNow(void)
  {
   datetime now = TimeTradeServer();
   if(now <= 0)
      now = TimeCurrent();
   return now;
  }

//+------------------------------------------------------------------+
//| Début du jour de trading, à minuit heure du serveur.             |
//+------------------------------------------------------------------+
datetime DayStart(const datetime when)
  {
   MqlDateTime parts;
   TimeToStruct(when, parts);
   parts.hour = 0;
   parts.min = 0;
   parts.sec = 0;
   return StructToTime(parts);
  }

//+------------------------------------------------------------------+
//| Profit, swap, commission et frais d'un deal.                     |
//+------------------------------------------------------------------+
double DealNet(const ulong deal)
  {
   return HistoryDealGetDouble(deal, DEAL_PROFIT)
          + HistoryDealGetDouble(deal, DEAL_SWAP)
          + HistoryDealGetDouble(deal, DEAL_COMMISSION)
          + HistoryDealGetDouble(deal, DEAL_FEE);
  }

//+------------------------------------------------------------------+
//| Le deal appartient à ce robot et à XAUUSD.                       |
//+------------------------------------------------------------------+
bool DealBelongsToBot(const ulong deal)
  {
   if(HistoryDealGetString(deal, DEAL_SYMBOL) != InpSymbol)
      return false;

   return (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) == MagicNumber;
  }

//+------------------------------------------------------------------+
//| Remet à zéro la série de pertes pour un nouveau jour.            |
//+------------------------------------------------------------------+
bool ResetDayCounters(const datetime dayStart, string &reason)
  {
   if(!SaveGv("LossStreak", 0.0) || !SaveGv("LastDeal", (double)dayStart) ||
      !SaveGv("LastPosId", 0.0) || !SaveGv("StreakDay", (double)dayStart))
     {
      reason = "impossible de réinitialiser les protections du jour";
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Enregistre l'equity de référence sans jamais l'agrandir ensuite. |
//+------------------------------------------------------------------+
bool StoreDayReference(const datetime dayStart, const double equity, string &reason)
  {
   if(equity <= 0.0)
     {
      reason = "equity indisponible";
      return false;
     }

   if(!SaveGv("Day", (double)dayStart) || !SaveGv("RefEquity", equity))
     {
      reason = "impossible d'enregistrer la référence du jour";
      return false;
     }

   return ResetDayCounters(dayStart, reason);
  }

//+------------------------------------------------------------------+
//| true si ce robot a déjà agi depuis le début du jour.             |
//+------------------------------------------------------------------+
bool BotActivitySince(const datetime dayStart, bool &acted, string &reason)
  {
   acted = false;
   const int positions = PositionsTotal();
   for(int i = positions - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
        {
         reason = "lecture des positions impossible";
         return false;
        }

      if(PositionGetString(POSITION_SYMBOL) == InpSymbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
        {
         acted = true;
         return true;
        }
     }

   const int orders = OrdersTotal();
   for(int i = orders - 1; i >= 0; i--)
     {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
        {
         reason = "lecture des ordres impossible";
         return false;
        }

      if(OrderGetString(ORDER_SYMBOL) == InpSymbol &&
         (ulong)OrderGetInteger(ORDER_MAGIC) == MagicNumber)
        {
         acted = true;
         return true;
        }
     }

   const datetime now = ServerNow();
   if(now <= 0 || !HistorySelect(dayStart, now))
     {
      reason = "historique indisponible";
      return false;
     }

   const int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
     {
      const ulong deal = HistoryDealGetTicket(i);
      if(deal != 0 && DealBelongsToBot(deal))
        {
         acted = true;
         return true;
        }
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Prépare l'equity de référence du jour serveur.                   |
//| Une référence déjà enregistrée pour ce jour n'est pas remplacée. |
//+------------------------------------------------------------------+
bool EnsureDayReference(double &referenceEquity, datetime &dayStart, string &reason)
  {
   const datetime now = ServerNow();
   if(now <= 0)
     {
      reason = "heure du serveur indisponible";
      return false;
     }

   dayStart = DayStart(now);
   const bool hadDay = GlobalVariableCheck(GvName("Day"));
   const datetime savedDay = hadDay ? (datetime)GlobalVariableGet(GvName("Day")) : 0;

   if(hadDay && savedDay == dayStart)
     {
      referenceEquity = GlobalVariableGet(GvName("RefEquity"));
      if(referenceEquity <= 0.0)
        {
         reason = "equity de référence invalide";
         return false;
        }

      const bool streakReady = GlobalVariableCheck(GvName("StreakDay")) &&
                               ((datetime)GlobalVariableGet(GvName("StreakDay")) == dayStart);
      if(!streakReady && !ResetDayCounters(dayStart, reason))
         return false;

      return true;
     }

   bool acted = false;
   if(!BotActivitySince(dayStart, acted, reason))
      return false;

   if(acted)
     {
      reason = "référence du jour absente";
      return false;
     }

   referenceEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(!StoreDayReference(dayStart, referenceEquity, reason))
      return false;

   if(hadDay)
      Print("[XAUUSD_Bot][INFO] Nouveau jour de trading. Protections réinitialisées. Référence ",
            DoubleToString(referenceEquity, 2), ".");
   else
      Print("[XAUUSD_Bot][INFO] Référence du jour enregistrée : ",
            DoubleToString(referenceEquity, 2), ".");

   return true;
  }

//+------------------------------------------------------------------+
//| Résultat net de toute la vie d'une position.                     |
//+------------------------------------------------------------------+
bool PositionNet(const ulong positionId, double &net)
  {
   if(!HistorySelectByPosition((long)positionId))
      return false;

   net = 0.0;
   bool found = false;
   const int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      const ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if((ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID) != positionId)
         continue;

      net += DealNet(deal);
      found = true;
     }

   return found;
  }

//+------------------------------------------------------------------+
//| true si la position est encore ouverte. uncertain si lecture HS. |
//+------------------------------------------------------------------+
bool PositionIdIsOpen(const ulong positionId, bool &uncertain)
  {
   uncertain = false;
   const int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
        {
         uncertain = true;
         return true;
        }

      if((ulong)PositionGetInteger(POSITION_IDENTIFIER) == positionId)
         return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Classe les clôtures de la plus ancienne à la plus récente.       |
//+------------------------------------------------------------------+
void SortClosedTrades(ulong &ids[], datetime &times[])
  {
   const int count = ArraySize(ids);
   for(int i = 0; i < count; i++)
     {
      for(int j = i + 1; j < count; j++)
        {
         if(times[j] < times[i] || (times[j] == times[i] && ids[j] < ids[i]))
           {
            const datetime swapTime = times[i];
            times[i] = times[j];
            times[j] = swapTime;
            const ulong swapId = ids[i];
            ids[i] = ids[j];
            ids[j] = swapId;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Met à jour la série de pertes à partir des positions terminées.  |
//+------------------------------------------------------------------+
bool UpdateClosedTrades(const datetime dayStart, string &reason)
  {
   const datetime now = ServerNow();
   if(now <= 0)
     {
      reason = "heure du serveur indisponible";
      return false;
     }

   if(!HistorySelect(dayStart, now))
     {
      reason = "historique indisponible";
      return false;
     }

   datetime lastTime = dayStart;
   ulong lastId = 0;
   const bool haveTime = GlobalVariableCheck(GvName("LastDeal"));
   const bool haveStreak = GlobalVariableCheck(GvName("LossStreak"));
   if(haveTime)
     {
      lastTime = (datetime)GlobalVariableGet(GvName("LastDeal"));
      if(GlobalVariableCheck(GvName("LastPosId")))
         lastId = (ulong)GlobalVariableGet(GvName("LastPosId"));
     }
   else if(haveStreak)
     {
      lastTime = now;
      if(!g_anchorWarningLogged)
        {
         Print("[XAUUSD_Bot][ERROR] Repère de clôture manquant. Les trades déjà comptés ne sont pas relus.");
         g_anchorWarningLogged = true;
        }
     }

   ulong ids[];
   datetime times[];
   ArrayResize(ids, 0);
   ArrayResize(times, 0);

   const int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
     {
      const ulong deal = HistoryDealGetTicket(i);
      if(deal == 0 || !DealBelongsToBot(deal))
         continue;

      const long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
         continue;

      const ulong positionId = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      const datetime dealTime = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
      int index = -1;
      for(int k = 0; k < ArraySize(ids); k++)
        {
         if(ids[k] == positionId)
           {
            index = k;
            break;
           }
        }

      if(index < 0)
        {
         const int size = ArraySize(ids);
         ArrayResize(ids, size + 1);
         ArrayResize(times, size + 1);
         ids[size] = positionId;
         times[size] = dealTime;
        }
      else if(dealTime > times[index])
         times[index] = dealTime;
     }

   SortClosedTrades(ids, times);
   int streak = haveStreak ? (int)GlobalVariableGet(GvName("LossStreak")) : 0;
   const string currency = AccountInfoString(ACCOUNT_CURRENCY);

   for(int i = 0; i < ArraySize(ids); i++)
     {
      if(times[i] < lastTime)
         continue;
      if(times[i] == lastTime && ids[i] <= lastId)
         continue;

      bool uncertain = false;
      if(PositionIdIsOpen(ids[i], uncertain))
        {
         if(uncertain)
           {
            reason = "lecture des positions impossible";
            return false;
           }
         continue;
        }

      double net = 0.0;
      if(!PositionNet(ids[i], net))
        {
         reason = "résultat du trade indisponible";
         return false;
        }

      if(net < 0.0)
         streak++;
      else
         streak = 0;

      lastTime = times[i];
      lastId = ids[i];
      if(!SaveGv("LossStreak", (double)streak) ||
         !SaveGv("LastDeal", (double)lastTime) ||
         !SaveGv("LastPosId", (double)lastId))
        {
         reason = "impossible d'enregistrer la série de pertes";
         return false;
        }

      Print("[XAUUSD_Bot][INFO] Trade clôturé ", IntegerToString((long)ids[i]),
            ", résultat net ", DoubleToString(net, 2), " ", currency,
            ". Pertes consécutives : ", IntegerToString(streak), ".");
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Résultat du jour : deals réalisés plus flottant encore ouvert.   |
//+------------------------------------------------------------------+
bool BotDailyResult(const datetime dayStart, double &result, string &reason)
  {
   const datetime now = ServerNow();
   if(now <= 0 || !HistorySelect(dayStart, now))
     {
      reason = "historique indisponible";
      return false;
     }

   result = 0.0;
   const int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
     {
      const ulong deal = HistoryDealGetTicket(i);
      if(deal == 0 || !DealBelongsToBot(deal))
         continue;

      result += DealNet(deal);
     }

   const int positions = PositionsTotal();
   for(int i = positions - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
        {
         reason = "lecture des positions impossible";
         return false;
        }

      if(PositionGetString(POSITION_SYMBOL) != InpSymbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      result += PositionGetDouble(POSITION_PROFIT);
      result += PositionGetDouble(POSITION_SWAP);
     }

   return true;
  }

//+------------------------------------------------------------------+
//| true s'il existe déjà une position ou un ordre de ce robot.      |
//+------------------------------------------------------------------+
bool HasOwnExposure(string &reason)
  {
   const int positions = PositionsTotal();
   for(int i = positions - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
        {
         reason = "lecture des positions impossible";
         return true;
        }

      if(PositionGetString(POSITION_SYMBOL) == InpSymbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
        {
         reason = "position XAUUSD déjà ouverte";
         return true;
        }
     }

   const int orders = OrdersTotal();
   for(int i = orders - 1; i >= 0; i--)
     {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
        {
         reason = "lecture des ordres impossible";
         return true;
        }

      if(OrderGetString(ORDER_SYMBOL) == InpSymbol &&
         (ulong)OrderGetInteger(ORDER_MAGIC) == MagicNumber)
        {
         reason = "ordre en attente déjà placé";
         return true;
        }
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Stop Loss initial de l'ordre qui a ouvert la position.           |
//+------------------------------------------------------------------+
bool InitialStopLoss(const ulong positionId, double &initialStop)
  {
   if(!HistorySelectByPosition((long)positionId))
      return false;

   ulong orderTicket = 0;
   datetime earliest = 0;
   const int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      const ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;

      const long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_IN && entry != DEAL_ENTRY_INOUT)
         continue;

      const datetime dealTime = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
      if(orderTicket == 0 || dealTime < earliest)
        {
         earliest = dealTime;
         orderTicket = (ulong)HistoryDealGetInteger(deal, DEAL_ORDER);
        }
     }

   if(orderTicket == 0 || !HistoryOrderSelect(orderTicket))
      return false;

   initialStop = HistoryOrderGetDouble(orderTicket, ORDER_SL);
   return initialStop > 0.0;
  }

//+------------------------------------------------------------------+
//| Resserre le Stop Loss. Le Take Profit et l'ancien SL restent.    |
//+------------------------------------------------------------------+
bool TightenStop(const ulong ticket, const double newStop, const double currentTakeProfit)
  {
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol = InpSymbol;
   request.magic = MagicNumber;
   request.sl = newStop;
   request.tp = currentTakeProfit;

   if(!OrderSend(request, result))
     {
      Print("[XAUUSD_Bot][ERROR] Modification du Stop Loss refusée. Code ", GetLastError(), ".");
      return false;
     }

   if(result.retcode != TRADE_RETCODE_DONE &&
      result.retcode != TRADE_RETCODE_PLACED &&
      result.retcode != TRADE_RETCODE_NO_CHANGES)
     {
      Print("[XAUUSD_Bot][ERROR] Modification du Stop Loss refusée. Retour ",
            IntegerToString((int)result.retcode), ".");
      return false;
     }

   return result.retcode != TRADE_RETCODE_NO_CHANGES;
  }

//+------------------------------------------------------------------+
//| Break-even à +1R, puis trailing à +1,5R. Jamais élargir le SL.   |
//+------------------------------------------------------------------+
void ManageOpenPositions(const bool atrReady)
  {
   const double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0 || ask < bid)
      return;

   double tickSize = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0)
      tickSize = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);

   const int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
   const double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   const long stopsLevel = SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(tickSize <= 0.0 || point <= 0.0 || stopsLevel < 0 || digits < 0)
      return;

   const double minDistance = (double)stopsLevel * point;
   const int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      const double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      const double currentStop = PositionGetDouble(POSITION_SL);
      const double currentTakeProfit = PositionGetDouble(POSITION_TP);
      const ulong positionId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      const long positionType = PositionGetInteger(POSITION_TYPE);

      if(currentStop <= 0.0 || currentTakeProfit <= 0.0)
        {
         bool repaired = false;
         if(currentStop > 0.0 && entry > 0.0)
           {
            const double distance = MathAbs(entry - currentStop);
            double rebuiltTakeProfit = 0.0;
            if(positionType == POSITION_TYPE_BUY)
               rebuiltTakeProfit = CeilToTick(entry + (distance * RewardRiskRatio), tickSize, digits);
            else if(positionType == POSITION_TYPE_SELL)
               rebuiltTakeProfit = FloorToTick(entry - (distance * RewardRiskRatio), tickSize, digits);

            if(rebuiltTakeProfit > 0.0 &&
               SetPositionStops(ticket, currentStop, rebuiltTakeProfit) &&
               PositionSelectByTicket(ticket) &&
               PositionGetDouble(POSITION_SL) > 0.0 &&
               PositionGetDouble(POSITION_TP) > 0.0)
               repaired = true;
           }

         if(!repaired)
           {
            string closeReason = "";
            if(CloseOwnPosition(ticket, closeReason))
               Print("[XAUUSD_Bot][ERROR] Position ", IntegerToString((long)ticket),
                     " fermée : Stop Loss ou Take Profit absent.");
            else
               Print("[XAUUSD_Bot][ERROR] Position ", IntegerToString((long)ticket),
                     " sans protection. Fermeture impossible : ", closeReason, ".");
           }
         continue;
        }

      double initialStop = 0.0;
      if(entry <= 0.0 || !InitialStopLoss(positionId, initialStop))
        {
         static ulong warnedTicket = 0;
         if(warnedTicket != ticket)
           {
            Print("[XAUUSD_Bot][ERROR] Stop Loss initial introuvable. Position ",
                  IntegerToString((long)ticket), " non modifiée.");
            warnedTicket = ticket;
           }
         continue;
        }

      const double riskDistance = MathAbs(entry - initialStop);
      if(riskDistance <= 0.0)
         continue;

      double candidate = 0.0;
      bool hasCandidate = false;

      if(positionType == POSITION_TYPE_BUY)
        {
         if(bid >= entry + riskDistance)
           {
            const double breakEven = FloorToTick(entry, tickSize, digits);
            if(breakEven > currentStop && breakEven < bid && (bid - breakEven) >= minDistance)
              {
               candidate = breakEven;
               hasCandidate = true;
              }
           }

         if(atrReady && g_atrM15 > 0.0 && bid >= entry + (1.5 * riskDistance))
           {
            const double trail = FloorToTick(bid - (g_atrM15 * AtrTrailMultiplier), tickSize, digits);
            if(trail > currentStop && trail < bid && (bid - trail) >= minDistance &&
               (!hasCandidate || trail > candidate))
              {
               candidate = trail;
               hasCandidate = true;
              }
           }
        }
      else if(positionType == POSITION_TYPE_SELL)
        {
         if(ask <= entry - riskDistance)
           {
            const double breakEven = CeilToTick(entry, tickSize, digits);
            if(breakEven > ask && (breakEven - ask) >= minDistance &&
               (currentStop <= 0.0 || breakEven < currentStop))
              {
               candidate = breakEven;
               hasCandidate = true;
              }
           }

         if(atrReady && g_atrM15 > 0.0 && ask <= entry - (1.5 * riskDistance))
           {
            const double trail = CeilToTick(ask + (g_atrM15 * AtrTrailMultiplier), tickSize, digits);
            if(trail > ask && (trail - ask) >= minDistance &&
               (currentStop <= 0.0 || trail < currentStop) &&
               (!hasCandidate || trail < candidate))
              {
               candidate = trail;
               hasCandidate = true;
              }
           }
        }

      if(!hasCandidate)
         continue;

      const double previousStop = currentStop;
      if(TightenStop(ticket, candidate, currentTakeProfit))
         Print("[XAUUSD_Bot][INFO] Stop Loss resserré de ",
               DoubleToString(previousStop, digits), " à ",
               DoubleToString(candidate, digits), ".");
     }
  }

//+------------------------------------------------------------------+
//| true s'il faut bloquer une nouvelle entrée à cause d'une annonce. |
//+------------------------------------------------------------------+
bool MajorNewsBlocks(string &reason)
  {
   const datetime now = ServerNow();
   if(now <= 0)
     {
      reason = "heure du serveur indisponible";
      return true;
     }

   MqlCalendarValue values[];
   const datetime window = (datetime)(InpNewsMinutes * 60);
   ResetLastError();
   if(!CalendarValueHistory(values, now - window, now + window, NULL, "USD"))
     {
      reason = "calendrier économique indisponible";
      return true;
     }

   const int count = ArraySize(values);
   for(int i = 0; i < count; i++)
     {
      if(values[i].time < (now - window) || values[i].time > (now + window))
         continue;

      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id, event))
        {
         reason = "calendrier économique indisponible";
         return true;
        }

      if(event.importance == CALENDAR_IMPORTANCE_HIGH)
        {
         reason = "annonce USD majeure";
         return true;
        }
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Actualise les blocages. true si une nouvelle entrée est refusée. |
//+------------------------------------------------------------------+
void RefreshProtections(const bool indicatorsReady)
  {
   string reason = "";
   string code = "";
   double referenceEquity = 0.0;
   datetime dayStart = 0;

   if(!EnsureDayReference(referenceEquity, dayStart, reason))
      code = "reference";
   else if(!UpdateClosedTrades(dayStart, reason))
      code = "history";
   else
     {
      double result = 0.0;
      string lossReason = "";
      if(!BotDailyResult(dayStart, result, lossReason))
        {
         code = "history";
         reason = lossReason;
        }
      else
        {
         const double limit = referenceEquity * MaxDailyLossPercent / 100.0;
         string exposure = "";
         const int streak = GlobalVariableCheck(GvName("LossStreak"))
                            ? (int)GlobalVariableGet(GvName("LossStreak"))
                            : 0;

         if(result < 0.0 && (-result) >= limit)
           {
            code = "daily";
            reason = "perte quotidienne " + DoubleToString(-result, 2)
                     + " " + AccountInfoString(ACCOUNT_CURRENCY)
                     + ", limite " + DoubleToString(limit, 2);
           }
         else if(HasOwnExposure(exposure))
           {
            code = (StringFind(exposure, "ordre") >= 0) ? "order" : "position";
            reason = exposure;
           }
         else if(streak >= MaxConsecutiveLosses)
           {
            code = "streak";
            reason = IntegerToString(streak) + " pertes consécutives";
           }
         else
           {
            string newsReason = "";
            if(MajorNewsBlocks(newsReason))
              {
               code = "news";
               reason = newsReason;
              }
           }
        }
     }

   if(code == "" && !indicatorsReady)
     {
      code = "data";
      reason = "données indisponibles";
     }

   ManageOpenPositions(indicatorsReady);

   g_entryBlocked = (code != "");
   g_blockReason = reason;
   if(g_entryBlocked && g_blockCode != code)
     {
      Print("[XAUUSD_Bot][INFO] ENTRY BLOCKED : ", reason, ".");
      g_blockCode = code;
     }
   else if(!g_entryBlocked)
      g_blockCode = "";
  }

//+------------------------------------------------------------------+
//| Affichage.                                                       |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Libellé de l'état technique affiché sur le graphique.            |
//+------------------------------------------------------------------+
string EntrySignalText(void)
  {
   if(g_entrySignal == ENTRY_BUY)
      return "ENTRY_BUY";
   if(g_entrySignal == ENTRY_SELL)
      return "ENTRY_SELL";
   return "ENTRY_NONE";
  }

//+------------------------------------------------------------------+
//| Affiche les valeurs clôturées et la dernière décision.           |
//+------------------------------------------------------------------+
void ShowStatus(void)
  {
   const int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);

   Comment("XAUUSD_Bot 0.6.0",
           "\nEMA 20 M15 : ", DoubleToString(g_ema20M15, digits),
           "\nEMA 50 M15 : ", DoubleToString(g_ema50M15, digits),
           "\nRSI 14 M15 : ", DoubleToString(g_rsiM15, 2),
           "\nATR 14 M15 : ", DoubleToString(g_atrM15, digits),
           "\nEMA 200 H1 : ", DoubleToString(g_ema200H1, digits),
           "\nÉtat d'entrée : ", EntrySignalText(),
           "\n", g_lastDecision,
           g_entryBlocked ? "\nBlocage : " + g_blockReason : "\nProtections : entrées autorisées");
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ShowDataUnavailable(void)
  {
   Comment("XAUUSD_Bot 0.6.0",
           "\nDonnées indisponibles",
           "\n", g_blockReason,
           "\nAucune entrée tant que les données manquent.");
  }

//+------------------------------------------------------------------+
//| Cycle de vie de l'Expert Advisor.                                |
//+------------------------------------------------------------------+
int OnInit(void)
  {
   if(!ParametersAreValid())
      return INIT_PARAMETERS_INCORRECT;

   if(Symbol() != InpSymbol)
     {
      Print("[XAUUSD_Bot][ERROR] Ce robot accepte uniquement ", InpSymbol,
            ". Graphique actuel : ", Symbol(), ".");
      return INIT_FAILED;
     }

   g_handleEma20M15 = iMA(InpSymbol, PERIOD_M15, EMA_M15_FAST_PERIOD, 0, MODE_EMA, PRICE_CLOSE);
   if(!IndicatorHandleIsValid(g_handleEma20M15, "EMA 20 M15"))
     {
      ReleaseIndicators();
      return INIT_FAILED;
     }

   g_handleEma50M15 = iMA(InpSymbol, PERIOD_M15, EMA_M15_SLOW_PERIOD, 0, MODE_EMA, PRICE_CLOSE);
   if(!IndicatorHandleIsValid(g_handleEma50M15, "EMA 50 M15"))
     {
      ReleaseIndicators();
      return INIT_FAILED;
     }

   g_handleRsiM15 = iRSI(InpSymbol, PERIOD_M15, RSI_M15_PERIOD, PRICE_CLOSE);
   if(!IndicatorHandleIsValid(g_handleRsiM15, "RSI 14 M15"))
     {
      ReleaseIndicators();
      return INIT_FAILED;
     }

   g_handleAtrM15 = iATR(InpSymbol, PERIOD_M15, ATR_M15_PERIOD);
   if(!IndicatorHandleIsValid(g_handleAtrM15, "ATR 14 M15"))
     {
      ReleaseIndicators();
      return INIT_FAILED;
     }

   g_handleEma200H1 = iMA(InpSymbol, PERIOD_H1, EMA_H1_TREND_PERIOD, 0, MODE_EMA, PRICE_CLOSE);
   if(!IndicatorHandleIsValid(g_handleEma200H1, "EMA 200 H1"))
     {
      ReleaseIndicators();
      return INIT_FAILED;
     }

   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > 0.0 && equity < 20.0)
      Print("[XAUUSD_Bot][INFO] Equity ", DoubleToString(equity, 2),
            " ", AccountInfoString(ACCOUNT_CURRENCY),
            ". Le capital recommandé pour ce réglage est 20.");

   Print("[XAUUSD_Bot][INFO] Version 0.6.0 démarrée sur ", Symbol(),
         ". Une ouverture n'est envoyée que si le signal, le risque et les protections passent.");
   Comment("XAUUSD_Bot 0.6.0",
           "\nIndicateurs en cours de préparation",
           "\nAucune entrée tant que les indicateurs ne sont pas prêts.");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ReleaseIndicators();
   Comment("");
   Print("[XAUUSD_Bot][INFO] Arrêt de l'EA. Code : ", reason, ".");
  }

//+------------------------------------------------------------------+
//| Protections à chaque prix. Signal une fois par bougie M15.       |
//+------------------------------------------------------------------+
void OnTick(void)
  {
   if(Symbol() != InpSymbol)
     {
      g_entrySignal = ENTRY_NONE;
      return;
     }

   const bool indicatorsReady = ReadIndicators();
   if(!indicatorsReady)
     {
      g_entrySignal = ENTRY_NONE;
      if(!g_dataMissingLogged)
        {
         Print("[XAUUSD_Bot][ERROR] Données des indicateurs indisponibles pour la bougie clôturée. Aucun signal validé.");
         g_dataMissingLogged = true;
        }
     }
   else if(!g_dataReadyLogged)
     {
      Print("[XAUUSD_Bot][INFO] Indicateurs disponibles sur la dernière bougie clôturée.");
      g_dataReadyLogged = true;
     }

   RefreshProtections(indicatorsReady);

   if(!indicatorsReady)
     {
      ShowDataUnavailable();
      return;
     }

   const datetime barTime = iTime(InpSymbol, PERIOD_M15, 1);
   if(barTime > 0 && barTime != g_lastEvaluatedBar)
     {
      g_entrySignal = ENTRY_NONE;
      string line = "";
      if(EvaluateClosedBar(line))
        {
         g_lastEvaluatedBar = barTime;
         g_contextMissingBar = 0;
         g_lastDecision = line;
         Print("[XAUUSD_Bot][INFO] ", line);
        }
      else if(g_contextMissingBar != barTime)
        {
         Print("[XAUUSD_Bot][ERROR] Données de marché indisponibles. Aucun signal validé.");
         g_contextMissingBar = barTime;
         g_lastDecision = "Données de marché indisponibles";
        }
     }

   ShowStatus();
  }

//+------------------------------------------------------------------+
