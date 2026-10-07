package hooks

import (
	"context"
	"fmt"
	"resource-syncer/pkg"
	"sort"

	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/klog/v2"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	requiredSCCAnnotation = "openshift.io/required-scc"
	sccAnnotation         = "openshift.io/scc"
	defaultSCC            = "restricted-v2"
	sccAPIGroup           = "security.openshift.io"
	sccResource           = "securitycontextconstraints"
)

type SCCHook struct {
	vclusterName  string
	virtualClient client.Client
}

func NewSCCHook(vclusterName string, virtualClient client.Client) *SCCHook {
	return &SCCHook{
		vclusterName:  vclusterName,
		virtualClient: virtualClient,
	}
}

func (h *SCCHook) Name() string {
	return "scc-bridge"
}

func (h *SCCHook) Resource() client.Object {
	return &corev1.Pod{}
}

func (h *SCCHook) MutateCreatePhysical(ctx context.Context, obj client.Object) (client.Object, error) {
	return h.selectSCC(ctx, obj)
}

func (h *SCCHook) MutateUpdatePhysical(ctx context.Context, obj client.Object) (client.Object, error) {
	return h.selectSCC(ctx, obj)
}

func (h *SCCHook) selectSCC(ctx context.Context, obj client.Object) (client.Object, error) {
	pod, ok := obj.(*corev1.Pod)
	if !ok {
		return obj, nil
	}

	annotations := pod.GetAnnotations()
	if annotations == nil {
		annotations = make(map[string]string)
	}

	// Strip any tenant-supplied SCC annotations to prevent escape
	if _, found := annotations[requiredSCCAnnotation]; found {
		klog.V(4).Infof("scc-bridge: stripping tenant-supplied %s on pod %s/%s",
			requiredSCCAnnotation, pod.Namespace, pod.Name)
	}
	delete(annotations, sccAnnotation)
	delete(annotations, requiredSCCAnnotation)

	saName, saNamespace := h.resolveVirtualSA(pod)
	sccName := defaultSCC

	if saName != "" && saNamespace != "" {
		selected, err := h.findBestSCC(ctx, saName, saNamespace)
		if err != nil {
			klog.Warningf("scc-bridge: SCC selection failed for %s/%s SA=%s/%s: %v — defaulting to %s",
				pod.Namespace, pod.Name, saNamespace, saName, err, defaultSCC)
		} else if selected != "" {
			sccName = selected
		}
	}

	hostSCCName := sccName
	if sccName != defaultSCC {
		hostSCCName = fmt.Sprintf("vc-%s-%s", h.vclusterName, sccName)
	}

	annotations[requiredSCCAnnotation] = hostSCCName
	pod.SetAnnotations(annotations)

	klog.V(4).Infof("scc-bridge: pod %s/%s SA=%s/%s → SCC=%s (host=%s)",
		pod.Namespace, pod.Name, saNamespace, saName, sccName, hostSCCName)

	return pod, nil
}

// resolveVirtualSA extracts the virtual SA name and namespace from a host pod.
// vCluster stores the original virtual identity in labels/annotations on the
// translated host pod.
func (h *SCCHook) resolveVirtualSA(pod *corev1.Pod) (string, string) {
	annotations := pod.GetAnnotations()
	labels := pod.GetLabels()

	vNamespace := ""
	if labels != nil {
		vNamespace = labels["vcluster.loft.sh/namespace"]
	}
	if vNamespace == "" && annotations != nil {
		vNamespace = annotations["vcluster.loft.sh/namespace"]
	}
	if vNamespace == "" {
		return "", ""
	}

	vSA := ""
	if annotations != nil {
		vSA = annotations["vcluster.loft.sh/service-account-name"]
	}
	if vSA == "" {
		vSA = "default"
	}
	return vSA, vNamespace
}

type sccCandidate struct {
	name     string
	priority int64
}

// findBestSCC finds the highest-priority SCC that the given virtual SA is
// allowed to use via RBAC. Returns empty string if no explicit grants exist.
func (h *SCCHook) findBestSCC(ctx context.Context, saName, saNamespace string) (string, error) {
	grantedSCCs, err := h.findGrantedSCCs(ctx, saName, saNamespace)
	if err != nil {
		return "", err
	}
	if len(grantedSCCs) == 0 {
		return "", nil
	}

	var candidates []sccCandidate
	for _, sccName := range grantedSCCs {
		priority, err := h.getSCCPriority(ctx, sccName)
		if err != nil {
			klog.V(4).Infof("scc-bridge: cannot read SCC %s priority: %v — skipping", sccName, err)
			continue
		}
		candidates = append(candidates, sccCandidate{name: sccName, priority: priority})
	}

	if len(candidates) == 0 {
		return "", nil
	}

	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].priority != candidates[j].priority {
			return candidates[i].priority > candidates[j].priority
		}
		return candidates[i].name < candidates[j].name
	})

	return candidates[0].name, nil
}

// findGrantedSCCs returns the list of SCC names that a virtual SA is allowed
// to use via ClusterRoleBindings and RoleBindings.
// TODO: cache RBAC state with an informer instead of listing per pod create.
func (h *SCCHook) findGrantedSCCs(ctx context.Context, saName, saNamespace string) ([]string, error) {
	sccSet := make(map[string]struct{})

	// Check ClusterRoleBindings
	var crbs rbacv1.ClusterRoleBindingList
	if err := h.virtualClient.List(ctx, &crbs); err != nil {
		return nil, fmt.Errorf("list ClusterRoleBindings: %w", err)
	}
	for _, crb := range crbs.Items {
		if !subjectMatches(crb.Subjects, saName, saNamespace) {
			continue
		}
		names, err := h.resolveSCCsFromRoleRef(ctx, crb.RoleRef, "")
		if err != nil {
			klog.V(4).Infof("scc-bridge: resolve roleRef %s/%s: %v", crb.RoleRef.Kind, crb.RoleRef.Name, err)
			continue
		}
		for _, n := range names {
			sccSet[n] = struct{}{}
		}
	}

	// Check RoleBindings in the SA's namespace
	var rbs rbacv1.RoleBindingList
	if err := h.virtualClient.List(ctx, &rbs, client.InNamespace(saNamespace)); err != nil {
		return nil, fmt.Errorf("list RoleBindings in %s: %w", saNamespace, err)
	}
	for _, rb := range rbs.Items {
		if !subjectMatches(rb.Subjects, saName, saNamespace) {
			continue
		}
		names, err := h.resolveSCCsFromRoleRef(ctx, rb.RoleRef, rb.Namespace)
		if err != nil {
			klog.V(4).Infof("scc-bridge: resolve roleRef %s/%s: %v", rb.RoleRef.Kind, rb.RoleRef.Name, err)
			continue
		}
		for _, n := range names {
			sccSet[n] = struct{}{}
		}
	}

	var result []string
	for name := range sccSet {
		result = append(result, name)
	}
	return result, nil
}

func (h *SCCHook) resolveSCCsFromRoleRef(ctx context.Context, roleRef rbacv1.RoleRef, namespace string) ([]string, error) {
	if roleRef.APIGroup != rbacv1.GroupName {
		return nil, nil
	}

	var rules []rbacv1.PolicyRule
	switch roleRef.Kind {
	case "ClusterRole":
		var cr rbacv1.ClusterRole
		if err := h.virtualClient.Get(ctx, client.ObjectKey{Name: roleRef.Name}, &cr); err != nil {
			return nil, err
		}
		rules = cr.Rules
	case "Role":
		if namespace == "" {
			return nil, nil
		}
		var role rbacv1.Role
		if err := h.virtualClient.Get(ctx, client.ObjectKey{Name: roleRef.Name, Namespace: namespace}, &role); err != nil {
			return nil, err
		}
		rules = role.Rules
	}

	return h.extractSCCGrants(ctx, rules)
}

func (h *SCCHook) extractSCCGrants(ctx context.Context, rules []rbacv1.PolicyRule) ([]string, error) {
	nameSet := make(map[string]struct{})
	for _, rule := range rules {
		if !pkg.ContainsStr(rule.APIGroups, sccAPIGroup) && !pkg.ContainsStr(rule.APIGroups, "*") {
			continue
		}
		if !pkg.ContainsStr(rule.Resources, sccResource) && !pkg.ContainsStr(rule.Resources, "*") {
			continue
		}
		if !pkg.ContainsStr(rule.Verbs, "use") && !pkg.ContainsStr(rule.Verbs, "*") {
			continue
		}
		if len(rule.ResourceNames) > 0 {
			for _, n := range rule.ResourceNames {
				nameSet[n] = struct{}{}
			}
		} else {
			allSCCs, err := h.listAllVirtualSCCs(ctx)
			if err != nil {
				return nil, err
			}
			for _, n := range allSCCs {
				nameSet[n] = struct{}{}
			}
		}
	}
	var result []string
	for name := range nameSet {
		result = append(result, name)
	}
	return result, nil
}

func (h *SCCHook) listAllVirtualSCCs(ctx context.Context) ([]string, error) {
	sccList := &unstructured.UnstructuredList{}
	sccList.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   sccAPIGroup,
		Version: "v1",
		Kind:    "SecurityContextConstraintsList",
	})
	if err := h.virtualClient.List(ctx, sccList); err != nil {
		return nil, err
	}
	var names []string
	for _, item := range sccList.Items {
		names = append(names, item.GetName())
	}
	return names, nil
}

func (h *SCCHook) getSCCPriority(ctx context.Context, name string) (int64, error) {
	scc := &unstructured.Unstructured{}
	scc.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   sccAPIGroup,
		Version: "v1",
		Kind:    "SecurityContextConstraints",
	})
	if err := h.virtualClient.Get(ctx, client.ObjectKey{Name: name}, scc); err != nil {
		return 0, err
	}
	priority, _, _ := unstructured.NestedInt64(scc.Object, "priority")
	return priority, nil
}

func subjectMatches(subjects []rbacv1.Subject, saName, saNamespace string) bool {
	for _, s := range subjects {
		if s.Kind != "ServiceAccount" {
			continue
		}
		if s.Name == saName && (s.Namespace == saNamespace || s.Namespace == "") {
			return true
		}
	}
	return false
}

