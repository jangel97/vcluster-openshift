#!/bin/bash
set -euo pipefail

NAMESPACE="$1"
VCLUSTER_NAME="$2"
VCLUSTER_BIN="$3"
HOST_CONTEXT="$4"
OPENSHIFT_APISERVER_IMAGE="$5"

if [ -z "$OPENSHIFT_APISERVER_IMAGE" ]; then
  echo "ERROR: OPENSHIFT_APISERVER_IMAGE is required."
  echo ""
  echo "Get it from your OCP cluster:"
  echo "  oc adm release info --image-for=openshift-apiserver"
  echo ""
  echo "Then run:"
  echo "  OPENSHIFT_APISERVER_IMAGE=<image> make deploy"
  exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="$ROOT_DIR/config/deploy-config.yaml"

echo "=== Reading deploy config ==="
ETCD_IMAGE=$(yq '.etcd.image' "$CONFIG")
ETCD_CLIENT_PORT=$(yq '.etcd.clientPort' "$CONFIG")
ETCD_PEER_PORT=$(yq '.etcd.peerPort' "$CONFIG")
OAS_PORT=$(yq '.openshiftApiserver.port' "$CONFIG")
echo "  etcd: $ETCD_IMAGE (ports: $ETCD_CLIENT_PORT/$ETCD_PEER_PORT)"
echo "  openshift-apiserver port: $OAS_PORT"

echo "=== Creating namespace ==="
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "=== Detecting namespace UID range ==="
RUN_AS_USER=""
for i in $(seq 1 15); do
  RUN_AS_USER=$(kubectl get namespace "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}' 2>/dev/null | cut -d/ -f1)
  if [ -n "$RUN_AS_USER" ]; then
    echo "Detected UID range: $RUN_AS_USER"
    break
  fi
  echo "  Waiting for UID range annotation (attempt $i/15)..."
  sleep 2
done
if [ -z "$RUN_AS_USER" ]; then
  echo "No OCP UID range annotation found, using defaults."
fi

echo "=== Generating vCluster values ==="
if [ -n "$RUN_AS_USER" ]; then
  sed "s/RUN_AS_USER/$RUN_AS_USER/g" "$ROOT_DIR/chart/vcluster-values.yaml.tpl" > "/tmp/vcluster-values-${VCLUSTER_NAME}.yaml"
else
  sed '/RUN_AS_USER/d; /runAsUser/d; /fsGroup/d' "$ROOT_DIR/chart/vcluster-values.yaml.tpl" > "/tmp/vcluster-values-${VCLUSTER_NAME}.yaml"
fi

echo "=== Creating vCluster ==="
if "$VCLUSTER_BIN" list --namespace "$NAMESPACE" 2>/dev/null | grep -q "$VCLUSTER_NAME"; then
  echo "vCluster $VCLUSTER_NAME already exists, skipping create."
else
  "$VCLUSTER_BIN" create "$VCLUSTER_NAME" \
    --namespace "$NAMESPACE" \
    --values "/tmp/vcluster-values-${VCLUSTER_NAME}.yaml" \
    --connect=false
fi
kubectl rollout status "statefulset/$VCLUSTER_NAME" -n "$NAMESPACE" --timeout=120s

echo "=== Creating host resources (ConfigMap + Secret) ==="
TEMPLATE_SED="s|OPENSHIFT_APISERVER_IMAGE|$OPENSHIFT_APISERVER_IMAGE|g"
TEMPLATE_SED="$TEMPLATE_SED; s/ETCD_IMAGE/$ETCD_IMAGE/g"
TEMPLATE_SED="$TEMPLATE_SED; s/ETCD_CLIENT_PORT/$ETCD_CLIENT_PORT/g"
TEMPLATE_SED="$TEMPLATE_SED; s/ETCD_PEER_PORT/$ETCD_PEER_PORT/g"
TEMPLATE_SED="$TEMPLATE_SED; s/OPENSHIFT_APISERVER_PORT/$OAS_PORT/g"
if [ -n "$RUN_AS_USER" ]; then
  TEMPLATE_SED="$TEMPLATE_SED; s/RUN_AS_USER/$RUN_AS_USER/g"
fi

sed "$TEMPLATE_SED" "$ROOT_DIR/config/openshift-apiserver.yaml.tpl" > "/tmp/openshift-apiserver-${VCLUSTER_NAME}.yaml"
kubectl create configmap openshift-apiserver-config \
  --from-file=config.yaml="/tmp/openshift-apiserver-${VCLUSTER_NAME}.yaml" \
  -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret tls openshift-apiserver-serving-cert \
  --cert="$ROOT_DIR/tls.crt" --key="$ROOT_DIR/tls.key" \
  -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "=== Patching StatefulSet with sidecars ==="
sed "$TEMPLATE_SED" "$ROOT_DIR/config/patch.yaml.tpl" | \
  kubectl patch statefulset "$VCLUSTER_NAME" -n "$NAMESPACE" --type strategic --patch-file /dev/stdin
kubectl rollout status "statefulset/$VCLUSTER_NAME" -n "$NAMESPACE" --timeout=180s

echo "=== Waiting for openshift-apiserver health ==="
for i in $(seq 1 30); do
  if kubectl exec "${VCLUSTER_NAME}-0" -n "$NAMESPACE" -c openshift-apiserver -- \
    curl -sk "https://127.0.0.1:${OAS_PORT}/healthz" 2>/dev/null | grep -q ok; then
    echo "openshift-apiserver is healthy!"
    break
  fi
  echo "  Attempt $i/30 — waiting..."
  sleep 5
done

echo "=== Connecting to vCluster ==="
"$VCLUSTER_BIN" connect "$VCLUSTER_NAME" --namespace "$NAMESPACE" &
CONNECT_PID=$!
echo "Waiting for vCluster port-forward (pid $CONNECT_PID)..."
sleep 5

echo "=== Applying in-cluster manifests ==="
kubectl apply -f "$ROOT_DIR/manifests/namespace.yaml"
kubectl apply -f "$ROOT_DIR/manifests/service.yaml"

echo "=== Setting up Endpoints ==="
POD_IP=$(kubectl get pod "${VCLUSTER_NAME}-0" -n "$NAMESPACE" \
  --context "$HOST_CONTEXT" -o jsonpath='{.status.podIP}' 2>/dev/null || true)
if [ -n "$POD_IP" ]; then
  sed "s/REPLACE_WITH_POD_IP/$POD_IP/" "$ROOT_DIR/manifests/endpoints.yaml" | kubectl apply -f -
  echo "Endpoints set to pod IP: $POD_IP"
else
  echo "WARNING: Could not detect pod IP. Set it manually."
  kubectl apply -f "$ROOT_DIR/manifests/endpoints.yaml"
fi

echo "=== Fetching CRDs from host cluster ==="
for crd in $(yq '.crds[]' "$CONFIG"); do
  echo "  Fetching $crd..."
  kubectl get crd "$crd" --context "$HOST_CONTEXT" -o json | \
    jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .metadata.managedFields, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"], .status)' | \
    kubectl apply -f -
done
sleep 5

echo "=== Registering APIServices ==="
kubectl apply -f "$ROOT_DIR/manifests/apiservices.yaml"

echo ""
echo "=== Deploy complete ==="
echo ""
echo "  kubeconfig is now set to the vCluster context."
echo "  Run 'make verify' to validate OpenShift APIs."
echo ""
echo "  To switch back to the host cluster:"
echo "    $VCLUSTER_BIN disconnect"
echo "    # or: kubectl config use-context $HOST_CONTEXT"
echo ""
echo "  Port-forward running in background (pid $CONNECT_PID)."
