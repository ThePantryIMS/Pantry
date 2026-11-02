#!/usr/bin/env bash
# Rebuilds a scratch database and runs the ERD-conformance and behaviour tests (needs local Postgres 15+).
# Usage: PGPORT=54329 PGHOST=/tmp ./tests/run.sh
set -uo pipefail
cd "$(dirname "$0")/.."
H=${PGHOST:-/tmp}; P=${PGPORT:-54329}; U=${PGUSER:-postgres}
psql -h "$H" -p "$P" -U "$U" -d postgres -qc "drop database if exists pantry_test" -c "create database pantry_test" || exit 1
for f in tests/00_supabase_stub.sql supabase/migrations/0001_pantry_schema.sql supabase/migrations/0002_pantry_processes.sql supabase/seed.sql; do
  psql -h "$H" -p "$P" -U "$U" -d pantry_test -v ON_ERROR_STOP=1 -q -f "$f" || { echo "FAILED while applying $f"; exit 1; }
done
for f in tests/01_erd_conformance.sql tests/02_behaviour.sql; do
  psql -h "$H" -p "$P" -U "$U" -d pantry_test -v ON_ERROR_STOP=1 -q -o /dev/null -f "$f" 2>&1 | sed 's/^psql:[^ ]* NOTICE:  //' | grep -v 'does not exist, skipping'
  [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "FAILED in $f"; exit 1; }
done
