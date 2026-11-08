# Registry migrations

Data migrations are manually triggered and live in this directory.

## Naming

```
YYYY-MM-DD-<slug>.lua
```

The ISO date prefix makes a plain directory listing chronological. Do not use
`11-7-26`: it sorts before `11-10-26` and after `10-31-26`.

Examples:

- `2026-11-07-add-sha256.lua`
- `2026-12-01-normalize-tags.lua`

## Rules

- Scripts are **never** run automatically. Use the **Run Migration** GitHub
  Actions workflow (`workflow_dispatch`) and pass the script path.
- Every script must be idempotent: running it twice must be a no-op.
- Every script must support `--dry-run`, which computes and reports changes
  without writing.
- A script may add `--force` or filters, but the default must be safe.
- Prefer a `--package <name>` filter for testing a single package first.
- The workflow runs `lde test` before committing.
- Data changes are committed by the workflow; do not commit generated
  migration output by hand.

## Local use

```sh
lde run scripts/2026-11-07-add-sha256.lua -- --dry-run
lde run scripts/2026-11-07-add-sha256.lua -- --package hood
lde run scripts/2026-11-07-add-sha256.lua
```

The script uses `curl` to download source archives and the local SHA-256
implementation in `src/registry/sha256.lua`.
