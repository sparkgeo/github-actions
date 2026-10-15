// Package geo: Covered is called by a fuzz target, Uncovered is not.
package geo

// Covered clamps a latitude.
func Covered(lat float64) float64 {
	if lat > 90 {
		return 90
	}
	if lat < -90 {
		return -90
	}
	return lat
}

// Uncovered has no fuzz target.
func Uncovered(lon float64) float64 { return lon }

func unexported() {}
