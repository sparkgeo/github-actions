// Consumer test: the browser bundle uses the Dafny-compiled quadkey core.
// Dafny's JavaScript backend emits a script, not a module, so it is wrapped
// once here to return the Quadkey namespace. Not generated (the drift check
// allows extra files); run with `npm test`.
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");

const src = readFileSync(path.join(__dirname, "quadkey.js"), "utf8");
// eslint-disable-next-line no-new-func -- loading generated code we commit and review
const { Quadkey, _dafny } = new Function("require", `${src}\nreturn { Quadkey, _dafny };`)(require);
const BigNumber = require("bignumber.js");
const n = (v) => new BigNumber(v);
const text = (seq) => [...seq].map((c) => String.fromCodePoint(c.value)).join("");

test("encode", () => {
  assert.equal(text(Quadkey.__default.EncodeChecked(n(3), n(5), n(3))), "213");
});

test("round trip", () => {
  for (let zoom = 0; zoom < 6; zoom++) {
    for (let x = 0; x < 2 ** zoom; x++) {
      for (let y = 0; y < 2 ** zoom; y += 3) {
        const key = Quadkey.__default.EncodeChecked(n(x), n(y), n(zoom));
        const [dx, dy, dz] = Quadkey.__default.Decode(key);
        assert.deepEqual([dx.toNumber(), dy.toNumber(), dz.toNumber()], [x, y, zoom]);
      }
    }
  }
});

test("runtime loaded", () => {
  assert.ok(_dafny);
});
