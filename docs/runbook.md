# Runbook

Conventions: `NS=webapp-<env>`, release name `webapp`, resources are prefixed
`webapp-webapp-platform-`.

```bash
NS=webapp-prod
P=webapp-webapp-platform
kubectl -n $NS get pods,hpa,pdb -l app.kubernetes.io/instance=webapp
```

## Deploy / rollback

| Action | How |
|---|---|
| Deploy a new version | Merge the chart version bump in the GitOps repo (`environments/<env>/config.yaml`). DEV/QUALIF sync automatically; PREPROD/PROD: Argo CD UI or `argocd app sync webapp-<env>`. |
| Rollback | Revert the GitOps commit, then sync. Avoid `argocd app rollback` on auto-synced apps (it is overwritten by the next sync). |
| Diff before sync | `argocd app diff webapp-<env>` |
| Render locally | `helm template webapp charts/webapp-platform -f charts/webapp-platform/values-<env>.yaml` |

## Alerts

### High 5xx rate
`WebappHighHttp5xxRate`
1. Which endpoints? Logs: `kubectl -n $NS logs deploy/$P-backend --since=15m | grep '"status":5'`.
2. Correlate with a deployment (Argo CD history) -> roll back if it started with a release.
3. Check dependencies: `WebappMongoDBDown`, `WebappPartnerApiErrors`.
4. Check saturation: HPA at max? CPU throttling? OOMKilled (`kubectl describe pod`)?

### High latency
`WebappHighLatencyP95`
1. Dashboard "Webapp platform - overview": latency panel vs. request rate.
2. If load-related: HPA status (`kubectl -n $NS describe hpa $P-backend`).
3. If not load-related: MongoDB slow queries (`db.currentOp({secs_running: {$gt: 2}})`),
   partner API latency (Istio metrics on the egress gateway).

### Frontend down
`WebappNginxDown`
- `kubectl -n $NS get pods -l app.kubernetes.io/component=frontend`
- Config error after a change? `kubectl -n $NS logs deploy/$P-frontend -c frontend` (nginx prints the faulty line).

### MongoDB down
`WebappMongoDBDown`
1. `kubectl -n $NS get pod $P-mongodb-0 -o wide` - Pending? (PVC / node), CrashLoop? (logs), Running? (exporter credentials).
2. `kubectl -n $NS logs $P-mongodb-0 -c mongodb --tail=200`
3. Volume full -> see [PVC full](#pvc-full).
4. Exporter only: `kubectl -n $NS logs $P-mongodb-0 -c mongodb-exporter` - authentication errors mean the
   metrics user is missing: re-run the bootstrap (below).

### Crashloop
`WebappPodRestarting`
- `kubectl -n $NS describe pod <pod>`: `OOMKilled` -> raise memory limit (check VPA recommendation);
  liveness failures -> check startup probe budget; config errors -> logs of the previous container (`--previous`).

### Replicas mismatch
`WebappDeploymentReplicasMismatch`
- Pending pods: quota (`kubectl -n $NS describe quota`), image pull (Harbor reachable? pull secret?).
- Rollout stuck: `kubectl -n $NS rollout status deploy/<name>`.

### HPA at max
`WebappHPAAtMaxReplicas`
- Real traffic increase -> raise `maxReplicas` in values (and check namespace quota).
- Downstream bottleneck (MongoDB / partner) -> adding pods will not help; investigate the dependency.

### PVC full
`WebappPVCAlmostFull`
1. `kubectl -n $NS exec $P-mongodb-0 -c mongodb -- df -h /data/db`
2. Expand: increase `mongodb.persistence.size` **and** patch the existing PVC
   (`volumeClaimTemplates` changes are not applied to existing PVCs):
   `kubectl -n $NS patch pvc data-$P-mongodb-0 -p '{"spec":{"resources":{"requests":{"storage":"80Gi"}}}}'`
   (requires a StorageClass with `allowVolumeExpansion: true`).

### Certificate expiry
`WebappCertificateExpiringSoon`
- Route certificate: renew through the platform's certificate process (or cert-manager), update the Route/TLS secret.
- SAML SP certificate: rotate in Vault (`webapp/<env>/saml-sp`), publish the new SP metadata to the IdP **before** the switch.
- Partner client certificate: rotate the Secret referenced by `istio.partner.credentialName`; the egress gateway picks it up via SDS without restart.

### Partner API errors
`WebappPartnerApiErrors` - see the troubleshooting table in
[case-study-istio-egress.md](case-study-istio-egress.md#troubleshooting-checklist).

## Routine operations

### Re-run the MongoDB user bootstrap
The Job is a Helm hook, re-run on every upgrade. To run it manually (idempotent):
```bash
argocd app sync webapp-<env>            # re-runs PostSync hooks
# or, outside Argo CD:
helm upgrade webapp charts/webapp-platform -n $NS -f charts/webapp-platform/values-<env>.yaml --reuse-values
kubectl -n $NS logs job/$P-mongodb-bootstrap
```

### Rotate MongoDB application password
1. Update `app-password` in Vault (`webapp/<env>/mongodb`).
2. The VaultStaticSecret refreshes the Secret and restarts the backend.
3. Run the bootstrap (above) so MongoDB's user matches the new password.
   Order matters: bootstrap first, then backend restart, to avoid an
   authentication gap - or run both within the same sync.

The **root** password is only read at first initialisation of the volume;
rotate it with `db.changeUserPassword()` then update Vault.

### Backup / restore (MongoDB)
```bash
kubectl -n $NS exec $P-mongodb-0 -c mongodb -- sh -c \
  'mongodump --archive --gzip -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin' > dump.gz
kubectl -n $NS exec -i $P-mongodb-0 -c mongodb -- sh -c \
  'mongorestore --archive --gzip --drop -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin' < dump.gz
```
Prefer volume snapshots (CSI `VolumeSnapshot`) for large datasets.
