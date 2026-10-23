package syncers

import (
	"fmt"
	"resource-syncer/pkg"
	"strings"

	"github.com/loft-sh/vcluster/pkg/patcher"
	"github.com/loft-sh/vcluster/pkg/syncer/synccontext"
	syncertypes "github.com/loft-sh/vcluster/pkg/syncer/types"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/klog/v2"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

var sccSpecFields = []string{
	"allowPrivilegedContainer",
	"allowedCapabilities",
	"defaultAddCapabilities",
	"requiredDropCapabilities",
	"volumes",
	"allowHostNetwork",
	"allowHostPorts",
	"allowHostPID",
	"allowHostIPC",
	"runAsUser",
	"seLinuxContext",
	"fsGroup",
	"supplementalGroups",
	"priority",
	"readOnlyRootFilesystem",
	"users",
	"groups",
	"seccompProfiles",
	"allowedUnsafeSysctls",
	"forbiddenSysctls",
	"defaultAllowPrivilegeEscalation",
	"allowPrivilegeEscalation",
	"allowedFlexVolumes",
}

func NewSCCSyncer(ctx *synccontext.RegisterContext, ceiling map[string]interface{}) syncertypes.Base {
	vclusterName := ctx.Config.Name

	obj := &unstructured.Unstructured{}
	obj.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   "security.openshift.io",
		Version: "v1",
		Kind:    "SecurityContextConstraints",
	})

	inner := pkg.NewSyncer(ctx, pkg.SyncerConfig[*unstructured.Unstructured]{
		Name:   "scc",
		Object: obj,
		HostNameFunc: func(_ *synccontext.SyncContext, vName, _ string) types.NamespacedName {
			return types.NamespacedName{Name: fmt.Sprintf("vc-%s-%s", vclusterName, vName)}
		},
		SyncFields: func(_ *synccontext.SyncContext, host, virtual *unstructured.Unstructured) {
			for _, field := range sccSpecFields {
				if val, ok := virtual.Object[field]; ok {
					host.Object[field] = val
				}
			}
		},
	})

	if len(ceiling) == 0 {
		return inner
	}

	return &ceilingSCCSyncer{
		Base:    inner,
		ceiling: ceiling,
	}
}

type ceilingSCCSyncer struct {
	syncertypes.Base
	ceiling map[string]interface{}
}

func (s *ceilingSCCSyncer) Syncer() syncertypes.Sync[client.Object] {
	inner := s.Base.(syncertypes.Syncer).Syncer()
	return &ceilingSyncInterceptor{
		inner:   inner,
		ceiling: s.ceiling,
	}
}

type ceilingSyncInterceptor struct {
	inner   syncertypes.Sync[client.Object]
	ceiling map[string]interface{}
}

func (c *ceilingSyncInterceptor) SyncToHost(ctx *synccontext.SyncContext, event *synccontext.SyncToHostEvent[client.Object]) (ctrl.Result, error) {
	if event.Virtual != nil {
		u, ok := event.Virtual.(*unstructured.Unstructured)
		if ok {
			if violations := ValidateSCCAgainstCeiling(u.Object, c.ceiling); len(violations) > 0 {
				klog.Warningf("scc-ceiling: blocking sync of SCC %q to host: %s",
					u.GetName(), strings.Join(violations, "; "))
				return ctrl.Result{}, nil
			}
		}
	}
	return c.inner.SyncToHost(ctx, event)
}

func (c *ceilingSyncInterceptor) Sync(ctx *synccontext.SyncContext, event *synccontext.SyncEvent[client.Object]) (ctrl.Result, error) {
	if event.Virtual != nil {
		u, ok := event.Virtual.(*unstructured.Unstructured)
		if ok {
			if violations := ValidateSCCAgainstCeiling(u.Object, c.ceiling); len(violations) > 0 {
				klog.Warningf("scc-ceiling: SCC %q exceeds ceiling, deleting host copy: %s",
					u.GetName(), strings.Join(violations, "; "))
				return patcher.DeleteHostObject(ctx, event.Host, event.Virtual, "SCC exceeds ceiling")
			}
		}
	}
	return c.inner.Sync(ctx, event)
}

func (c *ceilingSyncInterceptor) SyncToVirtual(ctx *synccontext.SyncContext, event *synccontext.SyncToVirtualEvent[client.Object]) (ctrl.Result, error) {
	return c.inner.SyncToVirtual(ctx, event)
}
