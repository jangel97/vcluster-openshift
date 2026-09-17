# Running RHOAI / ODH on vCluster with OpenShift APIs

This example deploys Open Data Hub (ODH) inside a vCluster that has OpenShift API support via `vcluster-openshift`.

## Prerequisites

- A running vCluster deployed with `make deploy` (see root README)
- kubectl context set to the vCluster
- Access to the host OCP cluster (for borrowing the service CA)

## What this sets up

1. **service-ca-operator** — runs inside the vCluster using the host's CA signing key. Watches Services for `service.beta.openshift.io/serving-cert-secret-name` annotations and auto-provisions TLS certificates. Certs are signed by the same CA as the host cluster.

2. **ODH operator** — installed via OLM Subscription from community-operators.

## Usage

```bash
# Set HOST_CONTEXT to your OCP cluster context (the one used with `make deploy`)
# List available contexts with: kubectl config get-contexts -o name
export HOST_CONTEXT="<your-host-ocp-context>"

# Switch to host context to get the service-ca-operator image
kubectl config use-context "$HOST_CONTEXT"
export SERVICE_CA_OPERATOR_IMAGE=$(oc adm release info --image-for=service-ca-operator)

# Switch back to the vCluster context
~/bin/vcluster connect <vcluster-name> --namespace <namespace>

# Run setup (in a separate terminal, since vcluster connect holds the terminal)
bash examples/rhoai/setup.sh
```

## How the service CA borrowing works

On real OCP, the `service-ca-operator` runs in `openshift-service-ca` and signs certificates using a cluster-internal CA. Instead of generating a new CA, we copy the host's signing key (`openshift-service-ca/signing-key`) into the vCluster and run the same operator binary. This means:

- Certificates inside the vCluster are signed by the same CA as the host
- Any trust chain that works on the host works inside the vCluster
- No cert-manager needed — same annotation-based flow as real OCP

## Known issues

### Notebook image tags

The RHOAI notebook images on `quay.io/modh/` use date-based tags (e.g., `v3-20250827`), not the `v3-2025a-YYYYMMDD` format. Check available tags before creating a Notebook:

```bash
skopeo list-tags docker://quay.io/modh/odh-minimal-notebook-container | jq '.Tags[]' | sort | tail -10
```

### Notebook PVCs need fsGroup

Notebook pods run under OCP's SCC-assigned UID (e.g., `1000900000`), but PVC mounts default to root ownership. Without `fsGroup`, the notebook crashes with `PermissionError` when writing to the workspace volume.

Set `fsGroup: 0` in the Notebook CR's pod securityContext:

```yaml
spec:
  template:
    spec:
      securityContext:
        fsGroup: 0
```

On real OCP the restricted SCC sets fsGroup automatically from the namespace's supplemental group range. In the vCluster this doesn't happen, so it must be set explicitly.

### No OAuth server

The vCluster runs vanilla Kubernetes — there's no OpenShift OAuth server. The ODH dashboard's oauth-proxy sidecar can't authenticate users, so "Login with OpenShift" returns a 403/500.

**Workaround** — access the dashboard directly on port 8080 (bypassing oauth-proxy) via port-forward, or create a Route targeting port 8080 with edge TLS.

### Routes

Routes created inside the vCluster are invisible to the host OCP router. Deploy with the `resource-syncer` plugin (see root README) to sync Routes to the host, or create them manually on the host namespace.

## What's next after setup

1. Create a `DSCInitialization` and `DataScienceCluster` to enable ODH components
2. Create a workbench namespace and Notebook CR (remember to set `fsGroup: 0`)
3. Verify the notebook pod starts and can run workloads
