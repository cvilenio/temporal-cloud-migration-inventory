#!/usr/bin/env bash
# ===========================================================================
# Self-hosted Temporal -> Temporal Cloud migration inventory
# SCRIPT A  -  everything that comes from the Temporal CLI
#
# ENDPOINT: your self-hosted Temporal frontend(s).
# PAIRS WITH: B-promql-inventory.sh, which talks to Prometheus.
#
# USAGE
#   Many clusters:   ./A-cli-inventory.sh --clusters clusters.conf --out ./out
#   One cluster:     CLUSTER_ID=my-cluster TEMPORAL_ADDRESS=host:7233 \
#                      ./A-cli-inventory.sh --out ./out
#
#   clusters.conf is two tab-separated columns, '#' starts a comment:
#       CLUSTER_ID <tab> TEMPORAL_ENV
#   TEMPORAL_ENV is a profile from `temporal env list`, so each cluster can
#   authenticate however it likes without this script knowing.
#
# WRITES (append, so partial runs accumulate)
#   $OUT/clusters.tsv     -> paste into the Raw_CLI_Clusters tab, at cell A2
#   $OUT/namespaces.tsv   -> paste into the Raw_CLI_Namespaces tab, at cell A2
#
# SCALE
#   --resume              skip namespaces already in namespaces.tsv. Makes the
#                         run interruptible: kill it and start it again, split
#                         it by cluster or by day, no bookkeeping either way.
#                         Omit it to refresh everything.
#   --parallel N          namespaces at a time, default 1. Cuts wall clock
#                         roughly linearly and raises peak visibility load by
#                         the same factor. Safe on Elasticsearch; think first
#                         on standard SQL visibility.
#   --skip-oldest-open    drop the one expensive call, at the cost of the
#                         oldest_open_execution_days column.
#
#   The script reports which visibility store it found and, in sequential mode,
#   extrapolates the remaining time for each cluster from the first namespace.
#
# 6 CLI calls per namespace. No Event History exports and no per-execution
# describes: `workflow list --output json` already carries historySizeBytes,
# historyLength, startTime and closeTime, so sampling N executions costs one
# call rather than N+1.
#
# COMPATIBILITY: bash 3.2 (stock macOS /bin/bash). Requires: temporal CLI, jq.
# ===========================================================================
set -uo pipefail
SCRIPT_VERSION="${SCRIPT_VERSION:-v0.1.0}"

CLUSTERS_FILE=""
OUT="./out"
RESUME=0
PARALLEL="${PARALLEL:-1}"
SKIP_OLDEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --clusters) CLUSTERS_FILE="${2:?--clusters needs a file}"; shift 2 ;;
    --out)      OUT="${2:?--out needs a directory}"; shift 2 ;;
    --resume)   RESUME=1; shift ;;
    --parallel) PARALLEL="${2:?--parallel needs a number}"; shift 2 ;;
    --skip-oldest-open) SKIP_OLDEST=1; shift ;;
    -h|--help)  sed -n '2,44p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$PARALLEL" in ''|*[!0-9]*) echo "--parallel needs a number" >&2; exit 2 ;; esac
[ "$PARALLEL" -lt 1 ] && PARALLEL=1

WINDOW_DAYS="${WINDOW_DAYS:-30}"      # keep identical to script B
SAMPLE="${SAMPLE:-200}"               # closed executions sampled per namespace
SKIP_NAMESPACES="${SKIP_NAMESPACES:-temporal-system}"
# Full timestamp, not a date: both scripts run on the same day, so day
# granularity cannot show that they were hours apart. Space separator and no
# trailing Z because that is what Google Sheets parses as a datetime.
RUN_TS="$(date -u +"%Y-%m-%d %H:%M:%S")"

mkdir -p "$OUT"
CL_OUT="$OUT/clusters.tsv"
NS_OUT="$OUT/namespaces.tsv"

# Headers only when the file is new, so repeated runs append cleanly.
[ -s "$CL_OUT" ] || printf 'cluster_id\trun_ts_utc\tcluster_name_configured\tserver_version\n' > "$CL_OUT"
[ -s "$NS_OUT" ] || printf 'row_key\tcluster_id\trun_ts_utc\tnamespace\treplication_role\treplicated_to\tretention_days\tavg_duration_to_closed_sec\toldest_open_execution_days\thistory_bytes_gb\tmax_history_kb\tmax_history_events\tavg_history_kb\tn_workflow_types\tschedules\tvisible_executions\tstatus_mix\tcustom_sa_count\tcustom_sa_by_type\tsa_limit_check\tsample_basis\n' > "$NS_OUT"

# Resume works off the row keys already in the output file, so it needs no
# state of its own and survives a kill at any point.
KEYFILE="$(mktemp)"
trap 'rm -f "$KEYFILE"' EXIT
if [ "$RESUME" = 1 ]; then
  awk -F'\t' 'NR>1 && $1!="" {print $1}' "$NS_OUT" > "$KEYFILE" 2>/dev/null || true
  echo "resume: $(grep -c . "$KEYFILE" 2>/dev/null || echo 0) namespace(s) already collected" >&2
fi

CONN_ARGS=()          # rebuilt per cluster: either --env X or --address + TLS
t() { temporal ${CONN_ARGS[@]+"${CONN_ARGS[@]}"} "$@"; }
# One count call per namespace, not six. `GROUP BY ExecutionStatus` returns the
# total plus a per-status breakdown in a single CountWorkflowExecutions RPC.
# This matters at scale: on standard SQL visibility each count is a COUNT(*)
# over executions_visibility competing with production visibility queries.
cnt_grouped() {
  t workflow count --namespace "$1" --query 'GROUP BY ExecutionStatus' \
     --output json 2>/dev/null || echo '{}'
}

# Millisecond clock that works on both GNU and BSD userland. BSD date has no
# %N, and returns the literal string, so the result is validated rather than
# assumed. Falls back to perl, then to whole seconds.
MS_MODE=""
now_ms() {
  if [ -z "$MS_MODE" ]; then
    _probe="$(date -u +%s%N 2>/dev/null)"
    case "$_probe" in
      *[!0-9]*|'') MS_MODE=perl ;;
      *) [ "${#_probe}" -ge 16 ] && MS_MODE=date || MS_MODE=perl ;;
    esac
    if [ "$MS_MODE" = perl ] && ! command -v perl >/dev/null 2>&1; then MS_MODE=sec; fi
  fi
  case "$MS_MODE" in
    date) echo $(( $(date -u +%s%N) / 1000000 )) ;;
    perl) perl -MTime::HiRes=time -e 'printf "%.0f\n", time()*1000' ;;
    *)    echo $(( $(date -u +%s) * 1000 )) ;;
  esac
}

# Which visibility store is behind this cluster, from one RPC. Standard SQL
# visibility rejects ORDER BY outright; Elasticsearch accepts it. The answer
# changes the cost of everything else this script does, because on SQL each
# count is a COUNT(*) over executions_visibility, shared with production.
probe_visibility() {
  _err="$(t workflow list --namespace "$1" --query 'ORDER BY StartTime ASC' \
            --limit 1 2>&1 >/dev/null)"
  case "$_err" in
    *"'ORDER BY' clause"*|*"not supported"*) echo standard ;;
    '')                                      echo elasticsearch ;;
    *)                                       echo unknown ;;
  esac
}

JQ_ROWS='
  (if type=="array" then .[] else .executions[]? end)
  | [ (.type.name // "?"),
      ((.historySizeBytes // 0) | tonumber),
      ((.historyLength    // 0) | tonumber),
      (if (.closeTime != null and .startTime != null)
       then ((.closeTime | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601)
           - (.startTime | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601))
       else -1 end) ] | @tsv
'
JQ_OPEN_START='
  (if type=="array" then .[] else .executions[]? end)
  | select(.startTime != null)
  | (.startTime | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601)
'

# ---------------------------------------------------------------------------
# One namespace, one output file. Writing per-namespace files rather than
# appending to a shared one is what makes --parallel safe: concurrent appends
# from separate processes interleave and corrupt rows.
do_namespace() {
  CLUSTER_ID="$1"; NS="$2"; THIS_CLUSTER="$3"; OUTF="$4"
    D="$(t operator namespace describe --namespace "$NS" --output json 2>/dev/null || echo '{}')"
    IS_GLOBAL="$(jq -r '.isGlobalNamespace // .namespaceInfo.isGlobalNamespace // false' <<<"$D")"
    ACTIVE="$(jq -r '.replicationConfig.activeClusterName // ""' <<<"$D")"
    CLUSTERS="$(jq -r '[.replicationConfig.clusters[]?.clusterName] | join(";")' <<<"$D")"
    RET="$(jq -r '.config.workflowExecutionRetentionTtl // ""' <<<"$D" | sed 's/s$//' \
          | awk '{ if ($1 ~ /^[0-9]+$/) printf "%d", $1/86400 }')"

    NC="$(awk -F';' '{print NF}' <<<"${CLUSTERS:-}")"
    if   [ "$IS_GLOBAL" != "true" ];            then ROLE="Local"
    elif [ -z "$CLUSTERS" ] || [ "$NC" -le 1 ]; then ROLE="Global - single cluster"
    elif [ "$ACTIVE" = "$THIS_CLUSTER" ];       then ROLE="Global - active on this cluster"
    else                                             ROLE="Global - standby on this cluster"; fi
    REPL_TO="$(tr ';' '\n' <<<"$CLUSTERS" | grep -vxF "$THIS_CLUSTER" | paste -sd';' -)"

    CNTJ="$(cnt_grouped "$NS")"
    VISIBLE="$(jq -r '.count // 0 | tonumber? // 0' <<<"$CNTJ")"
    # A status absent from the groups means zero executions in that state.
    eval "$(jq -r '
        ( [ .groups[]? | { k: (.groupValues[0] // ""), v: (.count // "0") } ] ) as $g
        | ( ["Running","Completed","Failed","Terminated","TimedOut"]
            | map(. as $s
                  | ($g | map(select(.k==$s)) | .[0].v // "0") as $v
                  | "ST_" + $s + "=" + $v) )
        | join("\n")' <<<"$CNTJ" 2>/dev/null)"
    RUNNING="${ST_Running:-0}"
    STATUS_MIX="run:${ST_Running:-0};done:${ST_Completed:-0};fail:${ST_Failed:-0}"
    STATUS_MIX="$STATUS_MIX;term:${ST_Terminated:-0};timeout:${ST_TimedOut:-0}"

    SAJ="$(t operator search-attribute list --namespace "$NS" --output json 2>/dev/null || echo '{}')"
    SA_BY_TYPE="$(jq -r '
        (.customAttributes // .customSearchAttributes // {})
        | to_entries
        | map(.value | sub("^INDEXED_VALUE_TYPE_";"")
                     | ascii_downcase
                     | if . == "keyword_list" then "KeywordList"
                       elif . == "datetime"   then "Datetime"
                       else (.[0:1] | ascii_upcase) + .[1:] end)
        | group_by(.) | map("\(.[0]):\(length)") | join(";")' <<<"$SAJ" 2>/dev/null)"
    SA_COUNT="$(jq -r '(.customAttributes // .customSearchAttributes // {}) | length' <<<"$SAJ" 2>/dev/null)"
    SA_COUNT="${SA_COUNT:-0}"
    SA_FLAG="$(awk -v s="$SA_BY_TYPE" 'BEGIN{
        n=split(s,a,";"); out=""
        for(i=1;i<=n;i++){ if(a[i]=="") continue
          split(a[i],kv,":"); k=kv[1]; v=kv[2]+0
          lim = (k=="Keyword") ? 40 : (k=="Text" || k=="KeywordList") ? 5 : 20
          if (v > lim) out = out (out==""?"":",") k " " v "/" lim }
        print (out=="" ? "ok" : "OVER LIMIT: " out) }')"

    SCHED="$(t schedule list --namespace "$NS" --output json 2>/dev/null \
             | jq -r 'if type=="array" then length else (.schedules // [] | length) end' 2>/dev/null)"
    SCHED="${SCHED:-0}"

    ROWS="$(t workflow list --namespace "$NS" --limit "$SAMPLE" --output json 2>/dev/null \
            | jq -r "$JQ_ROWS" 2>/dev/null)"

    # The most expensive call here: pages up to 1000 open executions because
    # visibility will not sort, so the oldest can only be found by reading them
    # all. --skip-oldest-open drops it and costs exactly one column.
    if [ "$SKIP_OLDEST" = 1 ]; then
      OLDEST=""
    else
      OLDEST="$(t workflow list --namespace "$NS" --limit 1000 \
                  --query 'ExecutionStatus="Running"' --output json 2>/dev/null \
                | jq -r "$JQ_OPEN_START" 2>/dev/null | sort -n | head -1)"
    fi
    NOW=$(date +%s)
    if [ "$SKIP_OLDEST" = 1 ]; then
      AGE_D="SKIPPED (--skip-oldest-open)"
    elif [ -n "$OLDEST" ]; then
      AGE_D="$(awk -v n="$NOW" -v o="$OLDEST" 'BEGIN{printf "%.2f",(n-o)/86400}')"
    elif [ "$RUNNING" -gt 0 ]; then
      AGE_D="UNKNOWN ($RUNNING running but list returned none)"
    else
      AGE_D="0"
    fi

    printf '%s/%s\t%s\t%s\t%s\t%s\t%s\t%s\t' \
      "$CLUSTER_ID" "$NS" "$CLUSTER_ID" "$RUN_TS" "$NS" "$ROLE" "$REPL_TO" "${RET:-}" >> "$OUTF"

    printf '%s\n' "$ROWS" | awk -F'\t' -v vis="$VISIBLE" -v age="$AGE_D" \
        -v sched="$SCHED" -v sac="$SA_COUNT" -v sabt="$SA_BY_TYPE" -v saf="$SA_FLAG" \
        -v mix="$STATUS_MIX" '
      NF >= 4 {
        n++
        if ($2+0 > maxb) maxb = $2+0
        if ($3+0 > maxe) maxe = $3+0
        sumb += $2+0
        if ($4+0 >= 0) { dn++; dsum += $4+0 }
        if (!seen[$1]++) types++
      }
      END {
        if (n == 0) {
          # Five tabs, not four: fields 10-13 (gb, max_kb, max_events, avg_kb)
          # are all blank here, and one short shifts every later column left.
          printf "\t%s\t\t\t\t\t0\t%s\t%d\t%s\t%s\t%s\t%s\tno executions in window\n",
                 age, sched, vis, mix, sac, sabt, saf
          exit
        }
        avgb = sumb / n
        gb   = (vis * avgb) / 1073741824
        # A sample that covered every visible execution is not a sample: the
        # maxima are the real ceilings and need no caveat.
        basis = (n >= vis ? sprintf("%d of %d - FULL POPULATION, maxima exact", n, vis) \
                          : sprintf("%d of %d sampled - maxima are lower bounds", n, vis))
        printf "%s\t%s\t%.5f\t%.1f\t%d\t%.1f\t%d\t%s\t%d\t%s\t%s\t%s\t%s\t%s\n",
               (dn ? sprintf("%.1f", dsum/dn) : ""), age,
               gb, maxb/1024, maxe, avgb/1024, types, sched, vis, mix, sac, sabt, saf, basis
      }' >> "$OUTF"
}

# ---------------------------------------------------------------------------
do_cluster() {
  CLUSTER_ID="$1"

  CJ="$(t operator cluster describe --output json 2>/dev/null || echo '{}')"
  THIS_CLUSTER="$(jq -r '.clusterName // .ClusterName // "UNKNOWN"' <<<"$CJ")"
  SERVER_VERSION="$(jq -r '.serverVersion // .ServerVersion // "UNKNOWN"' <<<"$CJ")"
  printf '%s\t%s\t%s\t%s\n' "$CLUSTER_ID" "$RUN_TS" "$THIS_CLUSTER" "$SERVER_VERSION" >> "$CL_OUT"

  if [ "$THIS_CLUSTER" = UNKNOWN ]; then
    echo "  WARN [$CLUSTER_ID] cluster describe returned nothing - connection may be failing." >&2
    echo "       Replication role cannot be computed without the cluster's own name." >&2
  fi

  NS_LIST=()
  if [ -n "${NAMESPACES:-}" ]; then
    for _n in $NAMESPACES; do NS_LIST+=("$_n"); done
  else
    while IFS= read -r _n; do
      [ -z "$_n" ] && continue
      case " $SKIP_NAMESPACES " in *" $_n "*) continue ;; esac
      NS_LIST+=("$_n")
    done <<EOF
$(t operator namespace list --output json 2>/dev/null \
  | jq -r '.[]?.namespaceInfo.name // .namespaceInfo.name // empty' | sort -u)
EOF
  fi

  if [ "${#NS_LIST[@]}" -eq 0 ]; then
    cat >&2 <<MSG
  ERROR [$CLUSTER_ID] no namespaces found - skipping this cluster.
        Check the connection: temporal ${CONN_ARGS[*]:-} operator namespace list
          * TLS error  -> the frontend wants mTLS; add tls-* keys to the env profile
          * conn error -> port-forward the frontend (7233) or internal-frontend (7236)
          * to bypass discovery: NAMESPACES="ns1 ns2" $0 ...
MSG
    return 1
  fi

  VIS_KIND="$(probe_visibility "${NS_LIST[0]}")"
  echo "  [$CLUSTER_ID] ${#NS_LIST[@]} namespace(s), visibility=$VIS_KIND" >&2
  if [ "$VIS_KIND" = standard ]; then
    cat >&2 <<'MSG'
    Standard SQL visibility. Every count is a COUNT(*) over
    executions_visibility on the database that also serves production
    visibility queries, so cost scales with table size, not namespace count.
    Prefer off-peak, and leave --parallel at 1 unless you know the headroom.
MSG
  fi

  IDX=0; RAN=0; SKIPPED=0; NSTMP="$(mktemp -d)"
  FIRST_MS=""
  for NS in ${NS_LIST[@]+"${NS_LIST[@]}"}; do
    IDX=$((IDX+1))
    if [ "$RESUME" = 1 ] && grep -qxF "$CLUSTER_ID/$NS" "$KEYFILE" 2>/dev/null; then
      SKIPPED=$((SKIPPED+1)); continue
    fi
    OUTF="$NSTMP/$(printf '%05d' "$IDX")"
    if [ "$PARALLEL" -le 1 ]; then
      _s="$(now_ms)"
      do_namespace "$CLUSTER_ID" "$NS" "$THIS_CLUSTER" "$OUTF"
      _e="$(now_ms)"; _d=$((_e-_s))
      RAN=$((RAN+1))
      echo "    ($IDX/${#NS_LIST[@]}) $NS  ${_d}ms" >&2
      # Extrapolate from the first real namespace, so a long run announces its
      # own cost while there is still time to stop it.
      if [ -z "$FIRST_MS" ]; then
        FIRST_MS="$_d"
        REMAIN=$(( ${#NS_LIST[@]} - IDX ))
        if [ "$REMAIN" -gt 0 ]; then
          echo "    estimate: ${REMAIN} more x ${_d}ms = $(( REMAIN * _d / 1000 ))s for this cluster" >&2
        fi
      fi
    else
      do_namespace "$CLUSTER_ID" "$NS" "$THIS_CLUSTER" "$OUTF" &
      RAN=$((RAN+1))
      if [ $((RAN % PARALLEL)) -eq 0 ]; then
        wait
        echo "    $RAN/${#NS_LIST[@]} done" >&2
      fi
    fi
  done
  wait
  [ "$PARALLEL" -gt 1 ] && echo "    $RAN/${#NS_LIST[@]} done" >&2
  cat "$NSTMP"/* >> "$NS_OUT" 2>/dev/null || true
  rm -rf "$NSTMP"
  [ "$SKIPPED" -gt 0 ] && echo "    resumed: skipped $SKIPPED already in $NS_OUT" >&2
  return 0
}

# ---------------------------------------------------------------------------
echo "script=A-cli-inventory.sh version=$SCRIPT_VERSION" >&2
echo "run_ts=$RUN_TS UTC  window=${WINDOW_DAYS}d  sample=$SAMPLE" >&2

if [ -n "$CLUSTERS_FILE" ]; then
  [ -r "$CLUSTERS_FILE" ] || { echo "cannot read $CLUSTERS_FILE" >&2; exit 2; }
  while IFS=$'\t' read -r CID CENV _rest; do
    case "${CID:-}" in ''|\#*) continue ;; esac
    CENV="$(printf '%s' "${CENV:-}" | tr -d ' \r')"
    [ -z "$CENV" ] && { echo "  skip [$CID] no TEMPORAL_ENV in clusters.conf" >&2; continue; }
    CONN_ARGS=(--env "$CENV")
    do_cluster "$CID" || true
  done < "$CLUSTERS_FILE"
else
  CID="${CLUSTER_ID:?set CLUSTER_ID, or pass --clusters clusters.conf}"
  CONN_ARGS=()
  [ -n "${TEMPORAL_ADDRESS:-}" ]  && CONN_ARGS+=(--address "$TEMPORAL_ADDRESS")
  [ -n "${TEMPORAL_TLS_CERT:-}" ] && CONN_ARGS+=(--tls-cert-path "$TEMPORAL_TLS_CERT")
  [ -n "${TEMPORAL_TLS_KEY:-}" ]  && CONN_ARGS+=(--tls-key-path  "$TEMPORAL_TLS_KEY")
  [ -n "${TEMPORAL_TLS_CA:-}" ]   && CONN_ARGS+=(--tls-ca-path   "$TEMPORAL_TLS_CA")
  do_cluster "$CID" || true
fi

# --- the collision that decides whether script B needs a cluster label ------
DUPES="$(awk -F'\t' 'NR>1 && $4!="" {print $4}' "$NS_OUT" | sort | uniq -d)"
{
  echo
  echo "wrote $CL_OUT and $NS_OUT"
  echo "  Paste each into its Raw_ tab: select rows 2-2000, delete, click A2, paste."
  echo
  if [ -n "$DUPES" ]; then
    echo "DUPLICATE NAMESPACE NAMES ACROSS CLUSTERS:"
    printf '%s\n' "$DUPES" | sed 's/^/    /'
    echo "  Two consequences. Script B needs CLUSTER_LABEL and CLUSTER_VALUE, because"
    echo "  Prometheus cannot tell these apart and would merge their metrics. And a"
    echo "  Cloud namespace name is unique per account, so all but one need renaming."
  elif [ "$(awk -F"\t" 'NR>1' "$NS_OUT" | grep -c .)" -eq 0 ]; then
    echo "No namespace rows collected, so the duplicate-name check proved nothing."
    echo "Fix the connection and re-run before relying on it."
  else
    echo "No duplicate namespace names across clusters - script B can query by"
    echo "namespace alone, and no Cloud renames are forced by collisions."
  fi
  echo
  echo "sample_basis says whether the maxima are exact. FULL POPULATION means the"
  echo "sample covered every visible execution, so no caveat applies; otherwise they"
  echo "are lower bounds and SAMPLE (now $SAMPLE) is what raises them."
  echo
  echo "schedules are NOT replicated by S2S. A non-zero count is a work item: every"
  echo "schedule is recreated on the target, and the timing decides between"
  echo "double-firing and missed runs."
  echo
  echo "custom_sa_by_type matters more than the count. Cloud limits per type -"
  echo "Keyword 40, Text 5, KeywordList 5, others 20 - so 8 Text fails while a"
  echo "count of 8 looks harmless. sa_limit_check does that comparison."
  echo
  echo "Keep WINDOW_DAYS identical between this script and script B."
} >&2
