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

# ── FLINK PROCESSOR ──────────────────────────────────────────────────────────
resource "helm_release" "flink_processor" {
  name      = "flink-processor"
  chart     = "../helm/charts/base-service"
  namespace = kubernetes_namespace.swms["waste-dev"].metadata[0].name

  set {
    name  = "image.repository"
    value = "ghcr.io/uom-cse-sem4-groupf/flink-processor"
  }
  set {
    name  = "image.tag"
    value = "latest"
  }

  # Probes disabled because flink-processor is a consumer, not a web server
  set {
    name  = "livenessProbe.enabled"
    value = "false"
  }
  set {
    name  = "readinessProbe.enabled"
    value = "false"
  }

  # Environment Variables
  set {
    name  = "env.APP_ENV"
    value = "dev"
  }
  set {
    name  = "env.KAFKA_BOOTSTRAP_SERVERS"
    value = "kafka.messaging.svc.cluster.local:9092"
  }
  set {
    name  = "env.KAFKA_USERNAME"
    value = "user1"
  }
  set {
    name  = "env.KAFKA_PASSWORD"
    value = var.kafka_sasl_password
  }
  set {
    name  = "env.POSTGRES_HOST"
    value = "postgres-waste-postgresql.waste-dev.svc.cluster.local"
  }
  set {
    name  = "env.POSTGRES_PORT"
    value = "5432"
  }
  set {
    name  = "env.POSTGRES_DB"
    value = "waste_management"
  }
  set {
    name  = "env.POSTGRES_USER"
    value = "waste_admin"
  }
  set {
    name  = "env.POSTGRES_PASSWORD"
    value = "waste_admin_password"
  }
  set {
    name  = "env.POSTGRES_SCHEMA"
    value = "f2" # ADDED: Required for v3 schema
  }
  set {
    name  = "env.INFLUX_URL"
    value = "http://influxdb.waste-dev.svc.cluster.local:8086"
  }
  set {
    name  = "env.INFLUX_ORG"
    value = "waste-org"
  }
  set {
    name  = "env.INFLUX_TOKEN"
    value = "my-super-token"
  }
  set {
    name  = "env.INFLUX_ENABLED"
    value = "true"
  }

  depends_on = [
    helm_release.postgres_waste,
    helm_release.influxdb
  ]
}

