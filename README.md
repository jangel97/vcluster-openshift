# vcluster-openshift

OpenShift APIs (ImageStream, Route, Build, and more) inside a [vCluster](https://www.vcluster.com/), powered by `openshift-apiserver` running as a sidecar.

**The problem.** vCluster gives you lightweight, isolated Kubernetes clusters on top of a host cluster. But it runs vanilla k8s. If your workloads depend on OpenShift-specific APIs like ImageStream or Route, they simply won't work. These APIs live inside the `openshift-apiserver` binary; they aren't CRDs and you can't install them separately.

**What this project does.** We run `openshift-apiserver` as a sidecar in the vCluster pod, with its own dedicated etcd. It plugs into the vCluster's kube-apiserver through standard [API aggregation](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/apiserver-aggregation/), so `kubectl get imagestreams` works exactly as you'd expect. We also pull in CRDs, cluster resources, and config from the host OCP cluster so that operators like ODH think they're on real OpenShift.

**Why we built it.** We're working on a platform (GPUaaS) that provisions isolated OpenShift-like environments with GPU access for AI/ML tenants. Spinning up a full OCP cluster per tenant is expensive. vCluster is much lighter, but tenants need RHOAI for notebook workbenches, and RHOAI needs OpenShift APIs. This project fills that gap.

**Status**: Proof of concept validated. ImageStream CRUD works end-to-end inside vCluster.

Related: [vCluster issue #509 — OpenShift support](https://github.com/loft-sh/vcluster/issues/509) | [Design proposal](design-proposal.md)

## Background

vCluster runs vanilla Kubernetes under the hood. Any workload that depends on OpenShift-native APIs — particularly **ImageStream** (`image.openshift.io/v1`) — simply can't run inside it. ImageStream isn't a CRD you can install; it's compiled directly into the `openshift-apiserver` binary.

This blocks a lot of real-world workloads:

- **RHOAI/ODH** workbenches use ImageStreams to track notebook images
- **OpenShift Builds** (Source-to-Image) depend on ImageStreams
- Anything that assumes OpenShift API availability

We solve this by running `openshift-apiserver` as a sidecar in the vCluster StatefulSet pod, wired in through standard [Kubernetes API aggregation](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/apiserver-aggregation/).

## Why not just use a CRD?

We spent time looking at lighter alternatives before committing to the sidecar approach. Here's what we considered:

| Approach | What's good | What breaks |
|----------|-------------|-------------|
| **openshift-apiserver sidecar** (this repo) | Full API fidelity — image resolution, import logic, ImageStreamTag virtual resources all work out of the box. Drop-in for any OpenShift client. | Heavier: needs a dedicated etcd sidecar + the apiserver container. |
| **CRD from `openshift/api` Go types** | Lighter — no sidecar. Schema matches upstream since it comes from the official types via `controller-gen`. | No server-side behavior: no image resolution, no digest lookups, no import triggers. ImageStreamTag is a virtual resource that only openshift-apiserver can serve. |
| **Hand-written minimal CRD** | Simplest — just the fields RHOAI actually reads. | Diverges from upstream. Breaks the moment RHOAI touches a field you didn't stub. |

We went with the sidecar because RHOAI doesn't just read ImageStreams — it creates them and expects `status` fields populated by server-side logic. ImageStreamTag (used by workbench image selectors) is a virtual sub-resource that only openshift-apiserver can serve. And tellingly, no project in the OpenShift ecosystem (MicroShift, OKD, CRC) has ever replaced openshift-apiserver with a CRD. If it were viable, someone would have done it by now.

The overhead is bounded: two extra containers (etcd + apiserver) in the same pod. No extra nodes, no network hops.

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
└── CRDs + cluster resources fetched from the host OCP cluster (configured in config.yaml)
```

Everything runs in a single pod. The openshift-apiserver talks to its own etcd over localhost, delegates authentication back to the vCluster's kube-apiserver, and registers itself through standard APIService objects. From the perspective of anything running inside the vCluster, the OpenShift APIs just exist.

## Prerequisites

- OpenShift cluster (tested on OCP 4.21)
- `vcluster` CLI ([install](https://www.vcluster.com/docs/getting-started/setup))
- `kubectl` with access to the OCP cluster
- `yq` ([install](https://github.com/mikefarah/yq)) for reading deploy config
- `jq` for cleaning CRD metadata during fetch
- `openssl` for generating serving certs

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

You can override defaults with environment variables:

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
| `RESOURCE_SYNCER_IMAGE` | *(optional)* | Resource syncer plugin image (enables syncing resources like Routes to host) |

### OpenShift with restricted UIDs

UID ranges are auto-detected from the namespace annotation during deploy. No manual configuration needed.

## What works

- `kubectl get imagestreams` inside the vCluster
- ImageStream create, update, delete
- OpenShift API groups auto-discovered and registered as APIServices
- Auth delegation from openshift-apiserver to vCluster's kube-apiserver

## What's not yet tested

- Route creation (the APIService is registered, but there's no ingress controller)
- ODH/RHOAI workbenches actually using these ImageStreams
- `openshift-controller-manager` (needed for ImageStream import from external registries)
- Persistence across pod restarts (etcd data lives in emptyDir)

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
├── config.yaml               # Central config (etcd image, ports, API groups, CRDs)
├── config/
│   ├── openshift-apiserver.yaml.tpl  # openshift-apiserver config template
│   └── patch.yaml.tpl               # StatefulSet patch template (sidecars)
├── plugins/
│   └── resource-syncer/      # vCluster plugin: syncs configured resources to host cluster
│       ├── main.go
│       ├── pkg/              # Generic syncer framework
│       ├── syncers/route.go  # Route-specific syncer (service name translation)
│       └── Dockerfile
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

Things we've hit that you should know about.

### Privileged SCC required on the host

The vCluster syncer creates pods on the host OCP cluster using the `vc-<name>` service account. Workloads inside the vCluster may set arbitrary `runAsUser` values and seccomp profiles that don't match the host namespace's SCC constraints. The deploy script grants `privileged` SCC to the syncer's service account — scoped to the vCluster namespace, not cluster-wide.

### Translate Patches is a Pro feature

vCluster's `sync.toHost.pods.patches` (which could rewrite `runAsUser` to match the host UID range) requires a vCluster Pro license. Without it, the `privileged` SCC grant is the only way to let synced pods pass OCP admission.

### Resource syncer plugin

Resources created inside the vCluster (Routes, etc.) are invisible to the host cluster. The **resource-syncer plugin** syncs configured resources from the vCluster to the host cluster. Which resources to sync is specified in the plugin config.

```bash
# Build the plugin
make build-plugin RESOURCE_SYNCER_IMAGE=quay.io/<org>/vcluster-resource-syncer:latest
make push-plugin

# Deploy with plugin enabled
RESOURCE_SYNCER_IMAGE=quay.io/<org>/vcluster-resource-syncer:latest \
OPENSHIFT_APISERVER_IMAGE=... make deploy
```

Resources with a registered typed syncer (like Routes) get special handling — e.g., Service name translation for Route backends. Everything else gets a generic syncer that copies spec and status.

Without the plugin, resources exist in the vCluster API but aren't visible on the host. Use `kubectl port-forward` to access services directly in that case.

### No openshift-controller-manager

We don't deploy the `openshift-controller-manager`. That means ImageStream import from external registries (image resolution, scheduled imports) doesn't work. ImageStreams with local references are fine.

### Etcd data is ephemeral

The openshift-apiserver's etcd sidecar stores data in an `emptyDir` volume. All OpenShift API resources (ImageStreams, Routes, etc.) are lost when the pod restarts. For anything beyond a PoC, back this with a PVC.

## Key technical decisions

See [design-proposal.md](design-proposal.md) for the full story. The short version:

- **Separate etcd**: vCluster's kine (SQLite-backed) uses a Unix socket without TLS. openshift-apiserver's etcd client requires TLS. Rather than fighting that mismatch, we run a dedicated etcd sidecar.
- **Dynamic CRD fetch**: openshift-apiserver hardcodes admission plugins that need certain CRDs to exist. Instead of shipping static stubs that drift out of sync, `deploy.sh` fetches CRD definitions live from the host cluster. What to fetch is configured in `config.yaml`.
- **Dynamic APIService registration**: Rather than maintaining a static list, `deploy.sh` queries the openshift-apiserver's `/apis` discovery endpoint and registers an APIService for each group it finds. This adapts automatically when different openshift-apiserver versions serve different groups.
- **`insecureSkipTLSVerify` on APIServices**: All traffic is pod-internal (localhost), so we skip TLS verification. Replace with proper CA trust for production.
- **Pod IP in Endpoints**: Kubernetes rejects loopback IPs in Endpoints objects. We use the pod's real IP, which changes on restart. `make deploy` handles this automatically.

## License

Apache 2.0
