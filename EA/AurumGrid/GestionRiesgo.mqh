//+------------------------------------------------------------------+
//|                                                GestionRiesgo.mqh |
//|  Módulo de gestión de riesgo: límites de cuenta que mandan sobre  |
//|  la estrategia. La estrategia pregunta; este módulo decide.       |
//+------------------------------------------------------------------+

input group "=== Gestión de riesgo ==="
input double InpLoteBase            = 0.01;   // Lote base de la rejilla
input double InpBalancePorLoteBase  = 0;      // Balance por cada lote base (0 = lote fijo)
input double InpMaxDDFlotantePct    = 10.0;   // Corte: pérdida flotante del EA (% del balance)
input double InpPerdidaDiariaPct    = 5.0;    // Corte: pérdida del día, cerrada + flotante (% del balance inicial del día)
input double InpMetaDiariaPct       = 0;      // Meta diaria (% del balance inicial del día, 0 = sin meta)
input double InpMaxLotesPorLado     = 5.0;    // Lotes máximos acumulados por lado
input int    InpMaxSpreadPuntos     = 60;     // Spread máximo para abrir (puntos, 0 = sin límite)
input double InpNivelMargenMin      = 300;    // Nivel de margen mínimo para abrir (%, 0 = sin límite)

enum ENUM_ESTADO_RIESGO
  {
   RIESGO_OK = 0,      // se puede operar
   RIESGO_BLOQUEO,     // no abrir nuevas; las abiertas siguen
   RIESGO_CORTE        // cerrar todo y parar hasta el día siguiente
  };

class CGestionRiesgo
  {
private:
   long              m_magic;
   string            m_simbolo;
   string            m_gvBloqueo;
   datetime          m_bloqueadoHasta;
   string            m_motivoBloqueo;
   double            m_realizadoHoy;
   datetime          m_ultCalculo;

   datetime          InicioDia(void) const
     {
      datetime t = TimeCurrent();
      return (datetime)(t - (t % 86400));
     }

   void              Bloquear(const string motivo)
     {
      m_bloqueadoHasta = InicioDia() + 86400;
      m_motivoBloqueo  = motivo;
      GlobalVariableSet(m_gvBloqueo, (double)m_bloqueadoHasta);
     }

   void              CalcularRealizado(void)
     {
      if(TimeCurrent() - m_ultCalculo < 5)
         return;
      m_ultCalculo = TimeCurrent();
      double suma = 0;
      if(HistorySelect(InicioDia(), TimeCurrent() + 60))
        {
         int total = HistoryDealsTotal();
         for(int i = 0; i < total; i++)
           {
            ulong tk = HistoryDealGetTicket(i);
            if(tk == 0)
               continue;
            if(HistoryDealGetInteger(tk, DEAL_MAGIC) != m_magic)
               continue;
            if(HistoryDealGetString(tk, DEAL_SYMBOL) != m_simbolo)
               continue;
            suma += HistoryDealGetDouble(tk, DEAL_PROFIT)
                    + HistoryDealGetDouble(tk, DEAL_SWAP)
                    + HistoryDealGetDouble(tk, DEAL_COMMISSION);
           }
        }
      m_realizadoHoy = suma;
     }

public:
                     CGestionRiesgo(void) : m_magic(0), m_bloqueadoHasta(0), m_realizadoHoy(0), m_ultCalculo(0) {}

   void              Init(const long magic, const string simbolo)
     {
      m_magic     = magic;
      m_simbolo   = simbolo;
      m_gvBloqueo = StringFormat("AG_bloqueo_%I64d_%I64d", AccountInfoInteger(ACCOUNT_LOGIN), magic);
      m_bloqueadoHasta = 0;
      m_motivoBloqueo  = "";
      if(GlobalVariableCheck(m_gvBloqueo))
        {
         m_bloqueadoHasta = (datetime)GlobalVariableGet(m_gvBloqueo);
         m_motivoBloqueo  = "Corte de riesgo anterior";
        }
      m_ultCalculo = 0;
      CalcularRealizado();
     }

   double            RealizadoHoy(void) const { return m_realizadoHoy; }
   double            BaseDia(void)      const { return AccountInfoDouble(ACCOUNT_BALANCE) - m_realizadoHoy; }
   datetime          BloqueadoHasta(void) const { return m_bloqueadoHasta; }

   //--- Lote base, fijo o proporcional al balance
   double            LoteBase(void) const
     {
      if(InpBalancePorLoteBase <= 0)
         return InpLoteBase;
      double factor = AccountInfoDouble(ACCOUNT_BALANCE) / InpBalancePorLoteBase;
      if(factor < 1.0)
         factor = 1.0;
      return InpLoteBase * factor;
     }

   //--- Estado global: se llama en cada tick con el flotante del EA
   ENUM_ESTADO_RIESGO Evaluar(const double flotanteEA, const int posiciones, string &motivo)
     {
      CalcularRealizado();

      if(TimeCurrent() < m_bloqueadoHasta)
        {
         motivo = m_motivoBloqueo + " (hasta " + TimeToString(m_bloqueadoHasta, TIME_DATE | TIME_MINUTES) + ")";
         return (posiciones > 0 ? RIESGO_CORTE : RIESGO_BLOQUEO);
        }

      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double base    = BaseDia();

      if(InpMaxDDFlotantePct > 0 && balance > 0 && flotanteEA < 0)
        {
         double dd = -flotanteEA / balance * 100.0;
         if(dd >= InpMaxDDFlotantePct)
           {
            Bloquear(StringFormat("Flotante %.1f%% >= limite %.1f%%", dd, InpMaxDDFlotantePct));
            motivo = m_motivoBloqueo;
            return RIESGO_CORTE;
           }
        }

      if(InpPerdidaDiariaPct > 0 && base > 0)
        {
         double pnlDia = m_realizadoHoy + flotanteEA;
         if(pnlDia <= -base * InpPerdidaDiariaPct / 100.0)
           {
            Bloquear(StringFormat("Perdida del dia %.1f%% >= limite %.1f%%", -pnlDia / base * 100.0, InpPerdidaDiariaPct));
            motivo = m_motivoBloqueo;
            return RIESGO_CORTE;
           }
        }

      if(InpMetaDiariaPct > 0 && base > 0 && posiciones == 0
         && m_realizadoHoy >= base * InpMetaDiariaPct / 100.0)
        {
         motivo = StringFormat("Meta diaria alcanzada (+%.1f%%)", m_realizadoHoy / base * 100.0);
         return RIESGO_BLOQUEO;
        }

      if(InpMaxSpreadPuntos > 0)
        {
         long spread = SymbolInfoInteger(m_simbolo, SYMBOL_SPREAD);
         if(spread > InpMaxSpreadPuntos)
           {
            motivo = StringFormat("Spread %d > maximo %d", (int)spread, InpMaxSpreadPuntos);
            return RIESGO_BLOQUEO;
           }
        }

      if(InpNivelMargenMin > 0)
        {
         double nivel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
         if(nivel > 0 && nivel < InpNivelMargenMin)
           {
            motivo = StringFormat("Nivel de margen %.0f%% < minimo %.0f%%", nivel, InpNivelMargenMin);
            return RIESGO_BLOQUEO;
           }
        }

      motivo = "";
      return RIESGO_OK;
     }

   //--- Permiso para una orden concreta
   bool              PermiteOrden(const ENUM_ORDER_TYPE tipo, const double lotesLado, const double lote,
                                  const double precio, string &motivo)
     {
      if(InpMaxLotesPorLado > 0 && lotesLado + lote > InpMaxLotesPorLado + 1e-8)
        {
         motivo = StringFormat("Lotes por lado %.2f + %.2f > maximo %.2f", lotesLado, lote, InpMaxLotesPorLado);
         return false;
        }
      double margen = 0;
      if(!OrderCalcMargin(tipo, m_simbolo, lote, precio, margen))
        {
         motivo = "No se pudo calcular el margen";
         return false;
        }
      if(margen > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
        {
         motivo = StringFormat("Margen libre insuficiente para %.2f lotes", lote);
         return false;
        }
      motivo = "";
      return true;
     }
  };
//+------------------------------------------------------------------+
