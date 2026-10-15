/-- A false statement: no proof exists, so the build fails with an error. -/
theorem off_by_one (n : Nat) : n + 1 = n := by
  omega
