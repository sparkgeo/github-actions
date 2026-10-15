// Package quadkey encodes and decodes XYZ tiles as Bing-style quadkeys.
//
// The acceptance criteria are checked three ways: FuzzRoundTrip (native
// fuzzing, the counterexample search) and a rapid property in
// quadkey_test.go, plus the input validation below at the boundary.
package quadkey

import (
	"errors"
	"strings"
)

// MaxZoom is the deepest level a quadkey may name.
const MaxZoom = 30

// ErrRange is returned for a tile outside the grid at its zoom.
var ErrRange = errors.New("quadkey: tile outside the grid")

// ErrDigit is returned for a key with a character other than 0-3.
var ErrDigit = errors.New("quadkey: digit outside 0-3")

// Encode returns the quadkey of tile (x, y) at zoom.
func Encode(x, y uint32, zoom int) (string, error) {
	if zoom < 0 || zoom > MaxZoom || uint64(x) >= 1<<zoom || uint64(y) >= 1<<zoom {
		return "", ErrRange
	}
	var b strings.Builder
	b.Grow(zoom)
	for i := zoom; i > 0; i-- {
		mask := uint32(1) << (i - 1)
		d := byte('0')
		if x&mask != 0 {
			d++
		}
		if y&mask != 0 {
			d += 2
		}
		b.WriteByte(d)
	}
	return b.String(), nil
}

// Decode returns (x, y, zoom) for a quadkey.
func Decode(key string) (x, y uint32, zoom int, err error) {
	if len(key) > MaxZoom {
		return 0, 0, 0, ErrRange
	}
	zoom = len(key)
	for i := 0; i < zoom; i++ {
		mask := uint32(1) << (zoom - i - 1)
		switch key[i] {
		case '0':
		case '1':
			x |= mask
		case '2':
			y |= mask
		case '3':
			x |= mask
			y |= mask
		default:
			return 0, 0, 0, ErrDigit
		}
	}
	return x, y, zoom, nil
}

// Parent returns the key one level up; the root's parent is the root.
func Parent(key string) string {
	if key == "" {
		return ""
	}
	return key[:len(key)-1]
}
