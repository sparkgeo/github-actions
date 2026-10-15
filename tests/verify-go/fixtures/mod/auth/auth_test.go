package auth

import "testing"

func FuzzAllowed(f *testing.F) {
	f.Add("admin")
	f.Fuzz(func(t *testing.T, role string) { _ = Allowed(role) })
}
