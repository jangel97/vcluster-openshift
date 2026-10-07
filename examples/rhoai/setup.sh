#!/bin/bash
set -euo pipefail

if [ -z "${HOST_CONTEXT:-}" ]; then
  echo "ERROR: HOST_CONTEXT is required (vCluster is the current context after deploy)."
  echo "  HOST_CONTEXT=<your-host-context> bash examples/rhoai/setup.sh"
  exit 1
fi
VCLUSTER_NAME="${VCLUSTER_NAME:-ocp}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Step 1: Install RHOAI operator ==="
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
echo "=== Step 2: Create openshift-service-ca.crt ConfigMaps ==="
SERVICE_CA_CERT=$(kubectl get secret service-ca-signing-key -n openshift-service-ca \
  -o jsonpath='{.data.tls\.crt}' | base64 -d)
for ns in redhat-ods-applications redhat-ods-operator olm rhods-notebooks; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
  kubectl create configmap openshift-service-ca.crt \
    --from-literal=service-ca.crt="$SERVICE_CA_CERT" \
    -n "$ns" --dry-run=client -o yaml | kubectl apply -f -
done
echo "  openshift-service-ca.crt ConfigMaps created."

echo ""
echo "=== Step 3: Create DSCI and DSC ==="
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
echo "=== Step 4: Dashboard OAuth proxy ==="
OAUTH_PROXY_IMAGE="${OAUTH_PROXY_IMAGE:-}"
if [ -z "$OAUTH_PROXY_IMAGE" ]; then
  OAUTH_PROXY_IMAGE=$(oc adm release info --image-for=oauth-proxy 2>/dev/null || true)
fi
if [ -z "$OAUTH_PROXY_IMAGE" ]; then
  echo "  WARNING: Could not detect oauth-proxy image. Skipping OAuth setup."
  echo "  Set OAUTH_PROXY_IMAGE and re-run, or access the dashboard via port-forward."
else
  INGRESS_DOMAIN=$(kubectl get ingress.config.openshift.io cluster \
    -o jsonpath='{.spec.domain}' 2>/dev/null || true)
  DASHBOARD_HOST="rhods-dashboard-redhat-ods-applications.${INGRESS_DOMAIN}"

  echo "  Fetching OAuth metadata from host..."
  OAUTH_METADATA=$(kubectl get --raw '/.well-known/oauth-authorization-server' --context "$HOST_CONTEXT" 2>/dev/null || true)
  if [ -n "$OAUTH_METADATA" ]; then
    OAUTH_LOGIN_URL=$(echo "$OAUTH_METADATA" | python3 -c "import sys,json; print(json.load(sys.stdin)['authorization_endpoint'])")
    OAUTH_REDEEM_URL=$(echo "$OAUTH_METADATA" | python3 -c "import sys,json; print(json.load(sys.stdin)['token_endpoint'])")
    echo "  OAuth login:  $OAUTH_LOGIN_URL"
    echo "  OAuth redeem: $OAUTH_REDEEM_URL"
  else
    echo "  WARNING: Could not fetch OAuth metadata from host."
    echo "  OAuth proxy will attempt auto-discovery (may fail in vCluster)."
  fi

  OAUTH_CLIENT_SECRET=$(openssl rand -hex 16)
  COOKIE_SECRET=$(openssl rand -base64 32 | head -c 32)
  TENANT_CLIENT_ID="vc-${VCLUSTER_NAME}-rhods-dashboard-oauth"

  echo "  Creating OAuthClient (synced to host by resource-syncer)..."
  kubectl apply -f - <<OAUTH
apiVersion: oauth.openshift.io/v1
kind: OAuthClient
metadata:
  name: rhods-dashboard-oauth
secret: ${OAUTH_CLIENT_SECRET}
redirectURIs:
  - https://${DASHBOARD_HOST}/oauth/callback
grantMethod: auto
OAUTH

  kubectl create secret generic rhods-dashboard-oauth-config \
    --from-literal=client-secret="$OAUTH_CLIENT_SECRET" \
    --from-literal=cookie-secret="$COOKIE_SECRET" \
    -n redhat-ods-applications --dry-run=client -o yaml | kubectl apply -f -

  echo "  Creating oauth-proxy ServiceAccount and RBAC..."
  kubectl apply -f - <<'SAEOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rhods-dashboard-oauth-proxy
  namespace: redhat-ods-applications
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rhods-dashboard-oauth-proxy-auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: rhods-dashboard-oauth-proxy
  namespace: redhat-ods-applications
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: oauth-proxy-serving-cert-reader
  namespace: openshift-config-managed
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["oauth-serving-cert"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: oauth-proxy-serving-cert-reader
  namespace: openshift-config-managed
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: oauth-proxy-serving-cert-reader
subjects:
- kind: ServiceAccount
  name: rhods-dashboard-oauth-proxy
  namespace: redhat-ods-applications
SAEOF

  echo "  Creating trusted CA bundle (vCluster CA + ingress CA)..."
  KUBE_CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)
  INGRESS_CA_CERT=$(kubectl get configmap host-ingress-ca -n openshift-config-managed \
    -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null || true)
  CA_BUNDLE="${KUBE_CA}"
  if [ -n "$INGRESS_CA_CERT" ]; then
    CA_BUNDLE="${CA_BUNDLE}
${INGRESS_CA_CERT}"
  fi
  kubectl create configmap oauth-proxy-trusted-ca \
    --from-literal=ca.crt="$CA_BUNDLE" \
    -n redhat-ods-applications --dry-run=client -o yaml | kubectl apply -f -

  echo "  Creating oauth-proxy Service (with service-ca TLS)..."
  kubectl apply -f - <<'SVCEOF'
apiVersion: v1
kind: Service
metadata:
  name: rhods-dashboard-oauth-proxy
  namespace: redhat-ods-applications
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: rhods-dashboard-oauth-proxy-tls
spec:
  selector:
    app: rhods-dashboard
  ports:
  - port: 9443
    targetPort: 9443
    name: https
SVCEOF

  echo "  Waiting for service-ca to provision TLS cert..."
  for i in $(seq 1 30); do
    if kubectl get secret rhods-dashboard-oauth-proxy-tls -n redhat-ods-applications &>/dev/null; then
      echo "  TLS cert ready."
      break
    fi
    [ "$i" -eq 30 ] && echo "  WARNING: TLS cert not provisioned after 60s"
    sleep 2
  done

  echo "  Scaling down dashboard operator (prevents reconciliation of sidecar)..."
  kubectl scale deploy dashboard-operator -n redhat-ods-applications --replicas=0 2>/dev/null || true

  OAUTH_EXTRA_ARGS=""
  if [ -n "${OAUTH_LOGIN_URL:-}" ]; then
    OAUTH_EXTRA_ARGS=", \"--login-url=${OAUTH_LOGIN_URL}\", \"--redeem-url=${OAUTH_REDEEM_URL}\""
  fi

  echo "  Injecting oauth-proxy sidecar into dashboard pod..."
  PATCH_FILE="/tmp/rhods-oauth-sidecar-patch.json"
  cat > "$PATCH_FILE" <<PATCHEOF
{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "oauth-proxy",
          "image": "${OAUTH_PROXY_IMAGE}",
          "args": [
            "--provider=openshift",
            "--https-address=:9443",
            "--upstream=http://127.0.0.1:8080",
            "--tls-cert=/etc/oauth-tls/tls.crt",
            "--tls-key=/etc/oauth-tls/tls.key",
            "--cookie-secret-file=/etc/oauth/cookie-secret",
            "--client-id=${TENANT_CLIENT_ID}",
            "--client-secret-file=/etc/oauth/client-secret",
            "--openshift-ca=/etc/oauth-ca/ca.crt",
            "--openshift-delegate-urls={\"/\":{\"resource\":\"projects\",\"verb\":\"list\",\"apiGroup\":\"project.openshift.io\"}}",
            "--skip-provider-button=true",
            "--pass-access-token",
            "--set-xauthrequest"${OAUTH_EXTRA_ARGS}
          ],
          "ports": [{"containerPort": 9443, "name": "oauth-proxy"}],
          "volumeMounts": [
            {"name": "oauth-tls", "mountPath": "/etc/oauth-tls", "readOnly": true},
            {"name": "oauth-config", "mountPath": "/etc/oauth", "readOnly": true},
            {"name": "oauth-trusted-ca", "mountPath": "/etc/oauth-ca", "readOnly": true}
          ]
        }],
        "volumes": [
          {"name": "oauth-tls", "secret": {"secretName": "rhods-dashboard-oauth-proxy-tls"}},
          {"name": "oauth-config", "secret": {"secretName": "rhods-dashboard-oauth-config"}},
          {"name": "oauth-trusted-ca", "configMap": {"name": "oauth-proxy-trusted-ca"}}
        ]
      }
    }
  }
}
PATCHEOF
  kubectl patch deploy rhods-dashboard -n redhat-ods-applications --type strategic --patch-file "$PATCH_FILE"

  echo "  Granting dashboard SA access to oauth-serving-cert..."
  kubectl apply -f - <<'RBACEOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: oauth-serving-cert-reader-dashboard
  namespace: openshift-config-managed
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: oauth-proxy-serving-cert-reader
subjects:
- kind: ServiceAccount
  name: rhods-dashboard
  namespace: redhat-ods-applications
RBACEOF

  echo "  Waiting for dashboard rollout with oauth-proxy sidecar..."
  kubectl rollout status deployment/rhods-dashboard -n redhat-ods-applications --timeout=120s

  echo "  Creating dashboard route via oauth-proxy..."
  kubectl delete route rhods-dashboard -n redhat-ods-applications 2>/dev/null || true
  kubectl apply -f - <<'ROUTEEOF'
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: rhods-dashboard
  namespace: redhat-ods-applications
spec:
  to:
    kind: Service
    name: rhods-dashboard-oauth-proxy
  port:
    targetPort: 9443
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
ROUTEEOF

  sleep 3
  HTTP_STATUS=$(curl -skI "https://${DASHBOARD_HOST}" -o /dev/null -w "%{http_code}" 2>/dev/null || true)
  if [ "$HTTP_STATUS" = "302" ] || [ "$HTTP_STATUS" = "303" ]; then
    echo "  OAuth redirect working (HTTP $HTTP_STATUS)."
  else
    echo "  WARNING: Expected 302, got HTTP $HTTP_STATUS. OAuth may need a moment to sync."
  fi
  echo "  Dashboard URL: https://${DASHBOARD_HOST}"
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "  Dashboard route:"
echo "    kubectl get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}'"
echo ""
