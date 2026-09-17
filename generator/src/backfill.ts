import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { $ } from "bun";
import {
	laterOf,
	metadataFile,
	readMetadata,
	root,
	type Metadata,
	type PackageMetadata,
	writeMetadata,
} from "./metadata";

// One-off migration. Packages published before the registry recorded metadata
// have no dates, so reconstruct them from the registry's own git history:
//
//   firstPublished = the commit that first added the portfile
//   lastUpdated    = the newest commit that touched the portfile (which, for a
//                    portfile, means a version was added)
//
// Entries produced here are marked `backfilled: true`, which the index exposes
// as `approximate` so the website can label them as estimates. A package that
// changes afterwards gets real recorded dates on the next bot run.
//
// Run from the generator directory, on a full clone:
//   bun run backfill
// Add --force to recompute entries that already exist.

const force = process.argv.includes("--force");
const packagesDir = join(root, "packages");
const metadata: Metadata = readMetadata();

const packageNames: string[] = [];
for (const file of readdirSync(packagesDir, { recursive: true })
	.filter((f): f is string => typeof f === "string")
	.filter((f) => f.endsWith(".json"))) {
	try {
		const parsed = JSON.parse(readFileSync(join(packagesDir, file), "utf8"));
		const name = typeof parsed?.name === "string" ? parsed.name : null;
		if (name) packageNames.push(name);
	} catch {
		// Invalid portfiles are rejected by check-pr.
	}
}

/**
 * Runs a git log template and returns the committer date it printed.
 *
 * The `%` is doubled because Bun's shell expands `%`-sequences inside template
 * literals — a single `%cI` never reaches git and the command silently returns
 * nothing (which is exactly how the old build-time dates went wrong).
 */
async function gitDate(command: ReturnType<typeof $>): Promise<string | null> {
	const out = (await command.nothrow().cwd(root).text()).trim();
	return out || null;
}

/** Commit date that first added this package's portfile. */
function gitAddedAt(name: string): Promise<string | null> {
	return gitDate(
		$`git log --follow --diff-filter=A --format=%cI -1 -- packages/${name}.json`,
	);
}

/** Commit date of the newest commit that touched this package's portfile. */
function gitModifiedAt(name: string): Promise<string | null> {
	return gitDate($`git log -1 --format=%cI -- packages/${name}.json`);
}

let changed = 0;

for (const name of packageNames.sort()) {
	const existing = metadata[name];
	if (existing && !existing.backfilled && !force) {
		console.log(`- ${name}: already recorded, skipping`);
		continue;
	}
	if (force) console.log(`~ ${name}: recomputing (--force)`);

	const added = await gitAddedAt(name);
	const modified = (await gitModifiedAt(name)) ?? added;

	const firstPublished = laterOf(existing?.firstPublished, added);
	const lastUpdated = laterOf(firstPublished, laterOf(existing?.lastUpdated, modified));

	const entry: PackageMetadata = {
		firstPublished,
		lastUpdated: laterOf(firstPublished, lastUpdated),
		// Only ever true here: nothing in this file was observed live.
		backfilled: true,
	};

	metadata[name] = entry;
	changed++;
	console.log(
		`+ ${name}: firstPublished=${entry.firstPublished} lastUpdated=${entry.lastUpdated} (approximate)`,
	);
}

writeMetadata(metadata);
console.log(
	`\nWrote ${Object.keys(metadata).length} entries to ${metadataFile} (${changed} rebuilt).`,
);
