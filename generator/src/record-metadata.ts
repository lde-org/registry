import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { $ } from "bun";
import { resolveIdentity } from "./identity";
import {
	laterOf,
	metadataFile,
	normalizeIso,
	readMetadata,
	root,
	type Metadata,
	type PackageMetadata,
	writeMetadata,
} from "./metadata";

const packagesDir = join(root, "packages");
const authorityFile = join(root, "authority.json");

const repo = process.env.REPO ?? "";
if (!repo) {
	console.error("Missing required env: REPO");
	process.exit(1);
}

// namespaces: namespace name -> owner GitHub ids. top: flat package name ->
// owner GitHub ids. Namespaced packages are owned via their namespace.
interface Authority {
	namespaces: Record<string, number[]>;
	top: Record<string, number[]>;
}

interface Portfile {
	name?: string;
	versions?: Record<string, string>;
}

// ---- Read the registry ----
// Load current authority (numeric GitHub ids).
let authority: Authority = { namespaces: {}, top: {} };
try {
	authority = JSON.parse(readFileSync(authorityFile, "utf8")) as Authority;
} catch {
	// no authority file yet
}

// Package name -> portfile, for every package in the registry.
const portfiles = new Map<string, Portfile>();
for (const file of readdirSync(packagesDir, { recursive: true })
	.filter((f): f is string => typeof f === "string")
	.filter((f) => f.endsWith(".json"))) {
	try {
		const parsed = JSON.parse(
			readFileSync(join(packagesDir, file), "utf8"),
		) as Portfile;
		if (typeof parsed.name === "string") portfiles.set(parsed.name, parsed);
	} catch {
		// Invalid portfiles are rejected by check-pr; skip them here.
	}
}

const packageNames = [...portfiles.keys()];

// last-updated.json is the registry's centralized package metadata file: for
// every package, when it was first published and when a new version was last
// added. Both dates are read from this repo's own history — a portfile only
// ever changes when a version is added, so the commit that last touched it is
// the last update and the commit that added it is the first publish. Nothing is
// taken from the portfile (it is user-submitted data) or the package's repo.
//
// The workflow checks out with fetch-depth: 0; on a shallow checkout every
// package would appear to change at the tip commit.
const metadata: Metadata = readMetadata();

/**
 * Runs a `git log` template and returns the commit hash and its committer date,
 * which the template prints on two lines.
 *
 * Note the doubled percent: Bun's shell expands `%`-sequences inside template
 * literals, so a single `%cI` never reaches git and the command silently
 * returns nothing. `%n` is a newline in git's own format.
 */
async function commitInfo(
	command: ReturnType<typeof $>,
): Promise<{ sha: string; date: string } | null> {
	const out = (await command.nothrow().cwd(root).text()).trim();
	const [sha, date] = out.split("\n").map((line: string) => line.trim());
	return sha && date ? { sha, date } : null;
}

/** The commit that first added this package's portfile, and its date. */
function firstCommit(name: string) {
	return commitInfo(
		$`git log --follow --diff-filter=A --format=%H%n%cI -1 -- packages/${name}.json`,
	);
}

/** The newest commit that touched this package's portfile, and its date. */
function lastCommit(name: string) {
	return commitInfo(
		$`git log -1 --format=%H%n%cI -- packages/${name}.json`,
	);
}

// ---- Owners ----
function isCovered(name: string): boolean {
	if (name.includes("/")) {
		const ns = name.split("/")[0] ?? "";
		return ns in authority.namespaces;
	}
	return name in authority.top;
}

// Every package file without an owner entry is new since the last sync.
const missing = packageNames.filter((n) => !isCovered(n));
let authorityChanged = false;

if (missing.length > 0) {
	console.log(`Resolving owners for: ${missing.join(", ")}`);

	for (const name of missing) {
		const relative = `packages/${name}.json`;

		const introducing = await firstCommit(name);
		if (!introducing) {
			console.error(`Could not find introducing commit for ${name}`);
			process.exit(1);
		}
		const { sha } = introducing;

		// Resolve the author's numeric GitHub id from the commit. Falls back to
		// the PR that introduced the commit when the commit author is not linked.
		let id = "";
		try {
			id = (
				await $`gh api repos/${repo}/commits/${sha} --jq .author.id`
					.nothrow()
					.quiet()
					.text()
			).trim();
		} catch {
			// fall through
		}
		if (!id || id === "null") {
			id = (
				await $`gh api repos/${repo}/commits/${sha}/pulls --jq '.[0].user.id'`
					.nothrow()
					.quiet()
					.text()
			).trim();
		}
		if (!id || id === "null") {
			console.error(
				`Could not resolve the GitHub id of the author of ${relative} (commit ${sha}). ` +
					`Record it manually in authority.json.`,
			);
			process.exit(1);
		}

		if (name.includes("/")) {
			const ns = name.split("/")[0] ?? "";
			authority.namespaces[ns] = [Number(id)];
			console.log(`  namespace ${ns} -> ${id}`);
		} else {
			authority.top[name] = [Number(id)];
			console.log(`  ${name} -> ${id}`);
		}
	}
	authorityChanged = true;
} else {
	console.log("No new packages to record.");
}

// ---- First published / last updated ----
// A package's dates only change when git shows a commit the recorded dates do
// not already account for. Once an entry is recorded, it is trusted as-is: git
// history being rewritten can then never rewind a date, and an admin can
// correct an entry by hand without the next run overwriting it.
let metadataChanged = false;

for (const name of packageNames) {
	const stored = metadata[name];
	const recorded = stored !== undefined && !stored.backfilled;

	if (recorded) continue;

	const introduced = await firstCommit(name);
	const modified = await lastCommit(name);

	const firstPublished = normalizeIso(introduced?.date);
	const lastUpdated = normalizeIso(modified?.date) ?? firstPublished;

	const entry: PackageMetadata = {
		firstPublished,
		lastUpdated: laterOf(firstPublished, lastUpdated),
	};

	// Only the first run for a package can be an estimate: it fills dates in
	// from history that nobody watched happen. Later runs record a commit that
	// was actually observed.
	if (stored && stored.backfilled) entry.backfilled = true;
	if (!firstPublished || !lastUpdated) entry.backfilled = true;

	if (JSON.stringify(stored) !== JSON.stringify(entry)) {
		metadata[name] = entry;
		metadataChanged = true;
		console.log(
			`  ${name}: firstPublished=${entry.firstPublished} lastUpdated=${entry.lastUpdated}` +
				(entry.backfilled ? " (backfilled)" : ""),
		);
	}
}

// Packages no longer in the registry don't linger in the metadata file.
for (const name of Object.keys(metadata)) {
	if (portfiles.has(name)) continue;
	delete metadata[name];
	metadataChanged = true;
	console.log(`  ${name}: removed`);
}

// ---- Write back sorted, tab-indented like the rest of the repo ----
if (authorityChanged) {
	writeFileSync(
		authorityFile,
		JSON.stringify(
			{
				namespaces: Object.fromEntries(
					Object.entries(authority.namespaces).sort(),
				),
				top: Object.fromEntries(Object.entries(authority.top).sort()),
			},
			null,
			"\t",
		) + "\n",
	);
}
if (metadataChanged) {
	writeMetadata(metadata);
	console.log(`Updated ${metadataFile}`);
}

// ---- Commit and push to master ----
if (!authorityChanged && !metadataChanged) {
	console.log("No package metadata changes.");
	process.exit(0);
}

await $`git add authority.json last-updated.json`.cwd(root);
const identity = await resolveIdentity();
const committed =
	await $`git -c user.name=${identity.name} -c user.email=${identity.email} commit -m "Record package metadata (owners, first published, last updated)"`
		.nothrow()
		.quiet()
		.cwd(root);
if (committed.exitCode !== 0) {
	console.error("Nothing to commit or commit failed");
	process.exit(0);
}

const token = process.env.GH_TOKEN ?? "";
const pushed =
	await $`git push https://x-access-token:${token}@github.com/${repo}.git HEAD:master`
		.nothrow()
		.quiet()
		.cwd(root);
if (pushed.exitCode !== 0) {
	console.error(
		"Push failed. The bot token needs contents:write on master (or branch protection must allow the bot).",
	);
	process.exit(1);
}
console.log("Pushed package metadata to master.");
