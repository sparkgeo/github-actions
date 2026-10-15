// An entry action throws on one path, and `orphan` has no transition into it.
import { createMachine } from "xstate";

export const jobMachine = createMachine({
  id: "job",
  initial: "queued",
  states: {
    queued: { on: { RUN: "running" } },
    running: { on: { CRASH: "crashed", FINISH: "finished" } },
    crashed: {
      entry: () => {
        throw new Error("crash handler not implemented");
      },
    },
    finished: { type: "final" },
    orphan: {},
  },
});
