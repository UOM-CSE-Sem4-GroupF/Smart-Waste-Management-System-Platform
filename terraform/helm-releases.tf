# Group F — Smart Waste Management System
# Helm Releases + Bootstrap Manifests
# Owner: F4 Platform Team
#
# Deployment order (dependency chain):
#
#   EKS cluster → node group → EBS CSI add-on
#     → gp3 StorageClass (remove gp2 default)
#     → namespaces
#       → Kafka → topic-init Job
#       → Vault → vault-bootstrap Job
#       → Kong ConfigMap → Kong
#       → Keycloak realm ConfigMap → Keycloak
#       → EMQX (depends on Kafka for bridge) → emqx-bootstrap Job
#
# NOTE on bootstrap Jobs (Vault, EMQX, Kafka topics):
#   These are multi-document YAML files. Rather than fragile string-splitting
#   inside Terraform, they are applied via null_resource + local-exec kubectl.
#   The Jobs are one-shot (not tracked as Terraform state), which is correct
#   since they run once at deploy time and do not need lifecycle management.
#
# NOTE on Kafka SASL password:
#   Bitnami Kafka auto-generates a random SASL password if not set explicitly.
#   We pin it via set_sensitive so that:
#   (a) EMQX bootstrap script can use the same known value for the Kafka bridge
#   (b) Vault secret reflects the actual password other services will use
#   The password is in var.kafka_sasl_password (default: swms-kafka-dev-2026).

# ── gp3 StorageClass ──────────────────────────────────────────────────────────
# EKS ships with a gp2 default StorageClass. All Bitnami charts that request
# persistent storage would land on gp2. gp3 gives 20% better baseline IOPS
# at the same price, so we make it the cluster default.
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer" # Don't provision EBS until pod is scheduled to a node
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [
    aws_eks_addon.ebs_csi_driver,
    aws_eks_node_group.main,
  ]
}

# Remove the default annotation from the gp2 StorageClass that EKS creates.
# Having two default StorageClasses causes warnings and unpredictable PVC binding.
resource "kubernetes_annotations" "remove_gp2_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"

  metadata {
    name = "gp2"
  }

  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  depends_on = [aws_eks_node_group.main]
}

# ── KAFKA ─────────────────────────────────────────────────────────────────────
resource "helm_release" "kafka" {
  name       = "kafka"
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "kafka"
  namespace  = kubernetes_namespace.swms["messaging"].metadata[0].name
  timeout    = 600 # 10 min — Kafka KRaft startup is slow on first run

  values = [file("../messaging/kafka/values-dev.yaml")]

  # AWS storage override
  set {
    name  = "persistence.storageClass"
    value = "gp3"
  }
  set {
    name  = "controller.persistence.storageClass"
    value = "gp3"
  }

  # Pin the SASL password so EMQX bootstrap and Vault secret use the same value.
  # Without this Bitnami generates a random password on each fresh install.
  set {
    name  = "auth.sasl.jaas.clientUsers[0]"
    value = "user1"
  }
  set_sensitive {
    name  = "auth.sasl.jaas.clientPasswords[0]"
    value = var.kafka_sasl_password
  }
  # which constructs the correct advertised.listeners with the public hostname.
  depends_on = [
    kubernetes_storage_class.gp3,
    kubernetes_namespace.swms,
  ]
}

# Apply the Kafka topic-init Job.
# topics.yaml uses kubectl apply via null_resource because the file has duplicate
# initContainers keys (YAML last-key-wins quirk) that yamldecode() handles
# inconsistently across Terraform versions. kubectl apply is authoritative here.
resource "null_resource" "kafka_topic_init" {
  triggers = {
    kafka_release_id = helm_release.kafka.id
    topics_hash      = filemd5("../messaging/kafka/topics.yaml")
  }

  provisioner "local-exec" {
    command = "kubectl apply -f ../messaging/kafka/topics.yaml -n messaging"
  }

  depends_on = [helm_release.kafka]
}

# ── VAULT ─────────────────────────────────────────────────────────────────────
resource "helm_release" "vault" {
  name       = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  namespace  = kubernetes_namespace.swms["auth"].metadata[0].name
  timeout    = 300

  values = [file("../auth/vault/values-dev.yaml")]

  # On EKS there are no NodePorts — access Vault via cluster-internal DNS or
  # kubectl port-forward. The vault-policies bootstrap Job connects internally.
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }
  set {
    name  = "ui.serviceType"
    value = "ClusterIP"
  }

  depends_on = [
    kubernetes_namespace.swms,
    aws_eks_node_group.main,
  ]
}

# Apply vault-policies.yaml (ConfigMap + ServiceAccount + ClusterRoleBinding + Job).
# The Kafka password is replaced with the pinned value so Vault's stored secret
# matches what Kafka actually uses.
resource "null_resource" "vault_bootstrap" {
  triggers = {
    vault_release_id  = helm_release.vault.id
    policies_hash     = filemd5("../auth/vault/vault-policies.yaml")
    kafka_password    = var.kafka_sasl_password
  }

  provisioner "local-exec" {
    command = "powershell -Command \"(Get-Content ../auth/vault/vault-policies.yaml).Replace('swms-kafka-dev-2026', '${var.kafka_sasl_password}') | kubectl apply -f - -n auth\""
  }

  depends_on = [helm_release.vault]
}

# ── KONG ConfigMap ────────────────────────────────────────────────────────────
# Kong runs in DB-less mode: the entire gateway config lives in this ConfigMap.
# It MUST be applied before the Kong Helm release starts — Kong reads it at
# startup and will crash-loop if the ConfigMap is absent.
resource "kubernetes_config_map" "kong_declarative_config" {
  metadata {
    name      = "kong-declarative-config"
    namespace = kubernetes_namespace.swms["gateway"].metadata[0].name
    labels = {
      project     = "group-f-swms"
      "managed-by" = "f4-platform"
    }
  }

  # Extract the embedded kong.yaml string from the outer K8s ConfigMap YAML.
  # yamldecode parses the file; .data["kong.yaml"] is the multi-line string
  # containing the Kong declarative config.
  data = {
    "kong.yaml" = yamldecode(file("../gateway/kong/kong-config.yaml")).data["kong.yaml"]
  }

  depends_on = [kubernetes_namespace.swms]
}

# ── KONG ──────────────────────────────────────────────────────────────────────
resource "helm_release" "kong" {
  name       = "kong"
  repository = "https://charts.konghq.com"
  chart      = "kong"
  namespace  = kubernetes_namespace.swms["gateway"].metadata[0].name
  timeout    = 300

  values = [file("../gateway/kong/values-dev.yaml")]

  # Override NodePort → internet-facing AWS NLB
  set {
    name  = "proxy.type"
    value = "LoadBalancer"
  }
  # Dots in annotation keys must be escaped with \\. in Helm set paths
  # so Terraform does not interpret them as sub-key separators.
  set {
    name  = "proxy.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "nlb"
  }
  set {
    name  = "proxy.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }
  # Clear NodePort value from values-dev.yaml (ignored for LoadBalancer, avoids warnings)
  set {
    name  = "proxy.http.nodePort"
    value = ""
  }

  depends_on = [
    kubernetes_config_map.kong_declarative_config,
    kubernetes_namespace.swms,
  ]
}

# ── KEYCLOAK realm ConfigMap ──────────────────────────────────────────────────
# The realm-export.json is mounted into Keycloak at startup via extraVolumeMounts
# (configured in values-dev.yaml). The ConfigMap must exist before Keycloak starts
# or the import will silently fail and the waste-management realm won't be created.
resource "kubernetes_config_map" "keycloak_realm" {
  metadata {
    name      = "keycloak-realm-config"
    namespace = kubernetes_namespace.swms["auth"].metadata[0].name
    labels = {
      project     = "group-f-swms"
      "managed-by" = "f4-platform"
    }
  }

  data = {
    "waste-management-realm.json" = file("../auth/keycloak/realm-export.json")
  }

  depends_on = [kubernetes_namespace.swms]
}

# ── KEYCLOAK ──────────────────────────────────────────────────────────────────
resource "helm_release" "keycloak" {
  name       = "keycloak"
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "keycloak"
  namespace  = kubernetes_namespace.swms["auth"].metadata[0].name
  timeout    = 600 # 10 min — Keycloak + embedded Postgres startup is slow

  values = [file("../auth/keycloak/values-dev.yaml")]

  # Traffic routes through Kong — no direct external exposure needed
  set {
    name  = "service.type"
    value = "ClusterIP"
  }
  set {
    name  = "service.nodePorts.http"
    value = ""
  }

  # Bundled Postgres PVC uses gp3
  set {
    name  = "postgresql.primary.persistence.storageClass"
    value = "gp3"
  }

  depends_on = [
    kubernetes_config_map.keycloak_realm,
    kubernetes_storage_class.gp3,
    kubernetes_namespace.swms,
  ]
}

# ── EMQX ──────────────────────────────────────────────────────────────────────
resource "helm_release" "emqx" {
  name       = "emqx"
  repository = "https://repos.emqx.io/charts"
  chart      = "emqx"
  namespace  = kubernetes_namespace.swms["messaging"].metadata[0].name
  timeout    = 300

  values = [file("../messaging/emqx/values-dev.yaml")]

  # MQTT must be publicly reachable for ESP32 / Node-RED devices.
  # Override NodePort → internet-facing AWS NLB.
  set {
    name  = "service.type"
    value = "LoadBalancer"
  }
  set {
    name  = "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "nlb"
  }
  set {
    name  = "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }

  # PVC uses gp3
  set {
    name  = "persistence.storageClass"
    value = "gp3"
  }

  depends_on = [
    kubernetes_storage_class.gp3,
    kubernetes_namespace.swms,
    # EMQX needs Kafka to be ready before the bootstrap Job wires the bridge
    helm_release.kafka,
  ]
}

# Apply emqx-bootstrap.yaml (ConfigMap + ServiceAccount + Job).
# The hardcoded Kafka password in the bootstrap script is replaced with
# the pinned var.kafka_sasl_password so the Kafka bridge connects successfully.
resource "null_resource" "emqx_bootstrap" {
  triggers = {
    emqx_release_id  = helm_release.emqx.id
    bootstrap_hash   = filemd5("../messaging/emqx/emqx-bootstrap.yaml")
    kafka_password   = var.kafka_sasl_password
  }

  provisioner "local-exec" {
    command = "powershell -Command \"(Get-Content ../messaging/emqx/emqx-bootstrap.yaml).Replace('QA7aKGtPHV', '${var.kafka_sasl_password}') | kubectl apply -f - -n messaging\""
  }

  depends_on = [
    helm_release.emqx,
    null_resource.kafka_topic_init, # Bridge rules reference topics that must exist
  ]
}
