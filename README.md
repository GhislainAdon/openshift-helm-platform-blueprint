# openshift-helm-platform-blueprint

[![ci](https://github.com/GhislainAdon/openshift-helm-platform-blueprint/actions/workflows/ci.yml/badge.svg)](https://github.com/GhislainAdon/openshift-helm-platform-blueprint/actions/workflows/ci.yml)
![Helm](https://img.shields.io/badge/helm-v3-0f1689)
![OpenShift](https://img.shields.io/badge/OpenShift-restricted--v2-ee0000)
![License](https://img.shields.io/badge/license-MIT-blue)

A production-grade Helm chart and delivery blueprint for running a **3-tier web
application on OpenShift** (or any Kubernetes) behind a SAML authentication
proxy, delivered with **GitLab CI + Argo CD GitOps**, observed with
**Prometheus / Grafana**, isolated with **NetworkPolicies**, and reaching an
external partner API through an **Istio egress gateway that originates mutual
TLS and tunnels through a corporate HTTP proxy**.

It distils a real platform engagement for a large public-sector organisation
(regulated, air-gapped-ish cluster, four environments) into a reusable,
fully generic reference.

> **Disclaimer** - Rewritten from scratch for portfolio purposes; contains no
> client code, identifiers, certificates or data. All hostnames use
> `example.org` / `example.com` / `corp.example`, all IP addresses are RFC 5737
> documentation addresses.

---

## What's inside

```text
.
├── charts/webapp-platform/          # the Helm chart
│   ├── templates/
│   │   ├── _helpers.tpl             # names, labels, selectors, guard rails
│   │   ├── _workload.tpl            # shared Deployment / Service renderers
│   │   ├── frontend/                # nginx (+ nginx-prometheus-exporter sidecar)
│   │   ├── auth-proxy/              # Apache + mod_auth_mellon SAML SP (+ apache_exporter)
│   │   ├── backend/                 # Node.js API
│   │   ├── mongodb/                 # StatefulSet + PVC + idempotent bootstrap Job
│   │   ├── istio/                   # Sidecar, ServiceEntry, Gateway, VS, DR, EnvoyFilter
│   │   └── platform/                # Route/Ingress, HPA/VPA/PDB, NetworkPolicies,
│   │                                # ServiceMonitors, PrometheusRule, secret sync
│   ├── dashboards/                  # Grafana dashboard (shipped as a ConfigMap)
│   ├── values.yaml                  # safe defaults (everything optional is off)
│   └── values-{dev,qualif,preprod,prod}.yaml
├── argocd/                          # ApplicationSet + AppProject + GitOps repo layout
├── ci/.gitlab-ci.yml                # reference GitLab pipeline (lint -> OCI push -> GitOps bump)
├── .github/workflows/ci.yml         # the pipeline that runs on this repo
└── docs/                            # architecture, case studies, runbook, lessons learned
```

## Features

| Area | What the chart does |
|---|---|
| **Workloads** | Deployments for `frontend`, `auth-proxy`, `backend`; startup/readiness/liveness probes toggled per component; resources; soft anti-affinity by default; rolling updates with `maxUnavailable: 0`; config checksums roll pods on change. |
| **OpenShift-native security** | `runAsNonRoot`, no fixed UID/GID (compatible with the `restricted-v2` SCC), `drop: [ALL]`, no privilege escalation, `RuntimeDefault` seccomp, read-only root FS with `emptyDir` scratch space, no SA token mounted. |
| **Exposure** | OpenShift `Route` (edge TLS, HTTP->HTTPS redirect, HSTS) **or** `Ingress`, one toggle. |
| **nginx** | SPA + `/api` reverse proxy, **CORS allow-list rendered from values** (exact origins only), security headers, JSON access logs. |
| **MongoDB** | `StatefulSet` + `volumeClaimTemplates` (retained on delete), WiredTiger cache sizing, **idempotent user bootstrap as a Helm hook Job** (upsert, retries, TTL), metrics user + exporter. |
| **Secrets** | `existingSecret`, `ExternalSecret` (External Secrets Operator) or `VaultStaticSecret` (Vault Secrets Operator) - **the chart never renders a credential** and has no default passwords. |
| **Autoscaling** | `autoscaling/v2` HPA (CPU 70 % / memory 80 %, scale-up 60 s, scale-down stabilisation 300 s), optional VPA in recommendation mode, PDBs - all behind `scalability.enabled`. HPA-managed Deployments omit `spec.replicas`. |
| **Observability** | One `ServiceMonitor` per component, `PrometheusRule` with 9-10 alerts (5xx ratio, p95 latency, restarts, replicas mismatch, HPA at max, MongoDB down, PVC almost full, certificate expiry, partner API errors), Grafana dashboard. |
| **Network isolation** | Default-deny ingress, allow from router namespace, allow intra-app, allow from monitoring, restricted egress (DNS, intra-app, mesh, explicit extra rules). |
| **Istio egress (case study)** | Backend sidecar with `REGISTRY_ONLY`, `ServiceEntry` for the partner API and the corporate proxy, egress `Gateway` (`ISTIO_MUTUAL`), `VirtualService` mesh -> gateway -> partner, `DestinationRule` originating **mutual TLS with `credentialName`**, `EnvoyFilter` adding **HTTP CONNECT tunnelling** through the proxy. Every Istio object is gated by `istio.enabled`. |
| **Guard rails** | `helm template` fails on invalid exposure/secret provider, missing secret names, Istio without backend, and **`NODE_TLS_REJECT_UNAUTHORIZED=0`**. |
| **Delivery** | GitHub Actions (lint, kubeconform with CRD schemas, negative tests, Trivy config, gitleaks, chart-testing) and a reference GitLab pipeline (OCI push to Harbor, GitOps bump, Kaniko with registry mirror). Argo CD `ApplicationSet` generating one Application per environment. |

## Quickstart

Prerequisites: Helm 3.12+ (Helm 4 works too), a Kubernetes >= 1.27 / OpenShift
4.14+ cluster. Optional CRDs (only needed for the features you enable):
Prometheus Operator, External Secrets / Vault Secrets Operator, VPA, Istio.

```bash
git clone https://github.com/GhislainAdon/openshift-helm-platform-blueprint.git
cd openshift-helm-platform-blueprint

# 1. Secrets are never created by the chart: provide them (dev uses existingSecret).
#    Generate throwaway values locally; never commit them.
kubectl create namespace webapp-dev
kubectl -n webapp-dev create secret generic webapp-mongodb-credentials \
  --from-literal=root-username=root     --from-literal=root-password="$(openssl rand -base64 24)" \
  --from-literal=app-username=webapp    --from-literal=app-password="$(openssl rand -base64 24)" \
  --from-literal=metrics-username=metrics --from-literal=metrics-password="$(openssl rand -base64 24)"
kubectl -n webapp-dev create secret generic webapp-saml-sp \
  --from-file=sp.key=./sp.key --from-file=sp.crt=./sp.crt --from-file=idp-metadata.xml=./idp-metadata.xml

# 2. Inspect, then install.
helm template webapp charts/webapp-platform -f charts/webapp-platform/values-dev.yaml -n webapp-dev | less
helm upgrade --install webapp charts/webapp-platform \
  -n webapp-dev -f charts/webapp-platform/values-dev.yaml

# 3. Check.
kubectl -n webapp-dev get pods,route
kubectl -n webapp-dev logs job/webapp-webapp-platform-mongodb-bootstrap
```

On plain Kubernetes, switch `exposure.type=ingress` and, because the official
MongoDB image does not declare a non-root `USER`, set
`mongodb.podSecurityContext.runAsUser/fsGroup` (OpenShift assigns them).

Render the full-featured profile (Istio + autoscaling + VPA + alerts):

```bash
helm template webapp charts/webapp-platform -f charts/webapp-platform/values-prod.yaml -n webapp-prod
```

## Environments

| | DEV | QUALIF | PREPROD | PROD |
|---|---|---|---|---|
| Host | `app-dev.example.org` | `app-qualif.example.org` | `app-preprod.example.org` | `app.example.org` |
| Replicas front / proxy / back | 1 / 1 / 1 | 1 / 1 / 2 | HPA 2-5 / 2-4 / 2-5 | HPA 2-5 / 2-4 / 2-5 |
| Backend resources (req -> limit) | 100m/192Mi -> 500m/512Mi | same | 250m/384Mi -> 1/768Mi | 500m/512Mi -> 2/1Gi |
| MongoDB volume | 2Gi | 5Gi | 20Gi | 50Gi |
| `scalability.enabled` (HPA, PDB) | false | false | true (+VPA Off) | true (+VPA Off) |
| `istio.enabled` (egress pattern) | false | true | true | true |
| Secrets provider | existingSecret | ExternalSecret | VaultStaticSecret | VaultStaticSecret |
| PrometheusRule / dashboard | - | yes | yes | yes |
| Argo CD sync | auto + self-heal | auto + self-heal | manual | manual |

## Security posture

- **Workload hardening** compatible with OpenShift `restricted-v2` without
  custom SCCs; Trivy config scan clean at MEDIUM/HIGH/CRITICAL (only LOW
  "set runAsUser > 10000" remains, intentionally - OpenShift allocates UIDs).
- **No secrets in Git or in rendered manifests.** Credentials come from
  Vault through an operator; the partner client key lives only in the egress
  gateway namespace and is loaded through SDS.
- **Zero-trust networking**: default-deny ingress, explicit flows, restricted
  egress; with Istio, `REGISTRY_ONLY` turns the list of `ServiceEntry` objects
  into the auditable list of external dependencies.
- **Supply chain**: images only from the internal Harbor (project images +
  proxy-cache mirrors, scanned by Harbor/Trivy); chart published as an OCI
  artefact; `gitleaks` and `trivy config` in CI; promotion to PROD via reviewed
  merge request + manual sync.
- **Unsafe settings are blocked at render time** (e.g. disabling Node.js TLS
  verification).

## Documentation

| Document | Content |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Runtime and delivery diagrams (Mermaid), components, constraints. |
| [docs/case-study-istio-egress.md](docs/case-study-istio-egress.md) | Mutual TLS to a partner through a corporate proxy, moved out of the app and into the mesh. |
| [docs/case-study-kaniko-rate-limit.md](docs/case-study-kaniko-rate-limit.md) | Kaniko builds failing on Docker Hub `TOOMANYREQUESTS` -> registry mirror. |
| [docs/scalability-strategy.md](docs/scalability-strategy.md) | HPA design, load-test scenarios (100 / 500 / 200 req/s), capacity estimate. |
| [docs/runbook.md](docs/runbook.md) | One section per alert + routine operations. |
| [docs/lessons-learned.md](docs/lessons-learned.md) | Six latent defects found in the previous manifests and how each is now prevented. |

## Validation

Every push runs (see [.github/workflows/ci.yml](.github/workflows/ci.yml)):

```bash
helm lint charts/webapp-platform -f charts/webapp-platform/values-<env>.yaml --strict
helm template webapp charts/webapp-platform -f charts/webapp-platform/values-<env>.yaml \
  | kubeconform -strict -ignore-missing-schemas -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
trivy config --ignorefile .trivyignore --severity HIGH,CRITICAL --exit-code 1 .
gitleaks detect --source . --redact
```

---

## Résumé (FR)

**openshift-helm-platform-blueprint** est un chart Helm et un modèle de livraison
« prêt pour la production » pour déployer une application web 3-tiers (frontend
nginx, proxy d'authentification SAML Apache, backend Node.js, MongoDB) sur
OpenShift, livrée en GitOps (GitLab CI + Argo CD) sur quatre environnements
(DEV, QUALIF, PREPROD, PROD).

Points clés :

- **Sécurité** : conteneurs non-root compatibles avec la SCC `restricted-v2`,
  système de fichiers en lecture seule, NetworkPolicies (deny par défaut),
  aucun secret dans Git (Vault via External Secrets ou Vault Secrets Operator),
  garde-fous qui font échouer le rendu (ex. `NODE_TLS_REJECT_UNAUTHORIZED=0`).
- **Scalabilité** : HPA `autoscaling/v2` (CPU 70 %, mémoire 80 %, montée en
  60 s, descente stabilisée 300 s), VPA en mode recommandation, PDB ; MongoDB
  volontairement exclu de l'autoscaling horizontal.
- **Observabilité** : ServiceMonitor par composant, exporters en sidecar,
  PrometheusRule (~10 alertes), tableau de bord Grafana.
- **Étude de cas Istio** : le backend appelle simplement
  `http://partner-api.example.org` ; le mesh (passerelle de sortie) réalise le
  mTLS avec certificat client et le tunnel HTTP CONNECT via le proxy
  d'entreprise. Plus aucune gestion TLS/proxy dans le code applicatif.
- **Retour d'expérience** : six défauts latents identifiés et corrigés
  (helper inexistant dans les HPA, HPA ciblant le mauvais type d'objet,
  EnvoyFilter non conditionné, Pods d'initialisation non idempotents,
  CronJob avec variables non définies, désactivation de la vérification TLS).

> Réécrit entièrement à des fins de portfolio : ne contient aucun code,
> identifiant, certificat ni donnée d'un client.

## License

[MIT](LICENSE) © Ghislain Adon
