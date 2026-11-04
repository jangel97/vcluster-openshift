apiVersion: openshiftcontrolplane.config.openshift.io/v1
kind: OpenShiftControllerManagerConfig
controllers: null
servingInfo:
  bindAddress: "0.0.0.0:OCM_PORT"
  certFile: /var/serving-cert/tls.crt
  keyFile: /var/serving-cert/tls.key
  clientCA: /data/pki/client-ca.crt
dockerPullSecret:
  internalRegistryHostname: "image-registry.openshift-image-registry.svc:5000"
build:
  imageTemplateFormat:
    format: ""
deployer:
  imageTemplateFormat:
    format: ""
leaderElection:
  name: openshift-master-controllers
  leaseDuration: 137s
  renewDeadline: 107s
  retryPeriod: 26s
imageImport:
  disableScheduledImport: false
  maxScheduledImageImportsPerMinute: 60
  scheduledImageImportMinimumIntervalSeconds: 900
