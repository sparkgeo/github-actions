// Package orient: the orientation predicate behind segment intersection,
// point-in-polygon and convex hulls, with Gobra pre- and postconditions
// (issue #129). Gobra discharges them through Viper and Z3; go build ignores
// the //@ annotations.
package orient

// Cross is the z component of (b - a) x (c - a): twice the signed area of
// the triangle a, b, c.
//@ decreases
//@ pure
func Cross(x1, y1, x2, y2, x3, y3 int) int {
	return (x2-x1)*(y3-y1) - (y2-y1)*(x3-x1)
}

// Orient is 1 when a, b, c turn counter-clockwise, -1 when clockwise and 0
// when collinear.
//@ ensures res == -1 || res == 0 || res == 1
//@ ensures (res == 1) == (Cross(x1, y1, x2, y2, x3, y3) > 0)
//@ ensures (res == -1) == (Cross(x1, y1, x2, y2, x3, y3) < 0)
func Orient(x1, y1, x2, y2, x3, y3 int) (res int) {
	d := Cross(x1, y1, x2, y2, x3, y3)
	if d > 0 {
		return 1
	}
	if d < 0 {
		return -1
	}
	return 0
}

// SwapReverses is a lemma (no body to run): swapping b and c negates the
// cross product, so by Orient's postconditions the orientation flips.
//@ ensures Cross(x1, y1, x3, y3, x2, y2) == -Cross(x1, y1, x2, y2, x3, y3)
func SwapReverses(x1, y1, x2, y2, x3, y3 int) {}

// Clamp keeps v inside [lo, hi].
//@ requires lo <= hi
//@ ensures lo <= res && res <= hi
//@ ensures (lo <= v && v <= hi) ==> res == v
func Clamp(v, lo, hi int) (res int) {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
