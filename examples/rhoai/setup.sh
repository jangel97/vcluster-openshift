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
sed "s|SERVICE_CA_OPERATOR_IMAGE|$SERVICE_CA_IMAGE|g" "$SCRIPT_DIR/service-ca.yaml" | kubectl apply -f -

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
echo "=== Step 4: Install ODH operator ==="
kubectl apply -f "$SCRIPT_DIR/odh-subscription.yaml"

echo "Waiting for Red Hat community-operators catalog..."
for i in $(seq 1 30); do
  if kubectl get pod -n olm -l olm.catalogSource=community-operators 2>/dev/null | grep -q "1/1"; then
    echo "Red Hat community-operators catalog is ready."
    break
  fi
  echo "  Waiting for community-operators catalog (attempt $i/30)..."
  sleep 10
done

echo "Waiting for ODH operator..."
for i in $(seq 1 60); do
  if kubectl get deployment opendatahub-operator-controller-manager -n openshift-operators 2>/dev/null | grep -q opendatahub; then
    kubectl rollout status deployment/opendatahub-operator-controller-manager -n openshift-operators --timeout=120s
    echo "ODH operator is running."
    break
  fi
  echo "  Waiting for ODH operator deployment (attempt $i/60)..."
  sleep 5
done

echo ""
echo "=== Step 5: Create DSCI and DSC ==="
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
  applicationsNamespace: opendatahub
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
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    dashboard:
      managementState: Managed
    datasciencepipelines:
      managementState: Removed
    kserve:
      managementState: Removed
    modelmeshserving:
      managementState: Removed
    ray:
      managementState: Removed
    workbenches:
      managementState: Removed
    codeflare:
      managementState: Removed
    kueue:
      managementState: Removed
    trainingoperator:
      managementState: Removed
DSC

echo "Waiting for ODH dashboard..."
for i in $(seq 1 30); do
  if kubectl get deployment odh-dashboard -n opendatahub 2>/dev/null | grep -q odh-dashboard; then
    kubectl rollout status deployment/odh-dashboard -n opendatahub --timeout=120s
    echo "ODH dashboard is running."
    break
  fi
  echo "  Waiting for dashboard deployment (attempt $i/30)..."
  sleep 5
done

echo ""
echo "=== Setup complete ==="
echo ""
echo "  Dashboard route:"
echo "    kubectl get route odh-dashboard -n opendatahub -o jsonpath='{.spec.host}'"
echo ""
