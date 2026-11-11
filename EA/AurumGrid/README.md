# AurumGrid

Expert Advisor para MetaTrader 5: rejilla a contratendencia en dos direcciones para oro (XAUUSD), con gestión de riesgo, bloqueo por noticias y panel informativo en módulos separados.

**Estado:** escrito sin compilar ni probar. Hay que compilarlo en MetaEditor y pasarlo por el probador de estrategias antes de ponerlo en una cuenta.

## Instalación

1. Copiar la carpeta `AurumGrid` completa a `MQL5/Experts/` (los cuatro archivos deben quedar juntos).
2. Compilar `AurumGrid.mq5` en MetaEditor.
3. Adjuntarlo a un gráfico de XAUUSD en una cuenta con **cobertura (hedging)**; en cuentas de compensación (netting) no arranca.

## Archivos

| Archivo | Qué hace |
|---|---|
| `AurumGrid.mq5` | Estrategia: entradas, lotes y cierre de cestas. |
| `GestionRiesgo.mqh` | Límites de cuenta que mandan sobre la estrategia. |
| `FiltroNoticias.mqh` | Bloqueo por calendario económico de MQL5. |
| `PanelInfo.mqh` | Panel con el estado y el motivo de cada decisión. |

## Estrategia

Cada lado (compras y ventas) lleva su propia cesta y las dos conviven.

- **Fase densa.** En cada vela nueva de `InpTF`, si la vela cerrada fue bajista se añade una compra; si fue alcista, una venta. Desde la segunda orden se exige además `InpPasoDenso` de distancia respecto a la orden más extrema. Los lotes suben por bloques: 5 × base, 5 × 2·base, 5 × 3·base, y así hasta `InpMaxDensas` órdenes.
- **Recuperación.** Agotada la fase densa, se añade una orden cada `InpPasoRecup` de precio en contra. El primer lote es la suma de la fase densa × `InpFactorPuente`; los siguientes se multiplican por `InpMultRecup`, hasta `InpMaxNivelesRecup` niveles.
- **Salida.** Una cesta se cierra completa cuando su flotante equivale a `InpTPCesta` de precio por encima de su punto de equilibrio.

Con los valores por defecto y lote base 0.01, la secuencia de un lado es 0.01 ×5, 0.02 ×5, 0.03 ×5, 0.04, y luego 0.51, 0.66, 0.86, 1.12, 1.46 (4.95 lotes en total).

## Gestión de riesgo

- **Corte por flotante** (`InpMaxDDFlotantePct`): si la pérdida flotante del EA llega a ese porcentaje del balance, cierra todo y no opera hasta el día siguiente.
- **Corte por pérdida diaria** (`InpPerdidaDiariaPct`): igual, contando lo cerrado en el día más el flotante.
- **Meta diaria** (`InpMetaDiariaPct`): al alcanzarla, sin posiciones abiertas, deja de abrir cestas ese día.
- **Por orden:** lotes máximos por lado, margen libre, spread máximo y nivel de margen mínimo.
- **Lote base** fijo o proporcional al balance (`InpBalancePorLoteBase`).

El corte queda guardado en una variable global del terminal, así que sobrevive a un reinicio del EA.

## Noticias

- Lee el calendario de MQL5 para las divisas de `InpNoticiasDivisas` (oro: `USD`).
- Cuenta los eventos de impacto alto y los de impacto medio cuyo nombre contenga alguna palabra de `InpNoticiasPalabras`.
- Bloquea entradas nuevas `InpNoticiasMinAntes` minutos antes y `InpNoticiasMinDespues` después (30/30 por defecto).
- `InpNoticiasMinProteger` minutos antes aplica `InpNoticiasAccion`: solo bloquear, cerrar las cestas en ganancia, o cerrar todo (por defecto).
- El calendario no existe en el probador de estrategias: el filtro solo actúa en vivo, y el panel lo indica.

## Panel

Muestra el estado (`OPERANDO`, `PARADO POR NOTICIA`, `BLOQUEADO POR RIESGO`, `CORTE POR RIESGO`), el motivo, balance y equidad, flotante y drawdown frente al límite, resultado del día, cada cesta con la condición que falta para su siguiente orden, spread, margen, y la próxima noticia con cuenta regresiva.

## Advertencia

Es una martingala: gana poco muchas veces y concentra la pérdida en los días en que el precio no retrocede. Los cortes de riesgo limitan esa pérdida, no la evitan. Probar primero en demo o en cuenta cent.
