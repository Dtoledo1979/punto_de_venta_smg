# Punto de Venta — South Media Group

Prototipo funcional en HTML/JS puro (sin build step), pensado para desplegarse
como sitio estático — igual que southmedia.co.nz — en `venta.southmedia.co.nz`.

## Archivos

- `index.html` — página de inicio: elegir Productos, Tickets o abrir Entrega.
- `pos-productos.html` — caja de productos. Al cobrar, el pedido queda
  **pendiente de entrega** hasta que alguien lo confirma en Entrega.
- `pos-tickets.html` — caja de tickets. Al cobrar, el ticket queda
  **entregado de inmediato** (se autoejecuta, no pasa por Entrega).
- `despacho.html` — pantalla de Entrega: lista en vivo los pedidos pendientes
  de la caja de productos, con un cronómetro por pedido (desde que se pagó
  hasta que se confirma la entrega) y un botón para cerrarlos.
- `schema.sql` — todo lo necesario en Supabase (tablas, función de ticket
  atómico, Realtime, políticas de seguridad, datos de ejemplo).

## 1. Configurar Supabase

1. Abre el proyecto **South Media Passport** (ref `umbkpzhgocryhcbbczhr`) en
   supabase.com — el mismo que usa [[topcoat]], en un schema nuevo llamado `pos`.
2. Ve a **SQL Editor** y ejecuta el contenido completo de `schema.sql`.
3. Ve a **Settings → Data API → Exposed schemas** y agrega `pos` a la lista
   (por defecto solo `public` está expuesto — este paso es indispensable o
   las páginas no van a poder leer/escribir nada).
4. Ve a **Settings → API** y copia la **Project URL** y la **anon public key**.
5. En cada uno de los 4 archivos HTML, reemplaza:
   ```js
   const SUPABASE_ANON_KEY = "REEMPLAZA_CON_TU_ANON_KEY";
   ```
   por tu anon key real. La URL ya viene precargada con el proyecto de South
   Media Passport — cámbiala si prefieres un proyecto Supabase separado.
6. En `schema.sql`, antes de ejecutarlo, ajusta el PIN y los nombres de los
   dos registros de ejemplo (`Barra Principal` / `Boletería`) por los reales.

## 2. Cómo funciona el flujo

**Productos:** Cobrar → pedido en estado `pendiente_entrega` (aparece de
inmediato en `despacho.html` vía Supabase Realtime) → alguien en Entrega
confirma → pedido `entregado`, se guarda `delivered_at` y con eso el tiempo
total de espera.

**Tickets:** Cobrar → pedido queda `entregado` en el mismo instante (no
necesita pasar por Entrega), porque quien vende también entrega.

El PIN es único por caja (no por persona), tal como se usa hoy.

### Cómo cobrar

- **💳 Tarjeta** — un clic, cobra el total completo a tarjeta y envía a Entrega. No requiere escribir nada.
- **💵 Efectivo** — pide un solo dato: "¿Cuánto te dio el cliente?".
  - Si da igual o más que el total → muestra el **vuelto** y aparece el botón "Cobrar".
  - Si da menos que el total → automáticamente se convierte en **pago mixto**: muestra "Faltan $X" y un botón de un clic "Cobrar $Y efectivo + $X tarjeta" que cierra la venta.
- **🎁 Cortesía** — pide el PIN de administrador ahí mismo (tabla `admin_settings`). Si es correcto, cobra $0 automáticamente. En la boleta sale con el precio original tachado, "$0" al lado, la leyenda "CORTESÍA — 100% DCTO." y el "valor referencial" para control interno.

Al terminal EFTPOS solo se le envía el **monto de tarjeta** de la venta (nunca el total ni la parte en efectivo).

También hay un campo para el **nombre del cliente**: en la caja de
**productos (bar) es obligatorio** — no deja cobrar sin escribirlo, porque
sirve para identificar a quién entregarle el pedido — y en la caja de
**tickets es opcional**. Queda impreso en la boleta, visible en la pantalla
de Entrega junto al número de ticket, y en el CSV exportado.

### Entrega por producto (checklist)

En `despacho.html`, cada producto del pedido se lista por separado y se
puede tocar para marcarlo como entregado individualmente (por ejemplo,
tickear "Piscola", "Mango Sour" y "Copa de vino" pero dejar "Terremoto"
pendiente). El pedido se mantiene abierto — y el cronómetro sigue
corriendo — aunque se tickeen todos los productos: **no se cierra solo**.
Se cierra únicamente con el botón, que se pone verde y dice "✔ Cerrar
pedido" cuando ya no queda nada pendiente.

### Buscar y reabrir tickets

Tanto en la caja de productos como en Entrega hay un buscador ("🔎 Buscar
ticket") que encuentra pedidos por **nombre de cliente** (parcial) o por
**número de ticket** (exacto), en cualquier estado. Desde ahí se puede
**reabrir** un pedido ya entregado o anulado (vuelve a `pendiente_entrega`
y reaparece en Entrega) o **anular** cualquier ticket encontrado, no solo
el último vendido.

### Control de stock (solo caja de productos)

Desde "Editar menú", cada producto tiene un interruptor "Controlar stock" +
una cantidad. Al guardar, ese número queda como stock inicial y cada venta
lo va descontando. "📦 Ver stock" muestra una tabla con el stock actual, el
% restante y una alerta "¡Reponer!" al llegar a ≤25%; además aparece un
aviso emergente justo después de una venta si el producto vendido quedó en
ese rango. Para recargar stock, vuelve a "Editar menú" y guarda la nueva
cantidad total — eso también reinicia la base del 25% a ese número.

### Menú responsive

La grilla de productos se ajusta sola al ancho de pantalla (celular,
tablet, etc.) en vez de saltar entre un número fijo de columnas. También
corregí un detalle de alineación: en monitores de PC anchos, algunas
secciones (el título de inicio, el buscador, el resumen de ventas) quedaban
pegadas al borde izquierdo en vez de centrarse con el resto — ya está
parejo en cualquier tamaño de pantalla.

### PIN de administrador

Además del PIN de cada caja, hay un **PIN de administrador** único para todo
el sistema (tabla `pos.admin_settings`, viene con `9999` de ejemplo —
cámbialo apenas puedas desde el **Table Editor** de Supabase). Desde el
botón **⚙️ Administración** dentro de cada caja, el administrador ahora
puede cambiar los **tres** PIN: el de la caja, el de Entrega, y el PIN de
administrador mismo — antes solo dejaba cambiar el de la caja, ya está
corregido. El PIN de Entrega también se puede cambiar directamente desde
la pantalla de Entrega (link "⚙️ Cambiar PIN de Entrega" en la pantalla de
acceso), sin tener que ir a la caja.

### PIN de Entrega, separado del de caja

Antes, Entrega usaba el mismo PIN que la caja de productos. Ahora tiene su
propio PIN (`despacho_pin`, ejemplo genérico `5678`), guardado en el mismo
registro de la caja pero como un campo aparte del PIN de caja (ejemplo
genérico `1234`).

### Nombre de quien atiende / recibe

Al entrar a Productos, Tickets o Entrega, además del PIN se pide el
**nombre de la persona** que va a operar esa pantalla en este momento. Ese
nombre se guarda en cada pedido (`attended_by` para quien vendió,
`delivered_by` para quien confirmó la entrega en Entrega) — es un dato
informativo para saber quién atendió cada caso, no reemplaza el PIN
compartido de la caja.

## 3. Seguridad — cómo quedó protegido

**Antes:** los PIN se leían directo desde la base de datos hacia el
navegador (bastaba abrir las herramientas de desarrollador para verlos), y
cualquiera con la anon key (pública, está en el código de la página) podía
insertar/editar/borrar pedidos, PIN, menú y stock **sin pasar por ningún
PIN**, hablándole directo a la API de Supabase.

**Ahora:** ningún PIN sale nunca de la base de datos. Todo lo sensible —
crear un pedido, anular, reabrir, cambiar el menú o el stock, cambiar
cualquier PIN, autorizar una cortesía — pasa por funciones dentro de
Supabase (`pos.create_order`, `pos.void_order`, `pos.admin_update_register`,
etc.) que reciben el PIN como parámetro, lo verifican **adentro** de la
base de datos, y solo ahí ejecutan el cambio. El navegador nunca ve el PIN
real de nadie, ni siquiera el suyo propio — solo un "sí/no". Las tablas ya
no aceptan escrituras directas desde afuera de esas funciones.

**Lo que sigue siendo una limitación conocida (aceptable para esta
operación, pero conviene que la tengas clara):** cualquiera con la anon key
todavía puede **leer** el historial de pedidos (nombres de clientes,
montos, etc.) directamente vía API, porque no hay un sistema de sesiones
reales por persona — solo el PIN compartido por caja. Cerrar eso del todo
requeriría pasar a un login individual real (Supabase Auth), que es un
cambio más grande. Si en algún momento te preocupa la privacidad de los
datos de clientes más que la posibilidad de pedidos falsos, dímelo y lo
evaluamos.



## 4. Integración EFTPOS (Verifone / BNZ)

Verifone normalmente no expone una API pública propia — la integración se
hace a través del procesador de fondo que usa tu banco (con BNZ, habría que
confirmar si es Worldline NZ u otro). Mientras se consigue esa
documentación, el código ya tiene el punto de enganche listo en ambos POS:

```js
const EFTPOS_ENABLED = false;
async function sendToEftpos(totalAmount) {
  if (!EFTPOS_ENABLED) return { ok: true, skipped: true };
  // TODO: acá va la llamada real a la API de BNZ/Verifone.
}
```

Cuando tengas las credenciales/documentación, se completa esa función para
que envíe el total al terminal y espere la confirmación de pago antes de
generar el ticket — no hay que tocar nada más del resto del sistema.

## 5. Desplegar en venta.southmedia.co.nz

Mismo patrón que usamos para southmedia.co.nz:

1. Sube esta carpeta a un repo en GitHub (ej. `Dtoledo1979/southmedia-pos`).
2. Conéctalo en Netlify como sitio estático (sin build command, publish
   directory = raíz del repo).
3. En Netlify, agrega el dominio personalizado `venta.southmedia.co.nz`.
4. En el proveedor de DNS de southmedia.co.nz, agrega un registro `CNAME`
   para `venta` apuntando al sitio de Netlify (Netlify te da el valor exacto
   al agregar el dominio).

## 6. Nota sobre la anon key

Aunque las escrituras ya están protegidas por PIN a nivel de base de datos
(sección 3), la anon key sigue siendo pública por diseño de Supabase —
sigue siendo buena práctica **no enlazar este sitio desde el sitio
público** de South Media, para que no quede indexado ni sea el primer
lugar donde alguien curioso vaya a mirar.

## Pendientes / próximos pasos sugeridos

- Conseguir de BNZ la documentación de integración EFTPOS y completar
  `sendToEftpos()`.
- Si se necesita saber *quién* atendió cada pedido más adelante, se puede
  pasar de PIN compartido a login individual sin rediseñar el resto — solo
  cambia cómo se abre la sesión.
- Ajustar los umbrales de color del cronómetro en `despacho.html`
  (`WARN_AFTER`, `DANGER_AFTER`) a los tiempos reales de tu operación.

## Auditoría de reportes y botones (07-09-2026)

Revisando el CSV exportado se encontraron 3 bugs reales, ya corregidos:

- **El CSV se desordenaba de columna.** La hora se exportaba con
  `toLocaleString`, que en español incluye una coma ("07-09-2026, 21:30:36").
  Como el CSV no protegía los campos con comas adentro, Excel/Sheets cortaba
  esa coma como si fuera un separador de columna y todo lo que venía después
  en esa fila quedaba corrido una columna a la derecha (por eso la hora
  aparecía donde debía ir el cliente, el cliente donde iba el producto, etc.).
  Se separó Fecha y Hora en dos valores sin coma, y además se agregó un
  escape de CSV real (entre comillas) para cualquier campo — así, aunque un
  nombre de cliente o una observación tenga una coma en el futuro, no vuelve
  a desordenar la fila.
- **El resumen de ventas no se abría al primer clic.** Hacía falta tocar
  "Ver resumen de ventas" dos veces la primera vez. Corregido.
- **Los totales y cortesías no se actualizaban solos.** Si dejabas el panel
  de resumen abierto mientras seguías vendiendo, se quedaba con los números
  viejos hasta cerrarlo y abrirlo de nuevo. Ahora se refresca solo después
  de cada cobro si está abierto.

También se agregó protección contra doble clic al cobrar (un clic doble
accidental ya no puede generar dos pedidos), y el desglose de cortesías del
resumen ahora muestra **a quién** se le entregó cada una (cliente, ticket,
hora y productos), no solo el total agregado por producto.
