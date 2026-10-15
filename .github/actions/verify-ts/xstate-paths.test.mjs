// Model-based tests for XState machines (verify-ts, issue #127, tier standard).
//
// Copied into the project under test and run with its own vitest, so `xstate`
// and `@xstate/graph` resolve from the project's node_modules. For every
// exported machine in the modules listed in VERIFY_TS_MACHINES (JSON array of
// absolute paths), generate every simple path with @xstate/graph and execute
// it on a fresh actor: the actor must end in the path's state value and
// context, and must not error. Machines with unbounded context (a counter, a
// retry count) need a bound: export `<machineName>Graph` with traversal
// options (`stopWhen`, `events`, `serializeState`) beside the machine.
// Without one, a traversal that exceeds VERIFY_TS_XSTATE_LIMIT states is
// retried keyed on the state value only and reported as "value-only".
// States no path reaches are reported. Results: VERIFY_TS_XSTATE_OUT (JSON).
import { writeFileSync } from "node:fs";
import { getSimplePaths, getStateNodes } from "@xstate/graph";
import { createActor } from "xstate";
import { describe, expect, it } from "vitest";

const modules = JSON.parse(process.env.VERIFY_TS_MACHINES || "[]");
const limit = Number(process.env.VERIFY_TS_XSTATE_LIMIT || "500");
const maxPaths = Number(process.env.VERIFY_TS_XSTATE_MAX_PATHS || "1000");
const out = process.env.VERIFY_TS_XSTATE_OUT || "xstate.json";
const results = [];

const isMachine = (v) =>
  v !== null && typeof v === "object" && typeof v.transition === "function" && v.root !== undefined && v.config !== undefined;

function leafIds(machine) {
  return getStateNodes(machine.root)
    .filter((n) => n.type === "atomic" || n.type === "final")
    .map((n) => n.path.join("."));
}

function valuePaths(value, prefix = []) {
  if (typeof value === "string") return [[...prefix, value].join(".")];
  return Object.entries(value).flatMap(([k, v]) => valuePaths(v, [...prefix, k]));
}

for (const file of modules) {
  const mod = await import(file);
  for (const [name, machine] of Object.entries(mod).filter(([, v]) => isMachine(v))) {
    const opts = mod[`${name}Graph`] ?? {};
    const entry = { file, machine: name, paths: 0, executed: 0, failures: [], bound: opts.stopWhen || opts.serializeState ? "exported" : "context", unreached: [] };
    let paths;
    try {
      paths = getSimplePaths(machine, { limit, ...opts });
    } catch (e) {
      if (!String(e).includes("Traversal limit exceeded")) throw e;
      entry.bound = "value-only";
      paths = getSimplePaths(machine, { limit, ...opts, serializeState: (s) => JSON.stringify(s.value) });
    }
    entry.paths = paths.length;
    const reached = new Set(paths.flatMap((p) => valuePaths(p.state.value)));
    entry.unreached = leafIds(machine).filter((id) => !reached.has(id));
    results.push(entry);
    describe(`${file.split("/").slice(-2).join("/")} ${name}`, () => {
      for (const [i, path] of paths.slice(0, maxPaths).entries()) {
        const label = path.steps.map((s) => s.event.type).filter((t) => !t.startsWith("xstate.")).join(" > ") || "(initial)";
        it(`path ${i}: ${label}`, () => {
          const actor = createActor(machine).start();
          try {
            for (const step of path.steps) if (!step.event.type.startsWith("xstate.")) actor.send(step.event);
            const snap = actor.getSnapshot();
            expect(snap.status).not.toBe("error");
            expect(snap.value).toEqual(path.state.value);
            if (entry.bound !== "value-only") expect(snap.context).toEqual(path.state.context);
            entry.executed++;
          } catch (e) {
            entry.failures.push({ path: label, error: String(e).slice(0, 300) });
            throw e;
          } finally {
            actor.stop();
            writeFileSync(out, JSON.stringify(results, null, 1));
          }
        });
      }
    });
  }
}

writeFileSync(out, JSON.stringify(results, null, 1));
it("machines discovered", () => {
  expect(modules.length).toBeGreaterThanOrEqual(0);
});
