// Package parse is a fixture parser with a deliberate crash on "{!".
package parse

// Parse returns the length of a brace-delimited payload and panics on "{!".
func Parse(b []byte) int {
	if len(b) == 0 || b[0] != '{' {
		return 0
	}
	if len(b) > 1 && b[1] == '!' {
		panic("fixture crash: bang after brace")
	}
	return len(b)
}
