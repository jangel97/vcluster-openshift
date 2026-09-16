# SCC Compatibility Bridge

## Problem

vCluster syncer creates host pods directly (not via Deployments/ReplicaSets).
OpenShift SCC admission evaluates the **creating user** — the syncer SA (`vc-ocp-test`),
which has `privileged` + `anyuid` for its own infrastructure needs.
Every tenant workload inherits `anyuid` regardless of what it actually needs.

We proved this with a controlled test — same pod, same workload SA:

| Who creates the pod             | SCC assigned   |
|---------------------------------|----------------|
| `vc-ocp-test` (syncer)          | `anyuid`       |
| `vc-workload-ocp-test` (direct) | `restricted-v2`|

The workload SA itself only has `restricted-v2` via `system:authenticated`.

## What works today

- SCC CRD stubs accept any schema (`x-kubernetes-preserve-unknown-fields: true` at root)
- KServe can create SCC objects inside the vCluster (e.g. `openshift-ai-llminferenceservice-scc`)
- `openshift.io/required-scc` annotation on host pods forces the exact SCC — proven manually
- Host SCC mutations (SELinux, caps) stay on host pod only, no sync-back conflicts

## What doesn't work

- vCluster OSS `translatePatches` is a **Pro-only feature** — can't use it to inject annotations
- No bridge between virtual SCC RBAC grants and host SCC admission
- Tenants cannot create custom SCCs and have them enforced on the host

## Goal

Make the full SCC lifecycle work like native OpenShift:

1. User creates a custom SCC inside the vCluster
2. User grants `use` of that SCC to a ServiceAccount through RBAC
3. Workload uses that ServiceAccount
4. The resulting physical pod is admitted using the corresponding host SCC

Host OpenShift remains the actual enforcement layer.

## Proposed Design

### SCC syncer (new typed syncer in plugin)

- Watch SCC objects inside the vCluster
- Create a prefixed host SCC: `vc-<vcluster>-<virtual-scc-name>`
- Copy the SCC spec (allowedCapabilities, runAsUser strategy, seLinuxContext, volumes, etc.)
- Clean up host SCC when virtual SCC is deleted
- **Never** sync host SCCs back into the vCluster — one-way only
- Reject/ignore virtual SCCs that reference host SCC names outside the vCluster prefix

### RBAC bridge

- Watch RoleBindings/ClusterRoleBindings inside the vCluster that grant `use` on SCC resources
- For each grant: create a corresponding host ClusterRoleBinding granting the **translated** workload SA
  `use` of the prefixed host SCC (`vc-<vcluster>-<scc-name>`)
- Clean up host RBAC when virtual bindings are deleted

### Pod mutation (plugin hook)

- Register `MutateCreatePhysical` hook in the plugin
- Before the syncer creates a host pod:
  1. Resolve the virtual pod's ServiceAccount
  2. Evaluate which virtual SCCs that SA is allowed to `use`
  3. Run minimal SCC selection: priority first, then choose an SCC capable of admitting the pod
  4. Map to the corresponding prefixed host SCC name
  5. Set `openshift.io/required-scc` annotation on the host pod
- Strip any tenant-provided `openshift.io/required-scc` or `openshift.io/scc` annotations
  to prevent tenants from referencing arbitrary host SCCs

### Default behavior

- If no explicit SCC grant exists for the SA, default to `restricted-v2`
  (the same SCC that `system:authenticated` gets on the host)
- The `vc-workload-<vcluster>` SA already has `restricted-v2` via `system:authenticated`,
  so this is a no-op on the host side

## Test Plan

| Test | Description | Expected |
|------|-------------|----------|
| A | Default workload, no SCC grant | `restricted-v2` |
| B | Custom SCC + Role/RoleBinding to SA | Custom mapped SCC (`vc-<name>-<scc>`) |
| C | Same custom SCC, no RBAC grant to SA | Workload must NOT get it, falls back to restricted-v2 |
| D | Two usable SCCs with different priorities | Higher priority wins (matches OpenShift behavior) |
| E | Tenant sets `openshift.io/required-scc: privileged` | Stripped/overridden by plugin, gets restricted-v2 |

## Implementation Order

1. Pod mutation hook — inject `openshift.io/required-scc: restricted-v2` on all host pods (baseline)
2. SCC syncer — sync virtual SCCs to prefixed host SCCs
3. RBAC bridge — sync virtual SCC grants to host RBAC
4. SCC selection logic — evaluate SA grants and pick the right SCC
5. Tests A-E

## Notes

- vCluster SDK exposes `MutateCreatePhysical` / `MutateUpdatePhysical` hooks
- OpenShift SCC priority: higher number = higher priority, `anyuid` is 10, `restricted-v2` is null (0)
- The syncer SA (`vc-ocp-test`) must keep `privileged` for its own sidecars —
  the bridge isolates tenant workloads from the syncer's elevated access
- This approach does NOT require implementing full SCC admission inside the vCluster —
  host OpenShift does the real validation, we just direct which SCC it uses
