package parse

import "testing"

func FuzzParse(f *testing.F) {
	f.Add([]byte("{}"))
	f.Fuzz(func(t *testing.T, b []byte) {
		Parse(b)
	})
}

func FuzzClean(f *testing.F) {
	f.Add([]byte("ok"))
	f.Fuzz(func(t *testing.T, b []byte) {
		_ = len(b)
	})
}
