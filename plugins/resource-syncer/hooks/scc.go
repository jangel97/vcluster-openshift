package hooks

import (
	"context"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/klog/v2"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	requiredSCCAnnotation = "openshift.io/required-scc"
	sccAnnotation         = "openshift.io/scc"
	defaultSCC            = "restricted-v2"
)

type SCCHook struct{}

func (h *SCCHook) Name() string {
	return "scc-bridge"
}

func (h *SCCHook) Resource() client.Object {
	return &corev1.Pod{}
}

func (h *SCCHook) MutateCreatePhysical(_ context.Context, obj client.Object) (client.Object, error) {
	return enforceSCC(obj), nil
}

func (h *SCCHook) MutateUpdatePhysical(_ context.Context, obj client.Object) (client.Object, error) {
	return enforceSCC(obj), nil
}

func enforceSCC(obj client.Object) client.Object {
	annotations := obj.GetAnnotations()
	if annotations == nil {
		annotations = make(map[string]string)
	}

	if _, found := annotations[requiredSCCAnnotation]; found {
		klog.V(4).Infof("stripping tenant-supplied %s on pod %s/%s", requiredSCCAnnotation, obj.GetNamespace(), obj.GetName())
	}
	delete(annotations, sccAnnotation)

	annotations[requiredSCCAnnotation] = defaultSCC
	obj.SetAnnotations(annotations)
	return obj
}
