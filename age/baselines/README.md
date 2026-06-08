# baselines/

Committed reference fixtures for the benchmark regression gates.

## `bench-sf3-baseline.json`

The canonical SF3 latency baseline. Both regression gates diff their run against it:

- the **implementer self-gate** (10K benchmark, `benchmark-local.properties`), as a smoke check, and
- the **main-session final gate** (20K benchmark, `benchmark-local-20k.properties`), as the authoritative regression check.

It is captured at the **20K final-gate profile**, so the final gate compares like-for-like;
the implementer's 10K run is a coarser smoke comparison against the same file.

### This file is measured data — it cannot be hand-written

It is produced by running the capture script against a loaded, snapshotted SF3 database:

```bash
CONNECTION_STRING=postgresql://postgres:postgres@localhost:5432/postgres \
  scripts/capture-baseline.sh
```

`capture-baseline.sh` restores, runs the 20K benchmark locally, copies
`results/LDBC-results.json` here, and restores again. It refuses any non-local
`CONNECTION_STRING` (the baseline must never be captured against shared HorizonDB).

If `bench-sf3-baseline.json` is absent or stale, regenerate it before relying on any
regression verdict. Refresh it after a landed optimization so future deltas measure against
current performance, then commit the updated file.
