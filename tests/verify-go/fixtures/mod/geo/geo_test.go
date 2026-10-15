package geo_test

import (
	"testing"
	"testing/quick"

	"example.com/fixture/geo"
)

func FuzzCovered(f *testing.F) {
	f.Add(1.0)
	f.Fuzz(func(t *testing.T, lat float64) {
		if v := geo.Covered(lat); v > 90 || v < -90 {
			t.Fatal(v)
		}
	})
}

func TestClampProperty(t *testing.T) {
	if err := quick.Check(func(x float64) bool { v := geo.Covered(x); return v <= 90 && v >= -90 }, nil); err != nil {
		t.Fatal(err)
	}
}
