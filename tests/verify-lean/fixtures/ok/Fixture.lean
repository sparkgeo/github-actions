/-- Quadkey length is the zoom: a core-Lean proof (no Mathlib), for the fixture. -/
def digits : Nat → List Nat
  | 0 => []
  | n + 1 => 0 :: digits n

theorem digits_length (n : Nat) : (digits n).length = n := by
  induction n with
  | zero => rfl
  | succ n ih => simp [digits, ih]
