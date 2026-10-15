// Unbounded context and no counterGraph export: falls back to value-only keys.
import { assign, setup } from "xstate";

export const counterMachine = setup({ types: { context: {} as { n: number } } }).createMachine({
  id: "counter",
  initial: "on",
  context: { n: 0 },
  states: { on: { on: { INC: { actions: assign({ n: ({ context }) => context.n + 1 }) }, OFF: "off" } }, off: { on: { ON: "on" } } },
});
