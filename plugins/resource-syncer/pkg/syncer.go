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
	Name         string
	Object       T
	SyncFields   func(ctx *synccontext.SyncContext, host, virtual T)
	HostNameFunc generic.PhysicalNameFunc
}

func NewSyncer[T client.Object](ctx *synccontext.RegisterContext, cfg SyncerConfig[T]) syncertypes.Base {
	nameFunc := cfg.HostNameFunc
	if nameFunc == nil {
		nameFunc = translate.Default.HostName
	}
	mapper, err := generic.NewMapper(ctx, cfg.Object, nameFunc)
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

func IdentityHostName(_ *synccontext.SyncContext, vName, _ string) types.NamespacedName {
	return types.NamespacedName{Name: vName}
}

type genericSyncer[T client.Object] struct {
	syncertypes.GenericTranslator
	syncFields func(ctx *synccontext.SyncContext, host, virtual T)
}

func tryMigrate(fn func() error) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("panic: %v", r)
		}
	}()
	return fn()
}

func (s *genericSyncer[T]) Migrate(ctx *synccontext.RegisterContext, mapper synccontext.Mapper) error {
	gvk := s.GroupVersionKind()
	deadline := time.Now().Add(5 * time.Minute)
	for time.Now().Before(deadline) {
		err := tryMigrate(func() error {
			return s.GenericTranslator.Migrate(ctx, mapper)
		})
		if err == nil {
			klog.Infof("migration for %s completed", gvk)
			return nil
		}
		klog.Infof("waiting for %s to be ready: %v", gvk, err)
		time.Sleep(10 * time.Second)
	}
	klog.Warningf("migration for %s timed out after 5m — will sync from scratch", gvk)
	return nil
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
