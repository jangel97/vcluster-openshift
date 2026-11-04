{
  "apiVersion": "kubecontrolplane.config.openshift.io/v1",
  "kind": "KubeAPIServerConfig",
  "servingInfo": {
    "bindAddress": "0.0.0.0:6444",
    "bindNetwork": "tcp4",
    "certFile": "/data/pki/apiserver.crt",
    "keyFile": "/data/pki/apiserver.key",
    "clientCA": "/data/pki/client-ca.crt",
    "minTLSVersion": "VersionTLS12"
  },
  "corsAllowedOrigins": [
    "//127\\.0\\.0\\.1(:|$)",
    "//localhost(:|$)"
  ],
  "admission": {
    "pluginConfig": {
      "PodSecurity": {
        "configuration": {
          "apiVersion": "pod-security.admission.config.k8s.io/v1",
          "kind": "PodSecurityConfiguration",
          "defaults": {
            "enforce": "privileged",
            "enforce-version": "latest",
            "audit": "restricted",
            "audit-version": "latest",
            "warn": "restricted",
            "warn-version": "latest"
          }
        }
      }
    }
  },
  "authConfig": {},
  "aggregatorConfig": {
    "proxyClientInfo": {
      "certFile": "/data/pki/front-proxy-client.crt",
      "keyFile": "/data/pki/front-proxy-client.key"
    }
  },
  "imagePolicyConfig": {
    "internalRegistryHostname": "image-registry.openshift-image-registry.svc:5000"
  },
  "projectConfig": {
    "defaultNodeSelector": ""
  },
  "servicesSubnet": "SERVICE_CIDR",
  "apiServerArguments": {
    "etcd-servers": ["https://VCLUSTER_NAME-etcd:2379"],
    "etcd-cafile": ["/data/pki/etcd/ca.crt"],
    "etcd-certfile": ["/data/pki/apiserver-etcd-client.crt"],
    "etcd-keyfile": ["/data/pki/apiserver-etcd-client.key"],
    "storage-backend": ["etcd3"],
    "storage-media-type": ["application/vnd.kubernetes.protobuf"],
    "bind-address": ["127.0.0.1"],
    "secure-port": ["6444"],
    "advertise-address": ["127.0.0.1"],
    "endpoint-reconciler-type": ["none"],
    "tls-cert-file": ["/data/pki/apiserver.crt"],
    "tls-private-key-file": ["/data/pki/apiserver.key"],
    "client-ca-file": ["/data/pki/client-ca.crt"],
    "service-account-issuer": ["https://kubernetes.default.svc.cluster.local"],
    "service-account-key-file": ["/data/pki/sa.pub"],
    "service-account-signing-key-file": ["/data/pki/sa.key"],
    "service-account-lookup": ["true"],
    "proxy-client-cert-file": ["/data/pki/front-proxy-client.crt"],
    "proxy-client-key-file": ["/data/pki/front-proxy-client.key"],
    "requestheader-client-ca-file": ["/data/pki/front-proxy-ca.crt"],
    "requestheader-allowed-names": ["front-proxy-client"],
    "requestheader-extra-headers-prefix": ["X-Remote-Extra-"],
    "requestheader-group-headers": ["X-Remote-Group"],
    "requestheader-username-headers": ["X-Remote-User"],
    "allow-privileged": ["true"],
    "authorization-mode": ["Scope", "SystemMasters", "RBAC", "Node"],
    "anonymous-auth": ["true"],
    "enable-bootstrap-token-auth": ["true"],
    "enable-aggregator-routing": ["true"],
    "profiling": ["false"],
    "service-cluster-ip-range": ["SERVICE_CIDR"],
    "authentication-token-webhook-config-file": ["/etc/webhook/webhook-token-auth.yaml"],
    "enable-admission-plugins": [
      "CertificateApproval",
      "CertificateSigning",
      "CertificateSubjectRestriction",
      "DefaultIngressClass",
      "DefaultStorageClass",
      "DefaultTolerationSeconds",
      "LimitRanger",
      "MutatingAdmissionWebhook",
      "NamespaceLifecycle",
      "NodeRestriction",
      "OwnerReferencesPermissionEnforcement",
      "PersistentVolumeClaimResize",
      "PodSecurity",
      "Priority",
      "ResourceQuota",
      "RuntimeClass",
      "ServiceAccount",
      "StorageObjectInUseProtection",
      "TaintNodesByCondition",
      "ValidatingAdmissionPolicy",
      "ValidatingAdmissionWebhook",
      "security.openshift.io/SecurityContextConstraint",
      "security.openshift.io/DefaultSecurityContextConstraints",
      "security.openshift.io/ValidateSecurityContextConstraints",
      "security.openshift.io/SCCExecRestrictions",
      "route.openshift.io/IngressAdmission"
    ]
  }
}
