# Argo CD Helm release for DOKS
# Non-destructive: uses Helm provider and `create_namespace = true` 

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "cicd"
  create_namespace = true
  timeout          = 600

  values = [<<EOF
server:
  service:
    type: LoadBalancer
    port: 80
controller:
  replicaCount: 1
EOF
  ]

  depends_on = []
}
