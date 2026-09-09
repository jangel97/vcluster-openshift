controlPlane:
  statefulSet:
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
