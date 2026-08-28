# Agent instructions

## Commit convention (MUST FOLLOW)

Authoritative rules live in [`CONTRIBUTING.md`](CONTRIBUTING.md).
Any agent writing a commit or PR title in this repo MUST obey them.
Summary:

- **Conventional Commits**, matching the existing history: `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `ci:`.
- Imperative mood, lowercase after the type, no trailing period, subject under ~72 chars.
- Body optional; wrap ~72 cols; explain *why*, not what.
- **Never add `Co-authored-by:` or generated-by-agent attribution.**
  [`.githooks/prepare-commit-msg`](.githooks/prepare-commit-msg) strips those trailers, but do not write them in the first place.

Good: `feat: add per-namespace history size percentiles`, `docs: document PROM_URL override`.
Bad: `Added percentiles.`, `update stuff`.

## Commit & push workflow - default to a PR (MUST)

When the user asks to **commit and push**, the default flow is a pull request.
The PR body is the history-recording artifact for this repo (solo-maintained; PRs record the *why*).
Do NOT push straight to `main`.

1. Branch off `main` with a short descriptive name.
2. Commit using the subject rules above.
   Keep the branch to one focused, well-formed commit.
3. Push the branch and open a PR with an informative body: summary, why, key changes, how it was verified.
4. **Rebase-merge** to `main` for linear history, then sync local `main` (`git checkout main && git pull --ff-only`).

Skip the PR only when the user explicitly says so for that request.

## Verify before merge - static review gates the PR

Scale the gate to the diff; this is a cost decision, not a blanket step.

- **Skip the review** for trivial diffs: docs, comments, README tables.
- **Run `/code-review <pr>`** for any diff with real logic - after opening the PR, before the rebase-merge.
  Fold the findings into the branch, then merge.

State in the PR body which review ran, or that the diff was trivial and the review was skipped.

## Sensitive content - this repo is public (MUST)

This repo is internal Temporal work published openly, and the scripts it holds run against **customer** estates.
A pre-commit hook ([`.githooks/pre-commit`](.githooks/pre-commit)) blocks commits containing credentials, internal hostnames, or customer names and data.
See [`CONTRIBUTING.md`](CONTRIBUTING.md) for setup and escape hatches.

Agent-specific rules on top of the hook:

- **Never commit real inventory output.**
  `out/` and `*.tsv` are gitignored because a real run's TSVs carry customer cluster IDs, namespace names, and volume data.
  Use synthetic values in examples and docs.
- **Never commit a real `clusters.conf`.**
  Only `clusters.conf.example`, with placeholder hostnames.
- **Do not paste real command output into commit messages, PR bodies, or docs** without redacting cluster and namespace names first.
- The hook's AI layer can be wrong in both directions.
  A block is not automatically correct, and a pass is not a guarantee - judge the diff yourself.

## Running the scripts against real clusters (MUST)

The scripts are read-only by design (describe, count, list, and Prometheus range/instant queries), and that property is load-bearing for customer trust.

- **Keep any new script read-only.**
  A change that issues a write, mutation, or terminate call against a customer cluster needs explicit approval first, and the README's "They are read-only" section must be updated in the same commit.
- **Do not fetch Event Histories or payloads.**
  Script A derives history-size statistics from `workflow list --output json` metadata precisely to avoid reading customer payloads.
  Preserve that.
- **Mind the query cost on a real estate.**
  A listing that fans out across every namespace in a large cluster is expensive for the customer's frontend.
  Prefer bounded time ranges and existing sampling flags over widening a scan; get approval before adding anything that fans out further.
- **Test against a local dev server** (`temporal server start-dev`) or synthetic fixtures before pointing a change at a customer cluster.

## Compatibility constraints

- **bash 3.2.**
  Stock macOS `/bin/bash` is the floor - no associative arrays, no `mapfile`, no `${var^^}`.
- **Dependencies are `temporal`, `curl`, `jq`, and `awk` only.**
  Adding a dependency is a real cost for an operator running this inside a customer's jump host; get agreement before introducing one.
- Every script keeps a `SCRIPT_VERSION` and prints it to stderr, so an output file can be traced back to the code that produced it.
  Bump it when output columns change.
