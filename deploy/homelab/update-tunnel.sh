#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# update-tunnel.sh
#
# Run this after `docker compose ... up -d` any time cloudflared gets a new
# quick-tunnel URL.  It:
#   1. Waits for the new *.trycloudflare.com URL to appear in container logs
#   2. Patches my-laptop.env  (JOBHUNT_ALLOWED_HOSTS, JOBHUNT_CSRF_TRUSTED_ORIGINS)
#   3. Patches Vercel env var  BACKEND_INTERNAL_URL  via Vercel API
#   4. Restarts the Django container so it reads the updated ALLOWED_HOSTS
#   5. Triggers a new Vercel deployment so the BFF picks up the new URL
#
# Usage (from this directory, in WSL):
#   bash update-tunnel.sh
#
# Requirements in my-laptop.env:
#   VERCEL_TOKEN=your_vercel_api_token
#   VERCEL_PROJECT_ID=your_vercel_project_id   (looks like prj_xxxx)
#   VERCEL_TEAM_ID=your_team_id                (optional; only if using a team)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/my-laptop.env"
COMPOSE_FILE="$SCRIPT_DIR/my-laptop.compose.yml"

# ── Load env ──────────────────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌  $ENV_FILE not found. Copy my-laptop.env.example and fill it in."
  exit 1
fi
# shellcheck disable=SC2046
export $(grep -v '^#' "$ENV_FILE" | grep -v '^$' | xargs)

VERCEL_TOKEN="${VERCEL_TOKEN:-}"
VERCEL_PROJECT_ID="${VERCEL_PROJECT_ID:-}"
VERCEL_TEAM_ID="${VERCEL_TEAM_ID:-}"

if [[ -z "$VERCEL_TOKEN" || -z "$VERCEL_PROJECT_ID" ]]; then
  echo "❌  VERCEL_TOKEN and VERCEL_PROJECT_ID must be set in $ENV_FILE"
  echo "    Get your token at: https://vercel.com/account/tokens"
  echo "    Get project ID from: https://vercel.com/<you>/<project>/settings"
  exit 1
fi

COMPOSE_CMD="docker compose --env-file $ENV_FILE -f $COMPOSE_FILE"

# ── 1. Wait for the tunnel URL ────────────────────────────────────────────────
echo "⏳  Waiting for cloudflared to print its tunnel URL (up to 60s)..."
TUNNEL_URL=""
for i in $(seq 1 60); do
  TUNNEL_URL=$(
    $COMPOSE_CMD logs cloudflared 2>/dev/null \
    | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' \
    | tail -1
  )
  if [[ -n "$TUNNEL_URL" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$TUNNEL_URL" ]]; then
  echo "❌  Could not find a trycloudflare.com URL in cloudflared logs after 60s."
  echo "    Is the container running?  Try: $COMPOSE_CMD logs cloudflared"
  exit 1
fi

TUNNEL_HOST="${TUNNEL_URL#https://}"
echo "✅  New tunnel URL: $TUNNEL_URL  (host: $TUNNEL_HOST)"

# ── 2. Patch my-laptop.env ────────────────────────────────────────────────────
echo "📝  Updating $ENV_FILE ..."

# Replace old trycloudflare host in JOBHUNT_ALLOWED_HOSTS
# Keep any other entries (localhost, django, 127.0.0.1, custom domains)
OLD_HOST=$(grep '^JOBHUNT_ALLOWED_HOSTS=' "$ENV_FILE" \
  | grep -oE '[a-zA-Z0-9-]+\.trycloudflare\.com' | head -1 || true)

if [[ -n "$OLD_HOST" && "$OLD_HOST" != "$TUNNEL_HOST" ]]; then
  sed -i "s|${OLD_HOST}|${TUNNEL_HOST}|g" "$ENV_FILE"
  echo "   JOBHUNT_ALLOWED_HOSTS: replaced $OLD_HOST → $TUNNEL_HOST"
elif [[ -z "$OLD_HOST" ]]; then
  # No existing trycloudflare host — append to JOBHUNT_ALLOWED_HOSTS
  sed -i "s|^JOBHUNT_ALLOWED_HOSTS=\(.*\)|JOBHUNT_ALLOWED_HOSTS=\1,$TUNNEL_HOST|" "$ENV_FILE"
  echo "   JOBHUNT_ALLOWED_HOSTS: appended $TUNNEL_HOST"
else
  echo "   JOBHUNT_ALLOWED_HOSTS: already up to date"
fi

# Replace old trycloudflare URL in JOBHUNT_CSRF_TRUSTED_ORIGINS
OLD_CF_URL=$(grep '^JOBHUNT_CSRF_TRUSTED_ORIGINS=' "$ENV_FILE" \
  | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | head -1 || true)

if [[ -n "$OLD_CF_URL" && "$OLD_CF_URL" != "$TUNNEL_URL" ]]; then
  sed -i "s|${OLD_CF_URL}|${TUNNEL_URL}|g" "$ENV_FILE"
  echo "   JOBHUNT_CSRF_TRUSTED_ORIGINS: replaced $OLD_CF_URL → $TUNNEL_URL"
elif [[ -z "$OLD_CF_URL" ]]; then
  sed -i "s|^JOBHUNT_CSRF_TRUSTED_ORIGINS=\(.*\)|JOBHUNT_CSRF_TRUSTED_ORIGINS=\1,$TUNNEL_URL|" "$ENV_FILE"
  echo "   JOBHUNT_CSRF_TRUSTED_ORIGINS: appended $TUNNEL_URL"
else
  echo "   JOBHUNT_CSRF_TRUSTED_ORIGINS: already up to date"
fi

# ── 3. Update Vercel env var ──────────────────────────────────────────────────
echo "🔧  Patching Vercel BACKEND_INTERNAL_URL → $TUNNEL_URL ..."

TEAM_PARAM=""
if [[ -n "$VERCEL_TEAM_ID" ]]; then
  TEAM_PARAM="?teamId=$VERCEL_TEAM_ID"
fi

# Upsert env var (creates if missing, updates if it exists)
# target=["production","preview"] covers both Vercel environments
VERCEL_API_RESPONSE=$(curl -sf -X PATCH \
  "https://api.vercel.com/v9/projects/${VERCEL_PROJECT_ID}/env${TEAM_PARAM}" \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d "[{
    \"key\": \"BACKEND_INTERNAL_URL\",
    \"value\": \"$TUNNEL_URL\",
    \"type\": \"plain\",
    \"target\": [\"production\", \"preview\"]
  }]" 2>&1 || true)

# If PATCH (upsert) fails, the var might not exist yet — try POST
if echo "$VERCEL_API_RESPONSE" | grep -q '"error"'; then
  echo "   (PATCH failed, trying POST to create...)"
  VERCEL_API_RESPONSE=$(curl -sf -X POST \
    "https://api.vercel.com/v10/projects/${VERCEL_PROJECT_ID}/env${TEAM_PARAM}" \
    -H "Authorization: Bearer $VERCEL_TOKEN" \
    -H "Content-Type: application/json" \
    -d "[{
      \"key\": \"BACKEND_INTERNAL_URL\",
      \"value\": \"$TUNNEL_URL\",
      \"type\": \"plain\",
      \"target\": [\"production\", \"preview\"]
    }]" 2>&1 || true)
fi

echo "   Vercel API response: $VERCEL_API_RESPONSE" | head -3
echo "✅  Vercel env updated."

# ── 4. Restart Django to pick up new ALLOWED_HOSTS ───────────────────────────
echo "🔄  Restarting Django container with updated env..."
$COMPOSE_CMD up -d --force-recreate django
echo "✅  Django restarted."

# ── 5. Trigger Vercel redeploy ────────────────────────────────────────────────
echo "🚀  Triggering Vercel redeploy..."

# Get the latest deployment ID for the production environment
LATEST_DEPLOY=$(curl -sf \
  "https://api.vercel.com/v6/deployments?projectId=${VERCEL_PROJECT_ID}&target=production&limit=1${VERCEL_TEAM_ID:+&teamId=$VERCEL_TEAM_ID}" \
  -H "Authorization: Bearer $VERCEL_TOKEN" 2>/dev/null \
  | grep -o '"uid":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

if [[ -n "$LATEST_DEPLOY" ]]; then
  REDEPLOY_RESPONSE=$(curl -sf -X POST \
    "https://api.vercel.com/v13/deployments?forceNew=1${VERCEL_TEAM_ID:+&teamId=$VERCEL_TEAM_ID}" \
    -H "Authorization: Bearer $VERCEL_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"deploymentId\": \"$LATEST_DEPLOY\"}" 2>/dev/null || true)
  echo "✅  Redeploy triggered (deployment: $LATEST_DEPLOY)"
else
  echo "⚠️   Could not find a production deployment to redeploy."
  echo "    Go to vercel.com → your project → Deployments → Redeploy manually."
fi

echo ""
echo "════════════════════════════════════════════════════════"
echo "  Done! New tunnel: $TUNNEL_URL"
echo "  Vercel will redeploy in ~30s. Watch at:"
echo "  https://vercel.com/dashboard"
echo "════════════════════════════════════════════════════════"
