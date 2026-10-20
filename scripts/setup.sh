#!/usr/bin/env bash
# One-time Cloudflare resource bootstrap for self-hosting this CRM.
#
# Idempotent: safe to re-run. Reuses anything that already exists (by
# name) instead of erroring, and only writes into wrangler.jsonc the
# fields that are still placeholders.
#
# Requires: `wrangler login` already done (checked below), Node + pnpm.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

WORKER_DIR="apps/worker"
WEB_DIR="apps/web"
WORKER_CONFIG="$WORKER_DIR/wrangler.jsonc"
WEB_CONFIG="$WEB_DIR/wrangler.jsonc"
DB_NAME="whatsapp-ai"
MEDIA_BUCKET="whatsapp-ai-media"
QUEUE_NAME="wa-broadcast-dispatch"
VECTORIZE_INDEX="wa-messages"
AGENT_VECTORIZE_INDEX="wa-docs"
KV_BINDING="REPLY_CACHE"
SECRET_FILE=""

cleanup() {
  if [ -n "$SECRET_FILE" ] && [ -f "$SECRET_FILE" ]; then
    rm -f "$SECRET_FILE"
  fi
}
trap cleanup EXIT

# Create wrangler.jsonc / .env.production from the templates if missing.
node scripts/config.mjs

# wrangler is a devDependency of apps/worker and apps/web, not the repo
# root, so every invocation below runs from inside apps/worker (never a
# bare `pnpm exec wrangler` at the repo root).
wrangler() { (cd "$WORKER_DIR" && pnpm exec wrangler "$@"); }

echo "==> Checking Cloudflare auth..."
if ! wrangler whoami >/dev/null 2>&1; then
  echo "Not logged in. Run '(cd apps/worker && pnpm exec wrangler login)' first, then re-run this script." >&2
  exit 1
fi

# ── D1 database (shared by both Workers) ────────────────────────────────
echo "==> D1 database ($DB_NAME)..."
CURRENT_DB_ID=$(grep -A2 '"d1_databases"' "$WORKER_CONFIG" | grep -o '"database_id": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
if [ "$CURRENT_DB_ID" = "REPLACE_WITH_D1_DATABASE_ID" ] || [ -z "$CURRENT_DB_ID" ]; then
  EXISTING=$(wrangler d1 list --json 2>/dev/null | node -e "
    let s = '';
    process.stdin.on('data', (d) => { s += d; });
    process.stdin.on('end', () => {
      try {
        const list = JSON.parse(s);
        const db = list.find((d) => d.name === '$DB_NAME');
        if (db) console.log(db.uuid);
      } catch {}
    });
  ")

  if [ -n "${EXISTING:-}" ]; then
    DB_ID="$EXISTING"
    echo "    found existing database, id=$DB_ID"
  else
    wrangler d1 create "$DB_NAME" >/dev/null
    DB_ID=$(wrangler d1 list --json 2>/dev/null | node -e "
      let s = '';
      process.stdin.on('data', (d) => { s += d; });
      process.stdin.on('end', () => {
        const db = JSON.parse(s).find((d) => d.name === '$DB_NAME');
        if (db) console.log(db.uuid);
      });
    ")
    if [ -z "$DB_ID" ]; then
      echo "Could not resolve the id of the newly created D1 database." >&2
      exit 1
    fi
    echo "    created database, id=$DB_ID"
  fi

  node -e "
    const fs = require('fs');
    for (const path of ['$WORKER_CONFIG', '$WEB_CONFIG']) {
      let src = fs.readFileSync(path, 'utf8');
      src = src.replace(/\"database_id\": *\"[^\"]*\"/, '\"database_id\": \"$DB_ID\"');
      fs.writeFileSync(path, src);
    }
  "
else
  DB_ID="$CURRENT_DB_ID"
  echo "    already configured, id=$DB_ID"
fi

# ── R2 bucket (media) ────────────────────────────────────────────────────
echo "==> R2 bucket ($MEDIA_BUCKET)..."
if wrangler r2 bucket list 2>/dev/null | grep -q "$MEDIA_BUCKET"; then
  echo "    already exists"
else
  wrangler r2 bucket create "$MEDIA_BUCKET"
fi

# ── Queue (safe-broadcast dispatch) ──────────────────────────────────────
echo "==> Queue ($QUEUE_NAME)..."
if wrangler queues list 2>/dev/null | grep -q "$QUEUE_NAME"; then
  echo "    already exists"
else
  wrangler queues create "$QUEUE_NAME"
fi

# ── Vectorize indexes (semantic search + agent RAG) ──────────────────────
for INDEX in "$VECTORIZE_INDEX" "$AGENT_VECTORIZE_INDEX"; do
  echo "==> Vectorize index ($INDEX)..."
  if wrangler vectorize list 2>/dev/null | grep -q "$INDEX"; then
    echo "    already exists"
  else
    wrangler vectorize create "$INDEX" --dimensions=1024 --metric=cosine
  fi
done

# ── KV namespace (AI agent reply cache) ──────────────────────────────────
echo "==> KV namespace ($KV_BINDING)..."
CURRENT_KV_ID=$(grep -A2 '"kv_namespaces"' "$WORKER_CONFIG" | grep -o '"id": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
if [ "$CURRENT_KV_ID" = "REPLACE_WITH_KV_NAMESPACE_ID" ] || [ -z "$CURRENT_KV_ID" ]; then
  if ! wrangler kv namespace list 2>/dev/null | grep -q "\"title\": *\"$KV_BINDING\""; then
    wrangler kv namespace create "$KV_BINDING" >/dev/null
    echo "    created namespace"
  else
    echo "    found existing namespace"
  fi
  KV_ID=$(wrangler kv namespace list 2>/dev/null | node -e "
    let s = '';
    process.stdin.on('data', (d) => { s += d; });
    process.stdin.on('end', () => {
      try {
        const list = JSON.parse(s);
        const ns = list.find((n) => n.title === '$KV_BINDING');
        if (ns) console.log(ns.id);
      } catch {}
    });
  ")
  if [ -n "${KV_ID:-}" ]; then
    node -e "
      const fs = require('fs');
      let src = fs.readFileSync('$WORKER_CONFIG', 'utf8');
      src = src.replace(/(\"kv_namespaces\"[\s\S]*?\"id\": *)\"[^\"]*\"/, '\$1\"$KV_ID\"');
      fs.writeFileSync('$WORKER_CONFIG', src);
    "
    echo "    wrote id into $WORKER_CONFIG"
  else
    echo "    WARNING: could not resolve KV namespace id — set it manually in $WORKER_CONFIG" >&2
  fi
else
  echo "    already configured, id=$CURRENT_KV_ID"
fi

# ── Run D1 migrations (remote) ───────────────────────────────────────────
echo "==> Applying D1 migrations..."
CI=true wrangler d1 migrations apply "$DB_NAME" --remote

# ── Auth secret ───────────────────────────────────────────────────────────
secret_exists() {
  local app_dir="$1"
  local name="$2"
  (cd "$app_dir" && pnpm exec wrangler secret list 2>/dev/null | grep -q "\"name\": \"$name\"")
}

put_generated_secret() {
  local name="$1"
  shift
  SECRET_FILE=$(mktemp)
  chmod 600 "$SECRET_FILE"
  node -e "process.stdout.write(require('crypto').randomBytes(32).toString('hex'))" >"$SECRET_FILE"
  for app_dir in "$@"; do
    (cd "$app_dir" && pnpm exec wrangler secret put "$name" <"$SECRET_FILE")
  done
  rm -f "$SECRET_FILE"
  SECRET_FILE=""
}

echo "==> Better Auth secret..."
if secret_exists "$WEB_DIR" "BETTER_AUTH_SECRET"; then
  echo "    already set"
else
  put_generated_secret "BETTER_AUTH_SECRET" "$WEB_DIR"
  echo "    generated and set a new secret"
fi

# ── WebSocket token secret ────────────────────────────────────────────────
# Signs/verifies the short-lived token the browser presents when opening a
# WebSocket to the engine's /ws endpoint (GET /session/:id/ws-token mints
# it, apps/worker/src/session/whatsapp-session.ts verifies it). Must be the
# SAME value in both apps — generate it once here and set it in both.
echo "==> WebSocket token secret (WS_TOKEN_SECRET)..."
if secret_exists "$WEB_DIR" "WS_TOKEN_SECRET" && secret_exists "$WORKER_DIR" "WS_TOKEN_SECRET"; then
  echo "    already set"
else
  put_generated_secret "WS_TOKEN_SECRET" "$WEB_DIR" "$WORKER_DIR"
  echo "    generated and set a new secret in both apps"
fi

# ── Engine internal secret (web -> engine auth) ──────────────────────────
echo "==> Engine internal secret (ENGINE_INTERNAL_SECRET)..."
if secret_exists "$WEB_DIR" "ENGINE_INTERNAL_SECRET" && secret_exists "$WORKER_DIR" "ENGINE_INTERNAL_SECRET"; then
  echo "    already set"
else
  put_generated_secret "ENGINE_INTERNAL_SECRET" "$WEB_DIR" "$WORKER_DIR"
  echo "    generated and set a new secret in both apps"
fi

# ── Validate BETTER_AUTH_URL ──────────────────────────────────────────────
echo "==> Validating BETTER_AUTH_URL..."
AUTH_URL=$(grep -o '"BETTER_AUTH_URL": *"[^"]*"' "$WEB_CONFIG" | sed 's/.*"\([^"]*\)"$/\1/')
if [ "$AUTH_URL" = "http://localhost:3000" ]; then
  echo ""
  echo "  WARNING: BETTER_AUTH_URL is still set to http://localhost:3000" >&2
  echo "  Update it in $WEB_CONFIG to your production URL before deploying." >&2
  echo "  Example: \"BETTER_AUTH_URL\": \"https://app.yourdomain.com\"" >&2
  echo ""
fi

# ── Validate Resend from-email ────────────────────────────────────────────
echo "==> Validating RESEND_FROM_EMAIL..."
RESEND_FROM=$(grep -o '"RESEND_FROM_EMAIL": *"[^"]*"' "$WEB_CONFIG" | sed 's/.*"\([^"]*\)"$/\1/')
if [ "$RESEND_FROM" = "onboarding@resend.dev" ]; then
  echo ""
  echo "  WARNING: RESEND_FROM_EMAIL is still set to onboarding@resend.dev (sandbox mode)." >&2
  echo "  Invitation emails will fail silently in production." >&2
  echo "  Update it in $WEB_CONFIG to a domain you've verified with Resend." >&2
  echo ""
fi

echo ""
echo "Setup complete. Next: set your URLs (BETTER_AUTH_URL in $WEB_CONFIG, CORS_ORIGIN in $WORKER_CONFIG,"
echo "VITE_ENGINE_URL in both $WEB_CONFIG and $WEB_DIR/.env.production), then run 'pnpm run deploy'."
