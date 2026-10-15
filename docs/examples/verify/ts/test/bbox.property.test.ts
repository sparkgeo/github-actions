import fc from "fast-check";
import { describe, expect, it } from "vitest";

import { crossesAntimeridian, normalizeBbox, splitAtAntimeridian, wrapLongitude } from "../src/bbox.js";

const lon = fc.double({ min: -180, max: 180, noNaN: true });
const lat = fc.double({ min: -90, max: 90, noNaN: true });
const rawBbox = fc.tuple(lon, lat, lon, lat);

describe("normalizeBbox", () => {
  it("keeps every longitude in [-180, 180] and orders the latitudes", () => {
    fc.assert(
      fc.property(rawBbox, (raw) => {
        const [w, s, e, n] = normalizeBbox(raw);
        expect(w).toBeGreaterThanOrEqual(-180);
        expect(w).toBeLessThanOrEqual(180);
        expect(e).toBeGreaterThanOrEqual(-180);
        expect(e).toBeLessThanOrEqual(180);
        expect(s).toBeLessThanOrEqual(n);
      }),
    );
  });

  it("is idempotent", () => {
    fc.assert(
      fc.property(rawBbox, (raw) => {
        const once = normalizeBbox(raw);
        expect(normalizeBbox(once)).toEqual(once);
      }),
    );
  });

  it("rejects input outside the degree ranges at the boundary", () => {
    fc.assert(
      fc.property(fc.double({ min: 180.5, max: 1e6, noNaN: true }), lat, lon, lat, (bad, s, e, n) => {
        expect(() => normalizeBbox([bad, s, e, n])).toThrow();
      }),
    );
  });
});

describe("splitAtAntimeridian", () => {
  it("returns boxes that never cross, covering the same longitudes", () => {
    fc.assert(
      fc.property(rawBbox, (raw) => {
        const bbox = normalizeBbox(raw);
        const parts = splitAtAntimeridian(bbox);
        for (const p of parts) expect(crossesAntimeridian(p)).toBe(false);
        expect(parts.length).toBe(crossesAntimeridian(bbox) ? 2 : 1);
      }),
    );
  });
});

describe("wrapLongitude", () => {
  it("is a no-op on values already in range", () => {
    fc.assert(
      fc.property(lon, (x) => {
        expect(wrapLongitude(x)).toBe(x);
      }),
    );
  });

  it("lands in [-180, 180] for any finite longitude", () => {
    fc.assert(
      fc.property(fc.double({ min: -1e6, max: 1e6, noNaN: true }), (x) => {
        const w = wrapLongitude(x);
        expect(w).toBeGreaterThanOrEqual(-180);
        expect(w).toBeLessThanOrEqual(180);
      }),
    );
  });
});
