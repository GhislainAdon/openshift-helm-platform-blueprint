# Case study: Kaniko builds failing on Docker Hub rate limits

## Symptom

Image builds in GitLab CI (Kaniko executor, no Docker daemon on the platform)
started failing intermittently, usually on Monday mornings and after merges that
triggered many pipelines at once:

```text
error building image: GET https://index.docker.io/v2/library/node/manifests/20-alpine:
TOOMANYREQUESTS: You have reached your pull rate limit.
```

Retrying "fixed" it sometimes, which made it look flaky rather than structural.

## Root cause

- All CI runners leave the platform through the same few egress IP addresses.
  For Docker Hub, every anonymous pull from every team counts against the
  **same** per-IP quota.
- Kaniko resolves the base images of each `FROM` (including intermediate stages
  of multi-stage Dockerfiles) against `index.docker.io` on every build.
- Peaks of parallel pipelines exhausted the quota within minutes; the window
  then took hours to reset.

## Fix

1. **Pull-through cache in Harbor.** A Harbor proxy-cache project (`mirror`)
   fronts Docker Hub, authenticated with a service account. The first pull of a
   tag fetches it upstream; subsequent pulls are served from the internal
   registry and do not count against the quota.

2. **Point Kaniko at the mirror** without touching any Dockerfile:

   ```bash
   /kaniko/executor \
     --context "$CI_PROJECT_DIR" \
     --dockerfile "$CI_PROJECT_DIR/Dockerfile" \
     --destination "harbor.example.org/webapp/backend:$CI_COMMIT_SHORT_SHA" \
     --registry-mirror "harbor.example.org/mirror" \
     --cache=true --cache-repo "harbor.example.org/webapp/cache"
   ```

   `--registry-mirror` only applies to `docker.io` references, so images already
   hosted elsewhere are unaffected. Kaniko falls back to Docker Hub if the
   mirror is unavailable, which keeps builds working during a registry incident
   (at the cost of the quota).

3. **Layer cache** (`--cache=true --cache-repo`) so unchanged layers are not
   rebuilt nor re-pulled.

4. **Shared CI template**: the flags live in a hidden `.kaniko-build` job (see
   `ci/.gitlab-ci.yml`) that every application pipeline `extends`, so the fix
   is applied once.

5. **Runtime images too**: all Kubernetes manifests reference
   `harbor.example.org/mirror/...` for third-party images (MongoDB, exporters),
   so node-level pulls are not exposed to the same limit.

## Result

- `TOOMANYREQUESTS` failures disappeared from CI.
- Base-image pulls became faster (LAN instead of Internet through the proxy).
- Third-party images go through Harbor, where they are scanned by Trivy like
  internal images, which gave the security team a single inventory.

## Lessons

- A "flaky" failure correlated with time-of-day is usually a shared quota.
- Fix it at the platform layer (registry mirror + shared CI template) rather
  than per Dockerfile (`FROM harbor.example.org/mirror/library/node:20-alpine`),
  which drifts and is easy to forget.
