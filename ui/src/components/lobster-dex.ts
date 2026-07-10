// The Lobsterdex: a quiet localStorage log of every lobster palette that has
// ever visited this browser. Purely client-side collection flavor; the pet
// records arrivals and the appearance settings card renders the gallery.
import { getSafeLocalStorage } from "../local-storage.ts";
import type { LobsterPetPaletteId } from "./lobster-pet.ts";

const LOBSTERDEX_KEY = "openclaw.control.lobsterdex.v1";

export function getLobsterdex(): ReadonlySet<string> {
  try {
    const raw = getSafeLocalStorage()?.getItem(LOBSTERDEX_KEY);
    const parsed: unknown = raw ? JSON.parse(raw) : [];
    return new Set(
      Array.isArray(parsed)
        ? parsed.flatMap((value) => (typeof value === "string" && value ? [value] : []))
        : [],
    );
  } catch {
    return new Set();
  }
}

export function recordLobsterVisit(paletteId: LobsterPetPaletteId): void {
  try {
    const seen = new Set(getLobsterdex());
    if (seen.has(paletteId)) {
      return;
    }
    seen.add(paletteId);
    getSafeLocalStorage()?.setItem(LOBSTERDEX_KEY, JSON.stringify([...seen].toSorted()));
  } catch {
    // best-effort — a full or blocked storage must not break visits
  }
}
