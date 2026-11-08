# lde-org/registry

This repository contains the registry for lde.

## How it works

The registry is just an easily indexable list of JSON files describing information for a package, and where to get it from.

No pre-built executables or library source code will be stored here.

## Contributing

You can use `lde publish` which will create a pull request with the changes to add your package to the registry.

Pull requests that touch `packages/**` are processed automatically by a bot (see [Automation](#automation)):

- New packages are validated against the schema and approved, but merged manually by a maintainer. The owner is recorded after merge.
- Updates to existing packages are auto-approved and auto-merged **only if** the author is the recorded package owner (or a repo admin) **and** the change adds exactly one new version without touching existing versions.
- Invalid JSON/schema → the bot requests changes with a list of errors.
- Non-owners touching an existing package → the PR is closed automatically.

### Naming

Packages may be namespaced: a package named `namespace/pkg` is stored at `packages/namespace/pkg.json`, and the portfile's `name` field must equal the path relative to `packages/` minus the `.json` extension.

Names follow these rules (applied to both the namespace and package parts):

- Lowercase only (`a-z`), digits, `_` and `-`. No dots, no `..`, no empty segments, no leading/trailing `/`.
- Must start with a letter and end with a letter or digit (no purely-special names like `---`; `a-a` is fine).
- A namespace is exactly one level deep: `foo/bar` is valid, `foo/bar/baz` is not.
- The namespace part must be **at least 3 characters** long.
- The full name (`namespace` + `/` + `package`) must be **at most 128 characters**.
- Flat packages (no `/`) keep working exactly as before.

### Example

```json
{
	"name": "hood",
	"description": "Cross-platform rendering in pure LuaJIT.",
	"authors": ["David Cruz <codebycruz@gmail.com>"],
	"tags": ["rendering", "graphics"],
	"git": "https://github.com/codebycruz/hood",
	"branch": "master",
	"versions": {
		"0.1.0": "5d4bb28703d8f1c17a0e241810145194a51042f0"
	}
}
```

`tags` is an optional list of up to 10 unique, lowercase tags (`a-z`, digits and
`-`, at most 32 characters) used by clients to categorize packages.

Version objects store only what differs from the top-level source. A normal
hash-pinned git version is `{ "commit": "...", "sha256": "..." }`; `git` and
`branch` appear only when that version moved to another repository or branch.

A version normally resolves to a 40-character lowercase commit hash in the
portfile's `git`/`branch`. When a release lives in a different repository or
branch, that version can carry its own source instead. New git versions also
carry a `sha256` of the archive clients download, so a changed source server is
detected before extraction:

```json
{
	"versions": {
		"0.1.0": "5d4bb28703d8f1c17a0e241810145194a51042f0",
		"0.2.0": {
			"commit": "0123456789abcdef0123456789abcdef01234567",
			"git": "https://github.com/codebycruz/hood-next",
			"branch": "main",
			"sha256": "9f2c4e8a7b6d5c3e1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8e"
		}
	}
}
```

A version can also be a hash-pinned tarball instead of a git commit. In that
case the top-level `git` is optional and every version must name an archive:

```json
{
	"name": "hood",
	"versions": {
		"1.0.0": {
			"archive": "https://github.com/codebycruz/hood/releases/download/v1.0.0/hood-1.0.0.tar.gz",
			"sha256": "9f2c4e8a7b6d5c3e1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8e"
		}
	}
}
```

The client verifies `sha256` before extracting. A mismatch means the source
changed after publication and the download is rejected.

A version can be revoked without deleting its entry or changing its commit/hash:

```json
{
	"revoked": ["1.0.0"]
}
```

Revoked versions are skipped by ranges and `latest`; an exact pin fails with a
clear error. Only the package owner or a repo admin may revoke a version, and
only repo admins may un-revoke one. This is a content
commitment in the registry, not an author signature: it protects against a
changed or compromised source server as long as the registry entry itself is
trusted. Author-key signatures require a separate key distribution and trust
policy.

## Migrations

One-off data changes live in `scripts/` and are named `YYYY-MM-DD-<slug>.lua`
so a directory listing is chronological. They are never run automatically.

Run one through the **Run Migration** workflow (`workflow_dispatch`) with a
`script` input such as `scripts/2026-11-07-add-sha256.lua`. Use `dry_run` first.
The workflow validates the path, runs the script, runs `lde test`, and commits
the resulting data changes.

Scripts must be idempotent and support `--dry-run`; see
[`scripts/README.md`](scripts/README.md).

## Automation

### Validation

On creation of a package, the bot will ensure that your PR is valid by verifying it fits the JSON schema, and that you aren't overwriting old versions.

If it fails, it will request changes with a list of errors.

If there are no errors, it will be approved, and wait pending a maintainer accepting creation of a package. This part is not automatic as to avoid abuse, name-squatting, etc.

### Automation implementation

The automation is written in Lua and runs on [lde](https://lde.sh). Its modules live under `src/registry/` and the entry points under `src/`:

```sh
lde run src/generate-index.lua     # dist/index.json
lde run src/check-pr.lua            # PR verdict (check-pr workflow)
lde run src/record-metadata.lua     # owners, first published, last updated
lde run src/namespace-request.lua   # namespace issues
lde run src/backfill.lua            # one-off metadata migration
lde test                            # automation test suite
```

Dependencies (`json`, `fs`, `path`, `process`) and the `lde-test` dev dependency are declared in `lde.json`; there is no Bun or Node toolchain anymore. Scripts use `process.exec` for `git` and `gh` (argument lists, never shell interpolation), and the `json` package for JSON.

### Ownership

If your PR is successfully approved, the bot will make note of you as the *owner* of the package. This means that any PRs you make touching the package in the future will be automatically approved and accepted.

It works based off your GitHub id, so there will be no conflicts if your username changes.

Ownership lives in `authority.json`, which has two sections:

- `top`: flat package name → list of owner GitHub ids.
- `namespaces`: namespace name → list of owner GitHub ids. A namespaced package `ns/pkg` is owned by the owner of its namespace (`ns`), so claiming a namespace claims every package in it.

Owners are stored as arrays (a package may have several). The bot only writes a fresh single-owner array when it records a new package. An existing owner can add co-owners through a pull request that only appends GitHub ids to keys they already own; the bot approves that PR and a maintainer merges it. Removing or reordering owners still requires a repo admin.

Repo admins bypass this check and can obviously modify packages at will.

### Package metadata

`last-updated.json` is the registry's centralized package metadata file. For every package it records exactly two dates:

```json
{
	"html": {
		"firstPublished": "2026-08-17T10:28:27Z",
		"lastUpdated": "2026-08-20T09:14:03Z"
	}
}
```

- `firstPublished` — when the package was first published to the registry (the "new package" date).
- `lastUpdated` — when a new version was last added (the "updated" date). It equals `firstPublished` for a package that has never been updated.
- `backfilled` — optional; present on entries reconstructed by the [one-off migration](#backfilling) rather than recorded as packages were published.

Both dates are derived from **this repository's own history**, and only from it. A portfile changes for exactly one reason — a version was added — so the commit that last touched `packages/<name>.json` is the last update, and the commit that first added it is the first publish. That keeps the metadata authoritative without trusting anything user-submitted: portfiles still contain nothing but the fields in [the schema](schemas/registry.schema.json) (no timestamps, nothing auto-generated beyond the commit hashes), and no date ever comes from a package's own repository.

Dates are taken as written and never moved backwards, so an incorrect entry can be corrected by hand, but history being rewritten cannot silently rewind the file.

Only repo admins may edit `last-updated.json` directly. The bot keeps it current on every push touching `packages/**`: it refreshes entries from git history, commits the file to master, then regenerates the index. The index generator only reads this file and never runs `git log`, so the index — and the dates the website shows — cannot be invented at build time, and building it needs nothing more than the file itself.

### Backfilling

Packages published before the metadata file existed have no recorded dates. `src/backfill.lua` reconstructs them once from registry history — the commit that first added the portfile becomes `firstPublished`, the newest commit that touched it becomes `lastUpdated` — and flags each entry with `"backfilled": true` so the website can show them as estimates:

```sh
lde run src/backfill.lua
lde run src/backfill.lua -- --force
```

It leaves entries that were recorded live alone, so it is safe to re-run, and `--force` recomputes backfilled entries. Run it on a full clone: a shallow one would date everything to the tip commit.

### Requesting a namespace

Namespaces aren't claimed through package PRs — they're requested through an issue. Open an issue containing `/request-namespace <name>` (this is what the lde website generates), and the bot will reply that a moderator must approve it. A repo moderator then comments `!approve` (or `@robolde approve`), and the bot creates the namespace in `authority.json`, assigns ownership to the issue author, and closes the issue. If the namespace already exists, the issue is closed with a notice.

### Rules enforced

1. **Schema**: every changed package JSON must validate against `schemas/registry.schema.json`, and the `name` field must match the path relative to `packages/` minus `.json` (see [Naming](#naming)).
2. **Ownership**: modifying or deleting an existing package requires its owner (for `ns/pkg`, the namespace owner) or a repo admin. New packages are claimable by whoever submits them.
3. **Versions**: updates may not modify or remove existing versions. Exactly one new version must be added.
4. **`authority.json`**: repo admins may edit it directly. An existing owner may add co-owners to a package or namespace they own; the PR must only append ids to those owner arrays, and a maintainer merges it.
5. **`last-updated.json`**: only repo admins may edit it directly (it is maintained by the bot).
6. **New packages are never auto-merged.** The bot approves them and a maintainer merges manually; the owner is recorded on `master` right after the merge.

### Self Hosting

The workflows authenticate with a **GitHub App** so the bot can comment, review, merge and push:

1. **Create a GitHub App** (Settings → Developer settings → GitHub Apps).
2. Grant it these repository permissions: **Contents: Read and write** (commits and the `dist` branch), **Pull requests: Read and write** (comments, reviews, merges), **Issues: Read and write** (namespace requests), and **Metadata: Read-only** (mandatory).
3. Add the App id as an Actions **variable** named `REGISTRY_APP_ID`, and a private key as an Actions **secret** named `REGISTRY_APP_PRIVATE_KEY`.
4. Install the App on `lde-org/registry`. If the App is installed on the organization with **Only select repositories**, add this repository explicitly. A token step that fails with `Not Found - .../get-a-repository-installation-for-the-authenticated-app` means the App is not installed on this repository, or the App id/private key belong to a different App.

`check-pr.yml` uses `pull_request_target` because fork PRs need the App token to comment, review and merge. It checks out the base revision and only reads PR contents via `git show`; it never executes fork code. GitHub's default event policy blocks `pull_request_target` on public repositories after December 2, 2026, so allow `pull_request_target` in the repository or organization Actions event policy if this workflow should keep running.

Each workflow mints a short-lived installation token with `actions/create-github-app-token@v3` and passes it as `GH_TOKEN` (and as the checkout token where a push is needed). Nothing is stored in the repository. `lde-org/setup-lde@v1` installs lde; the workflows no longer set up a JavaScript runtime or install JavaScript dependencies.

### User login (OAuth App)

The bot App is not used for user login: an installation token is scoped to the repositories the App is installed on, so it cannot write a contributor's fork. Create a separate **GitHub OAuth App** for users:

1. Set the callback URL to `https://lde.sh/api/auth/callback` (add a local URL for development).
2. Enable **Device flow** so `lde login` works from a terminal.
3. The CLI ships with the official OAuth App client ID, so users need no configuration. Override it with `github.clientId` in `~/.lde/config.json` (or `LDE_GITHUB_CLIENT_ID`) for a self-hosted app. The CLI requests `public_repo offline_access`; no client secret is stored.
5. Set `GITHUB_CLIENT_SECRET` as a Cloudflare secret for the website (`wrangler secret put`). The client ID defaults to the official app; set `GITHUB_CLIENT_ID` only for a self-hosted app. `REGISTRY_REPO`, `REGISTRY_BRANCH`, and `SITE_URL` are non-secret vars in `wrangler.jsonc`.

`public_repo` lets a signed-in user create issues and pull requests and write their own fork, which is how contributors without write access publish.

An installation token cannot call `GET /user`, so the bot's commits default to `robolde` / `robolde@users.noreply.github.com`. Set the optional `REGISTRY_BOT_NAME` and `REGISTRY_BOT_EMAIL` secrets to attribute them to a real account (for example a dedicated bot user's noreply address).
