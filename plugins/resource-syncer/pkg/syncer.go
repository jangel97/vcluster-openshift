package pkg

import (
	"fmt"
	"time"

	"github.com/loft-sh/vcluster/pkg/mappings/generic"
	"github.com/loft-sh/vcluster/pkg/patcher"
	"github.com/loft-sh/vcluster/pkg/syncer/synccontext"
	"github.com/loft-sh/vcluster/pkg/syncer/translator"
	syncertypes "github.com/loft-sh/vcluster/pkg/syncer/types"
	"github.com/loft-sh/vcluster/pkg/util/translate"

	"k8s.io/apimachinery/pkg/types"
	utilerrors "k8s.io/apimachinery/pkg/util/errors"
	"k8s.io/klog/v2"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

type SyncerConfig[T client.Object] struct {
	Name       string
	Object     T
	SyncFields func(ctx *synccontext.SyncContext, host, virtual T)
}

func NewSyncer[T client.Object](ctx *synccontext.RegisterContext, cfg SyncerConfig[T]) syncertypes.Base {
	mapper, err := generic.NewMapper(ctx, cfg.Object, translate.Default.HostName)
	if err != nil {
		panic(fmt.Sprintf("create %s mapper: %v", cfg.Name, err))
	}
	if err := ctx.Mappings.AddMapper(mapper); err != nil {
		panic(fmt.Sprintf("register %s mapper: %v", cfg.Name, err))
	}
	return &genericSyncer[T]{
		GenericTranslator: translator.NewGenericTranslator(ctx, cfg.Name, cfg.Object, mapper),
		syncFields:        cfg.SyncFields,
	}
}

type genericSyncer[T client.Object] struct {
	syncertypes.GenericTranslator
	syncFields func(ctx *synccontext.SyncContext, host, virtual T)
}

func (s *genericSyncer[T]) Migrate(ctx *synccontext.RegisterContext, mapper synccontext.Mapper) error {
	gvk := s.GroupVersionKind()
	restMapper := ctx.VirtualManager.GetRESTMapper()
	for {
		_, err := restMapper.RESTMapping(gvk.GroupKind(), gvk.Version)
		if err == nil {
			klog.Infof("API %s available, running migration", gvk)
			break
		}
		klog.Infof("waiting for API %s: %v", gvk, err)
		time.Sleep(5 * time.Second)
	}
	return s.GenericTranslator.Migrate(ctx, mapper)
}

func (s *genericSyncer[T]) Options() *syncertypes.Options {
	return &syncertypes.Options{ObjectCaching: true}
}

func (s *genericSyncer[T]) Syncer() syncertypes.Sync[client.Object] {
	return s
}

func (s *genericSyncer[T]) SyncToHost(ctx *synccontext.SyncContext, event *synccontext.SyncToHostEvent[client.Object]) (ctrl.Result, error) {
	if event.HostOld != nil || event.Virtual.GetDeletionTimestamp() != nil {
		return patcher.DeleteVirtualObject(ctx, event.Virtual, event.HostOld, "host object was deleted")
	}
	pObj := translate.HostMetadata(event.Virtual,
		s.VirtualToHost(ctx, types.NamespacedName{
			Name:      event.Virtual.GetName(),
			Namespace: event.Virtual.GetNamespace(),
		}, event.Virtual))
	s.syncFields(ctx, pObj.(T), event.Virtual.(T))
	return patcher.CreateHostObject(ctx, event.Virtual, pObj, s.EventRecorder(), true)
}

func (s *genericSyncer[T]) Sync(ctx *synccontext.SyncContext, event *synccontext.SyncEvent[client.Object]) (_ ctrl.Result, retErr error) {
	patch, err := patcher.NewSyncerPatcher(ctx, event.Host, event.Virtual)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("new syncer patcher: %w", err)
	}
	defer func() {
		if err := patch.Patch(ctx, event.Host, event.Virtual); err != nil {
			retErr = utilerrors.NewAggregate([]error{retErr, err})
		}
	}()
	s.syncFields(ctx, event.Host.(T), event.Virtual.(T))
	vLabels, hLabels := translate.LabelsBidirectionalUpdate(event)
	event.Virtual.SetLabels(vLabels)
	event.Host.SetLabels(hLabels)
	vAnn, hAnn := translate.AnnotationsBidirectionalUpdate(event)
	event.Virtual.SetAnnotations(vAnn)
	event.Host.SetAnnotations(hAnn)
	return ctrl.Result{}, nil
}

func (s *genericSyncer[T]) SyncToVirtual(ctx *synccontext.SyncContext, event *synccontext.SyncToVirtualEvent[client.Object]) (_ ctrl.Result, retErr error) {
	if event.VirtualOld != nil || translate.ShouldDeleteHostObject(event.Host) {
		return patcher.DeleteHostObject(ctx, event.Host, event.VirtualOld, "virtual object was deleted")
	}
	return ctrl.Result{}, nil
}
