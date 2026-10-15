// A false postcondition: Inc(-1) == 0.
package bad

//@ ensures res > 0
func Inc(x int) (res int) {
	return x + 1
}
