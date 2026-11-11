//+------------------------------------------------------------------+
//|                                               FiltroNoticias.mqh |
//|  Bloqueo por noticias con el calendario económico de MQL5.        |
//|  El calendario no existe en el probador de estrategias (error     |
//|  4014): el filtro solo actúa en vivo.                             |
//+------------------------------------------------------------------+

enum ENUM_ACCION_NOTICIA
  {
   NOTI_SOLO_BLOQUEAR = 0,     // Solo bloquear entradas nuevas
   NOTI_CERRAR_GANADORAS,      // Cerrar las cestas en ganancia y bloquear
   NOTI_CERRAR_TODO            // Cerrar todo y bloquear
  };

input group "=== Noticias ==="
input bool                           InpNoticiasActivo     = true;                     // Activar filtro de noticias
input string                         InpNoticiasDivisas    = "USD";                    // Divisas (separadas por coma)
input ENUM_CALENDAR_EVENT_IMPORTANCE InpNoticiasImpactoMin = CALENDAR_IMPORTANCE_HIGH; // Impacto mínimo
input string                         InpNoticiasPalabras   = "Fed,FOMC,Powell,Nonfarm,NFP,CPI,PCE,ISM,Retail Sales,Unemployment,GDP,Speech,Speaks,IPC,Nominas,Ventas minoristas,Desempleo,PIB,Discurso"; // Palabras que suben un evento medio a alto
input int                            InpNoticiasMinAntes   = 30;                       // Minutos de bloqueo antes
input int                            InpNoticiasMinDespues = 30;                       // Minutos de bloqueo después
input int                            InpNoticiasMinProteger = 5;                       // Minutos antes para proteger posiciones
input ENUM_ACCION_NOTICIA            InpNoticiasAccion     = NOTI_CERRAR_TODO;         // Acción sobre posiciones abiertas

struct SNoticia
  {
   datetime          hora;
   string            nombre;
   string            divisa;
   int               impacto;
  };

class CFiltroNoticias
  {
private:
   SNoticia          m_ev[];
   datetime          m_ultRefresco;
   bool              m_disponible;
   datetime          m_ultProtegido;
   string            m_palabras[];

   bool              TienePalabra(const string nombre)
     {
      string n = nombre;
      StringToLower(n);
      for(int i = 0; i < ArraySize(m_palabras); i++)
         if(m_palabras[i] != "" && StringFind(n, m_palabras[i]) >= 0)
            return true;
      return false;
     }

   void              Agregar(const datetime hora, const string nombre, const string divisa, const int impacto)
     {
      int n = ArraySize(m_ev);
      ArrayResize(m_ev, n + 1);
      int pos = n;
      while(pos > 0 && m_ev[pos - 1].hora > hora)
        {
         m_ev[pos] = m_ev[pos - 1];
         pos--;
        }
      m_ev[pos].hora    = hora;
      m_ev[pos].nombre  = nombre;
      m_ev[pos].divisa  = divisa;
      m_ev[pos].impacto = impacto;
     }

public:
                     CFiltroNoticias(void) : m_ultRefresco(0), m_disponible(false), m_ultProtegido(0) {}

   void              Init(void)
     {
      m_ultRefresco  = 0;
      m_ultProtegido = 0;
      m_disponible   = false;
      ArrayResize(m_ev, 0);
      int n = StringSplit(InpNoticiasPalabras, ',', m_palabras);
      for(int i = 0; i < n; i++)
        {
         StringTrimLeft(m_palabras[i]);
         StringTrimRight(m_palabras[i]);
         StringToLower(m_palabras[i]);
        }
     }

   bool              Activo(void)     const { return InpNoticiasActivo; }
   bool              Disponible(void) const { return m_disponible; }

   //--- Recarga el calendario cada 15 minutos
   void              Refrescar(void)
     {
      if(!InpNoticiasActivo)
         return;
      if(MQLInfoInteger(MQL_TESTER))
        {
         m_disponible = false;
         return;
        }
      datetime ahora = TimeTradeServer();
      if(m_ultRefresco != 0 && ahora - m_ultRefresco < 900)
         return;
      m_ultRefresco = ahora;

      ArrayResize(m_ev, 0);
      bool alguna = false;
      string divisas[];
      int nd = StringSplit(InpNoticiasDivisas, ',', divisas);
      for(int d = 0; d < nd; d++)
        {
         string div = divisas[d];
         StringTrimLeft(div);
         StringTrimRight(div);
         StringToUpper(div);
         if(div == "")
            continue;
         MqlCalendarValue vals[];
         ResetLastError();
         int n = CalendarValueHistory(vals, ahora - 4 * 3600, ahora + 48 * 3600, NULL, div);
         if(n < 0)
           {
            PrintFormat("Noticias: no se pudo leer el calendario de %s (error %d)", div, GetLastError());
            continue;
           }
         alguna = true;
         for(int i = 0; i < n; i++)
           {
            MqlCalendarEvent ev;
            if(!CalendarEventById(vals[i].event_id, ev))
               continue;
            int impacto = (int)ev.importance;
            if(impacto == (int)CALENDAR_IMPORTANCE_MODERATE && TienePalabra(ev.name))
               impacto = (int)CALENDAR_IMPORTANCE_HIGH;
            if(impacto < (int)InpNoticiasImpactoMin)
               continue;
            Agregar(vals[i].time, ev.name, div, impacto);
           }
        }
      m_disponible = alguna;
     }

   //--- ¿Estamos dentro de la ventana de bloqueo de algún evento?
   bool              EnVentana(SNoticia &actual)
     {
      if(!InpNoticiasActivo || !m_disponible)
         return false;
      datetime ahora = TimeTradeServer();
      for(int i = 0; i < ArraySize(m_ev); i++)
        {
         if(ahora >= m_ev[i].hora - InpNoticiasMinAntes * 60 && ahora <= m_ev[i].hora + InpNoticiasMinDespues * 60)
           {
            actual = m_ev[i];
            return true;
           }
        }
      return false;
     }

   //--- Próximo evento todavía no ocurrido
   bool              Proxima(SNoticia &prox)
     {
      if(!InpNoticiasActivo || !m_disponible)
         return false;
      datetime ahora = TimeTradeServer();
      for(int i = 0; i < ArraySize(m_ev); i++)
        {
         if(m_ev[i].hora > ahora)
           {
            prox = m_ev[i];
            return true;
           }
        }
      return false;
     }

   //--- Devuelve true una sola vez por evento, cuando toca proteger posiciones
   bool              TocaProteger(SNoticia &ev)
     {
      if(!InpNoticiasActivo || !m_disponible)
         return false;
      datetime ahora = TimeTradeServer();
      for(int i = 0; i < ArraySize(m_ev); i++)
        {
         if(m_ev[i].hora <= m_ultProtegido)
            continue;
         if(ahora >= m_ev[i].hora - InpNoticiasMinProteger * 60 && ahora <= m_ev[i].hora)
           {
            m_ultProtegido = m_ev[i].hora;
            ev = m_ev[i];
            return true;
           }
        }
      return false;
     }
  };
//+------------------------------------------------------------------+
