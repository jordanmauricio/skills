---
name: spike-triage
description: Triage a production latency or error spike on Google Cloud (Cloud Run, GKE, HTTPS load balancer) from Cloud Monitoring, Cloud Logging and the triage dashboard — find the hop that added the time and why. Use for a p50/p99 jump or a 5xx/504 burst in a time window, "what happened between X and Y" with a dashboard screenshot, or a latency step that will not go away.
---

# Spike triage

Find the **hop** before you read an error log. The hop is the service in the request chain
whose own latency rose — not the one that logs the loudest errors. Past wrong turns all
came from blaming a backend for timeouts that were lost before the call reached it, or from
treating constant error noise as part of the spike.

Three more leading words:

- **Baseline** — a quiet window to compare every number with: the same clock hours on the
  day before. A quieter hour on the same day makes everything look like the cause.
- **Signature** — the shape of the numbers that names the class of cause (table in step 4).
- **Stacked** — one window often holds two or three unrelated causes. Name each separately.

## 1. Load the system map

The map is private and lives outside this skill: the agent's memory for the project, or the
project's runbook. It holds the projects, the request chain in order with each hop's name in
metrics and logs, the dashboard, known error noise, and past incidents by signature (fields
in [The system map](#the-system-map)). This skill is public; keep every project and service
name in the map.

No map yet → build it as you go and save it at the end.

**Done when** you can name the project, the chain in order, and the dashboard (or know there
is none).

## 2. Pin the window

- Convert the reported times to UTC. Screenshots and dashboards show the viewer's local time;
  write the offset down once and give local times in brackets from then on.
- Pick the baseline window.
- Monitoring points aligned with `ALIGN_DELTA` carry the period **end** as their label; shift
  by one period before you name a minute, hour or day.

**Done when** the window and the baseline are written down in UTC.

## 3. Find the hop

If the user sent a dashboard screenshot, read it for a first hypothesis — a hypothesis, not a
verdict. Count-only charts hide a few heavy requests, and a traffic spike and a latency spike
in the same window can be unrelated.

Then measure every Cloud Run hop, window and baseline, services in chain order:

```bash
bash scripts/hop-table.sh PROJECT START_UTC END_UTC PERIOD_S SERVICE...
```

(`scripts/` sits next to this file.) It prints req/s, 5xx/s, p50/p99 ms, active instances
and mean CPU per period and service. Use 60 s periods for a spike, 600 s for a step.

The hop is the first service whose latency rises more than its downstream's. Every hop rising
with req/s points at traffic. GKE hops are not in the table: read
`kubernetes.io/container/{cpu,memory}/limit_utilization` per pod at 1-minute alignment.

**Done when** one hop is named with its window and baseline numbers, or the rise is shown on
every hop together with req/s.

## 4. Read the signature

| Signature | Usual class | Branch |
|---|---|---|
| p99 at the request timeout, 504s on one hop, its instance count jumps | Cold-start pile-on | Capacity |
| p50 step that holds for hours, req/s up | Crawler or scraper | Traffic |
| 1–3 min burst of deadline or unavailable errors at a caller | Backend down or slow | Backend |
| p50 step, req/s flat, CPU per request up | Deploy or dependency change | Change |
| Repeats on a fixed period (10 min, hourly) | Scheduled job, replica, cache expiry | Backend |
| New instances crash or never become ready | A startup dependency is down | Change |

Follow every branch the numbers point at; stacked causes are the norm.

### Traffic

The edge (load balancer logs) carries the real client IP, UA, ASN and JA4; inner hops see the
proxy. Compare 2 minutes of baseline with 2 minutes of the spike:

```bash
gcloud logging read --project P 'resource.type="http_load_balancer" timestamp>="A" timestamp<"B"' \
  --format='value(httpRequest.userAgent)' --limit 200000 | sort | uniq -c | sort -rn | head
```

Swap the field for `httpRequest.remoteIp`,
`jsonPayload.securityPolicyRequestData.remoteIpInfo.asn` or
`jsonPayload.securityPolicyRequestData.tlsJa4Fingerprint`.

- A rotating-IP crawler shows as thousands of one-request IPs that load no static assets.
  Follow it by JA4.
- A browser UA whose JA4 ALPN (characters 9–10) is not `h2` or `h3` is not a browser.
- Count shares from the logs; the LB `request_count` metric is off by up to ±30% per minute.

### Backend

- Count failed calls per backend per 10 s at the caller, from the log line it writes once per
  failed call (the map names it). A free-text search for backend + error code overcounts.
- Then read the backend's own request logs for the same seconds. Fast `499`s (caller
  cancelled) mean the time was lost between caller and backend — connection-pool wait, cold
  backend instances, a queue in front — not inside the backend.
- GKE: k8s events (`logs/events`, filter on `jsonPayload.involvedObject.namespace`) for
  `Killing` (HPA scale-down without drain, liveness), `Unhealthy`, `BackOff`; a pod at memory
  `limit_utilization` 1.0 that restarts with no liveness kill is an OOM.
- Compare every error rate with the baseline. Constant noise is listed in the map.

### Capacity

- Count `Starting new instance` per minute on the hop, then check whether its 504s sit on
  instances that started seconds before (request logs carry `labels.instanceId`).
- Per new instance, measure start → first request served. A framework may log "ready" before
  it can serve (Next.js does), so a TCP startup probe passes early. A request that triggers a
  new instance waits for that instance; an HTTP startup probe moves the wait out of the
  instance but does not shorten it.
- CPU near 1.0 on a flat request rate means each request costs more: go to Change.

### Change

- Revisions created near the onset, on the hop and everything below it.
- Image or dependency upgrades with no rollback path.
- An external dependency the service needs at startup (a CMS, an auth server): when it is
  down, new instances exit and the fleet cannot scale.

**Done when** every branch you followed ends in a count for window vs baseline that confirms
or clears it.

## 5. Report

- Timeline in UTC (local in brackets): one row per event, each with the number that shows it.
- Each stacked cause on its own, with its share of the slow or failed requests.
- Measured and inferred kept apart; for each open hypothesis, the check that would settle it.
- Fixes as suggestions. Infrastructure changes go through the owners' normal change path.
- Update the map: new noise, new signature → cause, new gotcha.

## Working rules

- Basic queries: `gcloud`, the Monitoring API and shell one-liners. Propose deeper analysis
  (custom scripts) and wait for a go-ahead.
- Every `gcloud logging read` gets `--project` and a `timestamp` range. At most 3 in parallel;
  narrow the window when one runs past 2 minutes.
- Cloud Run request-log `timestamp` is request arrival; latency is `httpRequest.latency`.
- A free-text log search also matches request logs: add
  `NOT logName:"run.googleapis.com%2Frequests"`.
- Trace IDs stop at the first hop that does not propagate them; correlate by second instead.
- `instance_count` is int64: read `.int64Value // .doubleValue`.
- Some services write request logs only for 5xx; read their app logs.

## The system map

One private note per system:

- **Projects** per environment, and region.
- **Chain**: each hop in order — platform (Cloud Run, GKE, LB backend), its name in metrics
  and logs, request timeout, instance limits.
- **Edge**: which logs carry the real client IP and UA.
- **Failure lines**: the caller's once-per-failed-call log filter, per backend.
- **Dashboard**: URL, and which question each section answers.
- **Noise**: error lines that are always there, with their normal rate.
- **Past incidents**: signature → cause, with a link to the write-up.
