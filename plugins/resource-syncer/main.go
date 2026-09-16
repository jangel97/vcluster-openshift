package main

import (
	"resource-syncer/pkg"
	"resource-syncer/syncers"
	"time"

	"github.com/loft-sh/vcluster/pkg/syncer/synccontext"
	syncertypes "github.com/loft-sh/vcluster/pkg/syncer/types"
	"github.com/loft-sh/vcluster-sdk/plugin"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/klog/v2"
)

var typedSyncers = map[schema.GroupVersionKind]func(*synccontext.RegisterContext) syncertypes.Base{
	{Group: "route.openshift.io", Version: "v1", Kind: "Route"}:   syncers.NewRouteSyncer,
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
		if newSyncer, ok := typedSyncers[gvk]; ok {
			klog.Infof("registering typed syncer for %s", gvk)
			plugin.MustRegister(newSyncer(ctx))
		} else {
			klog.Infof("registering generic syncer for %s", gvk)
			plugin.MustRegister(pkg.NewUnstructuredSyncer(ctx, gvk))
		}
	}

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
