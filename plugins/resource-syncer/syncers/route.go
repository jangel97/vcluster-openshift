package syncers

import (
	routev1 "github.com/openshift/api/route/v1"
	"resource-syncer/pkg"

	"github.com/loft-sh/vcluster/pkg/scheme"
	"github.com/loft-sh/vcluster/pkg/syncer/synccontext"
	syncertypes "github.com/loft-sh/vcluster/pkg/syncer/types"
	"github.com/loft-sh/vcluster/pkg/util/translate"
)

func init() {
	_ = routev1.Install(scheme.Scheme)
}

func NewRouteSyncer(ctx *synccontext.RegisterContext) syncertypes.Base {
	return pkg.NewSyncer(ctx, pkg.SyncerConfig[*routev1.Route]{
		Name:   "route",
		Object: &routev1.Route{},
		SyncFields: func(ctx *synccontext.SyncContext, host, virtual *routev1.Route) {
			host.Spec = *virtual.Spec.DeepCopy()
			translateRouteSpec(ctx, &host.Spec, virtual.Namespace)
			virtual.Status = host.Status
		},
	})
}

func translateRouteSpec(ctx *synccontext.SyncContext, spec *routev1.RouteSpec, namespace string) {
	if spec.To.Kind == "Service" || spec.To.Kind == "" {
		spec.To.Name = translate.Default.HostName(ctx, spec.To.Name, namespace).Name
	}
	for i := range spec.AlternateBackends {
		if spec.AlternateBackends[i].Kind == "Service" || spec.AlternateBackends[i].Kind == "" {
			spec.AlternateBackends[i].Name = translate.Default.HostName(ctx, spec.AlternateBackends[i].Name, namespace).Name
		}
	}
}
