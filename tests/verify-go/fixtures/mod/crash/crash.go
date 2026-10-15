// Package crash panics on a short prefix the fuzzer finds within seconds.
package crash

// Parse rejects nothing and panics on "bad".
func Parse(s string) int {
	if len(s) >= 3 && s[0] == 'b' && s[1] == 'a' && s[2] == 'd' {
		panic("bad input")
	}
	return len(s)
}
