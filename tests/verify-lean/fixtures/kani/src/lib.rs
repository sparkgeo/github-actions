//! Kani fixture (issue #131): `quadkey_len` is proven panic-free with the
//! right length for every zoom up to 30; `tile_index` overflows for large
//! zooms, which Kani reports as a failed harness.

/// Number of quadkey digits for a zoom level, clamped to 30.
pub fn quadkey_len(zoom: u8) -> usize {
    usize::from(zoom.min(30))
}

/// Linear index of tile (x, y) at a zoom: y * 2^zoom + x. Overflows u32 when
/// zoom > 16 and y is large: the bug the failing harness finds.
pub fn tile_index(x: u32, y: u32, zoom: u8) -> u32 {
    y * (1u32 << zoom) + x
}

#[cfg(kani)]
mod proofs {
    use super::*;

    #[kani::proof]
    fn quadkey_len_bounded() {
        let zoom: u8 = kani::any();
        let n = quadkey_len(zoom);
        assert!(n <= 30);
        assert!(zoom > 30 || n == usize::from(zoom));
    }

    #[kani::proof]
    fn tile_index_no_overflow() {
        let zoom: u8 = kani::any();
        kani::assume(zoom <= 30);
        let x: u32 = kani::any();
        let y: u32 = kani::any();
        kani::assume(x < (1u32 << zoom) && y < (1u32 << zoom));
        let _ = tile_index(x, y, zoom);
    }
}
