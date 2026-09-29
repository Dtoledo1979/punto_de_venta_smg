# Despliegue — Hospitality POS (Supabase + Netlify)

Rama del SaaS: `saas`. La rama `main` sigue siendo el POS de South Media en
producción y **no se toca** desde este flujo.

## 1. Base de datos (Supabase)

Todo el schema está en `supabase/migrations/` (12 migraciones, en orden). Una
base nueva se reproduce completa con ellas.

```bash
supabase login
supabase link --project-ref <ref-del-proyecto>
supabase db push --dry-run
supabase db push
bash scripts/verificar-db.sh --aplicado
```

`verificar-db.sh` corre todas las verificaciones de `supabase/checks/` dentro
de una transacción con ROLLBACK (no deja datos) y **se niega a correr contra
el proyecto de producción de South Media** (`umbkpzhgocryhcbbczhr`).

Con la base vacía (antes del primer push) se puede ensayar todo sin aplicar:
`bash scripts/verificar-db.sh` (migraciones + verificaciones + ROLLBACK).

### Configuración de Auth y API (en `supabase/config.toml`)

`supabase config push` aplica **sin pedir confirmación** y sube el archivo
completo: revisar el diff que imprime y comparar con lo que hay en el panel.

| Ajuste | Valor | Por qué |
|---|---|---|
| `[api] schemas` | incluye `pos` | la app habla con el schema `pos` |
| `[auth] enable_signup` | `false` hasta configurar SMTP propio | el correo de Supabase solo envía a miembros del equipo |
| `[auth.email] enable_signup` | `true` | **es el proveedor de email (login)**, no el registro |
| `[auth] minimum_password_length` / `password_requirements` | 10 / `lower_upper_letters_digits` | política de contraseñas |
| `[auth.email] enable_confirmations` | `true` | confirmar email antes de entrar |
| `[auth] site_url`, `additional_redirect_urls` | ver §3 | links de email (recuperación, confirmación) |

## 2. Frontend (Netlify)

| Ajuste | Valor |
|---|---|
| Rama | `saas` |
| Build command | `npm run build` (ya en `netlify.toml`) |
| Publish directory | `dist` (ya en `netlify.toml`) |
| Node | 22 (`NODE_VERSION` en `netlify.toml`) |
| Headers | CSP, X-Frame-Options, Referrer-Policy, Permissions-Policy (en `netlify.toml`) |

Es un sitio multi-página (no SPA): cada pantalla es un `.html` real, así que
recargar cualquier URL funciona sin reglas de reescritura.

### Variables de entorno (Netlify → Site configuration → Environment variables)

| Variable | Tipo | Requerida | De dónde | Para qué |
|---|---|---|---|---|
| `VITE_SUPABASE_URL` | pública | sí | Supabase → Project Settings → API → Project URL | conexión |
| `VITE_SUPABASE_ANON_KEY` | pública (va al navegador) | sí | Supabase → Project Settings → API → anon / publishable key | conexión |

**Nunca** poner la `service_role` / secret key en Netlify ni en el código.

## 3. URLs de Auth

Cuando Netlify asigne la URL (ej. `https://pos-staging-xxxx.netlify.app`) o el
dominio propio:

Supabase → Authentication → URL Configuration:
- **Site URL**: la URL de producción del POS.
- **Redirect URLs**: `https://<url>/**` (y `http://localhost:3000/**` para desarrollo).

Verificar: pedir "Forgot your password?" desde la URL publicada → el link del
email abre `https://<url>/login.html` con el formulario de contraseña nueva.

## 4. Desarrollo local

```bash
npm install
cp .env.example .env.local   # completar con los datos de staging
npm run dev                  # http://localhost:3000
npm test                     # tests del frontend
npm run build && npm run preview
```
