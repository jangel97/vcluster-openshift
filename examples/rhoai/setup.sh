#!/bin/bash
set -euo pipefail

if [ -z "${HOST_CONTEXT:-}" ]; then
  echo "ERROR: HOST_CONTEXT is required (vCluster is the current context after deploy)."
  echo "  HOST_CONTEXT=<your-host-context> bash examples/rhoai/setup.sh"
  exit 1
fi
NAMESPACE="${NAMESPACE:-vcluster-ocp}"

echo "=== Step 1: Copy service CA signing key and CA bundle from host ==="
kubectl create namespace openshift-service-ca --dry-run=client -o yaml | kubectl apply -f -

kubectl get secret signing-key -n openshift-service-ca --context "$HOST_CONTEXT" -o json | \
  jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.namespace, .metadata.managedFields, .metadata.annotations, .metadata.labels) | .metadata.name = "service-ca-signing-key"' | \
  kubectl apply -n openshift-service-ca -f -

kubectl get configmap signing-cabundle -n openshift-service-ca --context "$HOST_CONTEXT" -o json | \
  jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.namespace, .metadata.managedFields, .metadata.annotations, .metadata.labels)' | \
  kubectl apply -n openshift-service-ca -f -

echo "=== Step 2: Deploy service-ca-operator ==="
SERVICE_CA_IMAGE="${SERVICE_CA_OPERATOR_IMAGE:-}"
if [ -z "$SERVICE_CA_IMAGE" ]; then
  SERVICE_CA_IMAGE=$(oc adm release info --image-for=service-ca-operator 2>/dev/null || true)
fi
if [ -z "$SERVICE_CA_IMAGE" ]; then
  echo "ERROR: SERVICE_CA_OPERATOR_IMAGE is required."
  echo "  oc adm release info --image-for=service-ca-operator"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Reuse the service-ca manifest from the ODH example
sed "s|SERVICE_CA_OPERATOR_IMAGE|$SERVICE_CA_IMAGE|g" "$ROOT_DIR/examples/odh/service-ca.yaml" | kubectl apply -f -

echo "Waiting for service-ca controller..."
kubectl rollout status deployment/service-ca -n openshift-service-ca --timeout=120s
echo "service-ca-operator is running."

echo ""
echo "=== Step 3: Install OLM ==="
if kubectl get deployment olm-operator -n olm &>/dev/null; then
  echo "OLM already installed, skipping."
else
  curl -sL https://github.com/operator-framework/operator-lifecycle-manager/releases/download/v0.28.0/install.sh | bash -s v0.28.0
fi

echo "Waiting for OLM catalog pod..."
for i in $(seq 1 30); do
  if kubectl get pod -n olm -l olm.catalogSource=operatorhubio-catalog 2>/dev/null | grep -q "1/1"; then
    echo "OLM catalog is ready."
    break
  fi
  echo "  Waiting for catalog pod (attempt $i/30)..."
  sleep 10
done

echo ""
echo "=== Step 4: Copy pull secret for registry.redhat.io ==="
HOST_PULL_SECRET=$(kubectl get secret pull-secret -n openshift-config --context "$HOST_CONTEXT" -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null || true)
if [ -n "$HOST_PULL_SECRET" ]; then
  kubectl create secret docker-registry pull-secret \
    --from-file=.dockerconfigjson=<(echo "$HOST_PULL_SECRET" | base64 -d) \
    -n olm --dry-run=client -o yaml | kubectl apply -f -
  kubectl patch serviceaccount default -n olm -p '{"imagePullSecrets":[{"name":"pull-secret"}]}' 2>/dev/null || true
  echo "  Pull secret copied to olm namespace."
else
  echo "  WARNING: Could not copy pull secret from host."
  echo "  The redhat-operators catalog may fail to pull."
fi

echo ""
echo "=== Step 5: Create OpenShift prerequisites ==="
kubectl create namespace openshift-ingress --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-monitoring-view
rules:
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get"]
EOF

echo "  Installing Gateway API CRDs..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml 2>&1 | tail -1
echo "  OpenShift prerequisites created."

echo ""
echo "=== Step 6: Install RHOAI operator ==="
kubectl apply -f "$SCRIPT_DIR/rhoai-subscription.yaml"

echo "Waiting for Red Hat operators catalog (this may take a few minutes)..."
for i in $(seq 1 30); do
  if kubectl get pod -n olm -l olm.catalogSource=redhat-operators 2>/dev/null | grep -q "1/1"; then
    echo "Red Hat operators catalog is ready."
    break
  fi
  echo "  Waiting for redhat-operators catalog (attempt $i/30)..."
  sleep 10
done

echo "Waiting for RHOAI operator..."
for i in $(seq 1 60); do
  if kubectl get deployment rhods-operator -n redhat-ods-operator 2>/dev/null | grep -q rhods; then
    kubectl rollout status deployment/rhods-operator -n redhat-ods-operator --timeout=180s
    echo "RHOAI operator is running."
    break
  fi
  echo "  Waiting for RHOAI operator deployment (attempt $i/60)..."
  sleep 5
done

echo ""
echo "=== Step 7: Create DSCI and DSC ==="
INGRESS_CA=$(kubectl get configmap host-ingress-ca -n openshift-config-managed \
  -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null || true)
CUSTOM_CA_BUNDLE=""
if [ -n "$INGRESS_CA" ]; then
  CUSTOM_CA_BUNDLE="$INGRESS_CA"
  echo "  Ingress CA found — will inject into DSCI customCABundle"
else
  echo "  WARNING: host-ingress-ca not found in openshift-config-managed."
  echo "  OAuth login may fail — run 'make deploy' first to populate the CA."
fi

kubectl apply -f - <<DSCI
apiVersion: dscinitialization.opendatahub.io/v1
kind: DSCInitialization
metadata:
  name: default-dsci
spec:
  applicationsNamespace: redhat-ods-applications
  monitoring:
    managementState: Removed
  serviceMesh:
    managementState: Removed
  trustedCABundle:
    managementState: Managed
    customCABundle: |
$(echo "$CUSTOM_CA_BUNDLE" | sed 's/^/      /')
DSCI

kubectl apply -f - <<DSC
apiVersion: datasciencecluster.opendatahub.io/v2
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    dashboard:
      managementState: Managed
    kserve:
      managementState: Managed
      rawDeploymentServiceConfig: Headless
    workbenches:
      managementState: Managed
    aipipelines:
      managementState: Removed
    kueue:
      managementState: Removed
    ray:
      managementState: Removed
    trainingoperator:
      managementState: Removed
DSC

echo "Waiting for RHOAI dashboard..."
for i in $(seq 1 30); do
  if kubectl get deployment rhods-dashboard -n redhat-ods-applications 2>/dev/null | grep -q rhods-dashboard; then
    kubectl rollout status deployment/rhods-dashboard -n redhat-ods-applications --timeout=120s
    echo "RHOAI dashboard is running."
    break
  fi
  echo "  Waiting for dashboard deployment (attempt $i/30)..."
  sleep 5
done

echo ""
echo "=== Setup complete ==="
echo ""
echo "  Dashboard route:"
echo "    kubectl get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}'"
echo ""
