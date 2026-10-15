package quadkey

import (
	"testing"

	"pgregory.net/rapid"
)

// FuzzRoundTrip: any key Decode accepts encodes back to itself, and any key
// it rejects is rejected with ErrRange or ErrDigit. Parent never panics.
func FuzzRoundTrip(f *testing.F) {
	for _, seed := range []string{"", "0", "0123", "3333333333", "4", "x"} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, key string) {
		x, y, zoom, err := Decode(key)
		_ = Parent(key)
		if err != nil {
			if err != ErrRange && err != ErrDigit {
				t.Fatalf("Decode(%q): unexpected error %v", key, err)
			}
			return
		}
		got, err := Encode(x, y, zoom)
		if err != nil || got != key {
			t.Fatalf("Encode(Decode(%q)) = %q, %v", key, got, err)
		}
	})
}

// One property per acceptance criterion: the key has one digit per level and
// decodes back to the tile.
func TestEncodeDecodeProperty(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		zoom := rapid.IntRange(0, MaxZoom).Draw(t, "zoom")
		x := rapid.Uint32Range(0, uint32((uint64(1)<<zoom)-1)).Draw(t, "x")
		y := rapid.Uint32Range(0, uint32((uint64(1)<<zoom)-1)).Draw(t, "y")
		key, err := Encode(x, y, zoom)
		if err != nil {
			t.Fatalf("Encode(%d, %d, %d): %v", x, y, zoom, err)
		}
		if len(key) != zoom {
			t.Fatalf("len(%q) = %d, want %d", key, len(key), zoom)
		}
		gx, gy, gz, err := Decode(key)
		if err != nil || gx != x || gy != y || gz != zoom {
			t.Fatalf("Decode(%q) = %d, %d, %d, %v", key, gx, gy, gz, err)
		}
	})
}

func TestEncodeRejectsOutsideGrid(t *testing.T) {
	if _, err := Encode(2, 0, 1); err != ErrRange {
		t.Fatalf("Encode(2, 0, 1) err = %v, want ErrRange", err)
	}
}
