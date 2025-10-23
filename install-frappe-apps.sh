#!/bin/bash
set -euo pipefail

# ===========================
# install-frappe-apps.sh
# - Deploy/Upgrade Frappe (no Traefik) with ERPNext/HRMS/Payments
# - Pulls pre-packaged git deps from CUSTOM_IMAGE:<IMAGE_TAG>
# - IMAGE_TAG must match frappe_docker/pwd.yml tag
# ===========================

# ----- User configuration -----
# Load user.env from the same folder as this script (if present).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/user.env" ]; then
  echo "ℹ️  Loading user configuration from $SCRIPT_DIR/user.env"
  set -o allexport
  . "$SCRIPT_DIR/user.env"
  set +o allexport
else
  echo "➡️  No user environment file found. System will use default settings."
fi

# Read apps.json (same directory) and encode to base64
export APPS_JSON_BASE64="$(base64 -w 0 "${SCRIPT_DIR}/apps.json")"

# Defaults (used when not provided in user.env)
EMAIL=${EMAIL:-erp@example.com}
DB_PASSWORD=${DB_PASSWORD:-"ChangeMe123!"}
ERPNEXT_PASSWORD=${ERPNEXT_PASSWORD:-"ChangeMe123!"}
BENCH=${BENCH:-"erp"}
SITES=${SITES:-"erp.example.com"}
CUSTOM_IMAGE=${CUSTOM_IMAGE:-'ghcr.io/abc101/frappe-custom-apps'}
FRONT_HTTP_PORT=${FRONT_HTTP_PORT:-8080}
CFG="${CFG:-$HOME/gitops/$BENCH.yaml}"

# ----- Docker Compose plugin check -----
DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
mkdir -p "$DOCKER_CONFIG/cli-plugins"
if ! docker compose version >/dev/null 2>&1; then
  echo "ℹ️  Installing docker compose plugin ..."
  curl -sSL https://github.com/docker/compose/releases/download/v2.2.3/docker-compose-linux-x86_64 \
    -o "$DOCKER_CONFIG/cli-plugins/docker-compose"
  chmod +x "$DOCKER_CONFIG/cli-plugins/docker-compose"
else
  echo "✅  docker compose plugin is already installed."
fi

# ----- Clone or update frappe_docker -----
cd "$HOME"
if [ -d frappe_docker ]; then
  echo "📦 frappe_docker exists — updating..."
  (
    cd frappe_docker
    git fetch --all --prune
    git reset --hard origin/main
    git pull --rebase
  )
else
  echo "📥 Cloning frappe_docker..."
  git clone https://github.com/frappe/frappe_docker
fi
cd "$HOME/frappe_docker"

# ----- Resolve TARGET_VERSION (IMAGE_TAG) from pwd.yml or env -----
# Try pwd.yml first (image: frappe/erpnext:<tag>), then FRAPPE_ERPNEXT_VERSION.
IMAGE_TAG=""
PWD_YML="$HOME/frappe_docker/pwd.yml"
if [ -f "$PWD_YML" ]; then
  line="$(grep -E '^[[:space:]]*image:[[:space:]]*["'\'']?frappe/erpnext:[^"'\''[:space:]]+' "$PWD_YML" | head -n1 || true)"
  if [ -n "$line" ]; then
    IMAGE_TAG="$(echo "$line" | sed -E 's/.*frappe\/erpnext:[[:space:]]*["'\'']?([^"'\''[:space:]]+).*/\1/')"
  fi
fi
if [ -z "${IMAGE_TAG:-}" ] && [ -n "${FRAPPE_ERPNEXT_VERSION:-}" ]; then
  IMAGE_TAG="$FRAPPE_ERPNEXT_VERSION"
fi

if [ -z "${IMAGE_TAG:-}" ]; then
  echo "❌ Could not determine ERPNext image tag. Set FRAPPE_ERPNEXT_VERSION or define frappe/erpnext:<tag> in pwd.yml."
  exit 1
fi
echo "🎯 Target ERPNext tag: ${IMAGE_TAG}"

# ----- Ensure required CUSTOM_IMAGE:<IMAGE_TAG> exists on GHCR -----
REQUIRED_IMAGE="${CUSTOM_IMAGE}:${IMAGE_TAG}"
echo "🔎 Checking required image: ${REQUIRED_IMAGE}"
if ! docker manifest inspect "${REQUIRED_IMAGE}" >/dev/null 2>&1; then
  echo "❌ Required image not found in registry: ${REQUIRED_IMAGE}"
  echo "   Make sure docker-builder-frappe-apps.sh pushed this tag, then rerun."
  exit 1
fi
echo "✅ Found required image: ${REQUIRED_IMAGE}"

# ===== Version Gate (compare CURRENT vs TARGET) =====
_norm_ver() { echo "$1" | sed -E 's/^[vV]//; s/[^0-9.].*$//'; }
is_newer() {
  local A B top
  A="$(_norm_ver "$1")"; B="$(_norm_ver "$2")"
  top=$(printf "%s\n%s\n" "$A" "$B" | sort -V | tail -n1)
  [ "$top" = "$A" ] && [ "$A" != "$B" ]
}

# Detect if an existing deployment likely exists (containers or volumes)
has_existing="no"
if [ -f "$CFG" ] && docker compose -p "$BENCH" -f "$CFG" ps -q 2>/dev/null | grep -q .; then
  has_existing="yes"
elif docker ps -q --filter "label=com.docker.compose.project=${BENCH}" | grep -q .; then
  has_existing="yes"
elif docker volume ls -q --filter "name=${BENCH}_" | grep -q .; then
  has_existing="yes"
fi

# Try to read CURRENT_VERSION from bench (preferred), else from backend image tag
get_current_version() {
  if [ -f "$CFG" ] && docker compose -p "$BENCH" -f "$CFG" ps -q backend >/dev/null 2>&1 && \
     [ -n "$(docker compose -p "$BENCH" -f "$CFG" ps -q backend)" ]; then
    docker compose -p "$BENCH" -f "$CFG" exec -T backend \
      bash -lc 'bench version 2>/dev/null | awk '"'"'/^erpnext[[:space:]]/{print $2; exit}'"'"  || true"
  else
    echo ""
  fi
}
CURRENT_VERSION="$(get_current_version || true)"
if [ -z "$CURRENT_VERSION" ] && [ "$has_existing" = "yes" ]; then
  BID="$(docker ps -q --filter "label=com.docker.compose.project=${BENCH}" --filter "name=${BENCH}.*backend" | head -n1 || true)"
  if [ -n "$BID" ]; then
    img="$(docker inspect -f '{{.Config.Image}}' "$BID" 2>/dev/null || true)"
    if echo "$img" | grep -q ':'; then CURRENT_VERSION="${img##*:}"; fi
  fi
fi

if [ -n "$CURRENT_VERSION" ]; then
  echo "📦 Current ERPNext version: ${CURRENT_VERSION}"
else
  echo "📦 No installed ERPNext version detected."
fi

# If something exists and we're not forcing a fresh reinstall, gate on version
_install_mode="${INSTALL_MODE:-}"   # may be set later by selection prompt
if [ "$has_existing" = "yes" ] && [ "${_install_mode}" != "fresh" ] && [ -n "$CURRENT_VERSION" ]; then
  if is_newer "$IMAGE_TAG" "$CURRENT_VERSION"; then
    echo "✅ Target version is newer — upgrade can proceed."
  else
    if [ "${FORCE_UPGRADE:-}" = "yes" ]; then
      echo "⚠️ Target ($IMAGE_TAG) is not newer than current ($CURRENT_VERSION), but FORCE_UPGRADE=yes — continuing."
    else
      echo "ℹ️ Target ($IMAGE_TAG) is not newer than current ($CURRENT_VERSION)."
      echo "   Skipping upgrade to avoid unnecessary changes."
      echo "   - To force a redeploy: export FORCE_UPGRADE=yes"
      echo "   - To reinstall from scratch (DESTROYS DATA): export INSTALL_MODE=fresh"
      exit 0
    fi
  fi
fi

# ===== Mode Selection (default: upgrade if something exists) =====
if [ "$has_existing" = "yes" ]; then
  INSTALL_MODE="${INSTALL_MODE:-upgrade}"
  if [ -z "${SKIP_CONFIRM:-}" ]; then
    echo
    echo "Choose installation mode for project '$BENCH':"
    echo "  [U] Upgrade in-place (preserve data)  <-- DEFAULT"
    echo "  [F] Fresh reinstall (DESTROYS DATA: containers + volumes)"
    read -r -p "Press Enter for Upgrade, or type 'F' for Fresh: " _choice
    case "$_choice" in
      [Ff]) INSTALL_MODE="fresh" ;;
      *)    INSTALL_MODE="upgrade" ;;
    esac
  fi
else
  INSTALL_MODE="fresh"  # nothing exists → fresh install
fi
echo "🧭 Selected mode: ${INSTALL_MODE}"

# ===== Prepare gitops files (only delete on fresh) =====
if [ "$INSTALL_MODE" = "fresh" ]; then
  [ -d "$HOME/gitops" ] && rm -rf "$HOME/gitops"
fi
mkdir -p "$HOME/gitops"

# Create bench env for compose rendering
cp example.env "$HOME/gitops/$BENCH.env"
sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$DB_PASSWORD/" "$HOME/gitops/$BENCH.env"
sed -i "s/^DB_HOST=.*/DB_HOST=db/" "$HOME/gitops/$BENCH.env"
sed -i "s/^DB_PORT=.*/DB_PORT=3306/" "$HOME/gitops/$BENCH.env"
sed -i "s|^SITES=\`.*\`|SITES=\`$SITES\`|" "$HOME/gitops/$BENCH.env"
{
  echo "ROUTER=$BENCH"
  echo "BENCH_NETWORK=$BENCH"
} >> "$HOME/gitops/$BENCH.env"

# Frontend port exposure override
cat > "$HOME/gitops/$BENCH.ports.yaml" <<YAML
services:
  frontend:
    ports:
      - "${FRONT_HTTP_PORT}:8080"
YAML

# Render final compose file
docker compose \
  --project-name "$BENCH" \
  --env-file "$HOME/gitops/$BENCH.env" \
  -f compose.yaml \
  -f overrides/compose.redis.yaml \
  -f overrides/compose.mariadb.yaml \
  -f "$HOME/gitops/$BENCH.ports.yaml" \
  config > "$CFG"

# ===== Execute by mode =====

if [ "$INSTALL_MODE" = "fresh" ]; then
  # Fresh reinstall: stop & remove everything, including volumes (if any)
  if [ "$has_existing" = "yes" ]; then
    echo "⚠️  Fresh reinstall: bringing down previous stack (containers + volumes)"
    docker compose -p "$BENCH" -f "$CFG" down -v || true
  fi

  echo "🚀 Starting a fresh installation..."
  docker compose --project-name "$BENCH" -f "$CFG" up -d

  # jq requirement (for wait helper)
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
    echo "✅ jq installed: $(jq --version)"
  fi

  # Wait for core services
  echo "⏳  Waiting for services to become healthy ..."
  ATTEMPTS=10; SLEEP_SECS=5
  wait_service() {
    local svc="$1"; local i=0
    while [ $i -lt $ATTEMPTS ]; do
      state=$(docker compose --project-name "$BENCH" -f "$CFG" ps --format json \
        | jq -s -r 'if (.[0]|type)=="array" then .[0][] else .[] end | select(.Service=="'"$svc"'") | .State' | head -n1)
      if [ "$state" = "running" ] || [ "$state" = "healthy" ]; then return 0; fi
      i=$((i+1)); sleep "$SLEEP_SECS"
    done; return 1
  }
  wait_service db || { echo "❌  MariaDB not ready"; exit 1; }
  wait_service redis-cache || true
  wait_service backend || true
  echo "✅  All background systems are ready."

  # Create site (only for fresh install)
  echo "ℹ️  Creating site and installing ERPNext..."
  docker compose --project-name "$BENCH" -f "$CFG" exec -T backend bash -lc \
    "export MYSQL_PWD=\"$DB_PASSWORD\"; \
     bench new-site \
       --mariadb-user-host-login-scope=% \
       --db-root-password \"$DB_PASSWORD\" \
       --install-app erpnext \
       --admin-password \"$ERPNEXT_PASSWORD\" \
       \"$SITES\""

  # Install additional apps (if any)
  APPS=${APPS:-"hrms payments"}
  for app in $APPS; do
    echo "ℹ️  Installing app: $app"
    docker compose --project-name "$BENCH" -f "$CFG" exec -T backend bash -lc \
      "bench --site \"$SITES\" install-app $app"
  done

  echo
  echo "✅ Fresh installation complete."

else
  # Upgrade path (data preserved)
  echo "🛠  Proceeding with in-place UPGRADE (data preserved)."

  # Optional backup
  BACKUP_STAMP="$(date +%Y%m%d-%H%M%S)"
  HOST_BACKUP_DIR="${HOST_BACKUP_DIR:-$PWD/backups/$BENCH-$BACKUP_STAMP}"
  mkdir -p "$HOST_BACKUP_DIR"

  echo "🔒 Enabling maintenance mode..."
  docker compose -p "$BENCH" -f "$CFG" exec -T backend \
    bash -lc 'bench --site "'"$SITES"'" set-maintenance-mode on' || true

  echo "💾 Creating on-site backup (DB + files)..."
  docker compose -p "$BENCH" -f "$CFG" exec -T backend \
    bash -lc 'bench --site "'"$SITES"'" backup --with-files' || true

  # copy backups out (best effort)
  BACKEND_CID="$(docker compose -p "$BENCH" -f "$CFG" ps -q backend || true)"
  if [ -n "$BACKEND_CID" ]; then
    IN_BACKUP_DIR="/home/frappe/frappe-bench/sites/$SITES/private/backups"
    echo "📤 Copying backups to host: $HOST_BACKUP_DIR"
    docker cp "$BACKEND_CID:$IN_BACKUP_DIR/." "$HOST_BACKUP_DIR" 2>/dev/null || true
  fi

  echo "⬇️  Pulling latest images (if tags changed) ..."
  docker compose -p "$BENCH" -f "$CFG" pull || true

  echo "♻️  Recreating containers ..."
  docker compose -p "$BENCH" -f "$CFG" up -d

  echo "🧭 Running database migrations ..."
  docker compose -p "$BENCH" -f "$CFG" exec -T backend \
    bash -lc 'bench --site "'"$SITES"'" migrate'

  echo "🧱 Rebuilding production assets (frontend) ..."
  docker compose -p "$BENCH" -f "$CFG" exec -T frontend \
    bash -lc 'export NODE_OPTIONS="--max_old_space_size=2048"; bench build --production' || true

  echo "🔁 Restarting core services ..."
  docker compose -p "$BENCH" -f "$CFG" restart frontend backend websocket queue-short queue-long scheduler || true

  echo "🔓 Disabling maintenance mode ..."
  docker compose -p "$BENCH" -f "$CFG" exec -T backend \
    bash -lc 'bench --site "'"$SITES"'" set-maintenance-mode off' || true

  echo
  echo "✅ Upgrade complete. Backups saved in: $HOST_BACKUP_DIR"
fi

# ----- Final info -----
echo
echo "====================================================="
echo " ERPNext stack is up (frontend -> port ${FRONT_HTTP_PORT})"
echo " Reverse proxy to: http://<ERPNext_server_ip>:${FRONT_HTTP_PORT}"
echo " Site: ${SITES}"
if [ "$INSTALL_MODE" = "fresh" ]; then
  echo " Installed apps: ${APPS}"
else
  echo " Upgrade mode. Installed apps unchanged (see: bench --site \"$SITES\" list-apps)."
fi
echo "====================================================="
