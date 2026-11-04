apiVersion: openshiftcontrolplane.config.openshift.io/v1
kind: OpenShiftControllerManagerConfig
controllers: null
servingInfo:
  bindAddress: "0.0.0.0:CPC_PORT"
  bindNetwork: tcp
  certFile: /var/serving-cert/tls.crt
  keyFile: /var/serving-cert/tls.key
  clientCA: /data/pki/client-ca.crt
