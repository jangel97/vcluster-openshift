package syncers

import (
	"fmt"
	"resource-syncer/pkg"

	"github.com/loft-sh/vcluster/pkg/syncer/synccontext"
	syncertypes "github.com/loft-sh/vcluster/pkg/syncer/types"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
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

func NewSCCSyncer(ctx *synccontext.RegisterContext) syncertypes.Base {
	vclusterName := ctx.Config.Name

	obj := &unstructured.Unstructured{}
	obj.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   "security.openshift.io",
		Version: "v1",
		Kind:    "SecurityContextConstraints",
	})

	return pkg.NewSyncer(ctx, pkg.SyncerConfig[*unstructured.Unstructured]{
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
}
