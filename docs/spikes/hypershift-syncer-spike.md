# Spike: HyperShift Control Plane + vCluster Syncer

**Date**: 2026-11-04
**Branch**: `feat/hypershift-syncer-spike`
**Status**: Research complete
**Verdict**: Conditional go — feasible with bounded engineering work on the vCluster syncer

## Motivation

Our current approach (`feat/hypershift-components`) bolts individual OpenShift components onto vCluster as sidecars. It works, but we're reimplementing what HyperShift already solves: running a full OCP control plane outside the worker nodes.

This spike investigates a different architecture: let HyperShift deploy the real OCP control plane (using `None` platform), then replace its node/machine management with vCluster's syncer — which already knows how to reflect host nodes into a virtual cluster and schedule pods back onto the host.

If this works, we get a full OpenShift control plane (not just openshift-apiserver) with the multi-tenant density of vCluster.

## Architecture

```
Management OCP Cluster
│
├── Namespace: clusters-tenant-a          (HyperShift hosted control plane)
│   ├── kube-apiserver                    ── real OCP API server
│   ├── openshift-apiserver               ── ImageStreams, Routes, Builds
│   ├── openshift-controller-manager      ── ImageStream imports, build controller
│   ├── cluster-policy-controller         ── SCC enforcement
│   ├── oauth-apiserver                   ── Users, Groups, OAuth
│   ├── openshift-oauth-server            ── OAuth login flows
│   ├── etcd (3 pods)                     ── HA etcd cluster
│   ├── kube-controller-manager           ── core k8s controllers
│   ├── kube-scheduler                    ── scheduling
│   ├── cluster-version-operator          ── manages OCP operators
│   ├── ... (~40 more operator pods)
│   │
│   └── vcluster-syncer (NEW)             ── replaces NodePool/Machine management
│       ├── reflects host nodes → HyperShift guest API
│       ├── translates virtual pods → host pods
│       └── syncs Services, ConfigMaps, Secrets, etc.
│
├── Namespace: clusters-tenant-b          (another tenant, same pattern)
│   └── ...
│
└── Shared GPU worker nodes               (real workloads land here)
    ├── node-1 (A100)
    ├── node-2 (H100)
    └── ...
```

**Data flow:**
```
User kubectl ──► HyperShift KAS (tenant namespace)
                      │
                      ├── OCP APIs (ImageStream, Route, etc.) ──► openshift-apiserver
                      ├── Auth ──► oauth-apiserver
                      └── Pod scheduling ──► kube-scheduler
                              │
                              ▼
                      vcluster-syncer
                              │
                      ┌───────┴───────┐
                      │               │
                ┌─────▼─────┐   ┌─────▼─────┐
                │ Reflect   │   │ Translate  │
                │ host nodes│   │ virtual    │
                │ into guest│   │ pods to    │
                │ API       │   │ host pods  │
                └───────────┘   └───────────┘
                      │
                      ▼
              Host cluster (shared GPU workers)
```

## Key Findings

### HyperShift None Platform: Suitable

HyperShift's `None` platform (`hypershift-operator/controllers/hostedcluster/internal/platform/none/none.go`) is a no-op implementation — every method returns nil. It deploys the full OCP control plane but performs zero infrastructure provisioning. Workers must be externally managed.

This is exactly our use case: we want the control plane, and we supply workers via the syncer.

**What HyperShift None deploys** (~51 pods, ~2.4 cores / 7.35 GiB per tenant):

| Component | Pods | CPU Request | Memory Request |
|-----------|------|-------------|----------------|
| etcd | 3 | 300m | 600Mi |
| kube-apiserver | 1-3 | 350m+ | 1.5Gi+ |
| openshift-apiserver | 1 | 100m | 200Mi |
| kube-controller-manager | 1 | 60m | 200Mi |
| openshift-controller-manager | 1 | 100m | 100Mi |
| cluster-policy-controller | 1 | 10m | 50Mi |
| oauth-apiserver | 1 | 20m | 50Mi |
| openshift-oauth-server | 1 | 10m | 50Mi |
| cluster-version-operator | 1 | 20m | 75Mi |
| control-plane-operator | 1 | 10m | 80Mi |
| hosted-cluster-config-operator | 1 | 10m | 60Mi |
| ~25 other operator pods | ~25 | ~500m | ~2Gi |
| **Total** | **~51** | **~2.4 cores** | **~7.35 GiB** |

Compare with our sidecar approach: 7 containers in 1 pod, ~800m CPU, ~1.5Gi memory. HyperShift is ~3x heavier but gives a complete OCP control plane with HA support.

### vCluster Syncer: Cannot Connect to External API Server (Today)

**This is the critical blocker.** The syncer assumes it owns the virtual cluster's control plane and cannot be pointed at an external kube-apiserver.

Four hardcoded assumptions prevent this:

#### 1. Kubeconfig path is hardcoded

**File**: `pkg/setup/controller_context.go:197-202`

```go
func waitForClientConfig(ctx context.Context, options *VirtualClusterOptions) (clientcmd.ClientConfig, error) {
    return clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
        &clientcmd.ClientConfigLoadingRules{ExplicitPath: options.VirtualClusterKubeConfig().KubeConfig},
        &clientcmd.ConfigOverrides{},
    ), nil
}
```

`VirtualClusterKubeConfig().KubeConfig` resolves to the constant `/data/pki/admin.conf`. No CLI flag, no env var override.

#### 2. Server URL always rewritten to localhost

**File**: `pkg/setup/controller_context.go:257-277`

```go
func CreateVClusterKubeConfig(config *rest.Config, options *VirtualClusterOptions) *rest.Config {
    // ...
    config.Host = fmt.Sprintf("https://localhost:%d", options.Port)
    // ...
}
```

Even if you injected a kubeconfig pointing to HyperShift's KAS, the syncer would overwrite the server URL.

#### 3. Control plane startup is mandatory

**File**: `pkg/setup/initialize.go:21-103`

```go
func initialize(ctx context.Context, ...) error {
    // Always starts backing store, kube-apiserver, controller-manager
    err = k8s.StartK8S(ctx, ...)
    // No conditional path to skip this
}
```

The syncer always launches its own kube-apiserver + etcd/kine + controller-manager. There is no "headless" or "external" mode.

#### 4. No external distro in config schema

**File**: `config/config.go:2139-2161`

```go
type Distro struct {
    K8S K8S `json:"k8s,omitempty"`
    // Only K8S — no EKS, no External, no None
}
```

The config schema has a single distro option (`K8S`). There's no extension point for "connect to an existing API server."

### What Already Works in the Syncer

Despite the blocker above, the syncer's resource-syncing logic is well-suited for this use case:

- **Node reflection**: `pkg/controllers/resources/nodes/syncer.go` creates Node objects in the virtual cluster by copying from the host. Does not require kubelet registration — purely API-driven.
- **Pod translation**: Translates virtual pod specs to host pods with namespace/name rewriting, label translation, and DNS configuration.
- **31 resource types**: ConfigMaps, Secrets, Services, Endpoints, PVCs, PVs, Ingresses, NetworkPolicies, ServiceAccounts, etc.
- **Plugin system**: `pkg/plugin/` supports custom syncers for additional resource types (we already use this for Routes).
- **Selective sync**: Resources can be enabled/disabled per type with filtering rules.

### Required Changes to Make This Work

The syncer modifications are bounded — no need to rewrite the sync logic itself, just the initialization path:

| Change | File(s) | Effort |
|--------|---------|--------|
| Add `--virtual-cluster-server` flag | `cmd/vcluster/cmd/start.go` | Small |
| Add `--virtual-cluster-kubeconfig` flag | `cmd/vcluster/cmd/start.go` | Small |
| Add `External` distro type to config | `config/config.go` | Small |
| Skip control plane startup for External | `pkg/setup/initialize.go` | Medium |
| Remove localhost URL rewriting for External | `pkg/setup/controller_context.go` | Small |
| Support external kubeconfig loading | `pkg/setup/controller_context.go` | Small |
| Handle cert/auth differences | Various | Medium |
| Test with HyperShift KAS | — | Medium |

**Estimated effort**: 2-3 weeks for a working prototype, assuming familiarity with Go and the vCluster codebase. The sync engine, plugin system, and resource controllers don't need changes — only the bootstrap/init path.

### Compatibility Gaps and Mitigations

| Gap | Impact | Mitigation |
|-----|--------|------------|
| Syncer creates Nodes via API, not kubelet | HyperShift expects kubelet-registered nodes with proper conditions and capacity | Extend node syncer to set all conditions HyperShift's machine-approver and node-healthcheck-controller expect |
| No NodePool/Machine integration | HyperShift's CAPI controllers manage machines via NodePools | Disable CAPI controllers; syncer provides nodes directly. May need a shim MachineSet to satisfy CVO expectations |
| Syncer doesn't run kubelet | Some OCP operators expect kubelet metrics, node-level DaemonSets | Run a minimal kubelet shim or stub the expected endpoints. DaemonSets should sync naturally via pod translation |
| Pod identity differs on host | Service accounts, projected tokens differ between virtual and host | Syncer already handles SA token projection for vanilla k8s; verify OCP-specific token audience works |
| OCP-specific resources not synced | Routes, ImageStreams, BuildConfigs not in default sync list | Use plugin system (we already have a Route syncer); add syncers for each OCP resource type |
| Network policy enforcement | Host cluster may use different CNI than what OCP operators expect | Rely on host CNI; virtual NetworkPolicies are already synced to host |
| CSI/storage | OCP storage operators expect specific CSI drivers | Map virtual StorageClasses to host classes (syncer already supports this) |
| Monitoring stack | OCP deploys Prometheus operator, expects node metrics | Disable in-cluster monitoring or point at host Prometheus |

### Comparison with Current Sidecar Approach

| Dimension | Sidecar (current) | HyperShift + Syncer (this spike) |
|-----------|-------------------|-----------------------------------|
| **OCP API coverage** | 7 API groups via sidecars | Full OCP API surface |
| **Resource overhead** | ~800m CPU, ~1.5Gi mem, 1 pod | ~2.4 cores, ~7.35Gi, ~51 pods |
| **Operator compatibility** | Partial — no CVO, no monitoring | Full — CVO manages operators natively |
| **Engineering effort** | Done (feat/hypershift-components) | 2-3 weeks for syncer fork, ongoing integration |
| **Maintenance burden** | We own sidecar configs, version bumps | HyperShift manages component lifecycle |
| **HA support** | None (single pod) | Built-in (multi-replica KAS, HA etcd) |
| **Time to tenant** | Seconds (single pod start) | Minutes (51 pods, operator reconciliation) |
| **Upstream alignment** | Custom — our integration | Follows HyperShift patterns |
| **GPU scheduling** | Works via syncer | Works via syncer (same mechanism) |

## Feasibility Verdict: Conditional Go

**The architecture is sound, but requires a vCluster syncer fork.**

The integration is feasible because:

1. **HyperShift None platform** already does what we need — deploys a full OCP control plane with no infrastructure opinions about workers.
2. **vCluster syncer** already has the exact sync logic we need — node reflection, pod translation, resource syncing, plugin system.
3. **The gap is narrow** — only the syncer's init/bootstrap path needs changes. The sync engine itself works as-is.
4. **Changes are bounded** — ~6 files, no architectural redesign. Add a flag, add a distro type, add a conditional to skip local control plane startup.

The risk is:

1. **Maintaining a fork** — upstream vCluster has no interest in "external distro" mode (it would cannibalize their product). We'd carry patches indefinitely.
2. **HyperShift expectations** — unclear how well node reflection (without real kubelet) satisfies HyperShift's machine health checking, node approval, and operator prerequisites.
3. **3x resource overhead** — may or may not matter depending on tenant count and available management cluster capacity.

## Next Steps (if proceeding)

1. **Fork vCluster syncer** — create `github.com/<org>/vcluster` fork with External distro support
2. **Prototype External distro** — implement the 6 changes listed above, deploy syncer pointing at a HyperShift None cluster's KAS
3. **Validate node lifecycle** — verify HyperShift accepts syncer-reflected nodes (conditions, capacity, allocatable)
4. **Validate pod scheduling** — create a pod in the HyperShift guest cluster, verify it lands on a shared host node
5. **Test OCP operators** — install ODH, create DataScienceCluster, verify notebook workbench creation
6. **Benchmark** — measure time-to-tenant, resource overhead, and pod startup latency vs. sidecar approach
7. **Decision point** — if prototype works, evaluate fork maintenance cost vs. operational benefits

## Recommendation

**Continue with the sidecar approach (`feat/hypershift-components`) for near-term production use.** It's working, it's lightweight, and it covers our immediate needs (ImageStreams, Routes, SCCs, Users for RHOAI).

**Pursue the HyperShift + syncer approach as a parallel track** for environments that need full OCP fidelity (CVO-managed operators, HA control plane, complete API surface). The syncer fork is a ~2-3 week investment that could unlock significantly broader OpenShift compatibility.

The two approaches aren't mutually exclusive — the sidecar model can serve as the "lite" tier while HyperShift + syncer becomes the "full" tier, letting us match resource overhead to tenant requirements.
