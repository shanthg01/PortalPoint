#!/usr/bin/env python3
"""Full lift-and-shift: RDS -> self-hosted VM Postgres (no size limiting).

Built for the no-VM-managed-Postgres path's Postgres piece specifically: a
free-tier managed Postgres (Neon, Supabase, etc.) tops out around 0.5-1GB
storage, nowhere near enough for this project's real dataset (~42.5GB,
dominated by 5 ML-output tables). A self-hosted Postgres on a free-tier VM
(e.g. Oracle Cloud Always Free, 200GB block storage) has plenty of room --
this script does the actual copy. See docs/selfhost_no_vm_runbook.md.

Usage:
    # 1. Open the SSM tunnel to RDS first (see CLAUDE.md's "RDS Access via
    #    SSM Bastion Tunnel" section) -- this script assumes 127.0.0.1:5433
    #    is already forwarding to RDS, same as every other script here.
    # 2. Set required env vars (see REQUIRED_ENV below), then:
    python lift_and_shift_vm.py phase1        # full copy, all small/reference tables
    python lift_and_shift_vm.py batch N        # the 5 giant ML-output tables,
                                                # batch N of 0..(total-1),
                                                # BATCH_SIZE schools per batch
    python lift_and_shift_vm.py backfill-null  # one-off: player_projections
                                                # rows with school_id IS NULL
                                                # (neutral-mode projections) --
                                                # these are NOT covered by any
                                                # school_id batch above; run
                                                # this once after the batches
    python lift_and_shift_vm.py verify         # full row-count audit, every
                                                # real table, RDS vs target --
                                                # run this last; it's what
                                                # actually catches gaps like
                                                # the NULL one above

Every table copy is an anti-join on 'id' against what the target already
has, so batches -- and reruns of the same batch/phase after a dropped
connection -- are naturally idempotent/resumable. The SSM tunnel (and
occasionally the target connection) can drop mid-run; both sides reconnect
fresh for every single table copy so a drop costs at most one table's
retry, not the whole batch.

Required env vars (fails fast if any are missing):
    RDS_HOST, RDS_PORT, RDS_USER, RDS_PASSWORD, RDS_DBNAME
    TARGET_HOST, TARGET_PORT, TARGET_USER, TARGET_PASSWORD, TARGET_DBNAME
Optional:
    BATCH_SIZE (default 25) -- schools per phase-2 batch
"""
from __future__ import annotations

import asyncio
import os
import sys

import asyncpg

REQUIRED_ENV = [
    "RDS_HOST", "RDS_PORT", "RDS_USER", "RDS_PASSWORD", "RDS_DBNAME",
    "TARGET_HOST", "TARGET_PORT", "TARGET_USER", "TARGET_PASSWORD", "TARGET_DBNAME",
]


def _check_env() -> None:
    missing = [k for k in REQUIRED_ENV if not os.environ.get(k)]
    if missing:
        print(f"Missing required env vars: {', '.join(missing)}", file=sys.stderr)
        print(__doc__, file=sys.stderr)
        sys.exit(1)


def _rds_dsn() -> dict:
    return dict(
        host=os.environ["RDS_HOST"], port=int(os.environ["RDS_PORT"]),
        user=os.environ["RDS_USER"], password=os.environ["RDS_PASSWORD"],
        database=os.environ["RDS_DBNAME"], ssl="require",
    )


def _target_dsn() -> str:
    return (
        f"postgresql://{os.environ['TARGET_USER']}:{os.environ['TARGET_PASSWORD']}"
        f"@{os.environ['TARGET_HOST']}:{os.environ['TARGET_PORT']}/{os.environ['TARGET_DBNAME']}"
    )


BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "25"))  # schools per phase-2 batch

# The 5 largest tables (all-pairs player x school ML output) -- ~42GB of the
# ~42.5GB total dataset. Batched by school_id/to_school_id so a single
# invocation stays a manageable ~1-2h chunk against a bandwidth-capped
# tunnel instead of one multi-hour run.
GIANT_TABLES = {
    "player_team_fit_scores": "school_id",
    "playing_time_projections": "school_id",
    "player_projections": "school_id",
    "transfer_success_scores": "to_school_id",
    "team_rating_projections": "school_id",
}

EXCLUDE_PREFIXES = ("pt_staging_",)
# pt_staging_*: ephemeral scratch/materialized tables from the playing-time
# pipeline's internal CTEs -- not created by any alembic migration, not
# read by any live API route. alembic_version: alembic's own bookkeeping,
# not real data (the target's own `alembic upgrade head` already sets it).
EXCLUDE_EXACT = {"alembic_version"}


async def get_all_tables(conn: asyncpg.Connection) -> list[str]:
    rows = await conn.fetch(
        "SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE c.relkind = 'r' AND n.nspname = 'public'"
    )
    names = [r["relname"] for r in rows]
    return [
        n for n in names
        if n not in EXCLUDE_EXACT and not any(n.startswith(p) for p in EXCLUDE_PREFIXES)
    ]


async def get_fk_edges(conn: asyncpg.Connection) -> list[tuple[str, str]]:
    rows = await conn.fetch(
        "SELECT conrelid::regclass::text AS child, confrelid::regclass::text AS parent "
        "FROM pg_constraint WHERE contype = 'f'"
    )
    return [(r["child"], r["parent"]) for r in rows]


def topo_sort(tables: list[str], edges: list[tuple[str, str]]) -> list[str]:
    tableset = set(tables)
    deps = {t: set() for t in tables}
    for child, parent in edges:
        if child in tableset and parent in tableset and child != parent:
            deps[child].add(parent)

    ordered: list[str] = []
    remaining = set(tables)
    while remaining:
        ready = sorted(t for t in remaining if not (deps[t] & remaining))
        if not ready:
            raise RuntimeError(f"Cycle detected among remaining tables: {remaining}")
        ordered.extend(ready)
        remaining -= set(ready)
    return ordered


async def copy_table_once(table: str, where_clause: str | None = None) -> int:
    query = f"SELECT * FROM {table}"
    if where_clause:
        query += f" WHERE {where_clause}"

    rds = await asyncpg.connect(**_rds_dsn())
    try:
        rows = await rds.fetch(query)
    finally:
        await rds.close()

    target = await asyncpg.connect(_target_dsn())
    try:
        n = 0
        if rows:
            colnames = list(rows[0].keys())
            has_id = "id" in colnames
            if has_id:
                existing_ids = {r["id"] for r in await target.fetch(f"SELECT id FROM {table}")}
                rows = [r for r in rows if r["id"] not in existing_ids]
            if rows:
                records = [tuple(r[c] for c in colnames) for r in rows]
                await target.copy_records_to_table(table, records=records, columns=colnames)
                n = len(records)

        # Keep the target's serial/identity sequence ahead of whatever we
        # just inserted, so future app-level inserts don't collide.
        try:
            has_id_col = await target.fetchval(
                "SELECT 1 FROM information_schema.columns "
                f"WHERE table_name = '{table}' AND column_name = 'id'"
            )
            if has_id_col:
                seq = await target.fetchval(f"SELECT pg_get_serial_sequence('{table}', 'id')")
                if seq:
                    maxid = await target.fetchval(f"SELECT max(id) FROM {table}")
                    if maxid is not None:
                        await target.execute(f"SELECT setval('{seq}', {maxid})")
        except Exception as e:
            print(f"  [sequence sync skipped for {table}: {e}]")

        return n
    finally:
        await target.close()


async def copy_table(table: str, where_clause: str | None = None, retries: int = 5) -> int:
    last_err: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            return await copy_table_once(table, where_clause)
        except Exception as e:
            last_err = e
            print(f"  [{table}: attempt {attempt}/{retries} failed: {e!r} -- retrying]")
            await asyncio.sleep(5)
    assert last_err is not None
    raise last_err


async def phase1() -> None:
    rds = await asyncpg.connect(**_rds_dsn())
    try:
        all_tables = await get_all_tables(rds)
        small_tables = [t for t in all_tables if t not in GIANT_TABLES]
        edges = await get_fk_edges(rds)
    finally:
        await rds.close()
    ordered_small = topo_sort(small_tables, edges)

    print(f"\nPhase 1: {len(ordered_small)} small/reference tables, full copy")
    print(", ".join(ordered_small))

    total = 0
    for t in ordered_small:
        n = await copy_table(t)
        total += n
        print(f"  {t:35s} {n:>8} rows")
    print(f"Phase 1 total: {total} rows")


async def phase2(batch_num: int) -> None:
    # Union of distinct school ids actually referenced across all 5 giants,
    # sorted for a stable, deterministic batch order across invocations.
    rds = await asyncpg.connect(**_rds_dsn())
    try:
        all_ids: set[int] = set()
        for t, col in GIANT_TABLES.items():
            rows = await rds.fetch(f"SELECT DISTINCT {col} AS sid FROM {t}")
            all_ids.update(r["sid"] for r in rows)
    finally:
        await rds.close()
    all_ids.discard(None)  # NULL handled separately, see backfill_null()
    sorted_ids = sorted(all_ids)
    total_batches = (len(sorted_ids) + BATCH_SIZE - 1) // BATCH_SIZE

    if batch_num >= total_batches:
        print(f"Batch {batch_num} out of range -- only {total_batches} batches total (0-{total_batches - 1})")
        return

    start = batch_num * BATCH_SIZE
    batch_ids = sorted_ids[start:start + BATCH_SIZE]
    id_list = ",".join(str(i) for i in batch_ids)

    print(f"\nPhase 2, batch {batch_num}/{total_batches - 1}: school_ids {batch_ids[0]}-{batch_ids[-1]} ({len(batch_ids)} schools)")

    total = 0
    for t, col in GIANT_TABLES.items():
        n = await copy_table(t, where_clause=f"{col} IN ({id_list})")
        total += n
        print(f"  {t:35s} {n:>8} rows")
    print(f"Batch {batch_num} total: {total} rows")


async def backfill_null() -> None:
    """player_projections has NULL school_id for neutral-mode rows (by
    design -- see the two partial unique indexes splitting neutral vs.
    destination-mode dedup). phase2()'s school_id batching entirely misses
    these; run this once after all phase2 batches to pick them up. Caught
    originally by a post-migration full row-count audit against RDS
    (94,128-row gap) -- always worth re-running that audit after this."""
    print("\nBackfill: player_projections WHERE school_id IS NULL")
    n = await copy_table("player_projections", where_clause="school_id IS NULL")
    print(f"  player_projections (NULL school_id) {n:>8} rows")


async def verify() -> None:
    """Full row-count comparison, every real table, RDS vs target. This is
    what actually caught the NULL-school_id gap originally -- always run
    this after phase1 + all phase2 batches + backfill-null, don't assume
    completeness from the per-batch output alone."""
    rds = await asyncpg.connect(**_rds_dsn())
    target = await asyncpg.connect(_target_dsn())
    try:
        tables = await get_all_tables(rds)
        diffs = []
        for t in sorted(tables):
            r = await rds.fetchval(f"SELECT count(*) FROM {t}")
            try:
                v = await target.fetchval(f"SELECT count(*) FROM {t}")
            except Exception as e:
                v = f"ERROR: {e}"
            if r != v:
                diffs.append((t, r, v))
            print(f"{t:35s} RDS={r!s:>10} target={v}")
        print("---")
        if diffs:
            print("MISMATCHES:")
            for t, r, v in diffs:
                print(f"  {t}: RDS={r} target={v}")
        else:
            print("ALL TABLES MATCH")
    finally:
        await rds.close()
        await target.close()


async def main() -> None:
    _check_env()

    if len(sys.argv) < 2:
        print(__doc__)
        return

    if sys.argv[1] == "phase1":
        await phase1()
    elif sys.argv[1] == "batch":
        if len(sys.argv) < 3:
            print("Usage: lift_and_shift_vm.py batch N")
            sys.exit(1)
        await phase2(int(sys.argv[2]))
    elif sys.argv[1] == "backfill-null":
        await backfill_null()
    elif sys.argv[1] == "verify":
        await verify()
    else:
        print("Unknown command:", sys.argv[1])
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
