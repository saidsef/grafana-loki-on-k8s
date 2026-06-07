ALLOY_IMAGE    ?= docker.io/grafana/alloy:v1.16.2
KIND_CLUSTER   ?= loki-stack
KUBE_NAMESPACE ?= monitoring

.PHONY: validate validate-config validate-manifests
.PHONY: kind-up kind-deploy kind-wait kind-test kind-down

## ── Validation ────────────────────────────────────────────────────────────────

validate: validate-config validate-manifests ## Run all validation checks

validate-config: ## Validate Alloy River config syntax using Docker (no cluster required)
	@python3 -c "import yaml; print(yaml.safe_load(open('deployment/alloy/cm.yml'))['data']['config.alloy'])" \
	  > /tmp/_alloy_config.alloy
	@docker run --rm \
	  -v /tmp/_alloy_config.alloy:/tmp/config.alloy:ro \
	  $(ALLOY_IMAGE) fmt /tmp/config.alloy > /dev/null \
	  && echo "Alloy config: OK" \
	  || (echo "Alloy config: FAILED"; rm -f /tmp/_alloy_config.alloy; exit 1)
	@rm -f /tmp/_alloy_config.alloy

validate-manifests: ## Validate kustomize manifests render cleanly (no cluster required)
	kubectl kustomize deployment/ > /dev/null \
	  && echo "Manifests: OK"

## ── Kind cluster ──────────────────────────────────────────────────────────────

kind-up: ## Create a local kind cluster
	kind create cluster --name $(KIND_CLUSTER) --config kind-config.yml --wait 90s
	kubectl cluster-info --context kind-$(KIND_CLUSTER)

kind-deploy: ## Deploy the full stack to the kind cluster
	kubectl create namespace $(KUBE_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -k deployment/

kind-wait: ## Wait for key workloads to be ready
	kubectl rollout status deployment/grafana   -n $(KUBE_NAMESPACE) --timeout=300s
	kubectl rollout status daemonset/alloy      -n $(KUBE_NAMESPACE) --timeout=300s
	kubectl rollout status deployment/pyroscope -n $(KUBE_NAMESPACE) --timeout=300s

kind-test: kind-deploy kind-wait ## Deploy and verify the stack; smoke-test the Beyla/Pyroscope patch
	@echo "--- Smoke: beyla-profile-patch applied ---"
	kubectl get configmap beyla -n $(KUBE_NAMESPACE) \
	  -o jsonpath='{.data.beyla-config\.yml}' | grep -q "otel_profiles_export" \
	  && echo "beyla-profile-patch: OK" \
	  || (echo "beyla-profile-patch: MISSING"; exit 1)
	@echo "--- Cluster state ---"
	kubectl get all -n $(KUBE_NAMESPACE)

kind-down: ## Destroy the kind cluster
	kind delete cluster --name $(KIND_CLUSTER)
