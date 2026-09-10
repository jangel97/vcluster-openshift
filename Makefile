NAMESPACE              ?= vcluster-ocp
VCLUSTER_NAME          ?= ocp
VCLUSTER_BIN           ?= vcluster
HOST_CONTEXT           ?= $(shell kubectl config current-context)
OPENSHIFT_APISERVER_IMAGE ?=

.PHONY: deploy teardown verify generate-cert help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

deploy: generate-cert ## Deploy vCluster with OpenShift APIs (full end-to-end)
	@bash hack/deploy.sh "$(NAMESPACE)" "$(VCLUSTER_NAME)" "$(VCLUSTER_BIN)" "$(HOST_CONTEXT)" "$(OPENSHIFT_APISERVER_IMAGE)"

teardown: ## Tear down vCluster and clean up
	-$(VCLUSTER_BIN) disconnect 2>/dev/null
	-pkill -f "vcluster connect $(VCLUSTER_NAME)" 2>/dev/null
	-$(VCLUSTER_BIN) delete $(VCLUSTER_NAME) --namespace $(NAMESPACE)
	-kubectl delete namespace $(NAMESPACE)

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

