/**
 * Antimeridian-safe bbox normalisation (issue #127 example).
 *
 * A `Degrees` value is a number the boundary has checked; the brand keeps an
 * unchecked number out of the functions below at compile time. `BboxSchema`
 * is the boundary contract: `normalizeBbox` accepts only what it parsed. The
 * acceptance criteria are fast-check properties in test/bbox.property.test.ts:
 * the result's longitudes stay in [-180, 180], the west edge is never east of
 * the east edge unless the box crosses the antimeridian, and normalising twice
 * is the same as normalising once.
 */
import { z } from "zod";

export type Degrees = number & { readonly __brand: "Degrees" };

export const Longitude = z.number().min(-180).max(180).brand<"Degrees">();
export const Latitude = z.number().min(-90).max(90).brand<"Degrees">();

export const BboxSchema = z.tuple([Longitude, Latitude, Longitude, Latitude]);

export type Bbox = readonly [west: Degrees, south: Degrees, east: Degrees, north: Degrees];

/**
 * Wrap a longitude into [-180, 180]. In-range values come back unchanged (180
 * stays 180 so a box ending at the antimeridian keeps its edge, and -0 stays
 * -0: the fast-check property found the arithmetic path turning it into 0).
 */
export function wrapLongitude(lon: number): Degrees {
  if (lon >= -180 && lon <= 180) return lon as Degrees;
  const wrapped = ((((lon + 180) % 360) + 360) % 360) - 180;
  return wrapped as Degrees;
}

/** True when the box crosses the antimeridian, i.e. its west edge sits east of its east edge. */
export function crossesAntimeridian(bbox: Bbox): boolean {
  return bbox[0] > bbox[2];
}

/**
 * Parse an untrusted `[west, south, east, north]` and return it with the
 * longitudes wrapped and south <= north. Input outside the degree ranges is
 * rejected at the boundary.
 */
export function normalizeBbox(input: unknown): Bbox {
  const [west, south, east, north] = BboxSchema.parse(input);
  const s = Math.min(south, north) as Degrees;
  const n = Math.max(south, north) as Degrees;
  return [wrapLongitude(west), s, wrapLongitude(east), n];
}

/** Split a box that crosses the antimeridian into two that do not. */
export function splitAtAntimeridian(bbox: Bbox): readonly Bbox[] {
  if (!crossesAntimeridian(bbox)) return [bbox];
  const [west, south, east, north] = bbox;
  return [
    [west, south, 180 as Degrees, north],
    [-180 as Degrees, south, east, north],
  ];
}
