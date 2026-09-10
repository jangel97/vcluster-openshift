controlPlane:
  statefulSet:
    image:
      registry: ghcr.io
      repository: loft-sh/vcluster-oss
      tag: 0.37.0
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
sync:
  fromHost:
    storageClasses:
      enabled: true
experimental:
  deploy:
    vcluster:
      manifests: |-
        VCLUSTER_CRD_MANIFESTS
