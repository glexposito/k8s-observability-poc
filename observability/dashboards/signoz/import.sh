#!/bin/sh
# Imports every dashboard JSON in $DASHBOARD_DIR into SigNoz through its v2 API.
# Run by the signoz-dashboards-import Job (job.yaml) after each Argo CD sync.
#
# Idempotent: each file carries a fixed, immutable `name`. An existing dashboard
# with that name is unlocked, fully replaced (PUT) and locked again; a missing
# one is created (POST) and locked. Locking keeps the UI read-only, so git
# stays the source of truth.
set -eu

BASE="${SIGNOZ_URL:-http://signoz.signoz.svc.cluster.local:8080}"
DIR="${DASHBOARD_DIR:-/dashboards}"

apk add --no-cache -q curl jq

# curl that fails on HTTP errors but still prints the response body.
api() { curl -sS --fail-with-body -H 'Content-Type: application/json' "$@"; }

echo "Waiting for SigNoz at $BASE ..."
until curl -sf "$BASE/api/v1/health" >/dev/null; do sleep 5; done

# SigNoz creates the root user (signoz_user_root_* in observability/signoz/
# values.yaml) asynchronously after start, so retry the login for a while.
token=""
for attempt in $(seq 1 60); do
  org_id=$(curl -sf -G "$BASE/api/v2/sessions/context" \
             --data-urlencode "email=$SIGNOZ_EMAIL" --data-urlencode "ref=$BASE" \
           | jq -r '.data.orgs[0].id // empty' || true)
  if [ -n "$org_id" ]; then
    token=$(jq -n --arg e "$SIGNOZ_EMAIL" --arg p "$SIGNOZ_PASSWORD" --arg o "$org_id" \
              '{email: $e, password: $p, orgId: $o}' \
            | curl -sf -H 'Content-Type: application/json' -d @- "$BASE/api/v2/sessions/email_password" \
            | jq -r '.data.accessToken // empty' || true)
    [ -n "$token" ] && break
  fi
  echo "Login not ready yet (attempt $attempt/60), retrying in 10s ..."
  sleep 10
done
if [ -z "$token" ]; then
  echo "Could not log in as $SIGNOZ_EMAIL. If SigNoz was set up through its sign-up"
  echo "page before the root user existed, reset it: docker compose down -v" >&2
  exit 1
fi
auth="Authorization: Bearer $token"

existing=$(api -H "$auth" "$BASE/api/v2/dashboards?limit=200")

for file in "$DIR"/*.json; do
  name=$(jq -r '.name' "$file")
  id=$(echo "$existing" | jq -r --arg n "$name" '.data.dashboards[] | select(.name == $n) | .id' | head -1)
  if [ -n "$id" ]; then
    echo "Updating $name ($id)"
    curl -sS -o /dev/null -X DELETE -H "$auth" "$BASE/api/v2/dashboards/$id/lock" || true
    jq '{name, schemaVersion, spec, tags, image: (.image // "")}' "$file" \
      | api -X PUT -H "$auth" -d @- "$BASE/api/v2/dashboards/$id" >/dev/null
  else
    echo "Creating $name"
    id=$(api -X POST -H "$auth" -d @"$file" "$BASE/api/v2/dashboards" | jq -r '.data.id')
  fi
  api -X PUT -H "$auth" "$BASE/api/v2/dashboards/$id/lock" >/dev/null
  echo "  locked $name"
done
echo "Done."
