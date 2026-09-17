import { readdirSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { readMetadata, type Metadata } from "./metadata";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "../..");

const packagesDir = join(root, "packages");
const outputDir = join(__dirname, "../dist");
const outputFile = join(outputDir, "index.json");

interface Package {
	name: string;
	description?: string;
	authors?: string[];
	git: string;
	versions?: Record<string, string>;
}

interface IndexEntry {
	name: string;
	description: string | null;
	authors: string[];
	latest: string | null;
	git: string;
	/** When a new version was last added to this package. */
	lastUpdated: string | null;
	/** When this package was first published to the registry. */
	firstPublished: string | null;
	/** True when the dates are estimates reconstructed from git history. */
	approximate?: true;
}

interface MetadataEntry {
	firstPublished?: string | null;
	lastUpdated?: string | null;
	backfilled?: boolean;
}

/** Highest semver, so `latest` never depends on key order in the portfile. */
function latestVersion(versions: Record<string, string> | undefined): string | null {
	const parse = (v: string) => v.split(".").map((n) => Number(n) || 0);
	let latest: string | null = null;
	for (const version of Object.keys(versions ?? {})) {
		if (latest === null) {
			latest = version;
			continue;
		}
		const [a1 = 0, a2 = 0, a3 = 0] = parse(version);
		const [b1 = 0, b2 = 0, b3 = 0] = parse(latest);
		if (
			a1 > b1 ||
			(a1 === b1 && a2 > b2) ||
			(a1 === b1 && a2 === b2 && a3 > b3)
		) {
			latest = version;
		}
	}
	return latest;
}

// last-updated.json is the registry's centralized package metadata file: when
// each package was first published and when it was last updated (a new version
// was added). It is maintained by the bot (record-metadata.ts, with the one-off
// migration in backfill.ts) from this repo's own history.
//
// This generator only reads that file: it never runs git, so a build can't
// invent a date, and it works from a shallow checkout.
const metadata: Metadata = readMetadata();

const files = readdirSync(packagesDir, { recursive: true })
	.filter((f): f is string => typeof f === "string")
	.filter((f) => f.endsWith(".json"));

const index: IndexEntry[] = files.map((f) => {
	const filePath = join(packagesDir, f);
	const pkg: Package = JSON.parse(readFileSync(filePath, "utf8"));
	const meta = metadata[pkg.name] as MetadataEntry | undefined;

	const entry: IndexEntry = {
		name: pkg.name,
		description: pkg.description ?? null,
		authors: pkg.authors ?? [],
		latest: latestVersion(pkg.versions),
		git: pkg.git,
		lastUpdated: meta?.lastUpdated ?? null,
		firstPublished: meta?.firstPublished ?? null,
	};
	if (meta?.backfilled) entry.approximate = true;

	return entry;
});

// Newest first, so a client that only wants recent activity can read the head
// of the file. Packages without a date sort last, alphabetically.
index.sort((a, b) => {
	const ta = a.lastUpdated ? Date.parse(a.lastUpdated) || 0 : 0;
	const tb = b.lastUpdated ? Date.parse(b.lastUpdated) || 0 : 0;
	if (tb !== ta) return tb - ta;
	return a.name.localeCompare(b.name);
});

mkdirSync(outputDir, { recursive: true });
writeFileSync(outputFile, JSON.stringify(index));

const missing = index.filter((e) => !e.lastUpdated).length;
console.log(
	`Wrote ${index.length} packages to index.json` +
		(missing ? ` (${missing} without metadata — run backfill?)` : ""),
);
