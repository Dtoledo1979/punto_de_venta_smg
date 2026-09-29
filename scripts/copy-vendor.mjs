// Copia supabase-js (versión fijada en package-lock.json) a public/vendor,
// para servirlo desde el mismo sitio en vez de un CDN sin versión fija.
import { copyFileSync, mkdirSync } from "node:fs";

mkdirSync("public/vendor", { recursive: true });
copyFileSync("node_modules/@supabase/supabase-js/dist/umd/supabase.js", "public/vendor/supabase.js");
