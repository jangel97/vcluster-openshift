package pkg

import (
	"strings"

	"github.com/loft-sh/vcluster/pkg/syncer/synccontext"
	syncertypes "github.com/loft-sh/vcluster/pkg/syncer/types"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func NewUnstructuredSyncer(ctx *synccontext.RegisterContext, gvk schema.GroupVersionKind) syncertypes.Base {
	obj := &unstructured.Unstructured{}
	obj.SetGroupVersionKind(gvk)

	return NewSyncer(ctx, SyncerConfig[*unstructured.Unstructured]{
		Name:   strings.ToLower(gvk.Kind),
		Object: obj,
		SyncFields: func(ctx *synccontext.SyncContext, host, virtual *unstructured.Unstructured) {
			if spec, ok := virtual.Object["spec"]; ok {
				host.Object["spec"] = runtime.DeepCopyJSONValue(spec)
			}
			if status, ok := host.Object["status"]; ok {
				virtual.Object["status"] = status
			}
		},
	})
}
