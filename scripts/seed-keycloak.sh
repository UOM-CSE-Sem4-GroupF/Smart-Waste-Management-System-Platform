#!/usr/bin/env bash
# Group F SWMS — Keycloak Test User Seeding Script
# Creates all test users, assigns roles, and sets custom attributes.
# Safe to re-run — uses "get or create" pattern.
#
# Prerequisites: Keycloak must be running and accessible.
# Usage: bash ./scripts/seed-keycloak.sh [KEYCLOAK_URL]
#
# Default URL uses minikube NodePort. Override for DOKS:
#   bash ./scripts/seed-keycloak.sh http://<DOKS-LB-IP>

set -euo pipefail

KEYCLOAK_URL="${1:-http://localhost:30180}"
REALM="waste-management"
ADMIN_USER="admin"
ADMIN_PASS="swms-admin-dev-2026"
CLIENT_ID="admin-cli"

echo "======================================================"
echo " SWMS — Keycloak User Seeding"
echo " URL:   $KEYCLOAK_URL"
echo " Realm: $REALM"
echo "======================================================"

# ── Get admin token ────────────────────────────────────────────────────────
echo ""
echo "[1/3] Authenticating as admin..."
TOKEN=$(curl -sf \
  -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=${CLIENT_ID}&username=${ADMIN_USER}&password=${ADMIN_PASS}&grant_type=password" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ]; then
  echo "ERROR: Failed to get admin token. Is Keycloak running at ${KEYCLOAK_URL}?"
  exit 1
fi
echo "  ✅ Token obtained."

BASE="${KEYCLOAK_URL}/admin/realms/${REALM}"

# ── Helper: create user if not exists ─────────────────────────────────────
create_user() {
  local USERNAME="$1"
  local EMAIL="$2"
  local FIRST="$3"
  local LAST="$4"
  local PASSWORD="$5"
  local ROLE="$6"
  local EXTRA_ATTRS="${7:-}"

  echo ""
  echo "  Creating user: $USERNAME ($ROLE)..."

  # Check if exists
  EXISTING=$(curl -sf \
    -H "Authorization: Bearer $TOKEN" \
    "${BASE}/users?username=${USERNAME}" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")

  if [ -n "$EXISTING" ]; then
    echo "    ⚠️  Already exists (id=$EXISTING) — skipping create, updating role."
    USER_ID="$EXISTING"
  else
    # Create user
    ATTRS='"enabled":true,"emailVerified":true'
    [ -n "$EXTRA_ATTRS" ] && ATTRS="${ATTRS},${EXTRA_ATTRS}"
    curl -sf -o /dev/null \
      -X POST "${BASE}/users" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"${USERNAME}\",\"email\":\"${EMAIL}\",\"firstName\":\"${FIRST}\",\"lastName\":\"${LAST}\",${ATTRS}}"

    USER_ID=$(curl -sf \
      -H "Authorization: Bearer $TOKEN" \
      "${BASE}/users?username=${USERNAME}" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    # Set password
    curl -sf -o /dev/null \
      -X PUT "${BASE}/users/${USER_ID}/reset-password" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"type\":\"password\",\"value\":\"${PASSWORD}\",\"temporary\":false}"

    echo "    ✅ Created (id=$USER_ID)"
  fi

  # Assign realm role
  ROLE_ID=$(curl -sf \
    -H "Authorization: Bearer $TOKEN" \
    "${BASE}/roles/${ROLE}" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")

  if [ -n "$ROLE_ID" ]; then
    curl -sf -o /dev/null \
      -X POST "${BASE}/users/${USER_ID}/role-mappings/realm" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "[{\"id\":\"${ROLE_ID}\",\"name\":\"${ROLE}\"}]" || true
    echo "    ✅ Role '$ROLE' assigned."
  else
    echo "    ⚠️  Role '$ROLE' not found in realm."
  fi
}

# ── Create test users ──────────────────────────────────────────────────────
echo ""
echo "[2/3] Creating test users..."

create_user "admin-user"      "admin@swms-dev.local"      "Admin"      "User"       "Test1234!" "admin"
create_user "supervisor-user" "supervisor@swms-dev.local" "Supervisor" "User"       "Test1234!" "supervisor"
create_user "operator-user"   "operator@swms-dev.local"   "Operator"   "User"       "Test1234!" "fleet-operator"
create_user "driver-user"     "driver@swms-dev.local"     "Driver"     "User"       "Test1234!" "driver" \
  '"attributes":{"zone_id":["1"],"current_vehicle_id":["LORRY-01"],"employee_id":["EMP-001"]}'

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "[3/3] Done."
echo ""
echo "======================================================"
echo " ✅ Test users seeded in realm: $REALM"
echo ""
echo "  Username         Password    Role"
echo "  admin-user       Test1234!   admin"
echo "  supervisor-user  Test1234!   supervisor"
echo "  operator-user    Test1234!   fleet-operator"
echo "  driver-user      Test1234!   driver"
echo ""
echo " Login at: ${KEYCLOAK_URL}/realms/${REALM}/account"
echo "======================================================"
