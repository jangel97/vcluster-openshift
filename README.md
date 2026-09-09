# vcluster-openshift

Run OpenShift APIs (ImageStream, Route, Build, DeploymentConfig, Project, Template) inside a [vCluster](https://www.vcluster.com/) by running `openshift-apiserver` as an aggregated API server alongside `kube-apiserver`.

**Status**: Proof of concept validated. ImageStream CRUD works end-to-end inside vCluster.

Related: [vCluster issue #509 — OpenShift support](https://github.com/loft-sh/vcluster/issues/509) | [Design proposal](design-proposal.md)

## Why

vCluster runs vanilla Kubernetes. Workloads that depend on OpenShift-native APIs — particularly **ImageStream** (`image.openshift.io/v1`) — cannot run inside vCluster. ImageStream is compiled into the `openshift-apiserver` binary; it is not a CRD and cannot be installed separately.

This blocks:
- **RHOAI/ODH** workbenches (use ImageStreams for notebook images)
- **OpenShift Builds** (Source-to-Image depends on ImageStreams)
- Any workload that assumes OpenShift API availability

This project adds OpenShift API support by running `openshift-apiserver` as a sidecar in the vCluster StatefulSet pod, using standard [Kubernetes API aggregation](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/apiserver-aggregation/).

## Motivation: RHOAI on vCluster

[Red Hat OpenShift AI (RHOAI)](https://www.redhat.com/en/technologies/cloud-computing/openshift/openshift-ai) and its upstream [Open Data Hub (ODH)](https://opendatahub.io/) create and manage ImageStreams to track notebook images for workbenches. On vanilla vCluster, RHOAI installation fails because the ImageStream API doesn't exist.

We evaluated three approaches:

| Approach | Pros | Cons |
|----------|------|------|
| **1. openshift-apiserver sidecar** (this repo) | Full API fidelity — server-side image resolution, import logic, ImageStreamTag virtual resources all work. Drop-in compatible with any OpenShift client. | Heavier: requires a dedicated etcd sidecar + the apiserver container. |
| **2. CRD generated from `openshift/api` Go types** | Lighter — no sidecar. Schema matches upstream since it's derived from the official types via `controller-gen`. | CRD-backed storage has no server-side behavior: no image resolution, no digest lookups, no import triggers. ImageStreamTag is a virtual resource computed on the fly by openshift-apiserver — a CRD can't replicate it. |
| **3. Hand-written minimal CRD** | Simplest — only the fields RHOAI reads (`spec.tags[].from`, `spec.lookupPolicy`, `status.tags`). | Diverges from upstream schema. Breaks if RHOAI ever accesses a field not in the stub. |

We chose **approach 1** because:
- RHOAI doesn't just read ImageStreams — it creates them and expects `status` fields to be populated by server-side logic.
- ImageStreamTag (used by workbench image selectors) is a virtual sub-resource that only openshift-apiserver can serve.
- No project in the OpenShift ecosystem (MicroShift, OKD, CRC) has ever replaced openshift-apiserver with a CRD — if it were viable, someone would have done it.
- The sidecar overhead is bounded: two containers (etcd + apiserver) in the same pod, no extra nodes or network hops.

## Architecture

```
vCluster StatefulSet pod
├── syncer              (kube-apiserver + kine + controller-manager)
├── openshift-etcd      (dedicated etcd for openshift-apiserver, port 2479)
└── openshift-apiserver (aggregated API server, port 8444)
    ├── connects to openshift-etcd at https://127.0.0.1:2479
    ├── delegates auth to kube-apiserver at https://127.0.0.1:6443
    └── uses front-proxy certs for API aggregation

Inside vCluster:
├── APIServices auto-discovered from openshift-apiserver and registered dynamically
└── 6 CRDs fetched from host (admission plugin informer dependencies, configured in config.yaml)
```

## Prerequisites

- OpenShift cluster (tested on OCP 4.21)
- `vcluster` CLI ([install](https://www.vcluster.com/docs/getting-started/setup))
- `kubectl` with access to the OCP cluster
- `yq` ([install](https://github.com/mikefarah/yq)) (for reading deploy config)
- `jq` (for cleaning CRD metadata during fetch)
- `openssl` (for generating serving certs)

## Quickstart

```bash
# Get the openshift-apiserver image from your OCP cluster
export OPENSHIFT_APISERVER_IMAGE=$(oc adm release info --image-for=openshift-apiserver)

# Deploy a vCluster with OpenShift APIs
make deploy OPENSHIFT_APISERVER_IMAGE=$OPENSHIFT_APISERVER_IMAGE

# Verify it works
make verify

# Clean up
make teardown
```

### Configuration

Override defaults via environment variables:

```bash
NAMESPACE=my-vcluster VCLUSTER_NAME=my-ocp OPENSHIFT_APISERVER_IMAGE=<image> make deploy
```

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENSHIFT_APISERVER_IMAGE` | *(required)* | openshift-apiserver image from your OCP release |
| `NAMESPACE` | `vcluster-ocp` | Host namespace for the vCluster |
| `VCLUSTER_NAME` | `ocp` | vCluster name |
| `VCLUSTER_BIN` | `vcluster` | Path to vcluster binary |
| `HOST_CONTEXT` | current context | kubectl context for the host cluster |

### On OpenShift with restricted UIDs

UID ranges are auto-detected from the namespace annotation during deploy. No manual configuration needed.

## What works

- `kubectl get imagestreams` inside the vCluster
- ImageStream creation, update, deletion
- OpenShift API groups auto-discovered and registered as APIServices
- Auth delegation from openshift-apiserver to vCluster's kube-apiserver

## What's not yet tested

- Route creation (APIService registered, no ingress controller)
- ODH/RHOAI workbenches using these ImageStreams
- `openshift-controller-manager` (needed for ImageStream import from external registries)
- Persistence across pod restarts (etcd data is in emptyDir)

## Repo structure

```
.
├── Makefile                  # deploy, teardown, verify targets
├── design-proposal.md        # Upstream design proposal for vCluster #509
├── chart/                    # Helm chart for host-side resources
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
├── manifests/                # Manifests applied inside the vCluster
│   ├── namespace.yaml
│   ├── service.yaml
│   └── endpoints.yaml
├── config.yaml                   # Central config (etcd image, ports, API groups, CRDs)
├── config/
│   ├── openshift-apiserver.yaml.tpl  # openshift-apiserver config template
│   └── patch.yaml.tpl             # StatefulSet patch template (etcd + apiserver sidecars)
├── hack/
│   └── generate-cert.sh      # Generate self-signed serving cert
└── examples/
    └── imagestream-test.yaml  # Test ImageStream
```

## Pinned versions

| Component | Version |
|-----------|---------|
| vCluster | 0.36.1 |
| OpenShift (host) | 4.21.29 |
| vCluster K8s distro | v1.36.0 |
| openshift-apiserver | From OCP 4.21.29 release payload |
| etcd (sidecar) | v3.5.17 |

## Limitations

### Privileged SCC required on the host

The vCluster syncer creates pods on the host OCP cluster using the `vc-<name>` service account. Workloads inside the vCluster may set arbitrary `runAsUser` values and seccomp profiles that don't match the host namespace's SCC constraints. `deploy.sh` grants `privileged` SCC to the syncer's service account — scoped to the vCluster namespace, not cluster-wide.

### Translate Patches is a Pro feature

vCluster's `sync.toHost.pods.patches` (which could rewrite `runAsUser` to match the host UID range) requires a vCluster Pro license. Without it, the `privileged` SCC grant is the only way to let synced pods pass OCP admission.

### Routes don't reach the outside world

The Route API works inside the vCluster (served by openshift-apiserver), but there is no router/ingress controller to expose Routes externally. The host OCP router doesn't see Routes created inside the vCluster.

**Workaround** — use `kubectl port-forward` to access services directly.

### No openshift-controller-manager

The `openshift-controller-manager` is not deployed. This means ImageStream import from external registries (image resolution, scheduled imports) does not work. ImageStreams with local references work fine.

### Etcd data is ephemeral

The openshift-apiserver's etcd sidecar stores data in an `emptyDir` volume. OpenShift API resources (ImageStreams, Routes, etc.) are lost on pod restart. Use a PVC-backed volume for persistence in production.

## Key technical decisions

See [design-proposal.md](design-proposal.md) for full details.

- **Separate etcd**: vCluster's kine (SQLite-backed) uses a Unix socket without TLS. openshift-apiserver's etcd client requires TLS. A dedicated etcd sidecar avoids this incompatibility.
- **Dynamic CRD fetch**: openshift-apiserver hardcodes admission plugins that need certain CRDs. Rather than shipping static stubs, `deploy.sh` fetches the CRD definitions live from the host OCP cluster (listed in `config.yaml`). This keeps them in sync with the host OCP version.
- **Dynamic APIService registration**: Rather than maintaining a static list of APIServices, `deploy.sh` queries the openshift-apiserver's `/apis` discovery endpoint and registers an APIService for each group it serves. This adapts automatically to different openshift-apiserver versions.
- **`insecureSkipTLSVerify`**: APIServices skip TLS verification because traffic is pod-internal. Replace with proper CA trust in production.
- **Pod IP in Endpoints**: Kubernetes rejects loopback IPs. The Endpoints use the pod's real IP, which changes on restart. `make deploy` handles this automatically.

## License

Apache 2.0
