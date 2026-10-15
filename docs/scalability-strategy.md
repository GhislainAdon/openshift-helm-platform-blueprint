# Scalability strategy

## Goals

- Absorb daily peaks without manual intervention.
- Keep at least two replicas of every stateless tier in production-like
  environments (zero-downtime rollouts and node drains).
- Never let autoscaling and GitOps fight over the replica count.
- Keep the database out of horizontal autoscaling.

## What scales, and how

| Tier | Mechanism | Min | Max | Signals |
|---|---|---|---|---|
| frontend (nginx) | HPA `autoscaling/v2` | 2 | 5 | CPU 70 %, memory 80 % |
| auth-proxy (Apache SP) | HPA | 2 | 4 | CPU 70 %, memory 80 % |
| backend (Node.js) | HPA | 2 | 5 | CPU 70 %, memory 80 % |
| MongoDB | **Vertical only** (resources per environment, VPA recommendations) | 1 | 1 | - |

All of it is gated by `scalability.enabled` (true in PREPROD/PROD).

### HPA behaviour

```yaml
behavior:
  scaleUp:
    stabilizationWindowSeconds: 60     # react within a minute
    policies:
      - {type: Percent, value: 100, periodSeconds: 60}   # at most double...
      - {type: Pods,    value: 2,   periodSeconds: 60}   # ...or +2 pods
    selectPolicy: Max
  scaleDown:
    stabilizationWindowSeconds: 300    # wait 5 minutes of calm
    policies:
      - {type: Pods, value: 1, periodSeconds: 60}        # remove one pod per minute
```

Fast up, slow down: a burst is absorbed in 1-2 minutes; capacity is released
gradually to avoid flapping when traffic oscillates around the threshold.

### Why CPU **and** memory

Node.js memory grows with concurrent requests (buffers, open sockets), often
before CPU saturates on I/O-bound endpoints. nginx and Apache are CPU-bound
under TLS-less proxying. Using both metrics covers both shapes of load; the HPA
takes the highest recommendation.

### Requests sizing

HPA utilisation is relative to **requests**, so requests are set to the
observed steady-state usage (not the limit). Limits leave room for bursts.
The VPA runs in `updateMode: "Off"`: it only publishes recommendations, which
are reviewed and copied into `values-<env>.yaml`. A VPA in `Auto` mode on the
same CPU/memory signals as the HPA would fight it.

### Supporting objects

- **PodDisruptionBudget** `minAvailable: 1` per autoscaled Deployment.
- **Soft pod anti-affinity** (default) and **zone topology spread** (PROD)
  so that replicas do not share a node / zone.
- **Rolling updates** with `maxUnavailable: 0`, `maxSurge: 25%`.
- **Readiness probes** gate traffic; **startup probes** protect slow boots
  from premature liveness kills during scale-up.
- **GitOps**: when the HPA is on, `spec.replicas` is not rendered and Argo CD
  ignores `/spec/replicas` on Deployments.

### Why MongoDB is excluded

A standalone `mongod` scaled to N replicas by an HPA produces N independent
databases behind one Service: writes land on random members and data diverges.
Horizontal scaling of MongoDB requires a replica set (initiation, elections,
read preferences) managed by an operator. Until then the database scales
vertically, with `wiredTigerCacheSizeGB` kept below 50 % of the memory limit.

## Load-test scenarios

Run in PREPROD (same topology as PROD) with k6 or Gatling, through the public
route, with SAML bypassed by a test IdP session.

| # | Scenario | Profile | Target | Pass criteria |
|---|---|---|---|---|
| 1 | Nominal load | 1 000 virtual users, ramp 5 min, plateau 30 min | 100 req/s | p95 < 500 ms, error rate < 0.5 %, no scale-out beyond 3 backend pods |
| 2 | Peak | 5 000 virtual users, ramp 10 min, plateau 15 min | 500 req/s | p95 < 1 s, error rate < 1 %, HPA reaches max without OOMKill, scale-down completes < 15 min after the test |
| 3 | Endurance | 2 000 virtual users, 24 h | 200 req/s | No memory leak (backend RSS slope ~ 0), no restart, MongoDB volume growth within forecast |

### What to observe

- `WebappHPAAtMaxReplicas`: if it fires during scenario 2, the ceiling is too
  low **or** a downstream (MongoDB, partner API) is the bottleneck - scaling
  stateless tiers further will not help.
- Backend p95 vs. MongoDB operation latency: diverging curves point to the
  database or to connection pool size (`maxPoolSize` x replicas must stay
  below MongoDB's connection budget).
- Egress gateway latency for partner calls: the partner, not the cluster, is
  often the limiting factor; protect it with timeouts and retries budget (set
  in the VirtualService).
- Time-to-ready of new pods (image pull + startup probe): it bounds how fast
  the HPA can actually add capacity.

### Capacity estimate (starting point, to be confirmed by tests)

| Tier | Throughput per pod (observed order of magnitude) | Pods for 500 req/s |
|---|---|---|
| frontend | > 1 000 req/s (static + proxy) | 2 (availability) |
| auth-proxy | ~ 300 req/s | 2-3 |
| backend | ~ 120 req/s (mixed read/write) | 5 |

These numbers are what the HPA ceilings (5 / 4 / 5) were derived from.
