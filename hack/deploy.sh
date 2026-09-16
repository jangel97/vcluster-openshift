#!/bin/bash
set -euo pipefail

retry() {
  local n=3 delay=5
  for i in $(seq 1 "$n"); do
    if "$@"; then return 0; fi
    [ "$i" -lt "$n" ] && echo "  Retry $i/$n, waiting ${delay}s..." && sleep "$delay"
  done
  echo "ERROR: failed after $n attempts: $*" >&2
  return 1
}

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
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | retry kubectl apply -f -

echo "=== Granting privileged SCC to vCluster SA ==="
retry oc adm policy add-scc-to-user privileged "system:serviceaccount:${NAMESPACE}:vc-${VCLUSTER_NAME}" --context "$HOST_CONTEXT"

echo "=== Granting route hostname permission to vCluster SA ==="
ROUTE_ROLE='apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: vcluster-route-custom-host
rules:
  - apiGroups: ["route.openshift.io"]
    resources: ["routes/custom-host"]
    verbs: ["create", "update"]'
echo "$ROUTE_ROLE" | retry kubectl apply --context "$HOST_CONTEXT" -f -
retry oc adm policy add-cluster-role-to-user vcluster-route-custom-host \
  "system:serviceaccount:${NAMESPACE}:vc-${VCLUSTER_NAME}" --context "$HOST_CONTEXT"

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
CRD_NAMES=()
for crd in $(yq '.crds[]' "$CONFIG" 2>/dev/null); do
  CRD_NAMES+=("$crd")
done

ALL_HOST_CRDS=$(retry kubectl get crd --context "$HOST_CONTEXT" -o name 2>/dev/null || true)
for group in $(yq '.crdGroups[]' "$CONFIG" 2>/dev/null); do
  for crd in $(echo "$ALL_HOST_CRDS" | grep "\.${group}$" | sed 's|customresourcedefinition.apiextensions.k8s.io/||'); do
    CRD_NAMES+=("$crd")
  done
done

echo "  Fetching ${#CRD_NAMES[@]} CRDs in a single batch..."
ALL_CRDS_JSON=$(retry kubectl get crd "${CRD_NAMES[@]}" --context "$HOST_CONTEXT" -o json)

CRD_MANIFESTS=$(echo "$ALL_CRDS_JSON" | jq '[.items[] | {
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
}]' | yq -P '.[] | splitDoc')

echo "  Generated ${#CRD_NAMES[@]} CRD stubs"

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

echo "=== Detecting routing subdomain ==="
ROUTING_SUBDOMAIN=$(retry kubectl get ingress.config.openshift.io cluster --context "$HOST_CONTEXT" -o jsonpath='{.spec.domain}' 2>/dev/null || true)
if [ -z "$ROUTING_SUBDOMAIN" ]; then
  ROUTING_SUBDOMAIN="apps.example.com"
  echo "  WARNING: Could not detect ingress domain, using $ROUTING_SUBDOMAIN"
else
  echo "  Routing subdomain: $ROUTING_SUBDOMAIN"
fi

echo "=== Creating host resources (ConfigMaps + Secrets) ==="
TEMPLATE_SED="s|OPENSHIFT_APISERVER_IMAGE|$OPENSHIFT_APISERVER_IMAGE|g"
TEMPLATE_SED="$TEMPLATE_SED; s|ETCD_IMAGE|$ETCD_IMAGE|g"
TEMPLATE_SED="$TEMPLATE_SED; s|ETCD_CLIENT_PORT|$ETCD_CLIENT_PORT|g"
TEMPLATE_SED="$TEMPLATE_SED; s|ETCD_PEER_PORT|$ETCD_PEER_PORT|g"
TEMPLATE_SED="$TEMPLATE_SED; s|OPENSHIFT_APISERVER_PORT|$OAS_PORT|g"
TEMPLATE_SED="$TEMPLATE_SED; s|NGINX_IMAGE|$NGINX_IMAGE|g"
TEMPLATE_SED="$TEMPLATE_SED; s|ROUTING_SUBDOMAIN|$ROUTING_SUBDOMAIN|g"
if [ -n "$RUN_AS_USER" ]; then
  TEMPLATE_SED="$TEMPLATE_SED; s|RUN_AS_USER|$RUN_AS_USER|g"
fi

sed "$TEMPLATE_SED" "$ROOT_DIR/config/openshift-apiserver.yaml.tpl" > "/tmp/openshift-apiserver-${VCLUSTER_NAME}.yaml"

OAUTH_METADATA=$(retry kubectl get --raw /.well-known/oauth-authorization-server --context "$HOST_CONTEXT" 2>/dev/null || true)
if [ -n "$OAUTH_METADATA" ]; then
  echo "$OAUTH_METADATA" > "/tmp/oauth-metadata-${VCLUSTER_NAME}.json"
  echo "  OAuth metadata fetched from host"
else
  echo '{}' > "/tmp/oauth-metadata-${VCLUSTER_NAME}.json"
  echo "  WARNING: Could not fetch OAuth metadata from host — OAuth discovery will not work"
fi

# Build all ConfigMaps into a temp file and apply in a single call
CONFIGMAPS_FILE="/tmp/vcluster-configmaps-${VCLUSTER_NAME}.yaml"
cat > "$CONFIGMAPS_FILE" <<RESOURCES
apiVersion: v1
kind: ConfigMap
metadata:
  name: openshift-apiserver-config
  namespace: ${NAMESPACE}
data:
  config.yaml: |
$(sed 's/^/    /' "/tmp/openshift-apiserver-${VCLUSTER_NAME}.yaml")
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: webhook-token-auth
  namespace: ${NAMESPACE}
data:
  webhook-token-auth.yaml: |
$(sed 's/^/    /' "$ROOT_DIR/config/webhook-token-auth.yaml")
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-api-proxy-config
  namespace: ${NAMESPACE}
data:
  nginx.conf: |
$(sed 's/^/    /' "$ROOT_DIR/config/user-api-proxy.nginx.conf")
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: oauth-metadata
  namespace: ${NAMESPACE}
data:
  metadata.json: |
$(sed 's/^/    /' "/tmp/oauth-metadata-${VCLUSTER_NAME}.json")
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: oauth-metadata-proxy-config
  namespace: ${NAMESPACE}
data:
  nginx.conf: |
$(sed 's/^/    /' "$ROOT_DIR/config/nginx.conf.tpl")
RESOURCES
retry kubectl apply -f "$CONFIGMAPS_FILE"

kubectl create secret tls openshift-apiserver-serving-cert \
  --cert="$ROOT_DIR/tls.crt" --key="$ROOT_DIR/tls.key" \
  -n "$NAMESPACE" --dry-run=client -o yaml | retry kubectl apply -f -

echo "=== Granting auth-delegator to vCluster SA ==="
retry oc adm policy add-cluster-role-to-user system:auth-delegator \
  "system:serviceaccount:${NAMESPACE}:vc-${VCLUSTER_NAME}" --context "$HOST_CONTEXT"

echo "=== Patching StatefulSet with sidecars ==="
PATCH_FILE="/tmp/vcluster-patch-${VCLUSTER_NAME}.yaml"
sed "$TEMPLATE_SED" "$ROOT_DIR/config/patch.yaml.tpl" > "$PATCH_FILE"
retry kubectl patch statefulset "$VCLUSTER_NAME" -n "$NAMESPACE" --type strategic --patch-file "$PATCH_FILE"
retry kubectl rollout status "statefulset/$VCLUSTER_NAME" -n "$NAMESPACE" --timeout=180s

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
"$VCLUSTER_BIN" connect "$VCLUSTER_NAME" --namespace "$NAMESPACE" </dev/null &
CONNECT_PID=$!
echo "Waiting for vCluster connection (pid $CONNECT_PID)..."
for i in $(seq 1 30); do
  CURRENT_CTX=$(kubectl config current-context 2>/dev/null || true)
  if [ "$CURRENT_CTX" != "$HOST_CONTEXT" ] && kubectl get ns default &>/dev/null; then
    echo "  vCluster connection ready (context: $CURRENT_CTX)."
    break
  fi
  echo "  Waiting for vCluster context switch (attempt $i/30)..."
  sleep 3
done

echo "=== Applying in-cluster manifests ==="
CURRENT_CTX=$(kubectl config current-context)
if [ "$CURRENT_CTX" = "$HOST_CONTEXT" ]; then
  echo "ERROR: kubectl context is still the host cluster — vcluster connect may have failed."
  echo "       Refusing to apply in-cluster manifests to the host to avoid overwriting host resources."
  exit 1
fi
echo "  Using context: $CURRENT_CTX"
POD_IP=$(kubectl get pod "${VCLUSTER_NAME}-0" -n "$NAMESPACE" \
  --context "$HOST_CONTEXT" -o jsonpath='{.status.podIP}' 2>/dev/null || true)
for i in $(seq 1 20); do
  if kubectl create namespace openshift-apiserver --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null && \
     kubectl apply -f "$ROOT_DIR/manifests/service.yaml" 2>/dev/null && \
     kubectl apply -f "$ROOT_DIR/manifests/user-api-service.yaml" 2>/dev/null && \
     sed "s/REPLACE_WITH_POD_IP/$POD_IP/" "$ROOT_DIR/manifests/endpoints.yaml" | kubectl apply -f - 2>/dev/null && \
     sed "s/REPLACE_WITH_POD_IP/$POD_IP/" "$ROOT_DIR/manifests/user-api-endpoints.yaml" | kubectl apply -f - 2>/dev/null; then
    echo "  In-cluster manifests applied (pod IP: $POD_IP)."
    break
  fi
  echo "  Waiting for vCluster API to stabilize (attempt $i/20)..."
  sleep 3
done

echo "=== Verifying CRDs ==="
REMAINING=("${CRD_NAMES[@]}")
for attempt in $(seq 1 15); do
  [ ${#REMAINING[@]} -eq 0 ] && break
  FOUND=$(kubectl get crd "${REMAINING[@]}" --no-headers 2>/dev/null | awk '{print $1}' || true)
  NEXT=()
  for crd in "${REMAINING[@]}"; do
    if echo "$FOUND" | grep -qx "$crd"; then
      echo "  OK $crd"
    else
      NEXT+=("$crd")
    fi
  done
  REMAINING=("${NEXT[@]}")
  [ ${#REMAINING[@]} -gt 0 ] && echo "  ${#REMAINING[@]} CRDs not ready (attempt $attempt/15)..." && sleep 2
done
for crd in "${REMAINING[@]:-}"; do
  [ -n "$crd" ] && echo "  MISSING $crd"
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
    retry bash -c "kubectl get '$RESOURCE.$GROUP' '$NAME' --context '$HOST_CONTEXT' -o json | jq '$JQ_CLEAN_RES' | kubectl apply -f -"
    HAS_STATUS=$(retry kubectl get "$RESOURCE.$GROUP" "$NAME" --context "$HOST_CONTEXT" -o json 2>/dev/null | jq 'has("status")')
    if [ "$HAS_STATUS" = "true" ]; then
      echo "    Copying status subresource..."
      retry bash -c "kubectl get '$RESOURCE.$GROUP' '$NAME' --context '$HOST_CONTEXT' -o json | jq '{apiVersion, kind, metadata: {name: .metadata.name}, status: .status}' | kubectl replace --subresource=status -f -" 2>/dev/null || echo "    (status subresource not available, skipping)"
    fi
  done
else
  echo "  No host resources configured, skipping."
fi

echo "=== Copying host ingress CA into vCluster ==="
kubectl create namespace openshift-config-managed --dry-run=client -o yaml | kubectl apply -f -
INGRESS_CA=$(retry kubectl get secret router-certs-default -n openshift-ingress \
  --context "$HOST_CONTEXT" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d)
if [ -n "$INGRESS_CA" ]; then
  kubectl create configmap host-ingress-ca \
    --from-literal="ca-bundle.crt=$INGRESS_CA" \
    -n openshift-config-managed --dry-run=client -o yaml | kubectl apply -f -
  echo "  Ingress CA stored in openshift-config-managed/host-ingress-ca"
else
  echo "  WARNING: Could not fetch ingress CA from host"
fi

echo "=== Registering APIServices ==="
APISERVICE_YAML=""
for group in $(yq '.apiGroups[]' "$CONFIG"); do
  echo "  Including v1.${group}"
  APISERVICE_YAML+="---
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
"
done

echo "  Including v1.user.openshift.io"
APISERVICE_YAML+="---
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  name: v1.user.openshift.io
spec:
  group: user.openshift.io
  version: v1
  service:
    namespace: openshift-apiserver
    name: user-api
  groupPriorityMinimum: 9900
  versionPriority: 15
  insecureSkipTLSVerify: true
"

APISERVICE_FILE="/tmp/vcluster-apiservices-${VCLUSTER_NAME}.yaml"
echo "$APISERVICE_YAML" > "$APISERVICE_FILE"
retry kubectl apply -f "$APISERVICE_FILE"

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
