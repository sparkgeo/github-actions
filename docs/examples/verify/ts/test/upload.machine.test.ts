import { createActor } from "xstate";
import { describe, expect, it } from "vitest";

import { uploadMachine } from "../src/upload.machine.js";

describe("uploadMachine", () => {
  it("abandons after three failed attempts", () => {
    const actor = createActor(uploadMachine).start();
    actor.send({ type: "START" });
    for (let i = 0; i < 3; i++) {
      actor.send({ type: "FAIL" });
      actor.send({ type: "RETRY" });
    }
    expect(actor.getSnapshot().value).toBe("abandoned");
  });
});
