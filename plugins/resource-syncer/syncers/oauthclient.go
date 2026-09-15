package syncers

import (
	oauthv1 "github.com/openshift/api/oauth/v1"
	"resource-syncer/pkg"

	"github.com/loft-sh/vcluster/pkg/scheme"
	"github.com/loft-sh/vcluster/pkg/syncer/synccontext"
	syncertypes "github.com/loft-sh/vcluster/pkg/syncer/types"
)

func init() {
	_ = oauthv1.Install(scheme.Scheme)
}

func NewOAuthClientSyncer(ctx *synccontext.RegisterContext) syncertypes.Base {
	return pkg.NewSyncer(ctx, pkg.SyncerConfig[*oauthv1.OAuthClient]{
		Name:         "oauthclient",
		Object:       &oauthv1.OAuthClient{},
		HostNameFunc: pkg.IdentityHostName,
		SyncFields: func(_ *synccontext.SyncContext, host, virtual *oauthv1.OAuthClient) {
			host.Secret = virtual.Secret
			host.AdditionalSecrets = virtual.AdditionalSecrets
			host.RedirectURIs = virtual.RedirectURIs
			host.GrantMethod = virtual.GrantMethod
			host.ScopeRestrictions = virtual.ScopeRestrictions
			host.RespondWithChallenges = virtual.RespondWithChallenges
			host.AccessTokenMaxAgeSeconds = virtual.AccessTokenMaxAgeSeconds
			host.AccessTokenInactivityTimeoutSeconds = virtual.AccessTokenInactivityTimeoutSeconds
		},
	})
}
