controlPlane:
  distro:
    k8s:
      apiServer:
        extraArgs:
          - --enable-aggregator-routing=true
          - --secure-port=6444
          - --authentication-token-webhook-config-file=/etc/webhook/webhook-token-auth.yaml
  statefulSet:
    image:
      registry: ghcr.io
      repository: loft-sh/vcluster-oss
      tag: 0.37.0
    resources:
      limits:
        cpu: "4"
        memory: 8Gi
        ephemeral-storage: 10Gi
      requests:
        cpu: "2"
        memory: 4Gi
        ephemeral-storage: 1Gi
    security:
      podSecurityContext:
        fsGroup: RUN_AS_USER
      containerSecurityContext:
        runAsUser: RUN_AS_USER
        runAsNonRoot: true
rbac:
  role:
    extraRules:
    - apiGroups: [""]
      resources: ["endpoints/restricted"]
      verbs: ["create"]
    - apiGroups: ["discovery.k8s.io"]
      resources: ["endpointslices/restricted"]
      verbs: ["create"]
sync:
  fromHost:
    storageClasses:
      enabled: true
plugins:
  resource-syncer:
    image: RESOURCE_SYNCER_IMAGE
    imagePullPolicy: Always
    config:
      resources:
        - apiVersion: route.openshift.io/v1
          kind: Route
        - apiVersion: oauth.openshift.io/v1
          kind: OAuthClient
    rbac:
      role:
        extraRules:
          - apiGroups: ["route.openshift.io"]
            resources: ["routes", "routes/status"]
            verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
      clusterRole:
        extraRules:
          - apiGroups: ["oauth.openshift.io"]
            resources: ["oauthclients"]
            verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
experimental:
  deploy:
    vcluster:
      manifests: |-
        VCLUSTER_CRD_MANIFESTS
