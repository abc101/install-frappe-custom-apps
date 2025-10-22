#!/bin/bash
set -euo pipefail

# User configuration
# Always look for user.env in the same folder as this script
# If user.env exists, load variables from it.
# Example user.env:
# EMAIL=user@example.com
# DB_PASSWORD=SuperSecret
# ERPNEXT_PASSWORD=SuperSecret
# BENCH=mybench
# SITES=mydomain.com
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$SCRIPT_DIR/user.env" ]; then
  echo "ℹ️  Loading user configuration from $SCRIPT_DIR/user.env"
  set -o allexport
  . "$SCRIPT_DIR/user.env"
  set +o allexport
else
  echo "➡️  No user environment file found. System is going to use default settings."
fi

# Read apps.json from the same directory as the script and generate base64 string
export APPS_JSON_BASE64=$(base64 -w 0 "${SCRIPT_DIR}/apps.json")

# Fallback to default values if not provided in user.env
EMAIL=${EMAIL:-erp@example.com}
DB_PASSWORD=${DB_PASSWORD:-"ChangeMe123!"}
ERPNEXT_PASSWORD=${ERPNEXT_PASSWORD:-"ChangeMe123!"}
BENCH=${BENCH:-"erp"}
SITES=${SITES:-"erp.example.com"}
CUSTOM_IMAGE=${CUSTOM_IMAGE:-'ghcr.io/abc101/frappe-custom-apps'}

# Port to expose for external reverse proxy
FRONT_HTTP_PORT=${FRONT_HTTP_PORT:-8080}

# Docker Compose plugin check
DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
if [ ! -d "$DOCKER_CONFIG/cli-plugins" ]; then
  mkdir -p "$DOCKER_CONFIG/cli-plugins"
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "ℹ️  Installing docker compose plugin ..."
  curl -sSL https://github.com/docker/compose/releases/download/v2.2.3/docker-compose-linux-x86_64 \
    -o "$DOCKER_CONFIG/cli-plugins/docker-compose"
  chmod +x "$DOCKER_CONFIG/cli-plugins/docker-compose"
else
  echo "✅  docker compose plugin is already installed."
fi

# Clone frappe_docker repository
cd "$HOME"
[ -d frappe_docker ] || git clone https://github.com/frappe/frappe_docker
cd $HOME/frappe_docker

# Try to extract ERPNext image tag (e.g. v15.82.1) from pwd.yml and export it
set -euo pipefail

PWD_YML="$HOME/frappe_docker/pwd.yml"
if [ -f "$PWD_YML" ]; then
  ERPNEXT_IMAGE_LINE=$(grep -E '^\s*image:\s*["'\'']?frappe/erpnext:[^"'\'' ]+' "$PWD_YML" | head -n 1 || true)
  if [ -n "$ERPNEXT_IMAGE_LINE" ]; then
    IMAGE_TAG=$(echo "$ERPNEXT_IMAGE_LINE" | sed -E 's/.*frappe\/erpnext:[[:space:]]*["'\'']?([vV]?[0-9][^"'\'' ]*).*/\1/')
  fi
fi

# Fail fast if no tag could be determined
if [ -z "${IMAGE_TAG:-}" ]; then
  echo "❌ Could not determine ERPNext image tag (FRAPPE_ERPNEXT_VERSION not set and no tag found in pwd.yml)."
  echo "   Aborting install-frappe-apps.sh."
  exit 1
fi

# Check if GHCR image exists
REQUIRED_IMAGE="${CUSTOM_IMAGE}:${IMAGE_TAG}"
echo "🔎 Checking required image: ${REQUIRED_IMAGE}"
if ! docker manifest inspect "${REQUIRED_IMAGE}" >/dev/null 2>&1; then
  echo "❌ Required image not found in GHCR: ${REQUIRED_IMAGE}"
  echo "   Make sure docker-builder.sh pushed this tag, then rerun install-frappe-apps.sh."
  exit 1
fi

echo "✅ Found required image: ${REQUIRED_IMAGE} — proceeding with installation."

# Prepare gitops directory
[ -d "$HOME/gitops" ] && rm -rf "$HOME/gitops"
mkdir -p "$HOME/gitops"

# Create environment file for this bench
cp example.env "$HOME/gitops/$BENCH.env"
sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$DB_PASSWORD/" "$HOME/gitops/$BENCH.env"
sed -i "s/^DB_HOST=.*/DB_HOST=db/" "$HOME/gitops/$BENCH.env"
sed -i "s/^DB_PORT=.*/DB_PORT=3306/" "$HOME/gitops/$BENCH.env"
sed -i "s|^SITES=\`.*\`|SITES=\`$SITES\`|" "$HOME/gitops/$BENCH.env"
{
  echo "ROUTER=$BENCH"
  echo "BENCH_NETWORK=$BENCH"
} >> "$HOME/gitops/$BENCH.env"

# Override for frontend port exposure
cat > "$HOME/gitops/$BENCH.ports.yaml" <<YAML
services:
  frontend:
    ports:
      - "${FRONT_HTTP_PORT}:8080"
YAML

# Generate final compose configuration
docker compose \
  --project-name "$BENCH" \
  --env-file "$HOME/gitops/$BENCH.env" \
  -f compose.yaml \
  -f overrides/compose.redis.yaml \
  -f overrides/compose.mariadb.yaml \
  -f "$HOME/gitops/$BENCH.ports.yaml" \
  config > "$HOME/gitops/$BENCH.yaml"

# Start containers
docker compose --project-name "$BENCH" -f "$HOME/gitops/$BENCH.yaml" up -d

# Ensure jq is installed (required for health checks)
if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found. Installing..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y && sudo apt-get install -y jq
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y jq
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y jq
  elif command -v apk >/dev/null 2>&1; then
    sudo apk add --no-cache jq
  else
    echo "❌ Package manager not supported. Please install jq manually."
    exit 1
  fi
  echo "✅ jq installed successfully: $(jq --version)"
fi

# Wait for services to become healthy
echo "⏳  Waiting for database services to become healthy ..."
ATTEMPTS=10
SLEEP_SECS=5
wait_service() {
  local svc="$1"; local i=0
  while [ $i -lt $ATTEMPTS ]; do
    state=$(docker compose --project-name "$BENCH" -f "$HOME/gitops/$BENCH.yaml" ps --format json \
      | jq -s -r "if (.[0] | type) == \"array\" then .[0][] else .[] end | select(.Service==\"$svc\") | .State" | head -n1)
    if [ "$state" = "running" ] || [ "$state" = "healthy" ]; then return 0; fi
    i=$((i+1)); sleep "$SLEEP_SECS"
  done; return 1
}
wait_service db || { echo "❌  MariaDB not ready"; exit 1; }
wait_service redis-cache || true
wait_service backend || true

echo "✅  All background systems are ready to go!"

# Create site
echo "ℹ️  Now, frappe and erpnext will be installed."
docker compose --project-name "$BENCH" -f "$HOME/gitops/$BENCH.yaml" exec -T backend bash -lc \
  "export MYSQL_PWD=\"$DB_PASSWORD\"; \
   bench new-site \
     --mariadb-user-host-login-scope=% \
     --db-root-password \"$DB_PASSWORD\" \
     --install-app erpnext \
     --admin-password \"$ERPNEXT_PASSWORD\" \
     \"$SITES\""

# Install multiple apps (ERPNext + others)
APPS=${APPS:-"hrms payments"}
for app in $APPS; do
  echo "ℹ️  Installing app: $app"
  docker compose --project-name "$BENCH" -f "$HOME/gitops/$BENCH.yaml" exec -T backend bash -lc \
    "bench --site \"$SITES\" install-app $app"
done

# Final information
echo
echo "====================================================="
echo " ERPNext stack is up (frontend -> port ${FRONT_HTTP_PORT})"
echo " Reverse proxy to: http://<ERPNext_server_ip>:${FRONT_HTTP_PORT}"
echo " Site: ${SITES}"
echo " Installed apps: ${APPS}"
echo "====================================================="

