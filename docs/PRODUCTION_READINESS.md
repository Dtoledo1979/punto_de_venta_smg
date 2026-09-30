# Production Readiness Report — Hospitality POS SaaS

Fecha: 2026-09-30 · Rama: `saas` · Base: Supabase staging `hfteywhjfpdtbkhestja` (Sydney)

## 1. Resumen

Plataforma multi-tenant funcional y verificada en staging: autenticación real,
aislamiento entre negocios en la base de datos, ventas con pagos, reembolsos,
pago rechazado, inventario con recetas/mermas/tomas, sesiones de caja con
arqueo, GST, estaciones de preparación, auditoría inmutable, onboarding y
suscripciones con límites. Interfaz en inglés (por defecto) y español.

**Estado: READY WITH MANUAL SUPABASE ACTIONS REQUIRED** — el código y la base
están listos para desplegarse como *staging/piloto*. Para vender a terceros
faltan acciones externas (§9) y hay limitaciones conocidas (§14).

## 2. Arquitectura

- Frontend: HTML/JS sin framework, build con Vite (multi-página) → `dist/`,
  servido por Netlify. Núcleo compartido en `public/js/` (`pos-core`,
  `pos-utils`, `i18n`, `pos-refunds`, `pos-sessions`).
- Backend: Supabase (Postgres + Auth + Realtime). Toda la lógica de negocio en
  funciones `security definer` del schema `pos`; el navegador solo lee (RLS)
  y llama RPCs. Sin servidores propios ni Edge Functions.
- Tenancy: `organizations` → `locations` → `registers`; `memberships` con rol
  (owner/admin/manager/staff). Cada tabla lleva `org_id` + FKs compuestas.
- Dispositivos compartidos: una cuenta inicia sesión en el dispositivo; cada
  caja se desbloquea con su PIN (bcrypt, bloqueo por intentos).

## 3. Funcionalidad operativa

| Área | Estado |
|---|---|
| Login, recuperación de contraseña, cierre de sesión, sesión persistente | ✅ |
| Onboarding (negocio, GST, primera ubicación y caja) | ✅ (UI de envío no probada en navegador — ver §6) |
| Equipo: agregar cuenta existente, rol, desactivar | ✅ |
| Ventas: efectivo con vuelto, tarjeta con confirmación manual, mixto, cortesía | ✅ |
| Tarjeta rechazada/cancelada (se registra, no vende) | ✅ |
| Reembolso total/parcial por línea, con PIN de supervisor y comprobante | ✅ |
| Anular / reabrir (atómico, idempotente, con stock) | ✅ |
| Inventario: stock por producto, insumos con envases, recetas (3 decimales) | ✅ |
| Mermas con motivo, toma de inventario con diferencias | ✅ |
| Sesión de caja: apertura, entradas/salidas, cierre a ciegas, reporte Z | ✅ |
| GST 15% incluido por venta y reembolso, número de GST en boleta | ✅ |
| Estaciones (bar/cocina/café/retiro) y Entrega filtrable (KDS) | ✅ |
| Modo prueba aislado + borrar datos de prueba | ✅ |
| Auditoría inmutable de acciones sensibles | ✅ |
| Suscripción: prueba 14 días, planes con límites, enganche para billing | ✅ (billing real no conectado) |
| Idiomas EN/ES, formatos por región, boleta en idioma de la organización | ✅ |

## 4. Bugs encontrados

Del sistema original (siguen presentes en producción `main`):
1. Límite de intentos de PIN evadible (el `raise` deshacía el registro del intento).
2. Anular desde Entrega contaba como PIN de caja fallido (5 anulaciones bloqueaban la caja).
3. Idempotencia de `create_order` evaluada antes del PIN.
4. Montos redondeados a pesos (NZD $4.50 se mostraba $5); servidor aceptaba $1 de diferencia.
5. XSS almacenado en nombres (producto/cliente/evento).
6. Acciones (anular, reabrir, eventos) no verificaban el resultado.
7. Con 2+ cajas, el selector quedaba tapado por el PIN.
8. Dashboard con un solo evento devolvía al inicio.
9. Organización nueva no podía crear su primera caja.
10. Entrega perdía pedidos tras un corte de red.

Encontrados durante el desarrollo del SaaS:
11. Stock de insumos con 2 decimales vs recetas con 3 (deriva acumulada).
12. Privilegio global de Supabase exponía funciones nuevas; `_session_totals` filtraba totales entre organizaciones con el id de la sesión.
13. Funciones de guarda sin `search_path` fijo.
14. Recuperación de contraseña: supabase-js limpiaba el `#type=recovery` antes de leerlo.
15. `[auth.email] enable_signup=false` desactivaba el login con email.

## 5. Bugs corregidos

Todos los de §4 están corregidos en `saas` (1–10 también en el frontend nuevo;
en `main` siguen hasta decidir el cambio o aplicar un parche aparte).

## 6. Pruebas

| Suite | Casos | Resultado |
|---|---|---|
| `supabase/checks/fase1_aislamiento.sql` | aislamiento de lectura en 8 tablas, secretos, escritura directa, 14 RPCs cruzadas, roles, bloqueo de PIN, Entrega, cortesía, idempotencia, anon, dinero al centavo, org suspendida | PASS |
| `fase2_pagos.sql` | libro de pagos, rechazo sin venta, reembolso parcial/total, límite por medio, PIN supervisor, idempotencia, stock proporcional, inmutabilidad, auditoría, aislamiento | PASS |
| `fase3_inventario.sql` | precisión 0.125 ml ×8, mermas, validación de reposición, toma de inventario, inmutabilidad | PASS |
| `fase4_caja_gst.sql` | sesión obligatoria, una por caja, efectivo esperado calculado a mano ($84.00), GST, cierre con pendientes, inmutable, venta de sesión cerrada | PASS |
| `fase5_estaciones.sql` | estación en la venta, marcar por estación, cambio no retroactivo | PASS |
| `fase6_suscripciones.sql` | alta, límites de plan, prueba vencida, billing hook solo servidor, máx. orgs, equipo | PASS |
| `fase7_permisos.sql` | anon sin EXECUTE, internas no expuestas, search_path, RLS en todas las tablas, sin escritura directa | PASS |
| `fase7b_borrar_pruebas.sql` | borrar solo prueba, solo propia org, solo owner/admin | PASS |
| Instalación limpia (12 migraciones + todas las verificaciones) | — | PASS |
| Pruebas de mutación (guarda roto, idempotencia rota, fórmula de efectivo) | detectadas | PASS |
| Vitest (36): dinero, resumen, i18n completo, sintaxis de todas las pantallas | — | PASS |
| Navegador (staging): login, venta efectivo/tarjeta/mixto, doble clic, modo prueba, rechazo, reembolso (PIN del usuario), anular/reabrir con stock, mermas, toma, caja completa + Z, estaciones, Entrega, EN/ES, tablet 1024×768 y móvil 375 px | — | PASS |
| Navegador: cortesía (requiere PIN de supervisor), envío del onboarding, crear cuenta, cerrar sesión | — | NOT TESTED (requieren credenciales o crearían cuentas reales; cubiertos por SQL) |
| Sitio publicado `pointsalesforyou.netlify.app`: headers (CSP, HSTS, X-Frame-Options, Referrer/Permissions-Policy), variables inyectadas (clave anon del proyecto correcto), archivos internos no publicados (404), redirección a login, consola sin errores con la CSP | — | PASS |
| Sitio publicado con sesión iniciada (Realtime por wss bajo la CSP) | — | NOT TESTED (la sesión quedó en localhost; mismo código y base, probado ahí) |

## 7. Seguridad

- RLS en todas las tablas; solo políticas de lectura; ninguna escritura directa.
- Toda RPC verifica membresía/rol; PIN con bcrypt y bloqueo; `org_id` siempre del servidor.
- Datos financieros inmutables (triggers), auditoría inmutable.
- XSS: todo texto de la base se escapa; CSV neutraliza fórmulas; sin redirección abierta en el login.
- Sin secretos en el repositorio; `.env.local` y `.local/` ignorados.
- Advisors de Supabase: quedan 2 tipos de aviso esperados — (a) RPCs ejecutables por `authenticated` (es la API; cada una valida adentro); (b) protección de contraseñas filtradas desactivada (acción manual §9).
- CSP requiere `'unsafe-inline'` en scripts (pantallas con scripts y `onclick` en línea).

## 8. Base de datos

12 migraciones en `supabase/migrations/`, reproducibles desde cero. Tablas:
organizations, locations, memberships, org_secrets, registers, events,
menu_items, ingredients, recipe_items, promotions, orders, ticket_counters,
stock_movements, pin_attempts, payments, refunds, audit_log, stocktakes,
register_sessions, cash_movements.

## 9. Acciones manuales en Supabase

| Dónde | Qué | Valor | Por qué | Cómo verificar |
|---|---|---|---|---|
| Authentication → URL Configuration → Site URL | URL de producción | `https://<sitio>.netlify.app` o dominio propio | links de email | recuperar contraseña desde la URL publicada |
| Authentication → URL Configuration → Redirect URLs | agregar | `https://<sitio>/**` | idem | idem |
| Project Settings → Authentication → SMTP Settings | SMTP propio (Resend, Postmark, SES…) | credenciales del proveedor | el correo de Supabase solo envía a miembros del equipo y ~2/hora: **sin esto no hay registro público** | crear cuenta con un email externo |
| Authentication → Sign In / Providers → Email | Allow new users to sign up = ON | cuando exista SMTP propio | onboarding público | "Create an account" en el login |
| Authentication → Attack Protection | Prevent use of leaked passwords = ON | (plan Pro) | aviso del advisor | intentar una contraseña conocida filtrada |
| Authentication → Attack Protection | CAPTCHA (Turnstile/hCaptcha) | recomendado al abrir el registro | evitar altas masivas | — |
| Database → Backups | confirmar backups diarios; evaluar PITR | según plan | recuperación ante errores | ver último backup |
| Project Settings → Database | rotar la contraseña de la base | nueva | se pegó en un chat | `supabase db push` sigue funcionando |

## 10. Netlify

Build `npm run build`, publish `dist`, Node 22, rama `saas`. Todo en `netlify.toml`. Detalle en `docs/DEPLOY.md`.

## 11. Variables de entorno

`VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` (ambas públicas). Nada secreto en el frontend.

Sitio staging publicado: **https://pointsalesforyou.netlify.app** (rama `saas`). Supabase Auth ya tiene esa URL como Site URL y redirect.

## 12. Procedimiento de despliegue

1. Subir la rama `saas` a GitHub.
2. Netlify → Add new site → Import from Git → repo `punto_de_venta_smg`, rama `saas`.
3. Cargar las 2 variables de entorno; deploy.
4. Supabase → URL Configuration con la URL asignada (§9).
5. Smoke test (§13).

## 13. Verificación post-despliegue

1. Abrir la URL → redirige a login. 2. Iniciar sesión. 3. Ver la organización
en la barra. 4. Abrir Venta de productos con PIN. 5. Activar modo prueba y
cobrar (efectivo) → boleta "TEST". 6. Entrega: aparece el pedido 🧪. 7. Stock
real sin cambios. 8. Abrir caja con fondo, venta real, cerrar caja → reporte Z
cuadra. 9. Dashboard muestra ventas netas. 10. Recargar la página: sin
duplicados. 11. Cerrar sesión e iniciar de nuevo. 12. Recargar URLs directas
(`/insumos.html`, `/despacho.html`). 13. Consola del navegador sin errores.
14. DevTools → Network sin 4xx/5xx inesperados. 15. Supabase → Logs sin
errores. 16. Con otra cuenta de otra organización: no ve nada de la primera.
17. Tablet horizontal: botones y menú usables. 18. Borrar datos de prueba.
19. Headers: `curl -I https://<sitio>/index.html` muestra la CSP.
20. Recuperar contraseña desde la URL publicada.

## 14. Limitaciones conocidas (honestas)

- **EFTPOS integrado**: no existe; la tarjeta se confirma manualmente (pendiente documentación BNZ/Verifone).
- **Impresión**: `window.print()` al driver de Windows; sin ESC/POS, sin impresoras por estación, sin registro de reimpresiones.
- **Sin modo offline**: se necesita internet para vender.
- **Billing**: no hay proveedor conectado; los planes se cambian con `set_subscription` (servidor).
- **Invitaciones por email**: no; se agregan cuentas ya creadas.
- **Staff por ubicación**: un miembro ve todas las ubicaciones de su organización.
- **GST**: una tasa por organización; sin ítems exentos; sin factura tributaria completa (> NZ$200: datos del comprador) — **confirmar requisitos del IRD con un contador**.
- **Transferencias de stock entre ubicaciones** y **producción por lotes**: no implementadas.
- **Permisos por capacidad**: roles fijos + PIN de supervisor; no hay matriz configurable.
- **Descuentos manuales**: no existen (solo promociones "N por $X" y cortesías).
- **Producción `main`**: conserva los bugs 1–10 hasta migrar a esta plataforma o aplicar un parche.

## 15. Estado

**READY WITH MANUAL SUPABASE ACTIONS REQUIRED**
