# =============================================================================
# Makefile — Resources automation
# =============================================================================

NAMESPACE ?= grafana
GRAFANA_URL ?=
GRAFANA_TOKEN ?=
SELECT_TYPES ?=
OPTS ?=

.PHONY: help validate migrate clean

help:
	@echo "Available commands:"
	@echo "  make validate           - Locally validate all custom resources (yamllint, kustomize)"
	@echo "  make migrate            - Export resources from Grafana API to GitOps CRs"
	@echo "  make clean              - Remove temporary/dry-run files"

validate:
	@echo "Running yamllint..."
	yamllint -c .yamllint.yaml resources/
	@echo "Running CRD validation checks..."
	@FAIL=0; \
	for f in $$(find resources -name "*.yaml" 2>/dev/null); do \
		KIND=$$(yq eval '.kind' "$$f" 2>/dev/null || echo ""); \
		case "$$KIND" in \
			""|ConfigMap|Kustomization|Secret|Grafana|GrafanaNotificationPolicyRoute) continue ;; \
		esac; \
		if [ "$$KIND" = "GrafanaServiceAccount" ]; then \
			INST_NAME=$$(yq eval '.spec.instanceName' "$$f" 2>/dev/null || echo "null"); \
			if [ "$$INST_NAME" = "null" ] || [ -z "$$INST_NAME" ]; then \
				echo "❌ $$f ($$KIND): missing spec.instanceName"; \
				FAIL=1; \
			fi; \
		else \
			SELECTOR=$$(yq eval '.spec.instanceSelector.matchLabels' "$$f" 2>/dev/null || echo "null"); \
			if [ "$$SELECTOR" = "null" ] || [ -z "$$SELECTOR" ]; then \
				echo "❌ $$f ($$KIND): missing spec.instanceSelector.matchLabels"; \
				FAIL=1; \
			fi; \
		fi; \
	done; \
	for f in $$(find resources/dashboards -name "*.yaml" 2>/dev/null); do \
		KIND=$$(yq eval '.kind' "$$f" 2>/dev/null || echo ""); \
		[ "$$KIND" != "GrafanaDashboard" ] && continue; \
		NAME=$$(yq eval '.metadata.name' "$$f" 2>/dev/null || echo ""); \
		DIR=$$(dirname "$$f"); \
		CM_FILE="$$DIR/$${NAME}-configmap.yaml"; \
		if [ ! -f "$$CM_FILE" ]; then \
			echo "❌ $$f: missing ConfigMap pair at $$CM_FILE"; \
			FAIL=1; \
		fi; \
	done; \
	KNOWN_FOLDERS="general "; \
	for f in $$(find resources/folders -name "*.yaml" 2>/dev/null); do \
		KIND=$$(yq eval '.kind' "$$f" 2>/dev/null || echo ""); \
		[ "$$KIND" != "GrafanaFolder" ] && continue; \
		NAME=$$(yq eval '.metadata.name' "$$f" 2>/dev/null || echo ""); \
		[ -n "$$NAME" ] && KNOWN_FOLDERS="$$KNOWN_FOLDERS $$NAME "; \
	done; \
	for f in $$(find resources -path "*/dashboards/*.yaml" -o -path "*/alert-rule-groups/*.yaml" 2>/dev/null); do \
		KIND=$$(yq eval '.kind' "$$f" 2>/dev/null || echo ""); \
		case "$$KIND" in \
			GrafanaDashboard|GrafanaAlertRuleGroup) ;; \
			*) continue ;; \
		esac; \
		FREF=$$(yq eval '.spec.folder // .spec.folderRef // ""' "$$f" 2>/dev/null || echo ""); \
		[ -z "$$FREF" ] || [ "$$FREF" = "null" ] && continue; \
		case " $$KNOWN_FOLDERS " in \
			*" $$FREF "*) ;; \
			*) \
				echo "❌ $$f ($$KIND): folderRef=\"$$FREF\" has no matching GrafanaFolder"; \
				FAIL=1; \
				;; \
		esac; \
	done; \
	if [ $$FAIL -eq 0 ]; then \
		echo "🎉 All local validation checks passed."; \
	else \
		exit 1; \
	fi

migrate:
	@if [ -z "$(GRAFANA_URL)" ] || [ -z "$(GRAFANA_TOKEN)" ]; then \
		echo "Error: GRAFANA_URL and GRAFANA_TOKEN must be specified."; \
		echo "Usage: make migrate GRAFANA_URL=https://your-grafana.com GRAFANA_TOKEN=your-token"; \
		exit 1; \
	fi
	./scripts/migrate-from-grafana.sh \
		--url "$(GRAFANA_URL)" \
		--token "$(GRAFANA_TOKEN)" \
		--namespace "$(NAMESPACE)" \
		$(if $(SELECT_TYPES),--select-type "$(SELECT_TYPES)",) \
		$(OPTS)

clean:
	find . -name ".tmp.*" -delete
