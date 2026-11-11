//+------------------------------------------------------------------+
//|                                                    PanelInfo.mqh |
//|  Panel informativo ("narrador"): fondo y líneas de texto en la    |
//|  esquina superior izquierda del gráfico.                          |
//+------------------------------------------------------------------+

input group "=== Panel ==="
input bool InpPanelActivo  = true;  // Mostrar panel
input int  InpPanelX       = 10;    // Posición X
input int  InpPanelY       = 20;    // Posición Y
input int  InpPanelAncho   = 520;   // Ancho
input int  InpPanelFuente  = 9;     // Tamaño de letra

class CPanelInfo
  {
private:
   string            m_pref;
   int               m_lineas;
   int               m_alto;
   bool              m_creado;

   string            Nombre(const int i) const { return m_pref + "L" + IntegerToString(i); }

public:
                     CPanelInfo(void) : m_lineas(0), m_alto(0), m_creado(false) {}

   void              Init(const string prefijo, const int lineas)
     {
      m_pref   = prefijo;
      m_lineas = lineas;
      m_alto   = InpPanelFuente + 8;
      m_creado = false;
      if(!InpPanelActivo)
         return;

      string fondo = m_pref + "BG";
      ObjectCreate(0, fondo, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, fondo, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, fondo, OBJPROP_XDISTANCE, InpPanelX);
      ObjectSetInteger(0, fondo, OBJPROP_YDISTANCE, InpPanelY);
      ObjectSetInteger(0, fondo, OBJPROP_XSIZE, InpPanelAncho);
      ObjectSetInteger(0, fondo, OBJPROP_YSIZE, m_lineas * m_alto + 12);
      ObjectSetInteger(0, fondo, OBJPROP_BGCOLOR, C'18,22,30');
      ObjectSetInteger(0, fondo, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, fondo, OBJPROP_COLOR, C'70,80,100');
      ObjectSetInteger(0, fondo, OBJPROP_BACK, false);
      ObjectSetInteger(0, fondo, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, fondo, OBJPROP_HIDDEN, true);

      for(int i = 0; i < m_lineas; i++)
        {
         string n = Nombre(i);
         ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, n, OBJPROP_XDISTANCE, InpPanelX + 8);
         ObjectSetInteger(0, n, OBJPROP_YDISTANCE, InpPanelY + 6 + i * m_alto);
         ObjectSetString(0, n, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, n, OBJPROP_FONTSIZE, InpPanelFuente);
         ObjectSetInteger(0, n, OBJPROP_COLOR, clrWhite);
         ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
         ObjectSetString(0, n, OBJPROP_TEXT, " ");
        }
      m_creado = true;
     }

   void              Linea(const int i, const string texto, const color c = clrWhite)
     {
      if(!m_creado || i < 0 || i >= m_lineas)
         return;
      string n = Nombre(i);
      ObjectSetString(0, n, OBJPROP_TEXT, (texto == "" ? " " : texto));
      ObjectSetInteger(0, n, OBJPROP_COLOR, c);
     }

   void              Redibujar(void)
     {
      if(m_creado)
         ChartRedraw(0);
     }

   void              Destruir(void)
     {
      ObjectsDeleteAll(0, m_pref);
      m_creado = false;
      ChartRedraw(0);
     }
  };
//+------------------------------------------------------------------+
