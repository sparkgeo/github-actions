package crash

import "testing"

func FuzzParse(f *testing.F) {
	f.Add("ba")
	f.Fuzz(func(t *testing.T, s string) { _ = Parse(s) })
}
