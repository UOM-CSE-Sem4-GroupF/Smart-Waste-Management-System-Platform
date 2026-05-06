# Group F — F3 Application Services
# bin-status, notification, orchestrator, scheduler, frontend
# Owner: F3 Application Team

# ── KUBERNETES SECRETS ──────────────────────────────────────────────────────
# These are manually managed secrets that aren't yet in Vault.
# In a real setup, ESO (External Secrets Operator) would pull these from Vault.
resource "kubernetes_secret" "application_secrets" {
  metadata {
    name      = "application-secrets"
    namespace = kubernetes_namespace.swms["waste-dev"].metadata[0].name
  }

  data = {
    # Placeholder secrets - to be rotated by Vault in Phase 2
    "JWT_SECRET"       = "swms-dev-jwt-secret-2026"
    "MAPBOX_API_KEY"   = "pk.placeholder.mapbox.key"
    "POSTGRES_PASSWORD" = "waste_admin_password"
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace.swms]
}

# ── GITHUB REPOSITORY ENVIRONMENTS ──────────────────────────────────────────
# Requires GITHUB_TOKEN to be set in environment
# resource "github_repository_environment" "application_prod" {
#   repository  = "group-f-application"
#   environment = "production"
# }

# resource "github_repository_environment" "application_dev" {
#   repository  = "group-f-application"
#   environment = "development"
# }
