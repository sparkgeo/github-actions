// A postcondition calling an impure function: Gobra rejects it at type check.
package purity

func Twice(x int) int { return 2 * x }

//@ ensures res == Twice(x)
func Double(x int) (res int) { return x + x }
