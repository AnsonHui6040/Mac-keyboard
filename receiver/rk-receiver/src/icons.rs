//! The three tray icons, drawn in code so the program needs no art files: green disc (connected), grey ring (waiting),
//! orange disc with an exclamation mark (needs attention).

use crate::ui::IconState;

/// Edge length of the generated icons.
pub const SIZE: usize = 32;

const GREEN: [u8; 3] = [0x2E, 0xA0, 0x43];
const GREY: [u8; 3] = [0x8A, 0x8F, 0x98];
const ORANGE: [u8; 3] = [0xE0, 0x7B, 0x00];
const WHITE: [u8; 3] = [0xFF, 0xFF, 0xFF];

/// Alpha 0..=255 for a pixel at `distance` from the centre of a shape with the given radius (one pixel of anti-aliasing).
fn coverage(distance: f32, radius: f32) -> u8 {
    ((radius + 0.5 - distance).clamp(0.0, 1.0) * 255.0) as u8
}

/// `SIZE * SIZE * 4` bytes of RGBA, top row first.
pub fn rgba(state: IconState) -> Vec<u8> {
    let centre = (SIZE as f32 - 1.0) / 2.0;
    let mut out = Vec::with_capacity(SIZE * SIZE * 4);
    for y in 0..SIZE {
        for x in 0..SIZE {
            let (dx, dy) = (x as f32 - centre, y as f32 - centre);
            let distance = (dx * dx + dy * dy).sqrt();
            let (rgb, alpha) = match state {
                IconState::Connected => (GREEN, coverage(distance, 14.0)),
                IconState::Disconnected => {
                    // A ring: the disc minus a smaller disc.
                    let outer = coverage(distance, 14.0);
                    let hole = coverage(distance, 9.0);
                    (GREY, outer.saturating_sub(hole))
                }
                IconState::Attention => {
                    let bar = dx.abs() <= 2.0 && (-8.0..=3.0).contains(&dy);
                    let dot = dx.abs() <= 2.0 && (6.0..=10.0).contains(&dy);
                    let disc = coverage(distance, 14.0);
                    if bar || dot {
                        (WHITE, disc)
                    } else {
                        (ORANGE, disc)
                    }
                }
            };
            out.extend_from_slice(&[rgb[0], rgb[1], rgb[2], alpha]);
        }
    }
    out
}

/// A `.ico` file with the icon as one uncompressed 32-bit image.
pub fn ico(state: IconState) -> Vec<u8> {
    let pixels = rgba(state);
    let size = SIZE as u32;
    let mask_row = size.div_ceil(32) * 4;
    let image_bytes = 40 + size * size * 4 + mask_row * size;
    let mut out = Vec::new();
    // ICONDIR and one ICONDIRENTRY.
    out.extend_from_slice(&[0, 0, 1, 0, 1, 0]);
    out.extend_from_slice(&[SIZE as u8, SIZE as u8, 0, 0, 1, 0, 32, 0]);
    out.extend_from_slice(&image_bytes.to_le_bytes());
    out.extend_from_slice(&22u32.to_le_bytes());
    // BITMAPINFOHEADER: the height counts the AND mask too.
    out.extend_from_slice(&40u32.to_le_bytes());
    out.extend_from_slice(&size.to_le_bytes());
    out.extend_from_slice(&(size * 2).to_le_bytes());
    out.extend_from_slice(&[1, 0, 32, 0]);
    out.extend_from_slice(&[0; 24]);
    // Pixels bottom row first, as BGRA.
    for row in pixels.chunks(SIZE * 4).rev() {
        for px in row.chunks(4) {
            out.extend_from_slice(&[px[2], px[1], px[0], px[3]]);
        }
    }
    out.extend(std::iter::repeat_n(0u8, (mask_row * size) as usize));
    out
}

/// File names of the committed assets.
pub fn asset_name(state: IconState) -> &'static str {
    match state {
        IconState::Connected => "connected.ico",
        IconState::Disconnected => "disconnected.ico",
        IconState::Attention => "attention.ico",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [IconState; 3] = [IconState::Connected, IconState::Disconnected, IconState::Attention];

    fn pixel(data: &[u8], x: usize, y: usize) -> [u8; 4] {
        let i = (y * SIZE + x) * 4;
        [data[i], data[i + 1], data[i + 2], data[i + 3]]
    }

    #[test]
    fn every_icon_is_a_square_with_transparent_corners() {
        for state in ALL {
            let data = rgba(state);
            assert_eq!(data.len(), SIZE * SIZE * 4);
            assert_eq!(pixel(&data, 0, 0)[3], 0, "{state:?}");
            assert_eq!(pixel(&data, SIZE - 1, SIZE - 1)[3], 0, "{state:?}");
        }
    }

    #[test]
    fn the_three_states_look_different() {
        let (a, b, c) = (rgba(IconState::Connected), rgba(IconState::Disconnected), rgba(IconState::Attention));
        assert_ne!(a, b);
        assert_ne!(b, c);
        assert_ne!(a, c);
        assert_eq!(pixel(&a, SIZE / 2, SIZE / 2)[3], 255, "connected is a filled disc");
        assert_eq!(pixel(&b, SIZE / 2, SIZE / 2)[3], 0, "waiting is a ring");
    }

    #[test]
    fn ico_has_the_directory_and_the_declared_image_size() {
        let data = ico(IconState::Connected);
        assert_eq!(&data[..6], &[0, 0, 1, 0, 1, 0]);
        let declared = u32::from_le_bytes(data[14..18].try_into().unwrap()) as usize;
        assert_eq!(data.len(), 22 + declared);
    }

    #[test]
    fn committed_assets_match_the_generator() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("assets");
        for state in ALL {
            let path = dir.join(asset_name(state));
            if std::env::var_os("RK_WRITE_ASSETS").is_some() {
                std::fs::create_dir_all(&dir).unwrap();
                std::fs::write(&path, ico(state)).unwrap();
            }
            assert_eq!(std::fs::read(&path).unwrap_or_default(), ico(state), "{} is out of date: run with RK_WRITE_ASSETS=1", path.display());
        }
    }
}
