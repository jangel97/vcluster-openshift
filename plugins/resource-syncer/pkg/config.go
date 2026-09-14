package pkg

import "k8s.io/apimachinery/pkg/runtime/schema"

type PluginConfig struct {
	Resources []ResourceConfig `json:"resources"`
}

type ResourceConfig struct {
	APIVersion string `json:"apiVersion"`
	Kind       string `json:"kind"`
}

func (r ResourceConfig) GVK() schema.GroupVersionKind {
	gv, _ := schema.ParseGroupVersion(r.APIVersion)
	return gv.WithKind(r.Kind)
}
