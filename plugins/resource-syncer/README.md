# resource-syncer

vCluster plugin that syncs configured resources from the virtual cluster to the host cluster.

## Why

The openshift-apiserver sidecar gives the vCluster working OpenShift APIs, but resources created inside the vCluster (Routes, etc.) are invisible to the host cluster. This plugin watches configured resources in the vCluster, creates corresponding objects on the host (with translated names), and syncs status back.

## How it works

```
Virtual cluster                          Host cluster
┌─────────────────┐                     ┌──────────────────────┐
│ Route: my-route  │──── plugin ────►   │ Route: my-route-x-   │
│   to: my-svc     │    syncs           │       default-x-ocp  │
│   status: ?      │◄── status ────     │   to: my-svc-x-      │
│   status: ✓      │    back            │       default-x-ocp  │
└─────────────────┘                     │   status: admitted ✓  │
                                        └──────────────────────┘
```

- **Spec flows virtual → host**: Resource spec is copied to the host with name translations.
- **Status flows host → virtual**: Status is synced back so operators inside the vCluster see the resource as reconciled.
- **Cleanup**: Deleting a resource in the vCluster deletes the corresponding host resource.

## Configuration

Which resources to sync is specified in the plugin config (in vCluster values.yaml):

```yaml
plugins:
  resource-syncer:
    image: quay.io/<org>/vcluster-resource-syncer:latest
    config:
      resources:
        - apiVersion: route.openshift.io/v1
          kind: Route
        - apiVersion: cert-manager.io/v1
          kind: Certificate
    rbac:
      role:
        extraRules:
          - apiGroups: ["route.openshift.io"]
            resources: ["routes", "routes/status"]
            verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
          # Add RBAC for each additional resource type
```

### Typed vs generic syncers

Resources with a registered **typed syncer** (like Routes) get special handling — e.g., Service name translation in Route backends. Everything else gets a **generic syncer** that copies `spec` virtual→host and `status` host→virtual without any field-level translations.

To add a typed syncer for a new resource, add a file in `syncers/` and register it in `main.go`'s `typedSyncers` map.

## Build

```bash
# From the repo root
make build-plugin RESOURCE_SYNCER_IMAGE=quay.io/<org>/vcluster-resource-syncer:latest
make push-plugin
```

## Deploy

Pass `RESOURCE_SYNCER_IMAGE` when deploying the vCluster:

```bash
RESOURCE_SYNCER_IMAGE=quay.io/<org>/vcluster-resource-syncer:latest \
OPENSHIFT_APISERVER_IMAGE=... \
make deploy
```

The plugin is optional. If `RESOURCE_SYNCER_IMAGE` is not set, the vCluster deploys without it.

## Route-specific translations

| Route field | Translation |
|---|---|
| `spec.to.name` | Service name mangled to host format |
| `spec.alternateBackends[].name` | Same |
| `spec.host` | Kept as-is |
| `spec.tls` | Kept as-is |
| `spec.path`, `spec.port` | Kept as-is |
| `status.ingress` | Copied from host Route back to virtual |

## Limitations

- **TLS `externalCertificate`**: If a Route references a Secret by name via `spec.tls.externalCertificate`, the Secret name is not translated. Use inline `certificate`/`key` fields instead.
- **Host router must accept the hostname**: The Route's `spec.host` must match the host cluster's wildcard domain (e.g., `*.apps.<cluster>`), or the router will reject it.
- **Generic syncer doesn't translate names**: Only typed syncers translate resource references (like Service names). Generic syncers copy spec as-is.
