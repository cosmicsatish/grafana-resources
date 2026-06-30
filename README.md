# Grafana Resources GitOps Repository

This repository holds the pure Kubernetes Custom Resources (CRs) managed by the Grafana Operator. It acts as the single source of truth for all Grafana Cloud configurations.

---

## 📁 Repository Layout

```text
grafana-resources/
├── resources/                       # Sync directory applied by ArgoCD
│   ├── grafana/                     # Grafana instance CR
│   ├── datasources/                 # GrafanaDatasource CRs (flat)
│   ├── folders/                     # GrafanaFolder CRs (flat)
│   ├── service-accounts/            # GrafanaServiceAccount CRs (flat)
│   ├── dashboards/                  # GrafanaDashboard + ConfigMap (folder-mirrored)
│   │   └── ...
│   └── alerting/
│       ├── alert-rule-groups/       # GrafanaAlertRuleGroup CRs (folder-mirrored)
│       │   └── ...
│       ├── contact-points/          # GrafanaContactPoint CRs (flat)
│       └── notification-policies/  # GrafanaNotificationPolicy CR (singleton)
├── scripts/
│   └── migrate-from-grafana.sh      # Core migration engine script
├── Makefile                         # Unified automation task runner
├── README.md
└── .github/workflows/
    └── export-from-grafana.yml      # GitHub Actions periodic export/sync workflow
```

---

## 🔄 Exporter Workflow (API → Git)

A GitHub Actions workflow is provided under `.github/workflows/export-from-grafana.yml`. It runs on a schedule (or can be triggered manually via `workflow_dispatch`) to fetch the latest state from the Grafana Cloud HTTP API and commit the changes directly to `main` branch.

### Prerequisites

To enable the exporter, configure the following secrets and variables on your GitHub repository (Settings -> Secrets and variables -> Actions):
- **Secret: `GRAFANA_TOKEN`**: A Grafana Cloud Admin Service Account API key.
- **Variable: `GRAFANA_URL`**: The base URL of your Grafana Cloud instance (e.g. `https://your-instance.grafana.net`).
- **Variable: `NAMESPACE`**: The target Kubernetes namespace where resources are synced (e.g. `grafana`).

---

## 🔒 Secrets Management (Decoupled)

To prevent secret leaks:
1. `resources/secrets/` is ignored by git (`.gitignore`).
2. Do **not** commit real credential values to git.
3. Locally, secrets should be created manually in the cluster namespace using:
   ```bash
   kubectl create secret generic grafana-cloud-credentials --from-literal=token="<token>" -n grafana
   ```
4. In production, use **External Secrets Operator (ESO)** or **Sealed Secrets** to securely provision sensitive API tokens.

---

## 🛠️ Local Commands

### Validate Manifests
Run the local validation check to verify syntax and cross-resource references before committing:
```bash
make validate
```
This runs `yamllint`, validates dashboard ConfigMaps, checks folderRef linkages, and checks for potential validation errors.

