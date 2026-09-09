# Design Proposal: OpenShift Distro for vCluster

**Issue**: [#509 — Support OpenShift as backing virtual cluster](https://github.com/loft-sh/vcluster/issues/509)
**Status**: Proof of concept validated — ImageStream CRUD works inside vCluster
**Author**: @jmorenas
**Date**: 2026-09-09

## Summary

This proposal adds OpenShift as a backing distribution for vCluster by running `openshift-apiserver` as an aggregated API server alongside the existing `kube-apiserver`. This provides OpenShift-native APIs (ImageStream, Route, Build, DeploymentConfig, Project, Template) inside virtual clusters without requiring a full OpenShift control plane. A working proof of concept demonstrates that ImageStream creation works end-to-end using this approach.

## Motivation

### The problem

vCluster currently supports vanilla Kubernetes (K8S distro) as its backing distribution. Workloads that depend on OpenShift-native APIs — specifically APIs that are compiled into the `openshift-apiserver` binary rather than implemented as CRDs — cannot run inside vCluster.

The most impactful example is **ImageStream** (`image.openshift.io/v1`). ImageStream is used extensively across the OpenShift ecosystem:

- **Red Hat OpenShift AI (RHOAI)** uses ImageStreams to define notebook images for JupyterLab and VS Code Server workbenches. Without ImageStream, workbench creation fails entirely.
- **OpenShift Builds** (Source-to-Image) depend on ImageStreams for input/output image references.
- **OpenShift Templates** reference ImageStreams for application deployments.
- **ISVs and enterprise workloads** built for OpenShift assume ImageStream availability.

ImageStream is not a CRD — it is a built-in API type compiled into the `openshift-apiserver` binary. It cannot be added to a vanilla Kubernetes cluster by installing a CRD definition. This is a fundamental gap, not a configuration issue.

### Demand

Issue #509 was opened in June 2022 and has accumulated 30+ reactions over 4 years with no implementation, assignee, or design document. Comments on the issue show consistent demand from enterprise users running OpenShift who want vCluster's lightweight multi-tenancy without losing OpenShift APIs.

### Use cases

1. **AI/ML platforms**: Run RHOAI/ODH inside vClusters for per-team or per-workload version isolation while sharing a physical GPU pool via KAI Scheduler
2. **Dev/test environments**: Provide developers with isolated OpenShift-like namespaces without the cost of full OpenShift clusters
3. **Multi-tenancy on OpenShift**: Use vCluster for CRD isolation and API-level multi-tenancy on shared OpenShift infrastructure
4. **CI/CD**: Ephemeral OpenShift environments for integration testing

## Background

### How vCluster distros work

vCluster's architecture separates the **control plane** (API server, controller manager, backing store) from the **syncer** (which reconciles resources between virtual and host clusters). The syncer is completely distro-agnostic — it operates on standard Kubernetes resources regardless of which API server implementation is running.

Distros are container images containing Kubernetes binaries. An init container copies these binaries from the distro image into a shared volume:

```yaml
# From chart/templates/_init-containers.tpl
- name: kubernetes
  image: "ghcr.io/loft-sh/kubernetes:v1.36.0"
  command: ["cp"]
  args: ["-r", "/kubernetes/.", "/binaries/"]
  volumeMounts:
  - mountPath: /binaries
    name: binaries
```

The syncer process then launches `kube-apiserver`, `kube-controller-manager`, and optionally `kube-scheduler` from `/binaries/`. Configuration is defined in `config/config.go` (`DistroK8s` struct) and exposed via Helm values at `controlPlane.distro.k8s.*`.

This architecture is inherently extensible — adding a new distro means providing a new container image with additional binaries and startup logic.

### How OpenShift API aggregation works

In a standard OpenShift cluster, `openshift-apiserver` runs alongside `kube-apiserver` as a Kubernetes [aggregated API server](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/apiserver-aggregation/). The `kube-apiserver` proxies requests for OpenShift API groups to the `openshift-apiserver` via `APIService` registrations:

```
Client → kube-apiserver → [APIService: v1.image.openshift.io] → openshift-apiserver
```

This is a standard Kubernetes extension mechanism — the same one used by `metrics-server`, custom API servers, and service catalogs. The openshift-apiserver:
- Has its own etcd storage for OpenShift resources
- Delegates authentication and authorization back to kube-apiserver
- Uses front-proxy certificates for API aggregation trust

This means adding OpenShift APIs to vCluster requires running `openshift-apiserver` as a sidecar and registering its API groups via standard `APIService` objects. No modifications to vCluster's syncer or kube-apiserver are needed.

## Proof of Concept

We validated this approach on a live OpenShift 4.21.29 cluster with vCluster 0.36.1.

### What we built

The vCluster StatefulSet pod runs 3 containers:
1. **syncer** — standard vCluster control plane (kube-apiserver via kine + controller-manager)
2. **openshift-etcd** — dedicated etcd v3.5.17 sidecar on port 2479 with TLS
3. **openshift-apiserver** — from OCP 4.21.29 release payload, port 8444

Inside the vCluster, we registered 7 APIServices pointing to the openshift-apiserver and installed 6 CRD stubs required by admission plugin informers.

### What works

- openshift-apiserver starts, passes `/healthz`, and serves OpenShift APIs
- 7 OpenShift API groups registered and `Available: True` via API aggregation:
  - `image.openshift.io`, `route.openshift.io`, `apps.openshift.io`, `build.openshift.io`
  - `project.openshift.io`, `authorization.openshift.io`, `template.openshift.io`
- `kubectl get imagestreams` works inside the vCluster
- **ImageStream creation succeeds** — tested with an ODH notebook image reference
- Auth delegation to kube-apiserver works (authentication-kubeconfig + authorization-kubeconfig)

### Architecture

```
vCluster StatefulSet pod
├── syncer              (kube-apiserver + kine + controller-manager)
├── openshift-etcd      (dedicated etcd, port 2479, TLS)
├── openshift-apiserver (aggregated API server, port 8444)
│   ├── connects to openshift-etcd at https://127.0.0.1:2479
│   ├── delegates auth to kube-apiserver at https://127.0.0.1:6443
│   └── uses front-proxy certs for API aggregation
└── init: kubernetes    (copies K8s binaries)

Inside vCluster API:
├── APIService v1.image.openshift.io  → Service openshift-apiserver/api → pod:8444
├── APIService v1.route.openshift.io  → same
├── APIService v1.apps.openshift.io   → same
├── APIService v1.build.openshift.io  → same
├── APIService v1.project.openshift.io → same
├── APIService v1.authorization.openshift.io → same
├── APIService v1.template.openshift.io → same
├── CRD clusterresourcequotas.quota.openshift.io (stub)
├── CRD securitycontextconstraints.security.openshift.io (stub)
└── CRDs: imagecontentsourcepolicies, imagetagmirrorsets, imagedigestmirrorsets, ingresses (stubs)
```

### Issues encountered and resolved

We hit 6 issues during the PoC — all operational, none fundamental:

| # | Issue | Root Cause | Resolution |
|---|-------|-----------|------------|
| 1 | etcd cert path defaults | openshift-apiserver defaults to `/var/run/secrets/etcd-client/` | Explicit cert paths to vCluster's PKI at `/data/pki/` |
| 2 | kine TLS handshake failure | kine Unix socket is plain gRPC; openshift-apiserver's etcd client attempts TLS | Dedicated etcd sidecar on port 2479 with TLS |
| 3 | Auth delegation to host cluster | Pod's default `KUBERNETES_SERVICE_HOST` points to host API server | Set env `KUBERNETES_SERVICE_HOST=127.0.0.1` + kubeconfig flags |
| 4 | Loopback IP rejected in Endpoints | Kubernetes rejects `127.0.0.1` in Endpoints objects | Use pod's actual IP (needs automation on restart) |
| 5 | Admission plugin caches not synced | openshift-apiserver hardcodes its admission chain; `disabledAdmissionPlugins` is ignored | Install CRD stubs so informer caches sync with empty lists |
| 6 | `quota.openshift.io` returns "unsupported" | These API groups need backing infrastructure not present | Use CRDs instead of APIServices for `quota.openshift.io` and `security.openshift.io` |

Full details with error messages and fixes are documented in the [PoC README](openshift-apiserver-poc/README.md).

## Proposed Design

### Option A: Built-in distro (recommended)

Add OpenShift as a first-class distro alongside K8S, following the same patterns.

#### Config additions

Add a `DistroOpenShift` struct in `config/config.go` parallel to `DistroK8s`:

```go
type DistroOpenShift struct {
    Enabled bool `json:"enabled,omitempty"`

    // OpenShift API server (aggregated alongside kube-apiserver)
    APIServer DistroContainerEnabled `json:"apiServer,omitempty"`

    // OpenShift controller manager (ImageStream import, Build, DeploymentConfig controllers)
    ControllerManager DistroContainerEnabled `json:"controllerManager,omitempty"`

    // Dedicated etcd for openshift-apiserver storage
    Etcd DistroContainerEnabled `json:"etcd,omitempty"`

    // API groups to register (default: image, route, apps, build, project, authorization, template)
    APIGroups []string `json:"apiGroups,omitempty"`

    // OpenShift version (determines container image tag)
    Version string `json:"version,omitempty"`

    DistroCommon `json:",inline"`
}
```

Add to the `Distro` struct:

```go
type Distro struct {
    K8S       DistroK8s       `json:"k8s,omitempty"`
    OpenShift DistroOpenShift `json:"openShift,omitempty"`  // NEW
}
```

#### Helm values

```yaml
controlPlane:
  distro:
    openShift:
      enabled: false
      version: "4.21"
      apiServer:
        enabled: true
        extraArgs: []
      controllerManager:
        enabled: false   # optional, needed for ImageStream import
      etcd:
        enabled: true    # dedicated etcd for openshift-apiserver
        extraArgs: []
      apiGroups:
        - image.openshift.io
        - route.openshift.io
        - apps.openshift.io
        - build.openshift.io
        - project.openshift.io
        - authorization.openshift.io
        - template.openshift.io
      image:
        registry: quay.io
        repository: openshift-release-dev/ocp-v4.0-art-dev
        # tag determined by version or set explicitly
```

#### Container image

Build an OCP distro image containing:
- `openshift-apiserver` binary
- `openshift-controller-manager` binary (optional)
- `etcd` binary (for dedicated sidecar)
- Default config template

The image would be published to a registry (e.g., `ghcr.io/loft-sh/vcluster-openshift`) and extracted by an init container, same as the K8S distro:

```yaml
# chart/templates/_init-containers.tpl
- name: openshift
  image: "{{ .Values.controlPlane.distro.openShift.image.registry }}/{{ .Values.controlPlane.distro.openShift.image.repository }}:{{ tag }}"
  command: ["cp"]
  args: ["-r", "/openshift/.", "/binaries/openshift/"]
  volumeMounts:
  - mountPath: /binaries
    name: binaries
```

#### Startup sequence

New file `pkg/openshift/openshift.go` with `StartOpenShift()`:

```go
func StartOpenShift(ctx context.Context, vConfig *config.VirtualClusterConfig) error {
    ocpConfig := vConfig.ControlPlane.Distro.OpenShift

    // 1. Start dedicated etcd (if enabled)
    if ocpConfig.Etcd.Enabled {
        go startEtcd(ctx, vConfig)
    }

    // 2. Wait for kube-apiserver to be ready
    waitForAPI(ctx, vConfig)

    // 3. Register CRD stubs (admission plugin dependencies)
    registerCRDStubs(ctx, vConfig)

    // 4. Start openshift-apiserver
    if ocpConfig.APIServer.Enabled {
        go startOpenShiftAPIServer(ctx, vConfig)
        waitForOpenShiftAPI(ctx)
    }

    // 5. Register APIServices
    registerAPIServices(ctx, vConfig, ocpConfig.APIGroups)

    // 6. Start openshift-controller-manager (if enabled)
    if ocpConfig.ControllerManager.Enabled {
        go startOpenShiftControllerManager(ctx, vConfig)
    }

    return nil
}
```

This would be called from `pkg/setup/initialize.go` after `StartK8S()` completes.

#### Automatic resource registration

On startup, the OpenShift distro code would automatically:

1. Create the `openshift-apiserver` namespace inside the vCluster
2. Create the Service and Endpoints pointing to the openshift-apiserver sidecar
3. Register APIService objects for each configured API group
4. Install CRD stubs for admission plugin dependencies
5. Watch for pod IP changes and update Endpoints (solves the restart problem)

#### Etcd sidecar

The dedicated etcd runs as an additional container in the StatefulSet:
- Listens on `https://127.0.0.1:2479` (avoids port conflict with any embedded etcd)
- Uses the same PKI as vCluster's kube-apiserver (certs at `/data/pki/etcd/`)
- Data stored in a PVC subpath or emptyDir (configurable for persistence)

**Why not share kine?** vCluster's default backing store is kine (SQLite-backed etcd shim) accessed via a Unix socket. The openshift-apiserver's etcd client always attempts TLS when cert paths are configured, but kine's Unix socket serves plain gRPC — causing `tls: first record does not look like a TLS handshake`. A dedicated etcd with TLS is the clean solution.

### Option B: Plugin-based approach (alternative)

Use vCluster's plugin system to deploy openshift-apiserver and manage APIService registration:

```yaml
plugins:
  openshift:
    image: ghcr.io/myorg/vcluster-openshift-plugin:v1
```

**Pros**: No core vCluster changes, can evolve independently.
**Cons**: Plugins run as separate processes with IPC overhead, limited access to startup lifecycle, can't inject sidecar containers into the StatefulSet (plugins run inside the syncer container). The openshift-apiserver needs to be a sidecar with shared `/data` volume access — this doesn't fit the plugin model.

**Recommendation**: Option A (built-in distro). The plugin system is designed for custom syncers and resource translation, not for adding fundamental API server components.

## Phased Implementation

### Phase 1: Minimum viable — ImageStream support

- openshift-apiserver sidecar with dedicated etcd
- APIService registration for `image.openshift.io`
- CRD stubs for admission plugin dependencies
- Automatic Endpoints IP management
- Config struct and Helm values

This alone unblocks RHOAI workbenches and any workload that depends on ImageStream.

### Phase 2: Full OpenShift API surface

- Additional API groups: route, apps, build, project, authorization, template
- openshift-controller-manager sidecar (ImageStream import, Build controllers)
- Configurable API groups (users can enable only what they need)

### Phase 3: Ecosystem integration

- **Route syncing**: Sync Route objects from vCluster to host cluster (translate to host Routes or Ingress objects)
- **service-ca**: Minimal controller for `service.beta.openshift.io/serving-cert-secret-name` annotation — auto-provisions TLS certs for webhooks
- **SCC syncing**: Map vCluster SecurityContextConstraints to host Pod Security Standards
- **Persistent etcd**: PVC-backed storage for openshift-apiserver's etcd data

## Key Technical Decisions

### Why a separate etcd?

vCluster uses kine (SQLite-backed etcd shim) via a Unix socket at `/data/kine.sock`. The openshift-apiserver's etcd client library always attempts a TLS handshake when TLS certificates are configured. Kine's Unix socket serves plain gRPC without TLS, causing immediate connection failure.

Options considered:
1. **Disable TLS on openshift-apiserver's etcd client** — not possible, cert paths are populated from config defaults
2. **Add TLS to kine** — would require vCluster core changes and affect all distros
3. **Dedicated etcd sidecar** — clean isolation, uses existing PKI, no vCluster core changes ✓

### Why CRD stubs?

The openshift-apiserver hardcodes its admission plugin chain. Neither the `disabledAdmissionPlugins` config field nor the `--disable-admission-plugins` flag work. Admission plugins like `ClusterResourceQuota` start informer watches for their resource types. If the CRD doesn't exist, the informer cache never syncs, and the plugin blocks all writes with `caches not synchronized`.

Installing the CRD definitions (schema only, no instances needed) allows the informers to sync with empty lists, unblocking the admission plugins. This is the same approach used by MicroShift for running openshift-apiserver in minimal environments.

### Why `insecureSkipTLSVerify` on APIServices?

The openshift-apiserver uses a self-signed serving certificate. Configuring the kube-apiserver to trust this CA would require modifying vCluster's API server startup flags. Using `insecureSkipTLSVerify: true` on the APIService is simpler and safe because the traffic is pod-internal (localhost to localhost via pod IP).

In production, this should be replaced with proper CA trust configuration.

### Endpoints IP automation

Kubernetes rejects loopback addresses (`127.0.0.1`) in Endpoints objects. The Endpoints must use the pod's actual IP, which changes on every pod restart. The OpenShift distro startup code should:
1. Detect the current pod IP from the downward API
2. Create/update Endpoints on startup
3. Watch for IP changes via a controller

## Alternatives Considered

### HyperShift (Hosted Control Planes)

HyperShift deploys full OpenShift control planes as workloads. It provides complete OpenShift API compatibility but at the cost of a full control plane per tenant (etcd StatefulSet, API server Deployment, controller-manager Deployment, scheduler Deployment). For GPU sharing scenarios where hundreds of tenants share a physical cluster, this is too heavyweight — and it breaks shared scheduling because each HyperShift cluster has its own scheduler and node pool.

### MicroShift

MicroShift embeds OpenShift APIs as goroutines in a single binary optimized for edge. It demonstrates that openshift-apiserver can run in minimal environments, but its embedded architecture (single systemd process) doesn't map to vCluster's multi-container pod model. However, MicroShift's approach to CRD stubs for admission plugins informed our PoC solution.

### CRD reimplementation

Reimplement ImageStream as a CRD + custom controller. This would avoid the openshift-apiserver entirely but would require reimplementing the full ImageStream API surface (import, tag resolution, scheduled imports, triggers). It would also diverge from upstream OpenShift, causing compatibility issues with any workload that expects the real ImageStream API behavior.

## Open Questions

1. **Image sourcing**: Should the OpenShift distro image be built from OCP release payloads (`oc adm release info --image-for=openshift-apiserver`), from source (`github.com/openshift/openshift-apiserver`), or from OKD community images? Release payload images are production-tested but may have Red Hat licensing implications.

2. **Version matrix**: Which OpenShift versions should be supported? The openshift-apiserver version should roughly match the kube-apiserver version in the K8S distro (OCP 4.x maps to K8s 1.y). How should version skew be handled?

3. **Pro vs OSS**: Should this be a vCluster Pro feature or open source? The distro architecture is open source, but Loft Labs may have commercial considerations.

4. **Syncer changes**: Are any syncer modifications needed for OpenShift resource types, or does the existing syncer handle them transparently? Initial testing suggests the syncer is fully agnostic, but Route syncing (Phase 3) may need a custom syncer plugin.

5. **Testing infrastructure**: How should E2E tests for the OpenShift distro run in CI? They require an OpenShift host cluster for the vCluster to run on.

## References

- [vCluster issue #509](https://github.com/loft-sh/vcluster/issues/509) — original feature request
- [Kubernetes API Aggregation](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/apiserver-aggregation/) — the pattern used by openshift-apiserver
- [OpenShift API Server source](https://github.com/openshift/openshift-apiserver)
- [OpenShift Controller Manager source](https://github.com/openshift/openshift-controller-manager)
- [MicroShift](https://github.com/openshift/microshift) — minimal OpenShift for edge
- [HyperShift](https://github.com/openshift/hypershift) — hosted OpenShift control planes
- PoC artifacts: `openshift-apiserver-poc/` directory (config, patch, k8s manifests, README)
