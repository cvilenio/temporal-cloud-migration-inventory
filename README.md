# Temporal Cloud migration inventory scripts

Three read-only scripts that inventory a self-hosted Temporal estate ahead of a migration to Temporal Cloud. They collect the volume, limit and configuration data needed to size namespaces on Cloud and to check migration prerequisites.

They exist because that data is spread across the Temporal CLI and a Prometheus-compatible metrics store, and collecting it by hand across a large estate is slow and inconsistent.

## What each script does

| Script | Reads | Produces |
| :- | :- | :- |
| `scripts/preflight.sh` | Temporal CLI, connectivity only | terminal output |
| `scripts/A-cli-inventory.sh` | Temporal CLI, every cluster in `clusters.conf` | `clusters.tsv`, `namespaces.tsv` |
| `scripts/B-promql-inventory.sh` | Prometheus HTTP API, every cluster that instance scrapes | `promql.tsv` |

The TSV files are designed to be pasted into a companion inventory spreadsheet, but they are ordinary tab-separated files and are useful on their own.

## They are read-only

Script A issues describe, count and list calls. Script B issues HTTP range and instant queries. Neither writes to a cluster, a namespace, or a metrics store.

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

Map each cluster to a stable ID by copying `clusters.conf.example`. Columns are separated by a real tab. The ID becomes the join key in the output, so pick something durable.

Then:

```
./scripts/preflight.sh clusters.conf
./scripts/A-cli-inventory.sh --clusters clusters.conf --out ./out
PROM_URL=http://prometheus.internal:9090 ./scripts/B-promql-inventory.sh > out/promql.tsv 2> out/promql-notes.txt
```

## Options

Script A takes flags:

| Flag | Effect | Cost |
| :- | :- | :- |
| `--clusters FILE` | Cluster list to walk. Scope of a run is whatever is in this file. | |
| `--out DIR` | Output directory. Defaults to `./out`. | |
| `--resume` | Skips namespaces whose row key is already in `namespaces.tsv`. | Does not refresh existing rows. |
| `--parallel N` | N namespaces at a time, default 1. Wall clock falls roughly linearly. | Peak visibility load rises by the same factor. |
| `--skip-oldest-open` | Drops the most expensive call, which pages up to 1000 open executions. | Loses the `oldest_open_execution_days` column. |

Both scripts take environment variables:

| Variable | Applies to | Meaning |
| :- | :- | :- |
| `WINDOW_DAYS` | A and B | Metrics window in days, default 30. Keep identical between the two scripts. |
| `SAMPLE` | A | Closed executions sampled per namespace for history statistics, default 200. |
| `NAMESPACES` | A | Space-separated list. Skips discovery. Applies to every cluster in the run. |
| `SKIP_NAMESPACES` | A | Namespaces to exclude, default `temporal-system`. |
| `CLUSTER_ID`, `TEMPORAL_ADDRESS` | A | Single-cluster mode, used instead of `--clusters`. |
| `PROM_URL` | B | Prometheus HTTP API base URL. Required. |
| `CLUSTER_ID` | B | Cluster ID to stamp on each row. |
| `CLUSTER_LABEL`, `CLUSTER_VALUE` | B | Disambiguate a namespace name that exists on more than one cluster. |
| `PROM_JOB` | B | Pin a scrape job when several duplicate the same targets. |
| `MIN_COVERAGE` | B | Coverage floor below which rate columns are suppressed, default 20. |
| `STEP` | B | Range query step in seconds, default 300. |

## Cost of a run

Script A makes 6 CLI calls per namespace, sequentially. Each call is a separate `temporal` process, so round-trip time to the frontend dominates. After its first namespace the script extrapolates and prints an estimate for the rest of the cluster, so a long run announces its own cost while there is still time to stop it.

Frontend load is not a concern at these rates. The visibility store is the constraint that matters, and it depends which one you run. Script A prints which store it found.

With Elasticsearch visibility, counts and lists are cheap aggregations. With standard SQL visibility, every count is a `COUNT(*)` over `executions_visibility` on the database that also serves production visibility queries, so cost scales with table size rather than namespace count. Prefer off-peak and leave `--parallel` at 1 until you know your database headroom.

## Running in batches

There is no batch flag. The scope of a run is whatever is in the file you point `--clusters` at, so keep several conf files and run each when it suits you:

```
./scripts/A-cli-inventory.sh --clusters wave1.conf --out ./out
./scripts/A-cli-inventory.sh --clusters wave2.conf --out ./out --resume
```

Output files append rather than overwrite, and headers are written only when a file is new. Every namespace row is keyed on cluster ID plus namespace name, so runs against different conf files accumulate in the same TSVs.

`--resume` tracks progress rather than scope. It builds its skip list from the row keys already in `namespaces.tsv`, so it covers everything collected so far, not just the conf file being run.

## Reading the output

`sample_basis` says whether the history maxima are exact. `FULL POPULATION` means the sample covered every visible execution.

A blank cell is not a zero. A number is always a measurement, a blank means not computed, and zero means genuinely zero. Script B suppresses rate columns below the coverage floor rather than reporting a misleading zero; `coverage_pct` says why.

Duplicate scrape jobs multiply every absolute number while leaving every ratio correct. Script B detects this and reports it in the stderr preamble.

Search attribute limits on Cloud are per type, so a comfortable-looking total can hide one type being over. `sa_limit_check` does that comparison.

## Versioning

Each script prints its version to stderr on every run. Pin to a tagged release rather than to the default branch, and record the version alongside any data you collect.

## License

MIT. See `LICENSE`.
