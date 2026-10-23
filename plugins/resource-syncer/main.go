package main

import (
	"resource-syncer/hooks"
	"resource-syncer/pkg"
	"resource-syncer/syncers"
	"time"

	"github.com/loft-sh/vcluster/pkg/syncer/synccontext"
	syncertypes "github.com/loft-sh/vcluster/pkg/syncer/types"
	"github.com/loft-sh/vcluster-sdk/plugin"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/klog/v2"
)

var sccGVK = schema.GroupVersionKind{Group: "security.openshift.io", Version: "v1", Kind: "SecurityContextConstraints"}

var typedSyncers = map[schema.GroupVersionKind]func(*synccontext.RegisterContext) syncertypes.Base{
	{Group: "route.openshift.io", Version: "v1", Kind: "Route"}:       syncers.NewRouteSyncer,
	{Group: "oauth.openshift.io", Version: "v1", Kind: "OAuthClient"}: syncers.NewOAuthClientSyncer,
}

func main() {
	ctx := plugin.MustInit()

	cfg := &pkg.PluginConfig{}
	if err := plugin.UnmarshalConfig(cfg); err != nil {
		klog.Fatalf("unmarshal plugin config: %v", err)
	}

	if len(cfg.Resources) == 0 {
		klog.Fatal("no resources configured — add resources to the plugin config")
	}

	klog.Infof("resource-syncer: %d resources configured", len(cfg.Resources))

	for _, res := range cfg.Resources {
		gvk := res.GVK()
		if gvk == sccGVK {
			klog.Infof("registering SCC syncer with ceiling validation")
			plugin.MustRegister(syncers.NewSCCSyncer(ctx, cfg.SCCCeiling))
		} else if newSyncer, ok := typedSyncers[gvk]; ok {
			klog.Infof("registering typed syncer for %s", gvk)
			plugin.MustRegister(newSyncer(ctx))
		} else {
			klog.Infof("registering generic syncer for %s", gvk)
			plugin.MustRegister(pkg.NewUnstructuredSyncer(ctx, gvk))
		}
	}

	// SCC RBAC bridge: watches virtual RBAC bindings that grant SCC use and
	// creates corresponding host ClusterRoles/ClusterRoleBindings
	sccRBACBridge := syncers.NewSCCRBACBridge(ctx)
	plugin.MustRegister(sccRBACBridge)

	// SCC pod mutation hook: selects the correct SCC for each pod based on
	// virtual RBAC grants, sets openshift.io/required-scc on host pods
	sccHook := hooks.NewSCCHook(ctx.Config.Name, ctx.VirtualManager.GetClient())
	plugin.MustRegister(sccHook)

	for {
		klog.Infof("starting plugin...")
		if err := plugin.Start(); err != nil {
			klog.Errorf("plugin.Start() failed: %v — retrying in 10s", err)
			time.Sleep(10 * time.Second)
			continue
		}
		return
	}
}
