# Use case 03 — Low-latency repeated jobs with a warm pool

**Goal:** run the same Spark job over and over — every few minutes, on a
schedule, or while iterating — without paying the cold-start tax. A Data Flow
**warm pool** keeps executors hot so each run starts in **seconds** instead of
the ~1 minute a cold serverless run takes.

The sweet spot for near-real-time dashboards, frequent micro-batches, and tight
develop/test loops.

## Requires in the Resource Manager form

| Field | Value |
|-------|-------|
| Deploy Data Flow (Spark) applications | **on** |
| Create a Data Flow warm pool | **on** |
| Pool min / max executors | e.g. 1 / 4 |
| Deploy operator VM behind OCI Bastion | on |

The script still runs without a pool — it just warns that runs will cold-start.

> The warm pool bills continuously while it's up. Destroy the stack (or set the
> pool option off and re-apply) when you're done iterating.

## Run it (on the operator VM)

```bash
cd use-cases/03-warm-pool-low-latency
./run.sh
```

`run.sh` self-checks Data Flow (and warns if there's no warm pool), stages
`hourly_aggregate.py` + `events.csv`, ensures a Data Flow application
`<prefix>-hourly-aggregate` **attached to the warm pool** (when present), and
submits a run.

**Submit it a few times back to back** and compare the start latency:

```bash
oci data-flow run list --compartment-id "$COMPARTMENT_OCID" \
  --query 'data[].{name:"display-name",state:"lifecycle-state",created:"time-created"}'
```

The first run may still acquire pool capacity; subsequent runs land on hot
executors and start almost immediately. Run [use case 01](../01-serverless-etl/)
(no pool) to feel the cold-start difference.

## What this demonstrates

- **Warm pool economics.** Trade a steady baseline cost for fast, predictable
  starts. Tune the pool min/max executors to balance cost vs. burst headroom.
- **Same app, many runs.** Data Flow separates the *application* (definition)
  from the *run* (execution). Schedule this app from OCI Functions, cron, or
  Resource Scheduler and every invocation reuses the hot pool.
- The job (`hourly_aggregate.py`) does a windowed aggregation over an event-log
  CSV — counts and unique users per hour per event type — the kind of rollup
  you'd refresh frequently behind a dashboard.

## If it can't run

If Data Flow isn't deployed, `run.sh` stops and names the field to enable
(`Deploy Data Flow`). If only the warm pool is missing, it runs anyway with a
note to enable **Create a Data Flow warm pool** for fast starts.
