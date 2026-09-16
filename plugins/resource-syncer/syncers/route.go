package syncers

import (
	"sync"

	routev1 "github.com/openshift/api/route/v1"
	"resource-syncer/pkg"

	"github.com/loft-sh/vcluster/pkg/scheme"
	"github.com/loft-sh/vcluster/pkg/syncer/synccontext"
	syncertypes "github.com/loft-sh/vcluster/pkg/syncer/types"
	"github.com/loft-sh/vcluster/pkg/util/translate"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/klog/v2"
)

func init() {
	_ = routev1.Install(scheme.Scheme)
}

var (
	serviceCAOnce   sync.Once
	serviceCABundle string
)

func getServiceCA(ctx *synccontext.SyncContext) string {
	serviceCAOnce.Do(func() {
		var cm corev1.ConfigMap
		key := types.NamespacedName{
			Namespace: "openshift-service-ca",
			Name:      "signing-cabundle",
		}
		if err := ctx.VirtualClient.Get(ctx, key, &cm); err != nil {
			klog.Warningf("failed to read service CA bundle: %v", err)
			return
		}
		serviceCABundle = cm.Data["ca-bundle.crt"]
		klog.Infof("cached service CA bundle (%d bytes)", len(serviceCABundle))
	})
	return serviceCABundle
}

func injectServiceCA(ctx *synccontext.SyncContext, spec *routev1.RouteSpec) {
	if spec.TLS == nil || spec.TLS.Termination != routev1.TLSTerminationReencrypt {
		return
	}
	if spec.TLS.DestinationCACertificate != "" {
		return
	}
	if ca := getServiceCA(ctx); ca != "" {
		spec.TLS.DestinationCACertificate = ca
	}
}

func NewRouteSyncer(ctx *synccontext.RegisterContext) syncertypes.Base {
	return pkg.NewSyncer(ctx, pkg.SyncerConfig[*routev1.Route]{
		Name:   "route",
		Object: &routev1.Route{},
		SyncFields: func(ctx *synccontext.SyncContext, host, virtual *routev1.Route) {
			host.Spec = *virtual.Spec.DeepCopy()
			translateRouteSpec(ctx, &host.Spec, virtual.Namespace)
			injectServiceCA(ctx, &host.Spec)
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
