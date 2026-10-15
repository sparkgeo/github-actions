import Mathlib

/-!
# XYZ tile column of a longitude (issue #131)

`tileX z lon` is the Web Mercator / XYZ tile column that contains longitude
`lon` (degrees) at zoom `z`. The acceptance criterion is `tileX_mem`: every
longitude in `[-180, 180)` lands in a column that exists, `0 ≤ x < 2 ^ z`.
A reviewer checks that this theorem says what the criterion says; the
kernel checks the proof. `lake build --wfail` fails on any `sorry`.
-/

namespace Tiles

/-- Tile column of longitude `lon` at zoom `z`. -/
noncomputable def tileX (z : ℕ) (lon : ℝ) : ℤ :=
  ⌊(lon + 180) / 360 * 2 ^ z⌋

/-- Every longitude in `[-180, 180)` maps to an existing column at zoom `z`. -/
theorem tileX_mem (z : ℕ) (lon : ℝ) (h₁ : -180 ≤ lon) (h₂ : lon < 180) :
    0 ≤ tileX z lon ∧ tileX z lon < 2 ^ z := by
  have hp : (0 : ℝ) < 2 ^ z := by positivity
  have hfrac : (lon + 180) / 360 < 1 := by
    rw [div_lt_one (by norm_num)]
    linarith
  refine ⟨?_, ?_⟩
  · unfold tileX
    apply Int.floor_nonneg.mpr
    have : 0 ≤ lon + 180 := by linarith
    positivity
  · unfold tileX
    rw [Int.floor_lt]
    push_cast
    calc (lon + 180) / 360 * 2 ^ z < 1 * 2 ^ z := by gcongr
      _ = 2 ^ z := one_mul _

/-- Moving east by one column width moves the column by exactly one. -/
theorem tileX_add_width (z : ℕ) (lon : ℝ) :
    tileX z (lon + 360 / 2 ^ z) = tileX z lon + 1 := by
  unfold tileX
  have hp : (2 : ℝ) ^ z ≠ 0 := by positivity
  have : (lon + 360 / 2 ^ z + 180) / 360 * 2 ^ z = (lon + 180) / 360 * 2 ^ z + 1 := by
    field_simp
    ring
  rw [this, Int.floor_add_one]

end Tiles
