# Separate openshift-apiserver Deployment

## Problem

The vCluster pod currently runs 5 containers: syncer, kube-apiserver, etcd (openshift),
openshift-apiserver, and openshift-compat-proxy. Any one crashing restarts the entire pod,
taking down the control plane.

## Proposal

Move openshift-apiserver + its dedicated etcd into a separate Deployment in the same namespace.
The APIService already points at a Service (`openshift-apiserver/api`), not directly at the pod,
so this would be transparent to API aggregation.

The openshift-compat-proxy could also move to this Deployment since it serves the user.openshift.io
aggregation backend (port 8446) and the front-proxy (port 6443). However, the front-proxy on 6443
needs to sit in front of the kube-apiserver, so it may need to stay in the vCluster pod.

## Tradeoffs

**Pros:**
- openshift-apiserver crash doesn't kill the kube-apiserver and vice versa
- Independent scaling and resource limits
- Cleaner separation of concerns
- Easier to debug (logs, restarts are isolated)

**Cons:**
- More deployment complexity (second Deployment, shared certs/volumes)
- The openshift-apiserver needs access to the vCluster's kube-apiserver (admin.conf, front-proxy CA)
  — currently gets these via the shared `data` volume mount. A separate Deployment would need
  these mounted from Secrets.
- Two things to monitor instead of one
- Deploy script gets more complex (or this becomes the forcing function to move to a controller)

## Priority

Low — the current single-pod approach works. Revisit if stability becomes an issue at scale
or if we move the deploy logic to a controller/operator.
