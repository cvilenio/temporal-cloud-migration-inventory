#!/usr/bin/env bash
# ===========================================================================
# Self-hosted Temporal -> Temporal Cloud migration inventory
# SCRIPT B  -  everything that comes from Prometheus
#
# ENDPOINT: your Prometheus / Mimir / Thanos HTTP API.
# PAIRS WITH: A-cli-inventory.sh, which talks to the Temporal frontend.
#
# USAGE
#   PROM_URL=http://prom:9090 CLUSTER_ID=my-cluster ./B-promql-inventory.sh > promql.tsv
#
#   If two clusters share a namespace NAME (script A tells you), Prometheus
#   merges their metrics and no query can separate them. Then run once per
#   cluster with a discriminating label:
#     CLUSTER_LABEL=cluster CLUSTER_VALUE=use1 CLUSTER_ID=prod-us-east-1 ...
#   The discovery preamble lists the candidate labels.
#
# WRITES: one flat row per namespace on stdout, commentary on stderr.
#   Feed the TSV into your Cloud migration sizing / prerequisite review.
#
# COMPATIBILITY: bash 3.2 (stock macOS /bin/bash). Requires: curl, jq, awk.
# ===========================================================================
set -uo pipefail
SCRIPT_VERSION="${SCRIPT_VERSION:-v0.1.2}"

echo "# script=B-promql-inventory.sh version=$SCRIPT_VERSION" >&2
PROM="${PROM_URL:?set PROM_URL, e.g. http://localhost:9090}"
CLUSTER_ID="${CLUSTER_ID:-UNKNOWN}"
if [ "$CLUSTER_ID" = UNKNOWN ]; then
  echo "WARN CLUSTER_ID is not set. Every row will be keyed UNKNOWN/<namespace> and" >&2
  echo "     will not join to anything. Set CLUSTER_ID to the same value you used" >&2
  echo "     for this cluster in script A." >&2
fi
DAYS="${WINDOW_DAYS:-${DAYS:-30}}"
# Whole days, at least 1. A zero divides by zero downstream and emits a
# fabricated actions_per_day; a fraction leaves `start` unset and every query
# then runs from the Unix epoch. Both used to exit 0 with a plausible row.
case "$DAYS" in
  ''|*[!0-9]*) echo "WINDOW_DAYS must be a whole number of days (got '$DAYS')" >&2; exit 2 ;;
esac
[ "$DAYS" -lt 1 ] && { echo "WINDOW_DAYS must be at least 1 (got '$DAYS'). A metrics store holding less than a day cannot support these columns." >&2; exit 2; }
STEP="${STEP:-300}"
MIN_COVERAGE="${MIN_COVERAGE:-20}"
SKIP_NS="${SKIP_NS:-temporal-system temporal_system}"
RUN_TS="$(date -u +"%Y-%m-%d %H:%M:%S")"   # timestamp, not date: see script A

CLUSTER_LABEL="${CLUSTER_LABEL:-}"
CLUSTER_VALUE="${CLUSTER_VALUE:-}"
CSEL=""
if [ -n "$CLUSTER_LABEL" ] && [ -n "$CLUSTER_VALUE" ]; then
  CSEL="$CLUSTER_LABEL=\"$CLUSTER_VALUE\","
fi

if ! curl -sf --max-time 15 "$PROM/api/v1/query?query=1" >/dev/null 2>&1; then
  echo "ERROR cannot reach a Prometheus HTTP API at $PROM" >&2
  echo "      Tried: $PROM/api/v1/query?query=1" >&2
  echo "      Nothing was written. Check the URL, the port-forward, and any auth proxy." >&2
  exit 1
fi

_probe_metric() {
  curl -sf --max-time 20 -G --data-urlencode "query=count($1)" "$PROM/api/v1/query" 2>/dev/null \
    | jq -e '.data.result | length > 0' >/dev/null 2>&1
}
SR="service_requests"; ACT="action"
if ! _probe_metric "$SR"; then
  if _probe_metric "${SR}_total"; then
    SR="service_requests_total"; ACT="action_total"
    echo "# note: this store uses the _total suffix; using $SR and $ACT" >&2
  else
    echo "ERROR neither 'service_requests' nor 'service_requests_total' returned any series at $PROM" >&2
    echo "      Temporal SERVER metrics do not appear to be scraped here. SDK-only metrics" >&2
    echo "      cannot fill any load column. Nothing was written." >&2
    exit 1
  fi
fi

now=$(date +%s)
start=$(( now - DAYS * 86400 ))

pq() {
  curl -sG --data-urlencode "query=$1" "$PROM/api/v1/query" \
    | jq -r --arg lbl "$NSLABEL" '.data.result[]? | "\(.metric[$lbl] // "_none_")\t\(.value[1])"'
}

win() {  # metric selector -> ns, first_ts, last_ts, n_samples
  curl -sG \
      --data-urlencode "query=sum($1) by ($NSLABEL)" \
      --data-urlencode "start=$start" --data-urlencode "end=$now" \
      --data-urlencode "step=3600" \
      "$PROM/api/v1/query_range" \
    | jq -r --arg lbl "$NSLABEL" '
        .data.result[]? | select((.values|length) > 0)
        | [ (.metric[$lbl] // "_none_"), (.values[0][0]|floor),
            (.values[-1][0]|floor), (.values|length) ] | @tsv'
}

skip_ns() {
  _n="$(printf '%s' "$1" | tr '-' '_')"
  for _s in $SKIP_NS; do
    [ "$_n" = "$(printf '%s' "$_s" | tr '-' '_')" ] && return 0
  done
  return 1
}

# =============================================== discovery, all to stderr
{
echo "# =============================================================="
echo "# run_ts=$RUN_TS UTC  cluster_id=$CLUSTER_ID  window=${DAYS}d  step=${STEP}s"

# --- which label carries the namespace
NSLABEL="namespace"
probe="$(curl -sG --data-urlencode "query=group by (namespace, exported_namespace) (${SR})" \
  "$PROM/api/v1/query" | jq -r '[.data.result[]?.metric | keys[]] | unique | join(",")')"
case "$probe" in
  *exported_namespace*) NSLABEL="exported_namespace" ;;
  *namespace*)          NSLABEL="namespace" ;;
  *) echo "# WARN could not detect a namespace label; defaulting to '$NSLABEL'" ;;
esac
echo "# namespace label: $NSLABEL"

# --- candidate cluster discriminators, so a human can pick one
echo "# candidate cluster-discriminating labels:"
curl -sG --data-urlencode "match[]=${SR}{service_name=\"frontend\"}" \
    --data-urlencode "start=$start" --data-urlencode "end=$now" \
    "$PROM/api/v1/series" 2>/dev/null \
  | jq -r '[.data[]? | keys[]] | unique[]' 2>/dev/null \
  | grep -vE '^(__name__|namespace|exported_namespace|operation|service_name|type)$' \
  | while IFS= read -r lab; do
      vals="$(curl -sG --data-urlencode "query=group by ($lab) (${SR}{service_name=\"frontend\"})" \
        "$PROM/api/v1/query" | jq -r --arg l "$lab" '[.data.result[]?.metric[$l]] | unique | join(", ")')"
      n="$(printf '%s' "$vals" | awk -F', ' '{print NF}')"
      echo "#   $lab  ($n): $vals" | cut -c1-160
    done

# --- scrape duplication: identical series under several jobs
FRONTEND="service_name=\"frontend\""
JOBS="$(curl -sG --data-urlencode "query=count by (job) (${SR}{$FRONTEND})" \
  "$PROM/api/v1/query" 2>/dev/null | jq -r '.data.result[]? | "\(.metric.job) \(.value[1])"')"
NJOBS="$(printf '%s\n' "$JOBS" | grep -c . || true)"
JOB_SEL=""
if [ "${NJOBS:-0}" -gt 1 ]; then
  if [ -n "${PROM_JOB:-}" ]; then CHOSEN="$PROM_JOB"
  else CHOSEN="$(printf '%s\n' "$JOBS" | sort -k2 -nr | head -1 | awk '{print $1}')"; fi
  JOB_SEL="job=\"$CHOSEN\","
  echo "# SCRAPE DUPLICATION: $NJOBS jobs scrape the same targets - every absolute"
  echo "#   total would be ${NJOBS}x too high. Filtering to job=\"$CHOSEN\"."
  printf '%s\n' "$JOBS" | sed 's/^/#     job=/'
  echo "#   Override with PROM_JOB. If your jobs PARTITION targets rather than"
  echo "#   duplicating them, this drops data - check:"
  echo "#     count by (job, instance) (${SR}{$FRONTEND})"
else
  echo "# scrape jobs: ${NJOBS:-0} - no duplication"
fi

RET="$(curl -s "$PROM/api/v1/status/flags" 2>/dev/null \
  | jq -r '.data["storage.tsdb.retention.time"] // empty')"
[ -n "$RET" ] && echo "# store retention flag: $RET"
[ -n "$CSEL" ] && echo "# cluster filter: $CSEL"
echo "# =============================================================="
} >&2

# service_requests is emitted by EVERY service, so the frontend filter is not
# optional: without it one client call is counted again by history and matching.
FRONTEND="${JOB_SEL}${CSEL}service_name=\"frontend\""
LOAD_OP="${FRONTEND},operation=~\"StartWorkflowExecution|SignalWithStartWorkflowExecution\""
# SignalWithStart against an EXISTING workflow creates no execution, so it must
# not appear in a per-execution denominator.
NEWX_OP="${FRONTEND},operation=\"StartWorkflowExecution\""
SWS_OP="${FRONTEND},operation=\"SignalWithStartWorkflowExecution\""

RQ="sum(rate(${SR}{$LOAD_OP}[5m])) by ($NSLABEL)[${DAYS}d:5m]"

# =============================================== gather into one tagged stream
{
  win "${SR}{$LOAD_OP}" | awk -F'\t' -v d="$DAYS" '{
      printf "WIN\t%s\t%.1f\t%.0f\n", $1, ($3-$2)/86400, ($4/(d*24))*100 }'
  win "${ACT}{$FRONTEND}"          | awk -F'\t' '{ printf "AWIN\t%s\t%.1f\n", $1, ($3-$2)/86400 }'

  pq "quantile_over_time(0.5,  $RQ)"                                        | sed 's/^/P50\t/'
  pq "quantile_over_time(0.95, $RQ)"                                        | sed 's/^/P95\t/'
  pq "max_over_time($RQ)"                                                   | sed 's/^/MAX\t/'
  pq "sum(increase(${ACT}{$FRONTEND}[${DAYS}d])) by ($NSLABEL)"             | sed 's/^/ACT\t/'
  pq "sum(increase(${SR}{$NEWX_OP}[${DAYS}d])) by ($NSLABEL)"    | sed 's/^/NEWX\t/'
  pq "sum(increase(${SR}{$SWS_OP}[${DAYS}d])) by ($NSLABEL)"     | sed 's/^/SWS\t/'

  # peak shape: one range query per namespace, bucketed by hour-of-day
  for NS in $(pq "sum(rate(${SR}{$LOAD_OP}[5m])) by ($NSLABEL)" | awk '{print $1}' | sort -u); do
    [ "$NS" = "_none_" ] && continue
    skip_ns "$NS" && continue
    SERIES="$(curl -sG \
        --data-urlencode "query=sum(rate(${SR}{$LOAD_OP,$NSLABEL=\"$NS\"}[5m]))" \
        --data-urlencode "start=$start" --data-urlencode "end=$now" \
        --data-urlencode "step=$STEP" \
        "$PROM/api/v1/query_range" \
      | jq -r '.data.result[0].values[]? | "\(.[0]) \(.[1])"')"
    [ -z "$SERIES" ] && { printf 'PEAK\t%s\tNO DATA\t-\n' "$NS"; continue; }
    printf '%s\n' "$SERIES" | awk -v ns="$NS" '
      { h=int(($1%86400)/3600); d=int($1/86400); v=$2+0
        if (v>mx[h]) mx[h]=v
        hd[h "_" d] = (v>hd[h "_" d] ? v : hd[h "_" d])
        if (v>0 && !dt[d]) { dt[d]=1; nd++ } }
      END {
        g=0; for (h=0;h<24;h++) if (mx[h]>g) g=mx[h]
        if (g<=0) { printf "PEAK\t%s\tFLAT / NO TRAFFIC\t-\n", ns; exit }
        npk=0; for (h=0;h<24;h++) if (mx[h]>=0.7*g) { pk[h]=1; npk++ }
        out=""
        if (npk==24) out="all hours (flat load)"
        else for (h=0;h<24;h++) if (pk[h] && !pk[(h+23)%24]) {
          e=h; while (pk[(e+1)%24] && ((e+1)%24)!=h) e=(e+1)%24
          out = out (out==""?"":", ") sprintf("%02d:00-%02d:00", h, (e+1)%24) }
        # how many days actually REACHED peak magnitude? testing merely for
        # "traffic present" lets a nonzero baseline make a one-off look daily
        npd=0
        for (k in hd) { split(k,p,"_"); if (hd[k] >= 0.7*g && !seen[p[2]]) { seen[p[2]]=1; npd++ } }
        conf = (npd<=1) ? "SINGLE-DAY ARTIFACT - not a recurring window" \
             : (npd<=3) ? sprintf("weak - only %d days support it", npd) : "ok"
        if (npk==24) conf="flat load - no window to avoid"
        printf "PEAK\t%s\t%s\t%s\n", ns, out, conf
      }'
  done
} | awk -F'\t' -v cid="$CLUSTER_ID" -v rd="$RUN_TS" -v days="$DAYS" -v mincov="$MIN_COVERAGE" \
        -v skip="$SKIP_NS" '
  BEGIN {
    n=split(skip,a," "); for(i=1;i<=n;i++){ gsub(/-/,"_",a[i]); sk[a[i]]=1 }
    OFS="\t"
    print "row_key","cluster_id","run_ts_utc","namespace",
          "metrics_effective_window_days","coverage_pct",
          "p50_sustained","p95_peak","absolute_max",
          "peak_hours_utc","peak_confidence",
          "actions_in_window","actions_per_day",
          "new_executions","signal_with_start","actions_per_execution"
  }
  function keep(ns) { k=ns; gsub(/-/,"_",k); return !(k in sk) && ns != "_none_" && ns != "" }
  $1=="WIN"  { if (keep($2)) { seen[$2]=1; eff[$2]=$3; cov[$2]=$4 } ; next }
  $1=="AWIN" { if (keep($2)) { seen[$2]=1; aeff[$2]=$3 } ; next }
  $1=="P50"  { if (keep($2)) { seen[$2]=1; p50[$2]=$3 } ; next }
  $1=="P95"  { if (keep($2)) { seen[$2]=1; p95[$2]=$3 } ; next }
  $1=="MAX"  { if (keep($2)) { seen[$2]=1; mx[$2]=$3 } ; next }
  $1=="ACT"  { if (keep($2)) { seen[$2]=1; act[$2]=$3 } ; next }
  $1=="NEWX" { if (keep($2)) { seen[$2]=1; nx[$2]=$3 } ; next }
  $1=="SWS"  { if (keep($2)) { seen[$2]=1; sws[$2]=$3 } ; next }
  $1=="PEAK" { if (keep($2)) { seen[$2]=1; ph[$2]=$3; pc[$2]=$4 } ; next }
  END {
    for (ns in seen) {
      cv = cov[ns]+0; ef = eff[ns]+0; ae = aeff[ns]+0
      av = act[ns]+0; x = nx[ns]+0; w = sws[ns]+0

      # Below the coverage floor a quantile of a mostly-absent series is
      # degenerate. Blank is honest; 0.0000 reads as "this namespace is idle".
      if (cv < mincov) { s50=""; s95="" }
      else { s50=sprintf("%.4f",p50[ns]+0); s95=sprintf("%.4f",p95[ns]+0) }

      # Extrapolating a fixed burst over a shrinking window inflates the daily
      # rate on every re-run, so refuse rather than emit a moving number.
      # One value cannot mean both "measured zero" and "declined to extrapolate".
      # Blank is the second; a number is always a measurement, 0 included.
      suppressed = 0
      if (ae >= days*0.95)      { perday = (ae>0 ? av/ae : 0) }
      else if (cv < mincov)     { perday = 0; suppressed = 1 }
      else                      { perday = (ae>0.04 ? av/ae : 0) }

      apx = (x > 0 ? sprintf("%.2f", av/x) : (av > 0 ? "NO NEW EXECUTIONS - check CAN" : ""))

      print ns"", cid, rd, ns,
            (ef>0?sprintf("%.1f",ef):""), (cv>0?sprintf("%.0f",cv):"0"),
            s50, s95, sprintf("%.4f", mx[ns]+0),
            (ns in ph ? ph[ns] : ""), (ns in pc ? pc[ns] : ""),
            sprintf("%.0f", av), (suppressed ? "" : sprintf("%.1f", perday)),
            sprintf("%.0f", x), sprintf("%.0f", w), apx
    }
  }' | awk -F'\t' -v cid="$CLUSTER_ID" 'NR==1{print;next}{ $1=cid"/"$1; print }' OFS='\t' \
     | { IFS= read -r _hdr; printf '%s\n' "$_hdr"; sort -t"$(printf '\t')" -k1,1; }

cat >&2 <<MSG

Feed this TSV into your Cloud migration sizing / prerequisite review.

  p50, p95 and actions_per_day are BLANK below ${MIN_COVERAGE}% window coverage.
  Blank means "not computed"; a number is always a measurement, and 0 means
  genuinely zero. coverage_pct says why a cell is blank. Emitting 0 for a
  suppressed rate would be indistinguishable from a namespace with no traffic.

  new_executions counts StartWorkflowExecution only. Compare it against
  visible_executions from script A - but ONLY when this run's effective window is
  at least as long as that namespace's retention_days. Script A reports what
  visibility currently holds; this script reports flow over a lookback. If the
  lookback is shorter, a gap is arithmetic, not a finding. When the windows do
  line up, a large gap means
  retries, failed starts, or workflow-ID reuse, and it makes actions_per_execution
  understate by that factor.

  peak_confidence carries the artifact flag. A window is only a real pattern if
  several distinct days reached peak magnitude.

  WINDOW_DAYS applies to this script only. Script A has no time window.
MSG
