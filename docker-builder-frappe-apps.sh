#!/bin/bash
set -euo pipefail


echo "Generate base64 string from json file"
# Determine the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Read apps.json from the same directory as the script and generate base64 string
export APPS_JSON_BASE64=$(base64 -w 0 "${SCRIPT_DIR}/apps.json")

# Clone frappe_docker repository
cd "$HOME"
# Clone or update frappe_docker repository
if [ -d frappe_docker ]; then
  echo "📦 frappe_docker directory already exists — updating..."
  (
    cd frappe_docker
    git fetch --all --prune
    git reset --hard origin/main
    git pull --rebase
  )
else
  echo "📥 Cloning frappe_docker repository..."
  git clone https://github.com/frappe/frappe_docker
fi

cd $HOME/frappe_docker

# Try to extract ERPNext image tag (e.g. v15.82.1) from pwd.yml and export it
PWD_YML="$HOME/frappe_docker/pwd.yml"

if [ -f "$PWD_YML" ]; then
    # Find the line containing the ERPNext image tag
    # Example match: image: frappe/erpnext:v15.82.1
    ERPNEXT_IMAGE_LINE=$(grep -E '^\s*image:\s*["'\''"]?frappe/erpnext:[^"'\'' ]+' "$PWD_YML" | head -n 1 || true)

    if [ -n "$ERPNEXT_IMAGE_LINE" ]; then
        # Extract version tag (e.g., v15.82.1 or 15.82.1)
        FRAPPE_ERPNEXT_VERSION=$(echo "$ERPNEXT_IMAGE_LINE" | sed -E 's/.*frappe\/erpnext:[[:space:]]*["'\''"]?([vV]?[0-9][^"'\'' ]*).*/\1/')
        export FRAPPE_ERPNEXT_VERSION
        echo "✅ Detected ERPNext version: $FRAPPE_ERPNEXT_VERSION"
    else
        echo "⚠️ No frappe/erpnext image line found in $PWD_YML"
    fi
else
    echo "❌ File not found: $PWD_YML — skipping ERPNext version extraction"
fi

# Build and push docker image
echo "🚀 Build docker image"
cd $HOME/frappe_docker

# Use detected ERPNext version as image tag, and fail if not set
if [ -z "${FRAPPE_ERPNEXT_VERSION:-}" ]; then
  echo "❌ FRAPPE_ERPNEXT_VERSION is not set. Cannot determine image tag."
  echo "   Please export FRAPPE_ERPNEXT_VERSION before running this script."
  echo "   Example: export FRAPPE_ERPNEXT_VERSION=v15.81.2"
  exit 1
fi

# If GHCR_USER is provided (non-empty), use it. Otherwise prompt.
if [ "${GHCR_USER:-}" = "" ]; then
  echo
  read -rp "Enter your GHCR username (user or org, e.g., abc101): " GHCR_USER
fi

if [ -z "$GHCR_USER" ]; then
  echo "❌ GHCR username cannot be empty. Aborting."
  exit 1
fi

IMAGE_TAG="${FRAPPE_ERPNEXT_VERSION}"
IMAGE_NAME="${IMAGE_NAME:-frappe-custom-apps}"
FULL_IMAGE="ghcr.io/${GHCR_USER}/${IMAGE_NAME}:${IMAGE_TAG}"
echo
echo "================ Build Plan ================"
echo " Image : ${FULL_IMAGE}"
echo " Tag   : ${IMAGE_TAG}"
echo "==========================================="

docker build   \
	--platform=linux/amd64   \
	--build-arg=FRAPPE_PATH=https://github.com/frappe/frappe   \
	--build-arg=FRAPPE_BRANCH=version-15   \
	--build-arg=PYTHON_VERSION=3.11.9   \
	--build-arg=NODE_VERSION=20.19.2   \
	--build-arg=APPS_JSON_BASE64=$APPS_JSON_BASE64   \
	--tag=ghcr.io/abc101/frappe-custom-apps:${IMAGE_TAG}   \
	--file=images/custom/Containerfile .

echo "✅ Build completed: ${FULL_IMAGE}"

# --- Confirm push (or auto-push if PUSH=yes) ---
PUSH="${PUSH:-}"
if [ "$PUSH" = "yes" ] || [ "$PUSH" = "true" ]; then
  CONFIRM="y"
else
  echo
  read -rp "Do you want to push ${FULL_IMAGE} to GHCR? [y/N]: " CONFIRM
fi

if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo
  echo "🚀 Pushing image to GHCR..."
  docker push "${FULL_IMAGE}"
  echo "✅ Image pushed successfully: ${FULL_IMAGE}"
else
  echo "⏹  Push skipped."
fi

# --- Print final reminder for CI automation ---
echo
echo "Tip: run non-interactively with:"
echo "  GHCR_USER=${GHCR_USER} PUSH=yes ./docker-builder.sh"
