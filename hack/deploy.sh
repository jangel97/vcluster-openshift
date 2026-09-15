#!/bin/bash
set -euo pipefail

NAMESPACE="$1"
VCLUSTER_NAME="$2"
VCLUSTER_BIN="$3"
HOST_CONTEXT="$4"
OPENSHIFT_APISERVER_IMAGE="$5"
RESOURCE_SYNCER_IMAGE="${6:-}"

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
CONFIG="$ROOT_DIR/config.yaml"

echo "=== Reading deploy config ==="
ETCD_IMAGE=$(yq '.etcd.image' "$CONFIG")
ETCD_CLIENT_PORT=$(yq '.etcd.clientPort' "$CONFIG")
ETCD_PEER_PORT=$(yq '.etcd.peerPort' "$CONFIG")
OAS_PORT=$(yq '.openshiftApiserver.port' "$CONFIG")
NGINX_IMAGE=$(yq '.nginx.image' "$CONFIG")
echo "  etcd: $ETCD_IMAGE (ports: $ETCD_CLIENT_PORT/$ETCD_PEER_PORT)"
echo "  openshift-apiserver port: $OAS_PORT"
echo "  nginx proxy: $NGINX_IMAGE"

echo "=== Creating namespace ==="
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "=== Granting privileged SCC to vCluster SA ==="
oc adm policy add-scc-to-user privileged "system:serviceaccount:${NAMESPACE}:vc-${VCLUSTER_NAME}" --context "$HOST_CONTEXT"

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

echo "=== Fetching CRD stubs from host cluster ==="
# Collect all CRD names to fetch (individual + group-matched)
CRD_NAMES=()
for crd in $(yq '.crds[]' "$CONFIG" 2>/dev/null); do
  CRD_NAMES+=("$crd")
done
for group in $(yq '.crdGroups[]' "$CONFIG" 2>/dev/null); do
  for crd in $(kubectl get crd --context "$HOST_CONTEXT" -o name 2>/dev/null | grep "\.${group}$" | sed 's|customresourcedefinition.apiextensions.k8s.io/||'); do
    CRD_NAMES+=("$crd")
  done
done

# Generate minimal stub for each CRD and collect into a single manifests block.
# Minimal stubs use x-kubernetes-preserve-unknown-fields so the vCluster accepts
# any resource content without needing the full OpenAPI schema (which is often 40KB+
# and triggers a race condition in the embedded kube-apiserver's CRD registration).
CRD_MANIFESTS=""
for crd in "${CRD_NAMES[@]}"; do
  echo "  Generating stub for $crd"
  STUB=$(kubectl get crd "$crd" --context "$HOST_CONTEXT" -o json | jq -r '
    {
      apiVersion: "apiextensions.k8s.io/v1",
      kind: "CustomResourceDefinition",
      metadata: { name: .metadata.name },
      spec: {
        group: .spec.group,
        names: .spec.names,
        scope: .spec.scope,
        versions: [.spec.versions[] | {
          name: .name,
          served: .served,
          storage: .storage,
          subresources: (.subresources // null),
          schema: {
            openAPIV3Schema: {
              type: "object",
              properties: {
                spec: { type: "object", "x-kubernetes-preserve-unknown-fields": true },
                status: { type: "object", "x-kubernetes-preserve-unknown-fields": true }
              }
            }
          }
        }]
      }
    }
  ' | yq -P)

  if [ -n "$CRD_MANIFESTS" ]; then
    CRD_MANIFESTS="${CRD_MANIFESTS}
---
${STUB}"
  else
    CRD_MANIFESTS="$STUB"
  fi
done

echo "  Generated ${#CRD_NAMES[@]} CRD stubs"

# Append static CRD definitions (for native OpenShift APIs that aren't CRDs on the host)
if [ -d "$ROOT_DIR/crds" ]; then
  for crdfile in "$ROOT_DIR"/crds/*.yaml; do
    [ -f "$crdfile" ] || continue
    STATIC_CRD=$(cat "$crdfile")
    echo "  Including static CRD: $(basename "$crdfile")"
    if [ -n "$CRD_MANIFESTS" ]; then
      CRD_MANIFESTS="${CRD_MANIFESTS}
---
${STATIC_CRD}"
    else
      CRD_MANIFESTS="$STATIC_CRD"
    fi
  done
fi

echo "=== Generating vCluster values ==="
if [ -n "$RUN_AS_USER" ]; then
  sed "s/RUN_AS_USER/$RUN_AS_USER/g" "$ROOT_DIR/chart/vcluster-values.yaml.tpl" > "/tmp/vcluster-values-${VCLUSTER_NAME}.yaml"
else
  sed '/RUN_AS_USER/d; /runAsUser/d; /fsGroup/d' "$ROOT_DIR/chart/vcluster-values.yaml.tpl" > "/tmp/vcluster-values-${VCLUSTER_NAME}.yaml"
fi

# Inject CRD manifests into the values file, indented to match the YAML block scalar
INDENTED_MANIFESTS=$(echo "$CRD_MANIFESTS" | sed 's/^/        /')
ESCAPED_MANIFESTS=$(echo "$INDENTED_MANIFESTS" | sed 's/[&/\]/\\&/g')

# Strip plugin block if no resource-syncer image provided
if [ -z "$RESOURCE_SYNCER_IMAGE" ]; then
  python3 -c "
import sys, re
vals = open(sys.argv[1]).read()
vals = re.sub(r'plugins:.*?(?=\n\S)', '', vals, flags=re.DOTALL)
open(sys.argv[1], 'w').write(vals)
" "/tmp/vcluster-values-${VCLUSTER_NAME}.yaml"
  echo "  Resource syncer plugin: disabled (no image provided)"
else
  sed -i'' -e "s|RESOURCE_SYNCER_IMAGE|$RESOURCE_SYNCER_IMAGE|g" "/tmp/vcluster-values-${VCLUSTER_NAME}.yaml"
  echo "  Resource syncer plugin: $RESOURCE_SYNCER_IMAGE"
fi

# Use a python one-liner for safe multi-line replacement (sed struggles with newlines)
python3 -c "
import sys
vals = open(sys.argv[1]).read()
manifests = open(sys.argv[2]).read()
indented = '\n'.join('        ' + line if line.strip() else '' for line in manifests.splitlines())
vals = vals.replace('        VCLUSTER_CRD_MANIFESTS', indented)
open(sys.argv[1], 'w').write(vals)
" "/tmp/vcluster-values-${VCLUSTER_NAME}.yaml" <(echo "$CRD_MANIFESTS")

echo "=== Creating/upgrading vCluster ==="
"$VCLUSTER_BIN" create "$VCLUSTER_NAME" \
  --namespace "$NAMESPACE" \
  --values "/tmp/vcluster-values-${VCLUSTER_NAME}.yaml" \
  --connect=false \
  --upgrade
# Don't wait for rollout here — the pod might be unhealthy until the
# sidecar patch is applied (kube-apiserver port shift requires the nginx proxy).

echo "=== Creating host resources (ConfigMap + Secret) ==="
TEMPLATE_SED="s|OPENSHIFT_APISERVER_IMAGE|$OPENSHIFT_APISERVER_IMAGE|g"
TEMPLATE_SED="$TEMPLATE_SED; s|ETCD_IMAGE|$ETCD_IMAGE|g"
TEMPLATE_SED="$TEMPLATE_SED; s|ETCD_CLIENT_PORT|$ETCD_CLIENT_PORT|g"
TEMPLATE_SED="$TEMPLATE_SED; s|ETCD_PEER_PORT|$ETCD_PEER_PORT|g"
TEMPLATE_SED="$TEMPLATE_SED; s|OPENSHIFT_APISERVER_PORT|$OAS_PORT|g"
TEMPLATE_SED="$TEMPLATE_SED; s|NGINX_IMAGE|$NGINX_IMAGE|g"
if [ -n "$RUN_AS_USER" ]; then
  TEMPLATE_SED="$TEMPLATE_SED; s|RUN_AS_USER|$RUN_AS_USER|g"
fi

sed "$TEMPLATE_SED" "$ROOT_DIR/config/openshift-apiserver.yaml.tpl" > "/tmp/openshift-apiserver-${VCLUSTER_NAME}.yaml"
kubectl create configmap openshift-apiserver-config \
  --from-file=config.yaml="/tmp/openshift-apiserver-${VCLUSTER_NAME}.yaml" \
  -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret tls openshift-apiserver-serving-cert \
  --cert="$ROOT_DIR/tls.crt" --key="$ROOT_DIR/tls.key" \
  -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "=== Setting up OAuth metadata proxy ==="
OAUTH_METADATA=$(kubectl get --raw /.well-known/oauth-authorization-server --context "$HOST_CONTEXT" 2>/dev/null || true)
if [ -n "$OAUTH_METADATA" ]; then
  echo "$OAUTH_METADATA" > "/tmp/oauth-metadata-${VCLUSTER_NAME}.json"
  echo "  OAuth metadata fetched from host"
else
  echo '{}' > "/tmp/oauth-metadata-${VCLUSTER_NAME}.json"
  echo "  WARNING: Could not fetch OAuth metadata from host — OAuth discovery will not work"
fi
kubectl create configmap oauth-metadata \
  --from-file=metadata.json="/tmp/oauth-metadata-${VCLUSTER_NAME}.json" \
  -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap oauth-metadata-proxy-config \
  --from-file=nginx.conf="$ROOT_DIR/config/nginx.conf.tpl" \
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
kubectl create namespace openshift-apiserver --dry-run=client -o yaml | kubectl apply -f -
for i in $(seq 1 10); do
  kubectl get namespace openshift-apiserver &>/dev/null && break
  echo "  Waiting for namespace..."
  sleep 2
done
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

echo "=== Verifying CRDs ==="
for crd in "${CRD_NAMES[@]}"; do
  for attempt in $(seq 1 15); do
    if kubectl get crd "$crd" &>/dev/null; then
      echo "  OK $crd"
      break
    fi
    if [ "$attempt" -eq 15 ]; then
      echo "  MISSING $crd"
    fi
    sleep 2
  done
done

echo "=== Copying host resources ==="
RESOURCE_COUNT=$(yq '.hostResources | length' "$CONFIG" 2>/dev/null || echo 0)
if [ "$RESOURCE_COUNT" -gt 0 ]; then
  JQ_CLEAN_RES='del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .metadata.managedFields, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])'
  for idx in $(seq 0 $((RESOURCE_COUNT - 1))); do
    GROUP=$(yq ".hostResources[$idx].group" "$CONFIG")
    RESOURCE=$(yq ".hostResources[$idx].resource" "$CONFIG")
    NAME=$(yq ".hostResources[$idx].name" "$CONFIG")
    echo "  Waiting for $RESOURCE.$GROUP CRD to be established..."
    for attempt in $(seq 1 30); do
      if kubectl wait --for=condition=Established crd "${RESOURCE}.${GROUP}" --timeout=5s 2>/dev/null; then
        break
      fi
      echo "    CRD not ready yet (attempt $attempt/30)..."
      sleep 3
    done
    echo "  Copying $RESOURCE/$NAME ($GROUP)..."
    kubectl get "$RESOURCE.$GROUP" "$NAME" --context "$HOST_CONTEXT" -o json | \
      jq "$JQ_CLEAN_RES" | kubectl apply -f -
    HAS_STATUS=$(kubectl get "$RESOURCE.$GROUP" "$NAME" --context "$HOST_CONTEXT" -o json 2>/dev/null | jq 'has("status")')
    if [ "$HAS_STATUS" = "true" ]; then
      echo "    Copying status subresource..."
      kubectl get "$RESOURCE.$GROUP" "$NAME" --context "$HOST_CONTEXT" -o json | \
        jq '{apiVersion, kind, metadata: {name: .metadata.name}, status: .status}' | \
        kubectl replace --subresource=status -f - 2>/dev/null || echo "    (status subresource not available, skipping)"
    fi
  done
else
  echo "  No host resources configured, skipping."
fi

echo "=== Registering APIServices ==="
for group in $(yq '.apiGroups[]' "$CONFIG"); do
  echo "  Registering v1.${group}..."
  cat <<APISERVICE | kubectl apply -f -
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  name: v1.${group}
spec:
  group: ${group}
  version: v1
  service:
    namespace: openshift-apiserver
    name: api
  groupPriorityMinimum: 9900
  versionPriority: 15
  insecureSkipTLSVerify: true
APISERVICE
done

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
