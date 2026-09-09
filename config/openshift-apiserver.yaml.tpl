apiVersion: openshiftcontrolplane.config.openshift.io/v1
kind: OpenShiftAPIServerConfig
servingInfo:
  bindAddress: "0.0.0.0:OPENSHIFT_APISERVER_PORT"
  bindNetwork: "tcp4"
  certFile: /var/serving-cert/tls.crt
  keyFile: /var/serving-cert/tls.key
  clientCA: /data/pki/client-ca.crt
storageConfig:
  urls:
    - "https://127.0.0.1:ETCD_CLIENT_PORT"
  certFile: /data/pki/apiserver-etcd-client.crt
  keyFile: /data/pki/apiserver-etcd-client.key
  ca: /data/pki/etcd/ca.crt
  storagePrefix: "openshift.io"
kubeClientConfig:
  kubeConfig: /data/pki/admin.conf
aggregatorConfig:
  proxyClientInfo:
    certFile: /data/pki/front-proxy-client.crt
    keyFile: /data/pki/front-proxy-client.key
  requestheaderClientCAFile: /data/pki/front-proxy-ca.crt
admission:
  disabledAdmissionPlugins:
  - "quota.openshift.io/ClusterResourceQuota"
  - "image.openshift.io/ImagePolicy"
  - "image.openshift.io/ImageLimitRange"
apiServerArguments:
  authentication-kubeconfig:
    - /data/pki/admin.conf
  authorization-kubeconfig:
    - /data/pki/admin.conf
  disable-admission-plugins:
    - "quota.openshift.io/ClusterResourceQuota"
    - "image.openshift.io/ImagePolicy"
    - "image.openshift.io/ImageLimitRange"
imagePolicyConfig:
  maxImagesBulkImportedPerRepository: 50
  internalRegistryHostname: "image-registry.openshift-image-registry.svc:5000"
routingConfig:
  subdomain: "apps.example.com"
