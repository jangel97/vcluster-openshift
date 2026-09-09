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

## Limitations

### Routes don't reach the outside world

ODH dashboard creates a Route inside the vCluster. The Route API works (served by openshift-apiserver), but there's no router/ingress controller inside the vCluster to expose it externally. The host OCP router doesn't see Routes created inside the vCluster.

**Workaround** — use port-forward to access the dashboard:

```bash
kubectl port-forward svc/odh-dashboard -n opendatahub 8443:8443
# Open https://localhost:8443
```

A proper fix would be a Route syncer (vCluster plugin or controller) that copies Routes from the vCluster to the host namespace where the OCP router can pick them up. This is not yet implemented.

## What's next after setup

1. Create a `DSCInitialization` and `DataScienceCluster` to enable ODH components
2. Create a workbench and verify it can use ImageStreams for notebook images
