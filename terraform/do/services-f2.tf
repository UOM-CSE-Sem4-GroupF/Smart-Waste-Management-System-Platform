# Group F — F2 Application Services (DigitalOcean)
# PostgreSQL, InfluxDB, and Flink Processor
# Owner: F2 Data Analysis Team
#
# NOTE: Application deployments (Helm releases) have been migrated to Argo CD
# for strict GitOps separation. See cicd/applications/ for the manifests.

# ── POSTGRESQL (Waste DB) INIT SCRIPT ───────────────────────────────────────
resource "kubernetes_config_map" "postgres_init_scripts" {
  metadata {
    name      = "postgres-init-scripts"
    namespace = kubernetes_namespace.swms["waste-dev"].metadata[0].name
  }

  data = {
    # Pointing to the v3 schema in the root of DataAnalysis repo
    "init.sql" = file("../../../Smart-Waste-Management-System-DataAnalysis/database-schema-v3 (2).sql")
  }

  depends_on = [kubernetes_namespace.swms]
}

