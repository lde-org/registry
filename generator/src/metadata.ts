import { readFileSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

export const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
export const metadataFile = join(root, "last-updated.json");

/**
 * Timing metadata recorded for a single package. Both dates come from the
 * registry's own history: when the package's portfile was first added, and when
 * it last changed — which, for a portfile, only happens when a version is
 * added. Nothing is read from the portfile itself.
 */
export interface PackageMetadata {
	/** When the package was first published to the registry. */
	firstPublished: string | null;
	/** When a new version was last added to the package. */
	lastUpdated: string | null;
	/**
	 * True while the dates were reconstructed by the one-off migration
	 * (backfill.ts) rather than recorded as packages were published.
	 */
	backfilled?: boolean;
}

export type Metadata = Record<string, PackageMetadata>;

/**
 * The file's historical shape: a flat package -> ISO timestamp map of "last
 * updated". Normalized on read so an older file keeps working (and keeps its
 * dates) instead of silently losing them; every write uses the object shape.
 */
type LegacyMetadata = Record<string, string | null>;

function isLegacyEntry(value: unknown): value is string | null {
	return value === null || typeof value === "string";
}

export function readMetadata(): Metadata {
	let parsed: unknown;
	try {
		parsed = JSON.parse(readFileSync(metadataFile, "utf8"));
	} catch {
		// No metadata file yet - it is created on first write.
		return {};
	}
	if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};

	const raw = parsed as LegacyMetadata;
	const out: Metadata = {};
	for (const [name, value] of Object.entries(raw)) {
		if (isLegacyEntry(value)) {
			// A flat timestamp map carries no firstPublished, so it is never
			// treated as fully recorded — the migration fills the gap once.
			out[name] = {
				firstPublished: null,
				lastUpdated: normalizeIso(value),
				backfilled: true,
			};
			continue;
		}
		if (value && typeof value === "object") {
			const entry = value as PackageMetadata;
			const normalized: PackageMetadata = {
				firstPublished: normalizeIso(entry.firstPublished),
				lastUpdated: normalizeIso(entry.lastUpdated),
			};
			if (entry.backfilled) normalized.backfilled = true;
			out[name] = normalized;
		}
	}
	return out;
}

export function writeMetadata(metadata: Metadata): string {
	const body = JSON.stringify(sortObject(metadata), null, "\t") + "\n";
	writeFileSync(metadataFile, body);
	return body;
}

/** Keys sorted, tab-indented JSON like the rest of the repo. */
export function sortObject<T>(obj: Record<string, T>): Record<string, T> {
	const sorted: Record<string, T> = {};
	for (const key of Object.keys(obj).sort()) {
		const value = obj[key];
		if (value !== undefined) sorted[key] = value;
	}
	return sorted;
}

/**
 * Canonical ISO 8601 form of a date, in UTC: git hands back commit dates with a
 * local offset, and the file is easier to read (and diff) in one zone.
 * Unparseable input passes through untouched.
 */
export function normalizeIso(date: string | null | undefined): string | null {
	if (typeof date !== "string" || date === "") return null;
	const time = Date.parse(date);
	if (Number.isNaN(time)) return date;
	return new Date(time).toISOString().replace(/\.\d{3}Z$/, "Z");
}

/**
 * The later of two dates, ignoring missing ones. Used so a recorded date can
 * never move backwards, even if the branch it came from is rewritten.
 */
export function laterOf(
	a: string | null | undefined,
	b: string | null | undefined,
): string | null {
	const ta = a ? Date.parse(a) : NaN;
	const tb = b ? Date.parse(b) : NaN;
	if (Number.isNaN(ta)) return normalizeIso(b);
	if (Number.isNaN(tb)) return normalizeIso(a);
	return normalizeIso(ta >= tb ? a : b);
}
