package syncers

import (
	"context"
	"fmt"
	"resource-syncer/pkg"
	"strings"

	"github.com/loft-sh/vcluster/pkg/syncer/synccontext"
	"github.com/loft-sh/vcluster/pkg/util/translate"
	rbacv1 "k8s.io/api/rbac/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/klog/v2"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
	"sigs.k8s.io/controller-runtime/pkg/source"
)

const (
	sccAPIGroup    = "security.openshift.io"
	sccResource    = "securitycontextconstraints"
	sccUseVerb     = "use"
	sccRBACPrefix  = "scc-"
	ownerLabel     = "vcluster.io/scc-rbac-owner"
	ownerTypeLabel = "vcluster.io/scc-rbac-type"
)

type SCCRBACBridge struct {
	vclusterName  string
	virtualClient client.Client
	hostClient    client.Client
}

func NewSCCRBACBridge(ctx *synccontext.RegisterContext) *SCCRBACBridge {
	return &SCCRBACBridge{
		vclusterName:  ctx.Config.Name,
		virtualClient: ctx.VirtualManager.GetClient(),
		hostClient:    ctx.HostManager.GetClient(),
	}
}

func (b *SCCRBACBridge) Name() string {
	return "scc-rbac-bridge"
}

func (b *SCCRBACBridge) Register(ctx *synccontext.RegisterContext) error {
	c, err := controller.New("scc-rbac-bridge", ctx.VirtualManager, controller.Options{
		Reconciler: b,
	})
	if err != nil {
		return fmt.Errorf("create scc-rbac-bridge controller: %w", err)
	}

	if err := c.Watch(source.Kind(ctx.VirtualManager.GetCache(), &rbacv1.ClusterRoleBinding{}, &handler.TypedEnqueueRequestForObject[*rbacv1.ClusterRoleBinding]{})); err != nil {
		return fmt.Errorf("watch ClusterRoleBindings: %w", err)
	}
	if err := c.Watch(source.Kind(ctx.VirtualManager.GetCache(), &rbacv1.RoleBinding{}, &handler.TypedEnqueueRequestForObject[*rbacv1.RoleBinding]{})); err != nil {
		return fmt.Errorf("watch RoleBindings: %w", err)
	}
	if err := c.Watch(source.Kind(ctx.VirtualManager.GetCache(), &rbacv1.ClusterRole{}, handler.TypedEnqueueRequestsFromMapFunc(b.clusterRoleToBindings))); err != nil {
		return fmt.Errorf("watch ClusterRoles: %w", err)
	}
	if err := c.Watch(source.Kind(ctx.VirtualManager.GetCache(), &rbacv1.Role{}, handler.TypedEnqueueRequestsFromMapFunc(b.roleToBindings))); err != nil {
		return fmt.Errorf("watch Roles: %w", err)
	}

	return nil
}

func (b *SCCRBACBridge) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	if req.Namespace == "" {
		return b.reconcileClusterRoleBinding(ctx, req)
	}
	return b.reconcileRoleBinding(ctx, req)
}

func (b *SCCRBACBridge) reconcileClusterRoleBinding(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	var crb rbacv1.ClusterRoleBinding
	if err := b.virtualClient.Get(ctx, req.NamespacedName, &crb); err != nil {
		if errors.IsNotFound(err) {
			return ctrl.Result{}, b.cleanupHostRBAC(ctx, req.Name, "ClusterRoleBinding")
		}
		return ctrl.Result{}, err
	}

	sccNames, err := b.resolveClusterRoleSCCs(ctx, crb.RoleRef)
	if err != nil || len(sccNames) == 0 {
		return ctrl.Result{}, b.cleanupHostRBAC(ctx, req.Name, "ClusterRoleBinding")
	}

	hostSubjects := b.translateSubjects(ctx, crb.Subjects, "")
	if len(hostSubjects) == 0 {
		return ctrl.Result{}, b.cleanupHostRBAC(ctx, req.Name, "ClusterRoleBinding")
	}

	return ctrl.Result{}, b.ensureHostRBAC(ctx, crb.Name, "ClusterRoleBinding", sccNames, hostSubjects)
}

func (b *SCCRBACBridge) reconcileRoleBinding(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	bindingKey := fmt.Sprintf("%s--%s", req.Namespace, req.Name)

	var rb rbacv1.RoleBinding
	if err := b.virtualClient.Get(ctx, req.NamespacedName, &rb); err != nil {
		if errors.IsNotFound(err) {
			return ctrl.Result{}, b.cleanupHostRBAC(ctx, bindingKey, "RoleBinding")
		}
		return ctrl.Result{}, err
	}

	var sccNames []string
	var err error
	if rb.RoleRef.Kind == "ClusterRole" {
		sccNames, err = b.resolveClusterRoleSCCs(ctx, rb.RoleRef)
	} else {
		sccNames, err = b.resolveRoleSCCs(ctx, rb.RoleRef, rb.Namespace)
	}
	if err != nil || len(sccNames) == 0 {
		return ctrl.Result{}, b.cleanupHostRBAC(ctx, bindingKey, "RoleBinding")
	}

	hostSubjects := b.translateSubjects(ctx, rb.Subjects, rb.Namespace)
	if len(hostSubjects) == 0 {
		return ctrl.Result{}, b.cleanupHostRBAC(ctx, bindingKey, "RoleBinding")
	}

	return ctrl.Result{}, b.ensureHostRBAC(ctx, bindingKey, "RoleBinding", sccNames, hostSubjects)
}

func (b *SCCRBACBridge) resolveClusterRoleSCCs(ctx context.Context, roleRef rbacv1.RoleRef) ([]string, error) {
	if roleRef.Kind != "ClusterRole" || roleRef.APIGroup != rbacv1.GroupName {
		return nil, nil
	}

	var cr rbacv1.ClusterRole
	if err := b.virtualClient.Get(ctx, types.NamespacedName{Name: roleRef.Name}, &cr); err != nil {
		return nil, err
	}

	return b.resolveSCCMatches(ctx, extractSCCRules(cr.Rules))
}

func (b *SCCRBACBridge) resolveRoleSCCs(ctx context.Context, roleRef rbacv1.RoleRef, namespace string) ([]string, error) {
	if roleRef.Kind != "Role" || roleRef.APIGroup != rbacv1.GroupName {
		return nil, nil
	}

	var role rbacv1.Role
	if err := b.virtualClient.Get(ctx, types.NamespacedName{Name: roleRef.Name, Namespace: namespace}, &role); err != nil {
		return nil, err
	}

	return b.resolveSCCMatches(ctx, extractSCCRules(role.Rules))
}

func (b *SCCRBACBridge) resolveSCCMatches(ctx context.Context, matches []sccRuleMatch) ([]string, error) {
	if len(matches) == 0 {
		return nil, nil
	}

	nameSet := make(map[string]struct{})
	for _, m := range matches {
		if m.wildcard {
			allSCCs, err := b.listAllVirtualSCCs(ctx)
			if err != nil {
				return nil, fmt.Errorf("list virtual SCCs for wildcard grant: %w", err)
			}
			for _, name := range allSCCs {
				nameSet[name] = struct{}{}
			}
		} else {
			for _, name := range m.names {
				nameSet[name] = struct{}{}
			}
		}
	}

	var result []string
	for name := range nameSet {
		result = append(result, name)
	}
	return result, nil
}

func (b *SCCRBACBridge) listAllVirtualSCCs(ctx context.Context) ([]string, error) {
	sccList := &unstructured.UnstructuredList{}
	sccList.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   sccAPIGroup,
		Version: "v1",
		Kind:    "SecurityContextConstraintsList",
	})
	if err := b.virtualClient.List(ctx, sccList); err != nil {
		return nil, err
	}
	var names []string
	for _, item := range sccList.Items {
		names = append(names, item.GetName())
	}
	return names, nil
}

// sccRuleMatch describes an SCC grant from a PolicyRule.
type sccRuleMatch struct {
	names    []string // empty means wildcard (all SCCs)
	wildcard bool
}

func extractSCCRules(rules []rbacv1.PolicyRule) []sccRuleMatch {
	var matches []sccRuleMatch
	for _, rule := range rules {
		if !pkg.ContainsStr(rule.APIGroups, sccAPIGroup) && !pkg.ContainsStr(rule.APIGroups, "*") {
			continue
		}
		if !pkg.ContainsStr(rule.Resources, sccResource) && !pkg.ContainsStr(rule.Resources, "*") {
			continue
		}
		if !pkg.ContainsStr(rule.Verbs, sccUseVerb) && !pkg.ContainsStr(rule.Verbs, "*") {
			continue
		}
		if len(rule.ResourceNames) > 0 {
			matches = append(matches, sccRuleMatch{names: rule.ResourceNames})
		} else {
			matches = append(matches, sccRuleMatch{wildcard: true})
		}
	}
	return matches
}

func (b *SCCRBACBridge) translateSubjects(ctx context.Context, subjects []rbacv1.Subject, bindingNamespace string) []rbacv1.Subject {
	var hostSubjects []rbacv1.Subject
	for _, subj := range subjects {
		if subj.Kind != "ServiceAccount" {
			continue
		}
		ns := subj.Namespace
		if ns == "" {
			ns = bindingNamespace
		}
		if ns == "" {
			continue
		}
		hostName := translate.Default.HostName(nil, subj.Name, ns)
		hostSubjects = append(hostSubjects, rbacv1.Subject{
			Kind:      "ServiceAccount",
			Name:      hostName.Name,
			Namespace: hostName.Namespace,
		})
	}
	return hostSubjects
}

func (b *SCCRBACBridge) ensureHostRBAC(ctx context.Context, bindingKey, bindingType string, sccNames []string, subjects []rbacv1.Subject) error {
	for _, sccName := range sccNames {
		hostSCCName := fmt.Sprintf("vc-%s-%s", b.vclusterName, sccName)
		hostCRName := fmt.Sprintf("vc-%s-%s%s-%s", b.vclusterName, sccRBACPrefix, safeName(bindingKey), sccName)
		hostCRBName := hostCRName

		cr := &rbacv1.ClusterRole{
			ObjectMeta: metav1.ObjectMeta{
				Name: hostCRName,
				Labels: map[string]string{
					ownerLabel:     safeName(bindingKey),
					ownerTypeLabel: bindingType,
				},
			},
			Rules: []rbacv1.PolicyRule{{
				APIGroups:     []string{sccAPIGroup},
				Resources:     []string{sccResource},
				ResourceNames: []string{hostSCCName},
				Verbs:         []string{sccUseVerb},
			}},
		}

		existing := &rbacv1.ClusterRole{}
		if err := b.hostClient.Get(ctx, types.NamespacedName{Name: hostCRName}, existing); err != nil {
			if errors.IsNotFound(err) {
				if err := b.hostClient.Create(ctx, cr); err != nil && !errors.IsAlreadyExists(err) {
					return fmt.Errorf("create host ClusterRole %s: %w", hostCRName, err)
				}
				klog.Infof("scc-rbac-bridge: created host ClusterRole %s", hostCRName)
			} else {
				return err
			}
		} else {
			existing.Rules = cr.Rules
			existing.Labels = cr.Labels
			if err := b.hostClient.Update(ctx, existing); err != nil {
				return fmt.Errorf("update host ClusterRole %s: %w", hostCRName, err)
			}
		}

		crb := &rbacv1.ClusterRoleBinding{
			ObjectMeta: metav1.ObjectMeta{
				Name: hostCRBName,
				Labels: map[string]string{
					ownerLabel:     safeName(bindingKey),
					ownerTypeLabel: bindingType,
				},
			},
			RoleRef: rbacv1.RoleRef{
				APIGroup: rbacv1.GroupName,
				Kind:     "ClusterRole",
				Name:     hostCRName,
			},
			Subjects: subjects,
		}

		existingCRB := &rbacv1.ClusterRoleBinding{}
		if err := b.hostClient.Get(ctx, types.NamespacedName{Name: hostCRBName}, existingCRB); err != nil {
			if errors.IsNotFound(err) {
				if err := b.hostClient.Create(ctx, crb); err != nil && !errors.IsAlreadyExists(err) {
					return fmt.Errorf("create host ClusterRoleBinding %s: %w", hostCRBName, err)
				}
				klog.Infof("scc-rbac-bridge: created host ClusterRoleBinding %s", hostCRBName)
			} else {
				return err
			}
		} else {
			existingCRB.Subjects = crb.Subjects
			existingCRB.Labels = crb.Labels
			if err := b.hostClient.Update(ctx, existingCRB); err != nil {
				return fmt.Errorf("update host ClusterRoleBinding %s: %w", hostCRBName, err)
			}
		}
	}
	return nil
}

func (b *SCCRBACBridge) cleanupHostRBAC(ctx context.Context, bindingKey, bindingType string) error {
	labelSelector := client.MatchingLabels{
		ownerLabel:     safeName(bindingKey),
		ownerTypeLabel: bindingType,
	}

	var crbs rbacv1.ClusterRoleBindingList
	if err := b.hostClient.List(ctx, &crbs, labelSelector); err != nil {
		return err
	}
	for i := range crbs.Items {
		if err := b.hostClient.Delete(ctx, &crbs.Items[i]); err != nil && !errors.IsNotFound(err) {
			return err
		}
		klog.Infof("scc-rbac-bridge: deleted host ClusterRoleBinding %s", crbs.Items[i].Name)
	}

	var crs rbacv1.ClusterRoleList
	if err := b.hostClient.List(ctx, &crs, labelSelector); err != nil {
		return err
	}
	for i := range crs.Items {
		if err := b.hostClient.Delete(ctx, &crs.Items[i]); err != nil && !errors.IsNotFound(err) {
			return err
		}
		klog.Infof("scc-rbac-bridge: deleted host ClusterRole %s", crs.Items[i].Name)
	}

	return nil
}

func (b *SCCRBACBridge) clusterRoleToBindings(ctx context.Context, cr *rbacv1.ClusterRole) []reconcile.Request {
	if len(extractSCCRules(cr.Rules)) == 0 {
		return nil
	}

	var crbs rbacv1.ClusterRoleBindingList
	if err := b.virtualClient.List(ctx, &crbs); err != nil {
		klog.Warningf("scc-rbac-bridge: list ClusterRoleBindings: %v", err)
		return nil
	}

	var requests []reconcile.Request
	for _, crb := range crbs.Items {
		if crb.RoleRef.Kind == "ClusterRole" && crb.RoleRef.Name == cr.Name {
			requests = append(requests, reconcile.Request{
				NamespacedName: types.NamespacedName{Name: crb.Name},
			})
		}
	}
	return requests
}

func (b *SCCRBACBridge) roleToBindings(ctx context.Context, role *rbacv1.Role) []reconcile.Request {
	if len(extractSCCRules(role.Rules)) == 0 {
		return nil
	}

	var rbs rbacv1.RoleBindingList
	if err := b.virtualClient.List(ctx, &rbs, client.InNamespace(role.Namespace)); err != nil {
		klog.Warningf("scc-rbac-bridge: list RoleBindings in %s: %v", role.Namespace, err)
		return nil
	}

	var requests []reconcile.Request
	for _, rb := range rbs.Items {
		if rb.RoleRef.Kind == "Role" && rb.RoleRef.Name == role.Name {
			requests = append(requests, reconcile.Request{
				NamespacedName: types.NamespacedName{
					Name:      rb.Name,
					Namespace: rb.Namespace,
				},
			})
		}
	}
	return requests
}

func safeName(s string) string {
	s = strings.ReplaceAll(s, "/", "--")
	if len(s) > 63 {
		s = s[:63]
	}
	return s
}
