package syncers

import (
	"fmt"
	"resource-syncer/pkg"

	"github.com/loft-sh/vcluster/pkg/syncer/synccontext"
	syncertypes "github.com/loft-sh/vcluster/pkg/syncer/types"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
)

var oauthClientFields = []string{
	"secret",
	"additionalSecrets",
	"redirectURIs",
	"grantMethod",
	"scopeRestrictions",
	"respondWithChallenges",
	"accessTokenMaxAgeSeconds",
	"accessTokenInactivityTimeoutSeconds",
}

func NewOAuthClientSyncer(ctx *synccontext.RegisterContext) syncertypes.Base {
	vclusterName := ctx.Config.Name

	obj := &unstructured.Unstructured{}
	obj.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   "oauth.openshift.io",
		Version: "v1",
		Kind:    "OAuthClient",
	})

	return pkg.NewSyncer(ctx, pkg.SyncerConfig[*unstructured.Unstructured]{
		Name:   "oauthclient",
		Object: obj,
		HostNameFunc: func(_ *synccontext.SyncContext, vName, _ string) types.NamespacedName {
			return types.NamespacedName{Name: fmt.Sprintf("vc-%s-%s", vclusterName, vName)}
		},
		SyncFields: func(_ *synccontext.SyncContext, host, virtual *unstructured.Unstructured) {
			for _, field := range oauthClientFields {
				if val, ok := virtual.Object[field]; ok {
					host.Object[field] = val
				}
			}
		},
	})
}
