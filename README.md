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

### PIN de administrador

Además del PIN de cada caja, hay un **PIN de administrador** único para todo
el sistema (tabla `pos.admin_settings`, viene con `9999` de ejemplo —
cámbialo apenas puedas desde el **Table Editor** de Supabase). Sirve para
autorizar dos cosas desde el botón **⚙️ Administración** dentro de cada caja:
renombrar el punto de venta y resetear su PIN. Sin ese PIN maestro, nadie
puede cambiar el PIN de una caja desde la propia app.

## 3. Integración EFTPOS (Verifone / BNZ)

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

## 4. Desplegar en venta.southmedia.co.nz

Mismo patrón que usamos para southmedia.co.nz:

1. Sube esta carpeta a un repo en GitHub (ej. `Dtoledo1979/southmedia-pos`).
2. Conéctalo en Netlify como sitio estático (sin build command, publish
   directory = raíz del repo).
3. En Netlify, agrega el dominio personalizado `venta.southmedia.co.nz`.
4. En el proveedor de DNS de southmedia.co.nz, agrega un registro `CNAME`
   para `venta` apuntando al sitio de Netlify (Netlify te da el valor exacto
   al agregar el dominio).

## 5. Seguridad — léelo antes de usar en producción

Las tablas quedan abiertas a cualquiera que tenga la anon key (ver
`schema.sql`). Es razonable para una herramienta interna con un subdominio
que nadie más conoce, pero **no la enlaces desde el sitio público** de
South Media. Si más adelante se necesita más seguridad, el siguiente paso es
mover las escrituras a funciones RPC que validen el PIN en el servidor en
vez de dejar acceso directo a las tablas.

## Pendientes / próximos pasos sugeridos

- Conseguir de BNZ la documentación de integración EFTPOS y completar
  `sendToEftpos()`.
- Si se necesita saber *quién* atendió cada pedido más adelante, se puede
  pasar de PIN compartido a login individual sin rediseñar el resto — solo
  cambia cómo se abre la sesión.
- Ajustar los umbrales de color del cronómetro en `despacho.html`
  (`WARN_AFTER`, `DANGER_AFTER`) a los tiempos reales de tu operación.
