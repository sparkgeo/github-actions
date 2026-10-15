// Quadkey encode/decode for XYZ tiles, verified once and compiled to Python,
// Go and JavaScript (issue #128). The acceptance criterion is the lemma
// RoundTrip: decoding an encoded tile gives the tile back, for every zoom.
module Quadkey {
  // Opaque: left transparent, the solver unrolls Pow2 inside every
  // quantifier and RoundTrip times out. Pow2Step exposes one level.
  opaque function Pow2(n: nat): nat
  {
    if n == 0 then 1 else 2 * Pow2(n - 1)
  }

  lemma Pow2Step(n: nat)
    ensures Pow2(0) == 1
    ensures n > 0 ==> Pow2(n) == 2 * Pow2(n - 1)
  {
    reveal Pow2();
  }

  predicate IsKey(k: string) {
    forall i :: 0 <= i < |k| ==> k[i] in "0123"
  }

  function Digit(bitX: nat, bitY: nat): char
    requires bitX < 2 && bitY < 2
  {
    if bitX == 0 && bitY == 0 then '0'
    else if bitY == 0 then '1'
    else if bitX == 0 then '2'
    else '3'
  }

  // Manual lemmas: without them RoundTrip times out at 60 s, because the
  // solver will not derive x / 2 < Pow2(zoom - 1) from x < Pow2(zoom), find
  // 2 * (x / 2) + x % 2 == x, or undo Digit on its own. See
  // docs/verification.md, "SMT timeouts".
  lemma HalfBound(x: nat, zoom: nat)
    requires zoom > 0 && x < Pow2(zoom)
    ensures x / 2 < Pow2(zoom - 1)
  {
    Pow2Step(zoom);
  }

  lemma HalfPlusBit(x: nat)
    ensures x % 2 < 2 && x == 2 * (x / 2) + x % 2
  {}

  lemma DigitBits(bitX: nat, bitY: nat)
    requires bitX < 2 && bitY < 2
    ensures var d := Digit(bitX, bitY);
      (if d == '1' || d == '3' then 1 else 0) == bitX && (if d == '2' || d == '3' then 1 else 0) == bitY
  {}

  // One digit per level, most significant first.
  function Encode(x: nat, y: nat, zoom: nat): (k: string)
    requires x < Pow2(zoom) && y < Pow2(zoom)
    ensures |k| == zoom && IsKey(k)
  {
    if zoom == 0 then ""
    else
      HalfBound(x, zoom);
      HalfBound(y, zoom);
      Encode(x / 2, y / 2, zoom - 1) + [Digit(x % 2, y % 2)]
  }

  function Decode(k: string): (t: (nat, nat, nat))
    requires IsKey(k)
    ensures t.2 == |k| && t.0 < Pow2(|k|) && t.1 < Pow2(|k|)
  {
    Pow2Step(|k|);
    if |k| == 0 then (0, 0, 0)
    else
      var p := Decode(k[..|k| - 1]);
      var d := k[|k| - 1];
      var dx: nat := if d == '1' || d == '3' then 1 else 0;
      var dy: nat := if d == '2' || d == '3' then 1 else 0;
      (2 * p.0 + dx, 2 * p.1 + dy, p.2 + 1)
  }

  // The parent key is the key of the parent tile.
  function Parent(k: string): (p: string)
    requires IsKey(k)
    ensures IsKey(p) && |p| == if |k| == 0 then 0 else |k| - 1
  {
    if |k| == 0 then k else k[..|k| - 1]
  }

  lemma RoundTrip(x: nat, y: nat, zoom: nat)
    requires x < Pow2(zoom) && y < Pow2(zoom)
    ensures Decode(Encode(x, y, zoom)) == (x, y, zoom)
  {
    Pow2Step(zoom);  // zoom == 0: x < Pow2(0) == 1, so x == y == 0
    if zoom > 0 {
      HalfBound(x, zoom);
      HalfBound(y, zoom);
      RoundTrip(x / 2, y / 2, zoom - 1);
      var k := Encode(x, y, zoom);
      assert k[..|k| - 1] == Encode(x / 2, y / 2, zoom - 1);
      assert k[|k| - 1] == Digit(x % 2, y % 2);
      HalfPlusBit(x);
      HalfPlusBit(y);
      DigitBits(x % 2, y % 2);
    }
  }

  // Compiled entry point with the round trip stated as a postcondition, so
  // callers in the target languages get the proven contract.
  method EncodeChecked(x: nat, y: nat, zoom: nat) returns (k: string)
    requires x < Pow2(zoom) && y < Pow2(zoom)
    ensures |k| == zoom && IsKey(k) && Decode(k) == (x, y, zoom)
  {
    k := Encode(x, y, zoom);
    RoundTrip(x, y, zoom);
  }
}
