# Live Projected Resources

## Problem

Projected host resources (ClusterVersion, Infrastructure, Ingress, Authentication) are copied
once at deploy time. If the host cluster upgrades, changes IDP config, or rotates ingress
certs, the vCluster still shows stale data.

This is the same class of bug we already fixed for OAuth metadata — switching from a static
ConfigMap copy to a live proxy through the openshift-compat-proxy.

## Affected Resources

| Resource | Group | Why it matters |
|----------|-------|---------------|
| `clusterversions/version` | config.openshift.io | RHOAI checks OCP version for compatibility |
| `authentications/cluster` | config.openshift.io | IDP config, OAuth metadata URL |
| `ingresses/cluster` | config.openshift.io | Routing subdomain, ingress certs |
| `infrastructures/cluster` | config.openshift.io | Platform type, API/console URLs |

## Options

1. **Resource-syncer watch** — add a typed syncer in the plugin that watches these on the host
   and keeps the virtual copy in sync (one-way, host→virtual). Cleanest solution, reuses
   existing plugin infrastructure.

2. **Periodic re-copy** — a CronJob or controller that re-runs the copy logic on a schedule.
   Simpler but introduces drift windows.

3. **Proxy pattern** — like OAuth metadata, intercept API calls for these resources and proxy
   to the host live. More complex, would need to handle writes (which should be blocked).

## Recommendation

Option 1 (resource-syncer watch) fits best. These are singleton cluster-scoped resources that
rarely change — a watch is cheap and keeps the vCluster always in sync.

## Implementation Notes

- The syncer should be host→virtual only (no writes back to host)
- Status subresources need syncing too (ClusterVersion status has the actual version info)
- Could reuse the existing `pkg.NewSyncer` with a `HostToVirtual` direction if supported,
  or implement a simple informer-based watch
