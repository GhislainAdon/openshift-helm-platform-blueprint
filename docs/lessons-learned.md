# Lessons learned: latent defects found and fixed

The chart in this repository is a from-scratch rewrite. While reviewing the
manifests it replaces, several defects were found that had not caused visible
incidents yet - mostly because the code path was disabled in the environments
that were actually deployed. Each one is fixed here and, where possible, made
impossible to reintroduce.

## 1. HPA templates calling an undefined helper

**Found:** the HPA and VPA templates called `include "<chart>.labels"`, but the
chart's `_helpers.tpl` defined a single, unrelated helper - no labels, no
fullname, no selector labels. Because the HPAs were wrapped in a values toggle
that was `false` everywhere, Helm never evaluated them. The first environment
to set the toggle to `true` would have failed to render
(`error calling include: template: no template "<chart>.labels" associated with template "gotpl"`).

**Fix:** a complete `_helpers.tpl` (`webapp.name`, `webapp.fullname`,
`webapp.labels`, `webapp.selectorLabels`, `webapp.componentName`...). The HPA
and the Deployment use the **same** helper for the name, so they cannot drift.

**Guard rail:** CI renders every environment **and** a profile with every
toggle enabled. Code behind a disabled flag is still code.

## 2. HPA targeting the wrong kind

**Found:** the database HPA/VPA pointed at `kind: StatefulSet`, while the
database was actually deployed as a `Deployment`. Had it been enabled, the HPA
would have reported `FailedGetScale` and silently done nothing. Fixing only the
kind would have been worse: horizontally scaling a standalone `mongod` creates
independent, divergent databases behind one Service.

**Fix:** MongoDB is now a `StatefulSet` (stable identity + `volumeClaimTemplates`)
and is explicitly **excluded** from horizontal autoscaling (vertical sizing and
VPA recommendations only). HPAs are generated only for the stateless
Deployments, with `scaleTargetRef.kind: Deployment` hard-wired.

**Guard rail:** a CI negative test asserts no HPA targets a StatefulSet.

## 3. Ungated EnvoyFilter

**Found:** every Istio object was wrapped in `if .Values.istio.enabled`
except the EnvoyFilter. With Istio disabled, the chart still rendered an
EnvoyFilter: on a cluster without the CRD the sync failed; on a cluster with
Istio it patched a gateway the application was not using.

**Fix:** every file under `templates/istio/` starts with the same gate,
including the EnvoyFilter. The EnvoyFilter is also scoped by
`workloadSelector` and by cluster name.

**Guard rail:** CI fails if any `networking.istio.io` object is rendered with
`istio.enabled=false`.

## 4. Non-idempotent database bootstrap with bare Pods

**Found:** MongoDB users were created by plain `Pod` manifests running a
`createUser` script.

- Pods are immutable: any change to the script made `helm upgrade` / Argo CD
  sync fail (`spec: Forbidden: pod updates may not change fields...`).
- No retry: if MongoDB was not ready yet, the Pod failed once and stayed
  `Error` forever.
- `createUser` on an existing user fails, so re-running was not possible.
- Completed Pods accumulated and showed as out-of-sync.

**Fix:** a Helm hook **Job** (`post-install,post-upgrade`, mapped to Argo CD
`PostSync`) with `backoffLimit`, `activeDeadlineSeconds`, `ttlSecondsAfterFinished`
and `hook-delete-policy: before-hook-creation,hook-succeeded`. The script waits
for MongoDB, then **upserts** users (`getUser` -> `updateUser` or `createUser`),
reading credentials from environment variables, never from argv. Running it N
times converges to the same state and doubles as password rotation.

## 5. Log-rotation CronJob referencing undefined environment variables

**Found:** a nightly CronJob meant to rotate MongoDB logs passed credentials as
`$(MONGO_INITDB_ROOT_USERNAME)` / `$(MONGO_INITDB_ROOT_PASSWORD)` in its
command, but its container defined differently named variables
(`DB_ADMIN_USERNAME`, ...). Kubernetes leaves an unresolved `$(VAR)` reference
**as the literal string**, so the job authenticated with the text
`$(MONGO_INITDB_ROOT_USERNAME)` every night and failed - in a CronJob nobody
was watching.

**Fix:** the CronJob is gone: MongoDB logs to stdout, collected by the
platform's log stack (Loki), with retention handled there. The remaining
script (bootstrap Job) reads only variables declared in the same manifest,
from the environment, and runs with `sh -e`.

**Guard rail:** a `kube_job_status_failed` / CronJob last-success alert for any
scheduled job; reviewers check that every `$(VAR)` in `command`/`args` has a
matching `env` entry.

## 6. `NODE_TLS_REJECT_UNAUTHORIZED=0` in a non-production environment

**Found:** to get past certificate errors behind the corporate proxy, one
environment's values set `NODE_TLS_REJECT_UNAUTHORIZED=0` on the backend. This
disables server certificate verification for every outbound TLS call of the
process (database drivers, identity provider, partner API) - a man-in-the-middle
on any of them would go unnoticed. Settings like this tend to be copied into
the next environment.

**Fix:** removed. Non-mesh environments trust the corporate CA explicitly
(`NODE_EXTRA_CA_CERTS`); mesh environments do not do TLS in the application at
all (see [case study](case-study-istio-egress.md)).

**Guard rail:** `_helpers.tpl` fails the render if any component sets
`NODE_TLS_REJECT_UNAUTHORIZED` to `0`, with a message pointing to the right fix.
A CI job checks that the guard fires.

## Cross-cutting takeaways

- **Render everything in CI**, including disabled branches, and validate the
  output against schemas (kubeconform with CRD schemas), not just `helm lint`.
- **Turn review findings into tests**: each fix above has a negative test or a
  render-time `fail`.
- **Name things from one helper**: references between objects (HPA -> Deployment,
  Service -> pods, NetworkPolicy -> pods, Route -> Service) must come from the
  same template function.
- **Gate by feature, by file**: one toggle, checked at the top of every file of
  the feature, is easier to audit than conditions sprinkled inside templates.
