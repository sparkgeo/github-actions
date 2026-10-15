import { createMachine } from "xstate";

export const doorMachine = createMachine({
  id: "door",
  initial: "closed",
  states: {
    closed: { on: { OPEN: "open", LOCK: "locked" } },
    open: { on: { CLOSE: "closed" } },
    locked: { on: { UNLOCK: "closed" } },
  },
});
