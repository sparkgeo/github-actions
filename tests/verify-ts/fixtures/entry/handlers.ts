// Entry-point fixture: one validated, one unvalidated, one typed, one untyped arrow.
import { z } from "zod";

const Body = z.object({ name: z.string() });

export function createValidated(body: unknown): string {
  return Body.parse(body).name;
}

export function createUnvalidated(body: unknown): string {
  return String((body as { name: string }).name);
}

export function typed(n: number): number {
  return n + 1;
}

export const untypedArrow = (payload: any) => payload;

export const safeArrow = (payload: unknown) => Body.safeParse(payload).success;

function internal(x: unknown): unknown {
  return x;
}

export type Brand = string & { readonly __brand: "Id" };
export const used = internal;
