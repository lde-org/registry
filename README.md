# lde-org/registry

This repository contains the registry for LDE.

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
	"git": "https://github.com/codebycruz/hood",
	"branch": "master",
	"versions": {
		"0.1.0": "5d4bb28703d8f1c17a0e241810145194a51042f0"
	}
}
```

## Automation

### Validation

On creation of a package, the bot will ensure that your PR is valid by verifiying it fits the JSON schema, and that you aren't overwriting old versions.

If it fails, it will request changes with a list of errors.

If there are no errors, it will be approved, and wait pending a maintainer accepting creation of a package. This part is not automatic as to avoid abuse, name-squatting, etc.

### Ownership

If your PR is successfully approved, the bot will make note of you as the *owner* of the package. This means that any PRs you make touching the package in the future will be automatically approved and accepted.

It works based off your GitHub id, so there will be no conflicts if your username changes.

Ownership lives in `authority.json`, which has two sections:

- `top`: flat package name → list of owner GitHub ids.
- `namespaces`: namespace name → list of owner GitHub ids. A namespaced package `ns/pkg` is owned by the owner of its namespace (`ns`), so claiming a namespace claims every package in it.

Owners are stored as arrays (a package may have several), but the bot only ever writes a fresh single-owner array — adding additional owners is done by editing `authority.json` directly (admin only).

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

Packages published before the metadata file existed have no recorded dates. `generator/src/backfill.ts` reconstructs them once from registry history — the commit that first added the portfile becomes `firstPublished`, the newest commit that touched it becomes `lastUpdated` — and flags each entry with `"backfilled": true` so the website can show them as estimates:

```sh
cd generator
bun run backfill
```

It leaves entries that were recorded live alone, so it is safe to re-run, and `--force` recomputes backfilled entries. Run it on a full clone: a shallow one would date everything to the tip commit.

### Requesting a namespace

Namespaces aren't claimed through package PRs — they're requested through an issue. Open an issue containing `/request-namespace <name>` (this is what the lde website generates), and the bot will reply that a moderator must approve it. A repo moderator then comments `!approve` (or `@robolde approve`), and the bot creates the namespace in `authority.json`, assigns ownership to the issue author, and closes the issue. If the namespace already exists, the issue is closed with a notice.

### Rules enforced

1. **Schema**: every changed package JSON must validate against `schemas/registry.schema.json`, and the `name` field must match the path relative to `packages/` minus `.json` (see [Naming](#naming)).
2. **Ownership**: modifying or deleting an existing package requires its owner (for `ns/pkg`, the namespace owner) or a repo admin. New packages are claimable by whoever submits them.
3. **Versions**: updates may not modify or remove existing versions. Exactly one new version must be added.
4. **`authority.json`**: only repo admins may edit it directly (it is normally maintained by the bot).
5. **`last-updated.json`**: only repo admins may edit it directly (it is maintained by the bot).
6. **New packages are never auto-merged.** The bot approves them and a maintainer merges manually; the owner is recorded on `master` right after the merge.

### Self Hosting

The workflows use `GITHUB_TOKEN` for reading, but approving, merging and pushing need a real user token. You must:

1. **Create a dedicated bot account** (e.g. `lde-bot`) and add it as a repository collaborator with **write access**. Using a separate account matters: GitHub does not allow a user to approve their own pull request, so if the token belongs to the same account that opened the PR, the approve step fails. (The workflows tolerate that failure gracefully — the comment still posts and updates still merge — but the review stamp will be missing.)
2. Create a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) for the bot account (recommended), or a classic token with the `repo` scope.
   - Fine-grained: repository access = this repo, permissions = **Contents: Read and write**, **Pull requests: Read and write**, **Issues: Read and write** (the namespace request workflow comments on and closes issues).
3. Add it as an Actions secret named `REGISTRY_BOT_TOKEN` (Settings → Secrets and variables → Actions).

Without this secret, validation still runs, but the approve / request-changes / close / merge steps will fail.

Optional: `REGISTRY_BOT_NAME` and `REGISTRY_BOT_EMAIL` secrets override the author of the authority.json commit. By default the bot commits as the account behind `REGISTRY_BOT_TOKEN` (resolved from the token at runtime, using that account's noreply email so GitHub attributes the commit to it), falling back to `robolde` / `robolde@users.noreply.github.com`.
