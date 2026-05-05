# Group F — F2 Application Services
# PostgreSQL, InfluxDB, and Flink Processor
# Owner: F2 Data Analysis Team

# ── POSTGRESQL (Waste DB) ───────────────────────────────────────────────────
resource "kubernetes_config_map" "postgres_init_scripts" {
  metadata {
    name      = "postgres-init-scripts"
    namespace = kubernetes_namespace.swms["waste-dev"].metadata[0].name
  }

  data = {
    # CORRECTED: Pointing to the v3 schema in the root of DataAnalysis repo
    "init.sql" = file("../../Smart-Waste-Management-System-DataAnalysis/database-schema-v3 (2).sql")
  }

  depends_on = [kubernetes_namespace.swms]
}

resource "helm_release" "postgres_waste" {
  name       = "postgres-waste"
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "postgresql"
  namespace  = kubernetes_namespace.swms["waste-dev"].metadata[0].name
  version    = "15.5.3"

  set {
    name  = "auth.database"
    value = "waste_management"
  }
  set {
    name  = "auth.username"
    value = "waste_admin"
  }
  set {
    name  = "auth.password"
    value = "waste_admin_password"
  }
  set {
    name  = "primary.persistence.storageClass"
    value = "do-block-storage" # CORRECTED for DigitalOcean
  }
  set {
    name  = "primary.initdb.scriptsConfigMap"
    value = kubernetes_config_map.postgres_init_scripts.metadata[0].name
  }

  depends_on = [
    kubernetes_namespace.swms,
    kubernetes_config_map.postgres_init_scripts
  ]
}

# ── INFLUXDB ──────────────────────────────────────────────────────────────────
resource "helm_release" "influxdb" {
  name       = "influxdb"
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "influxdb"
  namespace  = kubernetes_namespace.swms["waste-dev"].metadata[0].name
  version    = "5.2.4"

  set {
    name  = "auth.admin.username"
    value = "admin"
  }
  set {
    name  = "auth.admin.password"
    value = "admin12345"
  }
  set {
    name  = "auth.admin.token"
    value = "my-super-token"
  }
  set {
    name  = "auth.admin.org"
    value = "waste-org"
  }
  set {
    name  = "auth.admin.bucket"
    value = "waste-bootstrap"
  }
  set {
    name  = "persistence.storageClass"
    value = "do-block-storage" # CORRECTED for DigitalOcean
  }

  depends_on = [
    kubernetes_namespace.swms
  ]
}

  depends_on = [
    kubernetes_namespace.swms
  ]
}

