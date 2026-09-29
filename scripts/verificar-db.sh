#!/usr/bin/env bash
# Ensaya TODAS las migraciones + las verificaciones de supabase/checks/
# contra el proyecto enlazado, dentro de una transacción que termina en
# ROLLBACK: valida contra el Postgres real de Supabase sin dejar nada.
#
# Solo tiene sentido mientras staging está vacío (antes del primer
# `supabase db push`). Después de eso, usar verificar-db.sh --aplicado,
# que corre solo las verificaciones sobre lo ya aplicado (también con
# ROLLBACK).
set -euo pipefail
cd "$(dirname "$0")/.."

ref=$(cat supabase/.temp/project-ref 2>/dev/null || true)
if [ "$ref" = "umbkpzhgocryhcbbczhr" ]; then
  echo "ABORTADO: el repo está enlazado al proyecto de PRODUCCIÓN de South Media." >&2
  exit 1
fi
if [ -z "$ref" ]; then
  echo "ABORTADO: el repo no está enlazado (supabase link --project-ref <ref>)." >&2
  exit 1
fi
echo "Proyecto enlazado: $ref"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
{
  echo "begin;"
  if [ "${1:-}" != "--aplicado" ]; then
    for f in supabase/migrations/*.sql; do
      echo "-- >>> $f"
      cat "$f"
      echo
    done
  fi
  for f in supabase/checks/*.sql; do
    echo "-- >>> $f"
    cat "$f"
    echo
  done
  echo "rollback;"
} > "$tmp"

supabase db query --linked -f "$tmp"
