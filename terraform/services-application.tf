# Group F — F3 Application Services
# bin-status, notification, orchestrator, scheduler, frontend
# Owner: F3 Application Team

# ── KUBERNETES SECRETS ──────────────────────────────────────────────────────
# Fallback K8s Secret for services not yet reading from ESO/Vault directly.
# Values come from Terraform variables (never hardcoded here) — pass via
# terraform.tfvars or TF_VAR_* environment variables at apply time.
# Long term: retire this resource and let ESO pull from Vault paths:
#   swms/jwt → JWT_SECRET
#   swms/mapbox → MAPBOX_API_KEY
#   swms/postgres-waste → POSTGRES_PASSWORD
resource "kubernetes_secret" "application_secrets" {
  metadata {
    name      = "application-secrets"
    namespace = kubernetes_namespace.swms["waste-dev"].metadata[0].name
  }

  data = {
    "JWT_SECRET"        = var.jwt_secret
    "MAPBOX_API_KEY"    = var.mapbox_api_key
    "POSTGRES_PASSWORD" = var.postgres_password
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
