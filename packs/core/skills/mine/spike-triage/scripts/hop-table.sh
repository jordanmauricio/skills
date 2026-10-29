#!/usr/bin/env bash
# Usage: hop-table.sh PROJECT START_UTC END_UTC PERIOD_S SERVICE...
# One row per period and Cloud Run service, services in the order given (pass them in
# request-chain order): req/s, 5xx/s, p50 and p99 latency in ms, active instances, mean CPU.
# Times are UTC and mark the START of each period; the API labels points with the end.
set -euo pipefail
[ $# -ge 5 ] || { sed -n 2,5p "$0" >&2; exit 2; }
PROJECT=$1 START=$2 END=$3 P=$4
shift 4
TOKEN=$(gcloud auth print-access-token)

q() { # service metric aligner reducer column [extra filter]
  curl -sf -H "Authorization: Bearer $TOKEN" -G "https://monitoring.googleapis.com/v3/projects/$PROJECT/timeSeries" \
    --data-urlencode "filter=metric.type=\"run.googleapis.com/$2\" AND resource.labels.service_name=\"$1\"${6:-}" \
    --data-urlencode "interval.startTime=$START" --data-urlencode "interval.endTime=$END" \
    --data-urlencode "aggregation.alignmentPeriod=${P}s" \
    --data-urlencode "aggregation.perSeriesAligner=$3" --data-urlencode "aggregation.crossSeriesReducer=$4" |
    jq -r --arg s "$1" --arg c "$5" --argjson p "$P" '.timeSeries[]?.points[] | [
      (.interval.endTime | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 - $p | strftime("%m-%d %H:%M")),
      $s, $c, (.value.int64Value // .value.doubleValue | tonumber)] | @tsv'
}

OUT=$(
  for s in "$@"; do
    q "$s" request_count ALIGN_DELTA REDUCE_SUM n &
    q "$s" request_count ALIGN_DELTA REDUCE_SUM e ' AND metric.labels.response_code_class="5xx"' &
    q "$s" request_latencies ALIGN_DELTA REDUCE_PERCENTILE_50 p50 &
    q "$s" request_latencies ALIGN_DELTA REDUCE_PERCENTILE_99 p99 &
    q "$s" container/instance_count ALIGN_MEAN REDUCE_SUM inst ' AND metric.labels.state="active"' &
    q "$s" container/cpu/utilizations ALIGN_DELTA REDUCE_MEAN cpu &
  done
  wait
)
[ -n "$OUT" ] || { echo "no data: check gcloud auth, the project and the service names" >&2; exit 1; }

awk -F'\t' -v p="$P" -v order="$*" '
  BEGIN { n = split(order, svc, " "); for (i = 1; i <= n; i++) rank[svc[i]] = i }
  { v[$1, $2, $3] = $4; seen[$1, $2] = 1 }
  END {
    for (k in seen) {
      split(k, t, SUBSEP)
      printf "%s\t%d\t%s\t%.1f\t%.2f\t%.0f\t%.0f\t%.1f\t%.2f\n", t[1], rank[t[2]], t[2],
        v[t[1], t[2], "n"] / p, v[t[1], t[2], "e"] / p, v[t[1], t[2], "p50"], v[t[1], t[2], "p99"],
        v[t[1], t[2], "inst"], v[t[1], t[2], "cpu"]
    }
  }' <<< "$OUT" |
  sort -t$'\t' -k1,1 -k2,2n | cut -f1,3- |
  { printf 'utc\tservice\treq/s\t5xx/s\tp50_ms\tp99_ms\tinst\tcpu\n'; cat; } | column -t -s$'\t'
