// Consumer test: the Go worker uses the Dafny-compiled quadkey core. Not
// generated (the drift check allows extra files); run with `go test ./...`.
package quadkey_test

import (
	"testing"

	"example.com/verify/dafny/quadkey/Quadkey"
	_dafny "github.com/dafny-lang/DafnyRuntimeGo/v4/dafny"
)

func TestEncode(t *testing.T) {
	key := Quadkey.Companion_Default___.EncodeChecked(_dafny.IntOf(3), _dafny.IntOf(5), _dafny.IntOf(3))
	if got := _dafny.SequenceVerbatimString(key, false); got != "213" {
		t.Fatalf("EncodeChecked(3, 5, 3) = %q, want 213", got)
	}
}

func TestRoundTrip(t *testing.T) {
	for zoom := 0; zoom < 6; zoom++ {
		for x := 0; x < 1<<zoom; x++ {
			for y := 0; y < 1<<zoom; y += 3 {
				key := Quadkey.Companion_Default___.EncodeChecked(_dafny.IntOf(x), _dafny.IntOf(y), _dafny.IntOf(zoom))
				got := Quadkey.Companion_Default___.Decode(key)
				want := _dafny.TupleOf(_dafny.IntOf(x), _dafny.IntOf(y), _dafny.IntOf(zoom))
				if !got.Equals(want) {
					t.Fatalf("Decode(EncodeChecked(%d, %d, %d)) = %v", x, y, zoom, got)
				}
			}
		}
	}
}
