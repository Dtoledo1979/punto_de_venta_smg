// Alta inicial de una organización en el proyecto enlazado (staging).
//
//   node scripts/seed-staging.mjs <email-del-owner>
//
// Crea la organización, sus ubicaciones y cajas llamando a las funciones
// reales del schema pos COMO el usuario owner (mismas validaciones que la
// app). Los PINs se generan al azar y se escriben en .local/ (ignorado por
// git) — nunca se imprimen en la consola.
//
// No es una migración: son datos de un ambiente, no estructura.
import { execFileSync, execSync } from "node:child_process";
import { randomInt } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const PROD_REF = "umbkpzhgocryhcbbczhr";

const ORG = { name: "South Media Group", slug: "south-media" };
const LOCATIONS = [
  { name: "Christchurch", registers: [
    { name: "Barra Principal", type: "product" },
    { name: "Boletería", type: "ticket" },
  ] },
  { name: "Wellington", registers: [
    { name: "Barra Wellington", type: "product" },
  ] },
];

const email = process.argv[2];
if (!email) {
  console.error("Uso: node scripts/seed-staging.mjs <email-del-owner>");
  process.exit(1);
}

const ref = readFileSync("supabase/.temp/project-ref", "utf8").trim();
if (ref === PROD_REF) {
  console.error("ABORTADO: el repo está enlazado al proyecto de PRODUCCIÓN de South Media.");
  process.exit(1);
}

function query(sql) {
  const file = join(tmpdir(), `seed-${process.pid}-${Date.now()}.sql`);
  writeFileSync(file, sql);
  try {
    // En Windows el CLI es un .cmd y solo se puede lanzar vía shell; la ruta
    // la genera este script (tmpdir), no viene de ningún input externo.
    const out = process.platform === "win32"
      ? execSync(`supabase db query --linked -f "${file}"`, { encoding: "utf8" })
      : execFileSync("supabase", ["db", "query", "--linked", "-f", file], { encoding: "utf8" });
    return JSON.parse(out.slice(out.indexOf("{"))).rows ?? [];
  } finally {
    rmSync(file, { force: true });
  }
}

// Evita PINs triviales (1234, 1111, 0000...).
function pin() {
  for (;;) {
    const p = String(randomInt(0, 10000)).padStart(4, "0");
    const d = [...p].map(Number);
    const repeated = new Set(d).size === 1;
    const sequential = d.every((x, i) => i === 0 || x === d[i - 1] + 1) ||
                       d.every((x, i) => i === 0 || x === d[i - 1] - 1);
    if (!repeated && !sequential) return p;
  }
}
const lit = (s) => `'${String(s).replace(/'/g, "''")}'`;

const [user] = query(`select id from auth.users where lower(email) = lower(${lit(email)})`);
if (!user) {
  console.error(`No existe el usuario ${email} en Auth. Créalo primero en el panel de Supabase.`);
  process.exit(1);
}
const [existing] = query(`select id from pos.organizations where slug = ${lit(ORG.slug)}`);
if (existing) {
  console.error(`La organización '${ORG.slug}' ya existe (${existing.id}). No se modifica nada.`);
  process.exit(1);
}

const supervisorPin = pin();
const registers = LOCATIONS.flatMap((l) =>
  l.registers.map((r) => ({ ...r, location: l.name, pin: pin(), despachoPin: pin() })));

// Todo en una transacción: o se crea completo, o no se crea nada.
const sql = `
begin;
select set_config('request.jwt.claims', ${lit(JSON.stringify({ sub: user.id, role: "authenticated" }))}, true);
set local role authenticated;
do $$
declare v_org uuid; v_loc uuid;
begin
  v_org := (pos.create_organization(${lit(ORG.name)}, ${lit(ORG.slug)}, ${lit(supervisorPin)})).id;
${LOCATIONS.map((l) => `
  v_loc := (pos.create_location(v_org, ${lit(l.name)})).id;
${registers.filter((r) => r.location === l.name).map((r) =>
`  perform pos.create_register(v_loc, ${lit(r.name)}, ${lit(r.type)}, ${lit(r.pin)}, ${lit(r.despachoPin)});`).join("\n")}`).join("\n")}
end $$;
reset role;
commit;
select o.id as org_id, o.name as org, l.name as ubicacion, r.name as caja, r.type as tipo
from pos.organizations o
join pos.locations l on l.org_id = o.id
join pos.registers r on r.location_id = l.id
where o.slug = ${lit(ORG.slug)}
order by l.name, r.name;`;

const rows = query(sql);

mkdirSync(".local", { recursive: true });
const credFile = join(".local", "credenciales-staging.md");
writeFileSync(credFile, `# Credenciales de STAGING (${ref}) — NO subir a git

Generadas: ${new Date().toISOString()}
Organización: ${ORG.name} (slug \`${ORG.slug}\`) — owner: ${email}

PIN de supervisor (cortesías): **${supervisorPin}**

| Ubicación | Caja | Tipo | PIN caja | PIN Entrega |
|---|---|---|---|---|
${registers.map((r) => `| ${r.location} | ${r.name} | ${r.type} | ${r.pin} | ${r.despachoPin} |`).join("\n")}
`);

console.log(`Organización creada: ${ORG.name}`);
for (const r of rows) console.log(`  ${r.ubicacion} / ${r.caja} (${r.tipo})`);
console.log(`PINs guardados en ${credFile} (ignorado por git).`);
