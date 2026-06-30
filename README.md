# Grafana Resources GitOps Repo

This repository holds the exported Grafana Cloud resources (dashboards, folders, datasources, contact points) and is continuously synchronized to the Kubernetes cluster running the Grafana Operator using ArgoCD.

## Layout

- `resources/` - Standard Kubernetes Custom Resources managed by the Grafana Operator.
- `.github/workflows/export-from-grafana.yml` - Periodic sync workflow that pulls the latest configuration from the Grafana Cloud API and commits/PRs it back to this repository.
- `Makefile` - Helper commands for validation and migrations.

## Local Validation

Before committing, validate the resources locally:
```bash
make validate
```
