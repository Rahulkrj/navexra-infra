#!/usr/bin/env bash
# Bootstrap the databases inside the dockerized Postgres. Idempotent —
# safe to run repeatedly. Run from the repo root on the machine running docker:
#   ./scripts/bootstrap-db.sh
#
# Creates:
#   * litellm role + DB (credentials from .env.llm LLM_DB_USER/PASSWORD/NAME)
#     — used by the LiteLLM gateway for virtual keys and spend logs.
# Re-running is safe: the role password is re-asserted from .env.llm
# (rotate by editing .env.llm, re-running, then restarting litellm).
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "ERROR: .env not found (postgres credentials)"; exit 1; }
[ -f .env.llm ] || { echo "ERROR: .env.llm not found (LLM_DB_PASSWORD)"; exit 1; }

LLM_DB_USER="$(grep -E '^LLM_DB_USER=' .env.llm | cut -d= -f2-)"
LLM_DB_PASSWORD="$(grep -E '^LLM_DB_PASSWORD=' .env.llm | cut -d= -f2-)"
LLM_DB_NAME="$(grep -E '^LLM_DB_NAME=' .env.llm | cut -d= -f2-)"

echo "==> Ensuring postgres is up..."
docker compose up -d postgres
docker compose exec -T postgres sh -c 'until pg_isready -U "$POSTGRES_USER" -d postgres -q; do sleep 1; done'

create_role_and_db() {
  local role="$1" pass="$2" db="$3"
  echo "==> Role '$role' + DB '$db'"
  docker compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres' <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$role') THEN
    CREATE ROLE $role LOGIN PASSWORD '$pass';
  ELSE
    ALTER ROLE $role WITH LOGIN PASSWORD '$pass';
  END IF;
END
\$\$;
SQL
  # CREATE DATABASE can't run inside DO/transaction; check-then-create instead.
  if ! docker compose exec -T postgres sh -c "psql -U \"\$POSTGRES_USER\" -d postgres -tAc \"SELECT 1 FROM pg_database WHERE datname='$db'\"" | grep -q 1; then
    docker compose exec -T postgres sh -c "psql -v ON_ERROR_STOP=1 -U \"\$POSTGRES_USER\" -d postgres -c \"CREATE DATABASE $db OWNER $role\""
  else
    docker compose exec -T postgres sh -c "psql -v ON_ERROR_STOP=1 -U \"\$POSTGRES_USER\" -d postgres -c \"ALTER DATABASE $db OWNER TO $role\""
  fi
  docker compose exec -T postgres sh -c "psql -v ON_ERROR_STOP=1 -U \"\$POSTGRES_USER\" -d postgres -c \"GRANT ALL PRIVILEGES ON DATABASE $db TO $role\""
}

create_role_and_db "$LLM_DB_USER" "$LLM_DB_PASSWORD" "$LLM_DB_NAME"

echo "==> Verifying connection..."
docker compose exec -T -e PGPASSWORD="$LLM_DB_PASSWORD" postgres psql -h 127.0.0.1 -U "$LLM_DB_USER" -d "$LLM_DB_NAME" -c '\conninfo'

echo "OK: litellm database ready."