# Handoff a Claude Code — South Media POS → Hospitality SaaS

Este documento existe porque el trabajo anterior se hizo en una
conversación de chat con Claude, y Claude Code arranca sin memoria de
esa conversación. Léelo completo antes de tocar código.

## Qué es este proyecto

Sistema de punto de venta (POS) construido originalmente para los
eventos propios de South Media Group (fiestas de la comunidad latina en
Christchurch/Wellington, NZ). Hoy Daniel decidió evolucionarlo hacia un
**producto SaaS comercial multi-tenant** para vender a otros negocios de
hospitality (food trucks, cafés, bares móviles, etc.), separado de su
operación interna.

## Dónde está todo

- Repositorio: `Dtoledo1979/punto_de_venta_smg` en GitHub, carpeta local
  `C:\Users\DJDLatino\Punto_de_venta_smg`.
- Frontend: 6 archivos HTML/JS estáticos, sin framework — `index.html`,
  `dashboard.html`, `pos-productos.html`, `pos-tickets.html`,
  `despacho.html`, `insumos.html`. Desplegado en Netlify.
- Backend: ninguno propio — toda la lógica vive en funciones PostgreSQL
  `security definer` dentro del schema `pos`, en el proyecto Supabase
  "South Media Passport" (project ref `umbkpzhgocryhcbbczhr`), compartido
  con otros productos de Daniel en otros schemas.
- `schema.sql` en la raíz del repo es la referencia completa y actual de
  toda la base de datos (tablas + funciones). Cada cambio se aplicó
  primero como un parche SQL suelto en Supabase, y después se reflejó acá.
- `README.md` tiene la bitácora completa de todo lo que se construyó y
  corrigió, en orden cronológico — es la fuente más confiable de
  "qué se hizo y por qué".

## Documentos clave a leer, en este orden

1. `README.md` — bitácora completa del desarrollo.
2. `SOLICITUD_AUDITORIA_EXPERTO.md` — el pedido de auditoría que se le
   hizo a un experto externo, con el contexto completo del sistema y
   todos los hallazgos hasta ese punto.
3. `FASE0_AUDITORIA_ARQUITECTURA_SAAS.md` — el análisis de arquitectura
   actual vs. objetivo para la evolución a SaaS multi-tenant (secciones
   A-H: arquitectura actual, problemas encontrados, arquitectura
   objetivo, cambios de base de datos, seguridad, migración,
   implementación por fases, riesgos). **Este es el documento que define
   el trabajo que sigue.**

## Estado actual del sistema (resumen ejecutivo)

Ya corregido (auditoría técnica externa pre-producción, un hallazgo a la
vez, con parche SQL propio para cada uno — todos documentados en
`README.md`):

- Precio y subtotal calculados siempre por el servidor (nunca confiando
  en lo que manda el navegador).
- Idempotencia en la creación de pedidos (un identificador único por
  intento de cobro evita ventas duplicadas por reintento de red).
- Anulación y reapertura de pedidos atómicas (sin condición de carrera
  entre dispositivos).
- Test Mode aislado de verdad (crear/anular/reabrir un pedido de prueba
  nunca toca stock real).
- Política de sobreventa: el stock puede quedar negativo a propósito
  (con aviso y confirmación antes de vender), para reconciliar exacto
  después — no se recorta a 0.
- Límite de intentos de PIN (bloqueo temporal tras fallos seguidos).
- Integridad entre cajas en `set_recipe`/`upsert_promotion` (ya no se
  puede mezclar por error un insumo/producto de una caja con otra).
- Aislamiento entre eventos y ubicaciones: cada caja física = su propio
  stock; búsqueda y CSV acotados al evento activo por defecto.
- Confirmación manual obligatoria de pago con tarjeta antes de imprimir
  (todavía no hay integración electrónica real con el terminal EFTPOS de
  BNZ/Verifone — sigue pendiente esa documentación del banco).

**Riesgo aceptado a propósito, todavía sin corregir**: los pedidos
(nombres de clientes, montos) se leen hoy directo desde el frontend con
la clave pública `anon` de Supabase — funciona porque cada pantalla ya
filtra por su propia caja, pero no hay ningún límite real a nivel de base
de datos. Para un solo negocio (South Media) se aceptó como riesgo menor
documentado. **Para el SaaS multi-tenant, este mismo problema es un
bloqueante crítico** — está identificado como tal en la sección B de
`FASE0_AUDITORIA_ARQUITECTURA_SAAS.md`, y se resuelve naturalmente como
parte de la Fase 1 (autenticación real + RLS).

## Decisión de arquitectura ya tomada

Daniel confirmó: **construir esto en serio como producto para vender**, y
que el sistema actual de South Media **puede pausarse o migrarse** si
hace falta para avanzar más rápido — no hace falta mantener
retrocompatibilidad completa con la instancia actual mientras se
construye la plataforma nueva.

Recomendación ya dada (pendiente de que la sigas o la discutas con él):
construir la arquitectura multi-tenant en un **proyecto de Supabase
separado** (staging), migrar los datos de South Media ahí una vez que
esté sólida, en vez de reescribir en caliente sobre la base de datos que
ya está en uso.

## Próximo paso acordado

Fase 1 del plan (ver sección G de `FASE0_AUDITORIA_ARQUITECTURA_SAAS.md`):
organizaciones, ubicaciones, autenticación real (Supabase Auth) y RLS
multi-tenant. Es la base de la que depende todo lo demás.

## Preferencia de Daniel sobre cómo entregar cambios

Cuando termines un cambio que requiere aplicar SQL + reemplazar archivos
+ subir a git, dale los pasos en este orden exacto: **1) correr el SQL
en Supabase, 2) reemplazar los archivos, 3) `git add`/`commit`/`push`.**
