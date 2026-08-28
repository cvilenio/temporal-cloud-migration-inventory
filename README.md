# Temporal Cloud migration inventory scripts

Three read-only scripts that inventory a self-hosted Temporal estate ahead of a migration to Temporal Cloud. They collect the volume, limit and configuration data needed to size namespaces on Cloud and to check migration prerequisites.

They exist because that data is spread across the Temporal CLI and a Prometheus-compatible metrics store, and collecting it by hand across a large estate is slow and inconsistent.

## What each script does

| Script | Reads | Produces |
| :- | :- | :- |
| `scripts/preflight.sh` | Temporal CLI, connectivity only | terminal output |
| `scripts/A-cli-inventory.sh` | Temporal CLI, every cluster in `clusters.conf` | `clusters.tsv`, `namespaces.tsv` |
| `scripts/B-promql-inventory.sh` | Prometheus HTTP API, one cluster per run | `promql.tsv` |

The TSV files feed the sizing and prerequisite checks in a Cloud migration. They are ordinary tab-separated files, so any downstream review process can consume them.

If you were pointed here by a migration inventory spreadsheet and its instructions document, those explain what to do with the output. This README covers the scripts themselves.

## They are read-only

Script A issues describe, count and list calls. Script B issues only HTTP GETs, against `/api/v1/query`, `/api/v1/query_range`, `/api/v1/series` and `/api/v1/status/flags`. Neither writes to a cluster, a namespace, or a metrics store.

Nothing is transmitted anywhere. All three write to local files or to your terminal.

Script A reads execution **metadata** only. `workflow list --output json` already carries `historySizeBytes`, `historyLength`, `startTime` and `closeTime`, so history size statistics are derived from that listing rather than by fetching event histories. No Event History is exported and no payload is read.

## Requirements

- `temporal` CLI, `curl`, `jq`, `awk`
- bash 3.2 or later, so stock macOS `/bin/bash` works
- Network reach to the Temporal frontend of each cluster in scope
- A Prometheus-compatible HTTP endpoint holding Temporal **server** metrics, for script B

## Quick start

Define one Temporal CLI connection profile per cluster. The scripts never handle credentials themselves; they delegate to the CLI, so each cluster can authenticate differently without any change here.

```
temporal env set --env prod-us-east --key address       --value temporal-fe.us-east.internal:7233
temporal env set --env prod-us-east --key tls-cert-path --value /secrets/us-east/client.pem
temporal env set --env prod-us-east --key tls-key-path  --value /secrets/us-east/client.key
temporal env set --env prod-us-east --key tls-ca-path   --value /secrets/us-east/ca.pem
```

Add `tls-server-name` whenever the address you connect to is not a name in the server certificate. Any port-forward, IP literal, or load-balancer hostname needs it, and the handshake fails without it. Set it to a name that appears on the certificate (often the same DNS name you would have used as `address` without the port-forward).

```
temporal env set --env prod-us-east --key tls-server-name --value <name-on-server-cert>
```

Map each cluster to a stable ID by copying `clusters.conf.example`. Columns are separated by a real tab. The ID becomes the join key in the output, so pick something durable.

Then:

```
./scripts/preflight.sh clusters.conf
./scripts/A-cli-inventory.sh --clusters clusters.conf --out ./out
PROM_URL=http://prometheus.internal:9090 CLUSTER_ID=prod-us-east-1 ./scripts/B-promql-inventory.sh > out/promql.tsv 2> out/promql-notes.txt
```

## Options

Script A takes flags:

| Flag | Effect | Cost |
| :- | :- | :- |
| `--clusters FILE` | Cluster list to walk. Scope of a run is whatever is in this file. | |
| `--out DIR` | Output directory. Defaults to `./out`. | |
| `--resume` | Skips namespaces whose row key is already in `namespaces.tsv`. | Saves the work, so already-collected rows keep their original data. Omit it to refresh. |
| `--parallel N` | N namespaces at a time, default 1. Wall clock falls roughly linearly. | Peak visibility load rises by the same factor. Suppresses the runtime estimate and switches progress to a running count. |
| `--skip-oldest-open` | Drops the most expensive call, which pages up to 1000 open executions. | The `oldest_open_execution_days` column is still emitted, carrying a `SKIPPED` marker instead of a number. |

Both scripts take environment variables:

| Variable | Applies to | Meaning |
| :- | :- | :- |
| `WINDOW_DAYS` (alias `DAYS`) | B | Metrics lookback in days, default 30. Script A has no time window, so there is nothing to keep in sync. |
| `SAMPLE` | A | Executions sampled per namespace for history statistics, default 200. No status filter, so open executions are included and their partial histories pull the mean down. |
| `NAMESPACES` | A | Space-separated list. Skips discovery, applies to every cluster in the run, and bypasses the `SKIP_NAMESPACES` exclusion. Do not repeat a name. |
| `SKIP_NAMESPACES` | A | Namespaces to exclude during discovery, default `temporal-system`. Setting it empty does not clear it; pass a name that matches nothing. |
| `CLUSTER_ID`, `TEMPORAL_ADDRESS` | A | Single-cluster mode, used instead of `--clusters`. |
| `TEMPORAL_TLS_CERT`, `TEMPORAL_TLS_KEY`, `TEMPORAL_TLS_CA` | A | TLS paths for single-cluster mode. This mode cannot express `tls-server-name`, `api-key`, `client-authority` or `codec-endpoint`, so use a profile when you need any of those. |
| `PARALLEL` | A | Same as `--parallel`. |
| `PROM_URL` | B | Prometheus HTTP API base URL. Required. |
| `CLUSTER_ID` | B | **Required.** Stamped on every row and used as the first half of the row key. Without it every row is keyed `UNKNOWN/<namespace>` and joins to nothing. |
| `CLUSTER_LABEL`, `CLUSTER_VALUE` | B | Disambiguate a namespace name that exists on more than one cluster. |
| `PROM_JOB` | B | Pin a scrape job when several duplicate the same targets. Ignored when only one job exists. |
| `SKIP_NS` | B | Namespaces to exclude, default `temporal-system temporal_system`. |
| `MIN_COVERAGE` | B | Coverage floor below which rate columns are suppressed, default 20. |
| `STEP` | B | Step for the peak-shape range query, in seconds, default 300. The window and coverage queries are fixed at hourly resolution. |
| `OPEN_PAGE` | A | Open executions paged for the oldest-open column, default 1000. |

## Cost of a run

Script A makes 6 CLI calls per namespace, sequentially, or 5 with `--skip-oldest-open`, plus 3 to 5 per cluster: the cluster describe, the namespace list, and a visibility probe that retries on up to three namespaces. Each call is a separate `temporal` process, so round-trip time to the frontend dominates.

After its first namespace the script extrapolates and prints an estimate for the rest of the cluster. It has nothing to extrapolate from on a single-namespace cluster, and it does not print an estimate under `--parallel`, so trial on a cluster with several namespaces if you want the number.

Frontend load is not a concern at these rates. The visibility store is the constraint that matters, and it depends which one you run. Script A prints which store it found.

With Elasticsearch visibility, counts and lists are cheap aggregations. With standard SQL visibility, every count is a `COUNT(*)` over `executions_visibility` on the database that also serves production visibility queries, so cost scales with table size rather than namespace count. Prefer off-peak and leave `--parallel` at 1 until you know your database headroom.

## Running in batches

There is no batch flag. The scope of a run is whatever is in the file you point `--clusters` at, so keep several conf files and run each when it suits you:

```
./scripts/A-cli-inventory.sh --clusters wave1.conf --out ./out
./scripts/A-cli-inventory.sh --clusters wave2.conf --out ./out --resume
```

Output files accumulate across runs, and headers are written only when a file is new. Every namespace row is keyed on cluster ID plus namespace name, and every cluster row on cluster ID, so runs against different conf files build up in the same TSVs.

Rows merge by key rather than being blindly appended. Collecting a namespace again replaces its previous row, so the file holds exactly one current row per key no matter how many runs produced it. A re-run is a genuine refresh, and a full file replace is always a coherent snapshot.

`--resume` tracks progress rather than scope. It builds its skip list from the row keys already in `namespaces.tsv`, so it covers everything collected so far, not just the conf file being run. Use it to continue an interrupted run; omit it to re-collect and refresh.

## Reading the output

`sample_basis` says whether the history maxima are exact. `FULL POPULATION` means the sample covered every visible execution.

`oldest_open_execution_days` pages up to `OPEN_PAGE` (default 1000) running executions. Above that it reports `AT LEAST <days>` together with the running count, because the true oldest cannot be found without reading them all and standard SQL visibility will not sort.

A blank cell is not a zero. A number is always a measurement, a blank means not computed, and zero means genuinely zero. Script B suppresses rate columns below the coverage floor rather than reporting a misleading zero; `coverage_pct` says why. Script A uses text markers for the same reason: `NONE OPEN`, `SKIPPED (--skip-oldest-open)`, and `NAMESPACE UNREADABLE` all say why a number is absent.

`history_bytes_gb` is an estimate, not a measurement. It is the visible execution count multiplied by the mean history size of the sampled executions, so its accuracy depends entirely on `sample_basis` on the same row. `FULL POPULATION` means it is exact; anything else means it is extrapolated from `SAMPLE` executions, and raising `SAMPLE` tightens it.

**Do not compare script A's `visible_executions` against script B's `new_executions` unless the windows line up.** Script A reports what visibility currently holds, bounded by each namespace's own `retention_days`. Script B reports flow over its lookback. If the lookback is shorter than the retention, a gap between the two is arithmetic rather than a finding. When they do line up, a large gap points at retries, failed starts, or workflow-ID reuse.

`actions_per_execution` reports `NO NEW EXECUTIONS - check CAN` only when the window has enough coverage to mean it. Below `MIN_COVERAGE` the cell is blank, because actions without starts is also just what a short window looks like.

Duplicate scrape jobs multiply every absolute number while leaving every ratio correct. Script B detects this and reports it in the stderr preamble.

Search attribute limits on Cloud are per type, so a comfortable-looking total can hide one type being over. `sa_limit_check` does that comparison.

## Versioning

Each script prints its version to stderr as its first line, before any argument handling, so even a failed run says what ran.

`SCRIPT_VERSION` is a literal in the script and can be overridden from the environment, so the reported version is only trustworthy on an unmodified checkout. If you change a script, change `SCRIPT_VERSION` too.

Pin to a tagged release rather than the default branch. Tags are mutable, so if you need provenance for a review, pin the commit SHA the tag points at.

## License

MIT. See `LICENSE`.
