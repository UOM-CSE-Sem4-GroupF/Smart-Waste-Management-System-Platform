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
  
  # Automatically bootstrap the platform project and root application!
  # This eliminates the need to run `kubectl apply -f root-app.yaml`
  additionalProjects:
    - name: platform
      namespace: cicd
      description: Platform infrastructure components
      sourceRepos:
        - '*'
      destinations:
        - server: https://kubernetes.default.svc
          namespace: '*'
      clusterResourceWhitelist:
        - group: '*'
          kind: '*'
      namespaceResourceWhitelist:
        - group: '*'
          kind: '*'

  additionalApplications:
    - name: root
      namespace: cicd
      project: platform
      source:
        repoURL: https://github.com/UOM-CSE-Sem4-GroupF/group-f-platform
        targetRevision: main
        path: cicd/applications
        directory:
          recurse: true
          include: "*.yaml"
      destination:
        server: https://kubernetes.default.svc
        namespace: cicd
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=false
          - ServerSideApply=true

controller:
  replicaCount: 1
EOF
  ]

  depends_on = [kubernetes_namespace.swms]
}

