NAMESPACE              ?= vcluster-ocp
VCLUSTER_NAME          ?= ocp
VCLUSTER_BIN           ?= vcluster
HOST_CONTEXT           ?= $(shell kubectl config current-context)
OPENSHIFT_APISERVER_IMAGE ?=
RESOURCE_SYNCER_IMAGE     ?=

.PHONY: deploy teardown verify generate-cert build-plugin push-plugin help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

deploy: generate-cert ## Deploy vCluster with OpenShift APIs (full end-to-end)
	@bash hack/deploy.sh "$(NAMESPACE)" "$(VCLUSTER_NAME)" "$(VCLUSTER_BIN)" "$(HOST_CONTEXT)" "$(OPENSHIFT_APISERVER_IMAGE)" "$(RESOURCE_SYNCER_IMAGE)"

teardown: ## Tear down vCluster and clean up
	-$(VCLUSTER_BIN) disconnect 2>/dev/null
	-pkill -f "vcluster connect $(VCLUSTER_NAME)" 2>/dev/null
	-$(VCLUSTER_BIN) delete $(VCLUSTER_NAME) --namespace $(NAMESPACE)
	@echo "Cleaning up cluster-scoped resources..."
	-oc adm policy remove-scc-from-user privileged "system:serviceaccount:$(NAMESPACE):vc-$(VCLUSTER_NAME)" 2>/dev/null
	-oc adm policy remove-cluster-role-from-user vcluster-route-custom-host "system:serviceaccount:$(NAMESPACE):vc-$(VCLUSTER_NAME)" 2>/dev/null
	-oc adm policy remove-cluster-role-from-user system:auth-delegator "system:serviceaccount:$(NAMESPACE):vc-$(VCLUSTER_NAME)" 2>/dev/null
	-kubectl delete clusterrole vcluster-$(VCLUSTER_NAME)-user-api-impersonation --ignore-not-found 2>/dev/null
	-kubectl delete namespace $(NAMESPACE) --wait=false
	@echo "Waiting for namespace deletion (force-finalizing if stuck)..."
	@for i in $$(seq 1 15); do \
		kubectl get namespace $(NAMESPACE) >/dev/null 2>&1 || { echo "Namespace deleted."; exit 0; }; \
		sleep 2; \
	done; \
	echo "Namespace stuck — removing finalizers..."; \
	kubectl get namespace $(NAMESPACE) -o json | jq '.spec.finalizers = []' | \
		kubectl replace --raw "/api/v1/namespaces/$(NAMESPACE)/finalize" -f - >/dev/null 2>&1; \
	echo "Namespace finalized."

verify: ## Verify OpenShift APIs are working
	@echo "=== Checking APIServices ==="
	@kubectl get apiservices | grep openshift
	@echo ""
	@echo "=== Testing ImageStream CRUD ==="
	kubectl apply -f examples/imagestream-test.yaml
	kubectl get imagestreams -n test
	kubectl delete -f examples/imagestream-test.yaml
	@echo ""
	@echo "All checks passed."

generate-cert: ## Generate self-signed TLS cert (if not present)
	@if [ ! -f tls.crt ] || [ ! -f tls.key ]; then \
		bash hack/generate-cert.sh .; \
	else \
		echo "TLS cert already exists, skipping."; \
	fi

build-plugin: ## Build route-syncer plugin image
	cd plugins/resource-syncer && docker build -t $(RESOURCE_SYNCER_IMAGE) .

push-plugin: build-plugin ## Build and push route-syncer plugin image
	docker push $(RESOURCE_SYNCER_IMAGE)
