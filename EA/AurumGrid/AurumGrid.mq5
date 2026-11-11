//+------------------------------------------------------------------+
//|                                                    AurumGrid.mq5 |
//|  Rejilla a contratendencia en dos direcciones para oro.           |
//|                                                                   |
//|  Fase densa:   en cada vela nueva, si la vela cerrada fue bajista |
//|                añade una compra (alcista: una venta), con lotes   |
//|                que suben por bloques (5 x base, 5 x 2·base, ...). |
//|  Recuperación: agotada la fase densa, órdenes más grandes cada    |
//|                InpPasoRecup de precio, multiplicadas por          |
//|                InpMultRecup.                                      |
//|  Salida:       cada lado cierra completo cuando su flotante       |
//|                supera InpTPCesta de precio sobre el punto de      |
//|                equilibrio.                                        |
//|                                                                   |
//|  Riesgo, noticias y panel viven en módulos aparte y mandan sobre  |
//|  la estrategia. Requiere cuenta con cobertura (hedging).          |
//+------------------------------------------------------------------+
#property copyright "Vinicio Cana"
#property version   "1.00"
#property description "Rejilla con recuperación en dos direcciones (XAUUSD) con gestión de riesgo, bloqueo por noticias y panel."

#include <Trade/Trade.mqh>

input group "=== Estrategia ==="
input long            InpMagic            = 20261111;  // Número mágico
input ENUM_TIMEFRAMES InpTF               = PERIOD_M1; // Marco de las velas de entrada
input bool            InpPermitirCompras  = true;      // Operar compras
input bool            InpPermitirVentas   = true;      // Operar ventas
input int             InpOrdenesPorBloque = 5;         // Fase densa: órdenes por bloque de lote
input int             InpMaxDensas        = 16;        // Fase densa: órdenes máximas por lado
input double          InpPasoDenso        = 0.20;      // Fase densa: distancia mínima entre órdenes (precio)
input double          InpFactorPuente     = 1.5;       // Recuperación: primer lote = suma densa x factor
input double          InpMultRecup        = 1.3;       // Recuperación: multiplicador de lote
input double          InpPasoRecup        = 3.0;       // Recuperación: distancia entre órdenes (precio)
input int             InpMaxNivelesRecup  = 5;         // Recuperación: niveles máximos por lado
input double          InpTPCesta          = 1.0;       // Cierre de cesta: ganancia sobre el equilibrio (precio)
input int             InpDeslizamiento    = 30;        // Deslizamiento máximo (puntos)

#include "GestionRiesgo.mqh"
#include "FiltroNoticias.mqh"
#include "PanelInfo.mqh"

//--- Resumen de las posiciones de un lado
struct SCesta
  {
   int               n;            // posiciones abiertas
   double            lotes;        // lotes acumulados
   double            precioMedio;  // precio medio ponderado
   double            flotante;     // ganancia + swap
   double            extremo;      // compra más baja / venta más alta
   double            loteMin;      // menor lote (el base con que arrancó la cesta)
  };

CTrade          g_trade;
CGestionRiesgo  g_riesgo;
CFiltroNoticias g_noticias;
CPanelInfo      g_panel;

datetime g_ultimaVela     = 0;
datetime g_ultimaOrden[2] = {0, 0};
string   g_estado         = "INICIANDO";
string   g_motivo         = "";
string   g_notaLado[2]    = {"", ""};
color    g_colorEstado    = clrWhite;

#define LINEAS_PANEL 12

//+------------------------------------------------------------------+
int OnInit()
  {
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("AurumGrid necesita una cuenta con cobertura (hedging): mantiene compras y ventas a la vez.");
      return INIT_FAILED;
     }
   if(InpOrdenesPorBloque < 1 || InpMaxDensas < 1 || InpMultRecup < 1.0 || InpPasoDenso <= 0 || InpPasoRecup <= 0)
     {
      Print("Parametros de estrategia no validos.");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpDeslizamiento);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_riesgo.Init(InpMagic, _Symbol);
   g_noticias.Init();
   g_panel.Init("AG_" + IntegerToString(InpMagic) + "_", LINEAS_PANEL);

   EventSetTimer(1);
   ActualizarPanel();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   g_panel.Destruir();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   g_noticias.Refrescar();
   ActualizarPanel();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   Procesar();
   ActualizarPanel();
  }

//+------------------------------------------------------------------+
//| Lectura de una cesta                                             |
//+------------------------------------------------------------------+
void LeerCesta(const ENUM_POSITION_TYPE tipo, SCesta &c)
  {
   c.n = 0;
   c.lotes = 0;
   c.precioMedio = 0;
   c.flotante = 0;
   c.extremo = 0;
   c.loteMin = 0;
   double sumaPrecio = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != tipo)
         continue;

      double vol    = PositionGetDouble(POSITION_VOLUME);
      double precio = PositionGetDouble(POSITION_PRICE_OPEN);
      c.n++;
      c.lotes    += vol;
      sumaPrecio += vol * precio;
      c.flotante += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(c.n == 1)
        {
         c.extremo = precio;
         c.loteMin = vol;
        }
      else
        {
         if(tipo == POSITION_TYPE_BUY)
            c.extremo = MathMin(c.extremo, precio);
         else
            c.extremo = MathMax(c.extremo, precio);
         c.loteMin = MathMin(c.loteMin, vol);
        }
     }
   if(c.lotes > 0)
      c.precioMedio = sumaPrecio / c.lotes;
  }

//+------------------------------------------------------------------+
//| Lotes                                                            |
//+------------------------------------------------------------------+
double NormalizarLote(const double lote)
  {
   double paso = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(paso <= 0)
      paso = 0.01;
   double v = MathRound(lote / paso) * paso;
   if(v < minv)
      v = minv;
   if(v > maxv)
      v = maxv;
   return NormalizeDouble(v, 8);
  }

double LoteDenso(const int indice, const double base)
  {
   return base * (1 + indice / InpOrdenesPorBloque);
  }

double SumaDensa(const double base)
  {
   double s = 0;
   for(int i = 0; i < InpMaxDensas; i++)
      s += LoteDenso(i, base);
   return s;
  }

//--- Lote de la orden número n (0 = primera) de una cesta
double LoteNivel(const int n, const double base)
  {
   if(n < InpMaxDensas)
      return NormalizarLote(LoteDenso(n, base));
   int k = n - InpMaxDensas;
   return NormalizarLote(SumaDensa(base) * InpFactorPuente * MathPow(InpMultRecup, k));
  }

//--- Ganancia en dinero de una distancia de precio para un volumen
double DineroPorDistancia(const double distancia, const double lotes)
  {
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0)
      return 0;
   return distancia / tickSize * tickValue * lotes;
  }

//+------------------------------------------------------------------+
//| Órdenes                                                          |
//+------------------------------------------------------------------+
bool Abrir(const ENUM_POSITION_TYPE tipo, const double lote, const string comentario)
  {
   bool ok;
   if(tipo == POSITION_TYPE_BUY)
      ok = g_trade.Buy(lote, _Symbol, 0, 0, 0, comentario);
   else
      ok = g_trade.Sell(lote, _Symbol, 0, 0, 0, comentario);

   uint ret = g_trade.ResultRetcode();
   if(!ok || (ret != TRADE_RETCODE_DONE && ret != TRADE_RETCODE_PLACED && ret != TRADE_RETCODE_DONE_PARTIAL))
     {
      PrintFormat("Orden rechazada (%s %.2f): %d %s", comentario, lote, ret, g_trade.ResultRetcodeDescription());
      return false;
     }
   g_ultimaOrden[tipo == POSITION_TYPE_BUY ? 0 : 1] = TimeCurrent();
   return true;
  }

void CerrarLado(const ENUM_POSITION_TYPE tipo, const string razon)
  {
   int cerradas = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != tipo)
         continue;
      if(g_trade.PositionClose(tk))
         cerradas++;
      else
         PrintFormat("No se pudo cerrar #%I64u: %d %s", tk, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
     }
   if(cerradas > 0)
      PrintFormat("Cerradas %d %s: %s", cerradas, (tipo == POSITION_TYPE_BUY ? "compras" : "ventas"), razon);
  }

bool EsNuevaVela(void)
  {
   datetime t = iTime(_Symbol, InpTF, 0);
   if(t == 0 || t == g_ultimaVela)
      return false;
   bool primera = (g_ultimaVela == 0);
   g_ultimaVela = t;
   return !primera;   // la primera lectura tras arrancar no cuenta
  }

//+------------------------------------------------------------------+
//| Entradas de un lado                                              |
//+------------------------------------------------------------------+
void GestionarLado(const ENUM_POSITION_TYPE tipo, const SCesta &c, const bool nuevaVela,
                   const int direccionVela, const MqlTick &tk)
  {
   int    idx     = (tipo == POSITION_TYPE_BUY ? 0 : 1);
   bool   compra  = (tipo == POSITION_TYPE_BUY);
   double precio  = (compra ? tk.ask : tk.bid);
   bool   permitido = (compra ? InpPermitirCompras : InpPermitirVentas);

   if(!permitido)
     {
      g_notaLado[idx] = (c.n == 0 ? "desactivado" : "desactivado: solo espera el cierre");
      return;
     }
   if(TimeCurrent() - g_ultimaOrden[idx] < 2)
      return;

   double base = (c.n > 0 ? c.loteMin : NormalizarLote(g_riesgo.LoteBase()));
   double lote = LoteNivel(c.n, base);
   string comentario;

   if(c.n < InpMaxDensas)
     {
      //--- Fase densa: una orden por vela, contra la vela cerrada
      double nivel = (compra ? c.extremo - InpPasoDenso : c.extremo + InpPasoDenso);
      bool   velaOk = (compra ? direccionVela < 0 : direccionVela > 0);
      bool   distOk = (c.n == 0) || (compra ? precio <= nivel : precio >= nivel);
      if(c.n == 0)
         g_notaLado[idx] = StringFormat("espera vela %s", compra ? "bajista" : "alcista");
      else
         g_notaLado[idx] = StringFormat("sig. %.2f en %s%.2f + vela %s", lote, compra ? "<=" : ">=", nivel,
                                        compra ? "bajista" : "alcista");
      if(!nuevaVela || !velaOk || !distOk)
         return;
      comentario = StringFormat("AG D%02d", c.n + 1);
     }
   else
     {
      //--- Recuperación: por precio, en cualquier tick
      int k = c.n - InpMaxDensas;
      if(k >= InpMaxNivelesRecup)
        {
         g_notaLado[idx] = "maximo de niveles: espera retroceso";
         return;
        }
      double nivel = (compra ? c.extremo - InpPasoRecup : c.extremo + InpPasoRecup);
      g_notaLado[idx] = StringFormat("recup. %d/%d: %.2f en %s%.2f", k + 1, InpMaxNivelesRecup, lote,
                                     compra ? "<=" : ">=", nivel);
      if(compra ? precio > nivel : precio < nivel)
         return;
      comentario = StringFormat("AG R%02d", k + 1);
     }

   string motivo = "";
   if(!g_riesgo.PermiteOrden(compra ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, c.lotes, lote, precio, motivo))
     {
      g_notaLado[idx] = "riesgo: " + motivo;
      return;
     }
   Abrir(tipo, lote, comentario);
  }

//+------------------------------------------------------------------+
//| Ciclo principal                                                  |
//+------------------------------------------------------------------+
void Procesar(void)
  {
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return;

   SCesta cb, cv;
   LeerCesta(POSITION_TYPE_BUY, cb);
   LeerCesta(POSITION_TYPE_SELL, cv);
   bool nuevaVela = EsNuevaVela();

   //--- 1. Riesgo: manda sobre todo lo demás
   string motivo = "";
   ENUM_ESTADO_RIESGO er = g_riesgo.Evaluar(cb.flotante + cv.flotante, cb.n + cv.n, motivo);
   if(er == RIESGO_CORTE)
     {
      CerrarLado(POSITION_TYPE_BUY, motivo);
      CerrarLado(POSITION_TYPE_SELL, motivo);
      g_estado = "CORTE POR RIESGO";
      g_motivo = motivo;
      g_colorEstado = clrTomato;
      return;
     }

   //--- 2. Noticias: proteger posiciones antes del evento
   g_noticias.Refrescar();
   SNoticia ev;
   if(g_noticias.TocaProteger(ev))
     {
      string razon = "noticia " + ev.divisa + " " + ev.nombre;
      if(InpNoticiasAccion == NOTI_CERRAR_TODO)
        {
         CerrarLado(POSITION_TYPE_BUY, razon);
         CerrarLado(POSITION_TYPE_SELL, razon);
         return;
        }
      if(InpNoticiasAccion == NOTI_CERRAR_GANADORAS)
        {
         if(cb.n > 0 && cb.flotante >= 0)
            CerrarLado(POSITION_TYPE_BUY, razon);
         if(cv.n > 0 && cv.flotante >= 0)
            CerrarLado(POSITION_TYPE_SELL, razon);
         return;
        }
     }

   //--- 3. Cierre de cesta en ganancia (siempre activo)
   if(cb.n > 0 && cb.flotante >= DineroPorDistancia(InpTPCesta, cb.lotes))
     {
      CerrarLado(POSITION_TYPE_BUY, StringFormat("objetivo de cesta (%.2f)", cb.flotante));
      return;
     }
   if(cv.n > 0 && cv.flotante >= DineroPorDistancia(InpTPCesta, cv.lotes))
     {
      CerrarLado(POSITION_TYPE_SELL, StringFormat("objetivo de cesta (%.2f)", cv.flotante));
      return;
     }

   //--- 4. Bloqueos de entradas nuevas
   if(er == RIESGO_BLOQUEO)
     {
      g_estado = "BLOQUEADO POR RIESGO";
      g_motivo = motivo;
      g_colorEstado = clrOrange;
      return;
     }
   if(g_noticias.EnVentana(ev))
     {
      g_estado = "PARADO POR NOTICIA";
      g_motivo = ev.divisa + " " + ev.nombre + " " + TimeToString(ev.hora, TIME_MINUTES);
      g_colorEstado = clrGold;
      return;
     }

   //--- 5. Entradas
   g_estado = "OPERANDO";
   g_motivo = "";
   g_colorEstado = clrLimeGreen;

   int direccion = 0;
   double o = iOpen(_Symbol, InpTF, 1);
   double cl = iClose(_Symbol, InpTF, 1);
   if(cl < o)
      direccion = -1;
   else
      if(cl > o)
         direccion = 1;

   GestionarLado(POSITION_TYPE_BUY, cb, nuevaVela, direccion, tk);
   GestionarLado(POSITION_TYPE_SELL, cv, nuevaVela, direccion, tk);
  }

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
string CuentaAtras(const long segundos)
  {
   long s = (segundos < 0 ? 0 : segundos);
   return StringFormat("%02d:%02d:%02d", (int)(s / 3600), (int)((s % 3600) / 60), (int)(s % 60));
  }

string TextoCesta(const string nombre, const SCesta &c, const string nota)
  {
   if(c.n == 0)
      return StringFormat("%s: sin posiciones | %s", nombre, nota);
   return StringFormat("%s: %d ord  %.2f lotes  medio %.2f  flot %+.2f | %s",
                       nombre, c.n, c.lotes, c.precioMedio, c.flotante, nota);
  }

void ActualizarPanel(void)
  {
   if(!InpPanelActivo)
      return;

   SCesta cb, cv;
   LeerCesta(POSITION_TYPE_BUY, cb);
   LeerCesta(POSITION_TYPE_SELL, cv);

   string div      = AccountInfoString(ACCOUNT_CURRENCY);
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equidad  = AccountInfoDouble(ACCOUNT_EQUITY);
   double flot     = cb.flotante + cv.flotante;
   double ddPct    = (balance > 0 && flot < 0 ? -flot / balance * 100.0 : 0);
   double base     = g_riesgo.BaseDia();
   double pnlDia   = g_riesgo.RealizadoHoy() + flot;
   double pnlPct   = (base > 0 ? pnlDia / base * 100.0 : 0);
   double nivelMrg = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);

   g_panel.Linea(0, StringFormat("AURUMGRID  %s %s  magic %I64d", _Symbol, EnumToString(InpTF), InpMagic), clrGold);
   g_panel.Linea(1, "Estado: " + g_estado, g_colorEstado);
   g_panel.Linea(2, (g_motivo == "" ? "Motivo: -" : "Motivo: " + g_motivo), clrSilver);
   g_panel.Linea(3, StringFormat("Balance %.2f  Equidad %.2f %s", balance, equidad, div));
   g_panel.Linea(4, StringFormat("Flotante EA %+.2f  (DD %.1f%% de %.1f%%)", flot, ddPct, InpMaxDDFlotantePct),
                 (ddPct >= InpMaxDDFlotantePct * 0.7 ? clrTomato : clrWhite));
   g_panel.Linea(5, StringFormat("Hoy %+.2f (%+.2f%%)  cerrado %+.2f  limite -%.1f%%", pnlDia, pnlPct,
                                 g_riesgo.RealizadoHoy(), InpPerdidaDiariaPct),
                 (pnlDia >= 0 ? clrLimeGreen : clrTomato));
   g_panel.Linea(6, TextoCesta("Compras", cb, g_notaLado[0]), clrDeepSkyBlue);
   g_panel.Linea(7, TextoCesta("Ventas ", cv, g_notaLado[1]), clrLightCoral);
   g_panel.Linea(8, StringFormat("Spread %d pts (max %d)  Margen %s", (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD),
                                 InpMaxSpreadPuntos, (nivelMrg > 0 ? StringFormat("%.0f%%", nivelMrg) : "-")));
   g_panel.Linea(9, StringFormat("Lote base %.2f  Max por lado %.2f  Niveles recup. %d",
                                 NormalizarLote(g_riesgo.LoteBase()), InpMaxLotesPorLado, InpMaxNivelesRecup), clrSilver);

   string lineaNoticia;
   color  colorNoticia = clrSilver;
   SNoticia ev;
   if(!g_noticias.Activo())
      lineaNoticia = "Noticias: filtro desactivado";
   else
      if(!g_noticias.Disponible())
         lineaNoticia = (MQLInfoInteger(MQL_TESTER) ? "Noticias: no disponible en el probador"
                         : "Noticias: calendario no disponible");
      else
         if(g_noticias.EnVentana(ev))
           {
            long seg = (long)(ev.hora + InpNoticiasMinDespues * 60 - TimeTradeServer());
            lineaNoticia = StringFormat("NOTICIA: %s %s  reanuda en %s", ev.divisa, ev.nombre, CuentaAtras(seg));
            colorNoticia = clrGold;
           }
         else
            if(g_noticias.Proxima(ev))
              {
               long seg = (long)(ev.hora - TimeTradeServer());
               lineaNoticia = StringFormat("Proxima: %s %s  %s  en %s", ev.divisa, ev.nombre,
                                           TimeToString(ev.hora, TIME_MINUTES), CuentaAtras(seg));
              }
            else
               lineaNoticia = "Noticias: nada relevante en 48 h";
   g_panel.Linea(10, lineaNoticia, colorNoticia);
   g_panel.Linea(11, StringFormat("Bloqueo noticias: %d min antes / %d despues  Impacto >= %s",
                                  InpNoticiasMinAntes, InpNoticiasMinDespues,
                                  (InpNoticiasImpactoMin == CALENDAR_IMPORTANCE_HIGH ? "alto" :
                                   InpNoticiasImpactoMin == CALENDAR_IMPORTANCE_MODERATE ? "medio" : "bajo")),
                 clrSilver);
   g_panel.Redibujar();
  }
//+------------------------------------------------------------------+
