// Borra por completo una organización de PRUEBA del proyecto enlazado
// (staging): ventas, pagos, stock, auditoría, cajas… todo, en cascada.
//
//   node scripts/delete-org.mjs <slug>                       → muestra qué se borraría
//   node scripts/delete-org.mjs <slug> --confirm=<slug>      → borra
//   node scripts/delete-org.mjs <slug> --confirm=<slug> --with-users
//        → además borra las cuentas (Auth) que SOLO pertenecían a esa org
//
// Protecciones: nunca contra el proyecto de producción de South Media;
// nunca la organización "south-media"; exige repetir el slug para confirmar.
// Es IRREVERSIBLE.
import { execSync, execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const PROD_REF = "umbkpzhgocryhcbbczhr";
const PROTECTED_SLUGS = ["south-media"];

const [slug, ...flags] = process.argv.slice(2);
const confirm = (flags.find((f) => f.startsWith("--confirm=")) || "").split("=")[1];
const withUsers = flags.includes("--with-users");
if (!slug) { console.error("Uso: node scripts/delete-org.mjs <slug> [--confirm=<slug>] [--with-users]"); process.exit(1); }

const ref = readFileSync("supabase/.temp/project-ref", "utf8").trim();
if (ref === PROD_REF) { console.error("ABORTADO: el repo está enlazado al proyecto de PRODUCCIÓN."); process.exit(1); }
if (PROTECTED_SLUGS.includes(slug)) { console.error(`ABORTADO: "${slug}" está protegida y no se puede borrar con este script.`); process.exit(1); }
if (!/^[a-z0-9-]{3,40}$/.test(slug)) { console.error("Slug inválido."); process.exit(1); }

function query(sql) {
  const file = join(tmpdir(), `delorg-${process.pid}-${Date.now()}.sql`);
  writeFileSync(file, sql);
  try {
    const out = process.platform === "win32"
      ? execSync(`supabase db query --linked -f "${file}"`, { encoding: "utf8" })
      : execFileSync("supabase", ["db", "query", "--linked", "-f", file], { encoding: "utf8" });
    return JSON.parse(out.slice(out.indexOf("{"))).rows ?? [];
  } finally { rmSync(file, { force: true }); }
}

const [org] = query(`
  select o.id, o.name, o.plan, o.subscription_status,
    (select count(*) from pos.orders where org_id = o.id) as orders,
    (select count(*) from pos.orders where org_id = o.id and not is_test) as real_orders,
    (select count(*) from pos.registers where org_id = o.id) as registers,
    (select string_agg(u.email, ', ') from pos.memberships m join auth.users u on u.id = m.user_id where m.org_id = o.id) as members,
    (select string_agg(u.email, ', ') from pos.memberships m join auth.users u on u.id = m.user_id
       where m.org_id = o.id and not exists (select 1 from pos.memberships m2 where m2.user_id = m.user_id and m2.org_id <> o.id)) as only_here
  from pos.organizations o where o.slug = '${slug}'`);
if (!org) { console.error(`No existe una organización con slug "${slug}".`); process.exit(1); }

console.log(`Proyecto: ${ref}`);
console.log(`Organización: ${org.name} (${slug}) · plan ${org.plan} / ${org.subscription_status}`);
console.log(`Pedidos: ${org.orders} (reales: ${org.real_orders}) · cajas: ${org.registers}`);
console.log(`Miembros: ${org.members || "—"}`);
console.log(`Cuentas que solo pertenecen a esta org: ${org.only_here || "—"}${withUsers ? "  → SE BORRARÁN" : "  (se conservan; usa --with-users para borrarlas)"}`);

if (confirm !== slug) {
  console.log(`\nNo se borró nada. Para borrar, repite el slug: --confirm=${slug}`);
  process.exit(0);
}

const users = withUsers ? query(`
  select m.user_id from pos.memberships m
  where m.org_id = '${org.id}' and not exists (select 1 from pos.memberships m2 where m2.user_id = m.user_id and m2.org_id <> '${org.id}')`) : [];

query(`begin;
delete from pos.organizations where id = '${org.id}';
${users.map((u) => `delete from auth.users where id = '${u.user_id}';`).join("\n")}
commit;`);

const [left] = query(`select count(*) as n from pos.organizations where slug = '${slug}'`);
console.log(Number(left.n) === 0 ? `\nBorrada: ${org.name}${users.length ? ` y ${users.length} cuenta(s)` : ""}.` : "\nERROR: la organización sigue existiendo.");
