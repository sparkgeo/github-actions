/**
 * Upload lifecycle as an XState machine. At tier standard verify-ts generates
 * every simple path with @xstate/graph and executes it against this machine.
 */
import { assign, setup } from "xstate";

export const uploadMachine = setup({
  types: {
    context: {} as { attempts: number },
    events: {} as { type: "START" } | { type: "DONE" } | { type: "FAIL" } | { type: "RETRY" } | { type: "CANCEL" },
  },
  guards: {
    canRetry: ({ context }) => context.attempts < 3,
  },
}).createMachine({
  id: "upload",
  initial: "idle",
  context: { attempts: 0 },
  states: {
    idle: { on: { START: "uploading" } },
    uploading: {
      entry: assign({ attempts: ({ context }) => context.attempts + 1 }),
      on: { DONE: "done", FAIL: "failed", CANCEL: "idle" },
    },
    failed: {
      on: {
        RETRY: [{ guard: "canRetry", target: "uploading" }, { target: "abandoned" }],
        CANCEL: "idle",
      },
    },
    done: { type: "final" },
    abandoned: { type: "final" },
  },
});

/**
 * Traversal bound for @xstate/graph: `attempts` grows on every START, so the
 * context-keyed state space is unbounded without it. One past the guard's
 * limit keeps `abandoned` reachable.
 */
export const uploadMachineGraph = {
  stopWhen: (state: { context: { attempts: number } }) => state.context.attempts > 3,
};
