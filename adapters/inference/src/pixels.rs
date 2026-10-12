//! Buffer, colour and alpha conversion at the LensWorks/inference boundary.
//!
//! The inference contracts carry tightly packed 8-bit sRGB pixels: `Image` is RGB and
//! `RgbaImage` is RGBA with **straight** alpha. Native callers hand the adapter strided
//! buffers in either straight or premultiplied alpha; everything is normalised here, once,
//! into owned tightly packed straight-alpha copies. Nothing in the adapter keeps a caller
//! pointer past the call that supplied it.

use runtime_macos::gen_core::{Image, RgbaImage};

/// Colour space tag for every 8-bit buffer crossing this ABI. Only sRGB is accepted or
/// produced: the inference models are trained on and emit sRGB-encoded 8-bit pixels, so a
/// caller holding any other space converts (colour-managed) before calling.
pub const COLOR_SPACE_SRGB: u32 = 1;

pub const ALPHA_NONE: u32 = 0;
pub const ALPHA_STRAIGHT: u32 = 1;
pub const ALPHA_PREMULTIPLIED: u32 = 2;

/// Upper bound on a single input dimension; far above any model input, small enough that
/// `width * height * 4` cannot overflow.
pub const MAX_EDGE: u32 = 32_768;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Alpha {
    None,
    Straight,
}

/// An owned, tightly packed, straight-alpha sRGB image with 1 (gray/mask), 3 (RGB) or 4
/// (RGBA) channels.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostImage {
    pub width: u32,
    pub height: u32,
    pub channels: u32,
    pub pixels: Vec<u8>,
}

/// Borrowed description of a caller buffer (the C struct, already null-checked).
#[derive(Clone, Copy, Debug)]
pub struct BufferDesc<'a> {
    pub bytes: &'a [u8],
    pub width: u32,
    pub height: u32,
    pub row_bytes: u32,
    pub channels: u32,
    pub alpha: u32,
    pub color_space: u32,
}

impl HostImage {
    pub fn alpha(&self) -> Alpha {
        if self.channels == 4 {
            Alpha::Straight
        } else {
            Alpha::None
        }
    }

    /// Validate and copy a caller buffer, removing row padding and converting premultiplied
    /// alpha to straight alpha.
    pub fn ingest(desc: BufferDesc<'_>) -> Result<Self, String> {
        if desc.color_space != COLOR_SPACE_SRGB {
            return Err(format!(
                "input color space {} is not sRGB; convert to sRGB before calling",
                desc.color_space
            ));
        }
        if desc.width == 0 || desc.height == 0 || desc.width > MAX_EDGE || desc.height > MAX_EDGE {
            return Err(format!(
                "input size {}x{} is outside 1..={MAX_EDGE}",
                desc.width, desc.height
            ));
        }
        let channels = desc.channels;
        match (channels, desc.alpha) {
            (1 | 3, ALPHA_NONE) | (4, ALPHA_STRAIGHT | ALPHA_PREMULTIPLIED) => {}
            (4, ALPHA_NONE) => {
                return Err(
                    "a 4-channel input must declare straight or premultiplied alpha".into(),
                );
            }
            _ => {
                return Err(format!(
                    "unsupported input layout: {channels} channels with alpha mode {}",
                    desc.alpha
                ));
            }
        }
        let packed = desc.width as usize * channels as usize;
        let row_bytes = desc.row_bytes as usize;
        if row_bytes < packed {
            return Err(format!(
                "row_bytes {row_bytes} is smaller than width*channels {packed}"
            ));
        }
        let needed = row_bytes * (desc.height as usize - 1) + packed;
        if desc.bytes.len() < needed {
            return Err(format!(
                "input buffer holds {} bytes; {needed} required",
                desc.bytes.len()
            ));
        }
        let mut pixels = Vec::with_capacity(packed * desc.height as usize);
        for row in 0..desc.height as usize {
            pixels.extend_from_slice(&desc.bytes[row * row_bytes..row * row_bytes + packed]);
        }
        if channels == 4 && desc.alpha == ALPHA_PREMULTIPLIED {
            unpremultiply_in_place(&mut pixels);
        }
        Ok(Self {
            width: desc.width,
            height: desc.height,
            channels,
            pixels,
        })
    }

    /// The RGB view a provider that only accepts RGB receives. RGBA is composited over
    /// white — the inference contract's own flattening rule (`RgbaImage::to_rgb_over_white`)
    /// — and gray is replicated to three channels.
    pub fn to_rgb(&self) -> Image {
        let pixels = match self.channels {
            3 => self.pixels.clone(),
            1 => self.pixels.iter().flat_map(|&v| [v, v, v]).collect(),
            _ => {
                let mut out = Vec::with_capacity(self.pixels.len() / 4 * 3);
                for px in self.pixels.chunks_exact(4) {
                    let a = f32::from(px[3]) / 255.0;
                    for &c in &px[..3] {
                        out.push((f32::from(c) * a + 255.0 * (1.0 - a)).round() as u8);
                    }
                }
                out
            }
        };
        Image {
            width: self.width,
            height: self.height,
            pixels,
        }
    }

    /// Straight-alpha RGBA view; opaque sources get `A = 255`.
    pub fn to_rgba(&self) -> RgbaImage {
        let pixels = match self.channels {
            4 => self.pixels.clone(),
            3 => self
                .pixels
                .chunks_exact(3)
                .flat_map(|p| [p[0], p[1], p[2], 255])
                .collect(),
            _ => self.pixels.iter().flat_map(|&v| [v, v, v, 255]).collect(),
        };
        RgbaImage {
            width: self.width,
            height: self.height,
            pixels,
        }
    }

    pub fn from_rgb(image: Image) -> Result<Self, String> {
        let want = image.width as usize * image.height as usize * 3;
        if image.width == 0 || image.height == 0 || image.pixels.len() != want {
            return Err(format!(
                "provider returned a malformed RGB image ({}x{}, {} bytes)",
                image.width,
                image.height,
                image.pixels.len()
            ));
        }
        Ok(Self {
            width: image.width,
            height: image.height,
            channels: 3,
            pixels: image.pixels,
        })
    }

    pub fn from_rgba(image: RgbaImage) -> Result<Self, String> {
        image
            .validate()
            .map_err(|e| format!("provider returned a malformed RGBA image: {e}"))?;
        Ok(Self {
            width: image.width,
            height: image.height,
            channels: 4,
            pixels: image.pixels,
        })
    }

    pub fn mask(width: u32, height: u32, pixels: Vec<u8>) -> Result<Self, String> {
        if width == 0 || height == 0 || pixels.len() != width as usize * height as usize {
            return Err(format!(
                "malformed mask ({width}x{height}, {} bytes)",
                pixels.len()
            ));
        }
        Ok(Self {
            width,
            height,
            channels: 1,
            pixels,
        })
    }

    pub fn row_bytes(&self) -> u32 {
        self.width * self.channels
    }
}

/// Premultiplied → straight, rounding to nearest. `A = 0` yields black: a fully transparent
/// premultiplied pixel carries no recoverable colour.
pub fn unpremultiply_in_place(rgba: &mut [u8]) {
    for px in rgba.chunks_exact_mut(4) {
        let a = u32::from(px[3]);
        if a == 0 {
            px[..3].fill(0);
        } else if a < 255 {
            for c in &mut px[..3] {
                *c = ((u32::from(*c) * 255 + a / 2) / a).min(255) as u8;
            }
        }
    }
}

/// Straight → premultiplied, rounding to nearest.
pub fn premultiply_in_place(rgba: &mut [u8]) {
    for px in rgba.chunks_exact_mut(4) {
        let a = u32::from(px[3]);
        if a < 255 {
            for c in &mut px[..3] {
                *c = ((u32::from(*c) * a + 127) / 255) as u8;
            }
        }
    }
}

/// Resize a binary/soft mask grid (values in 0..=1 as f32) to `dst_w`×`dst_h` with bilinear
/// sampling (half-pixel centres) and threshold at 0.5. Used to map SAM3's fixed 288² mask
/// grid back onto the source pixel grid (SAM3 squashes the frame to a square, so the grid
/// maps to the full normalised frame on each axis independently).
pub fn resize_binary_mask(
    src: &[f32],
    src_w: usize,
    src_h: usize,
    dst_w: u32,
    dst_h: u32,
) -> Vec<u8> {
    let (dw, dh) = (dst_w as usize, dst_h as usize);
    let mut out = Vec::with_capacity(dw * dh);
    let sx = src_w as f32 / dw as f32;
    let sy = src_h as f32 / dh as f32;
    let at = |x: usize, y: usize| src[y.min(src_h - 1) * src_w + x.min(src_w - 1)];
    for y in 0..dh {
        let fy = ((y as f32 + 0.5) * sy - 0.5).max(0.0);
        let y0 = fy.floor() as usize;
        let ty = fy - y0 as f32;
        for x in 0..dw {
            let fx = ((x as f32 + 0.5) * sx - 0.5).max(0.0);
            let x0 = fx.floor() as usize;
            let tx = fx - x0 as f32;
            let top = at(x0, y0) * (1.0 - tx) + at(x0 + 1, y0) * tx;
            let bottom = at(x0, y0 + 1) * (1.0 - tx) + at(x0 + 1, y0 + 1) * tx;
            let v = top * (1.0 - ty) + bottom * ty;
            out.push(if v > 0.5 { 255 } else { 0 });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn desc(
        bytes: &[u8],
        width: u32,
        height: u32,
        row_bytes: u32,
        channels: u32,
        alpha: u32,
    ) -> BufferDesc<'_> {
        BufferDesc {
            bytes,
            width,
            height,
            row_bytes,
            channels,
            alpha,
            color_space: COLOR_SPACE_SRGB,
        }
    }

    #[test]
    fn strided_rgb_rows_are_packed() {
        // 2x2 RGB with 2 bytes of padding per row.
        let bytes = [
            1, 2, 3, 4, 5, 6, 0xEE, 0xEE, 7, 8, 9, 10, 11, 12, 0xEE, 0xEE,
        ];
        let image = HostImage::ingest(desc(&bytes, 2, 2, 8, 3, ALPHA_NONE)).unwrap();
        assert_eq!(image.pixels, vec![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
        assert_eq!(image.row_bytes(), 6);
        // The last row need not carry padding.
        assert!(HostImage::ingest(desc(&bytes[..14], 2, 2, 8, 3, ALPHA_NONE)).is_ok());
        assert!(HostImage::ingest(desc(&bytes[..13], 2, 2, 8, 3, ALPHA_NONE)).is_err());
    }

    #[test]
    fn premultiplied_input_becomes_straight() {
        // 50% alpha red stored premultiplied, a transparent pixel, an opaque pixel.
        let bytes = [128, 0, 0, 128, 9, 9, 9, 0, 10, 20, 30, 255];
        let image = HostImage::ingest(desc(&bytes, 3, 1, 12, 4, ALPHA_PREMULTIPLIED)).unwrap();
        assert_eq!(
            image.pixels,
            vec![255, 0, 0, 128, 0, 0, 0, 0, 10, 20, 30, 255]
        );
        assert_eq!(image.alpha(), Alpha::Straight);
        let straight = HostImage::ingest(desc(&bytes, 3, 1, 12, 4, ALPHA_STRAIGHT)).unwrap();
        assert_eq!(
            straight.pixels,
            bytes.to_vec(),
            "straight input is copied verbatim"
        );
    }

    #[test]
    fn premultiply_round_trip_is_exact_for_opaque_and_bounded_for_translucent() {
        let original = vec![200, 100, 50, 255, 200, 100, 50, 64];
        let mut buf = original.clone();
        premultiply_in_place(&mut buf);
        assert_eq!(&buf[..4], &original[..4], "opaque pixels are unchanged");
        assert_eq!(&buf[4..8], &[50, 25, 13, 64]);
        unpremultiply_in_place(&mut buf);
        for (a, b) in buf.iter().zip(&original) {
            // 8-bit premultiplication quantises colour by up to 255/(2*alpha) levels.
            assert!(a.abs_diff(*b) <= 2, "{buf:?} vs {original:?}");
        }
    }

    #[test]
    fn rgba_flattens_over_white_like_the_inference_contract() {
        let image = HostImage {
            width: 2,
            height: 1,
            channels: 4,
            pixels: vec![0, 0, 0, 0, 255, 0, 0, 128],
        };
        let rgb = image.to_rgb();
        assert_eq!(rgb.pixels, vec![255, 255, 255, 255, 127, 127]);
        let contract = image.to_rgba().to_rgb_over_white().unwrap();
        assert_eq!(
            rgb, contract,
            "adapter flattening matches gen-core's to_rgb_over_white"
        );
    }

    #[test]
    fn gray_and_rgb_widen_to_opaque_rgba() {
        let gray = HostImage {
            width: 1,
            height: 1,
            channels: 1,
            pixels: vec![7],
        };
        assert_eq!(gray.to_rgb().pixels, vec![7, 7, 7]);
        assert_eq!(gray.to_rgba().pixels, vec![7, 7, 7, 255]);
        let rgb = HostImage {
            width: 1,
            height: 1,
            channels: 3,
            pixels: vec![1, 2, 3],
        };
        assert_eq!(rgb.to_rgba().pixels, vec![1, 2, 3, 255]);
    }

    #[test]
    fn invalid_layouts_and_color_spaces_are_rejected() {
        let bytes = [0u8; 16];
        assert!(HostImage::ingest(desc(&bytes, 2, 2, 8, 4, ALPHA_NONE)).is_err());
        assert!(HostImage::ingest(desc(&bytes, 2, 2, 6, 3, ALPHA_STRAIGHT)).is_err());
        assert!(HostImage::ingest(desc(&bytes, 2, 2, 4, 2, ALPHA_NONE)).is_err());
        assert!(HostImage::ingest(desc(&bytes, 0, 2, 4, 1, ALPHA_NONE)).is_err());
        assert!(
            HostImage::ingest(desc(&bytes, 2, 2, 4, 3, ALPHA_NONE)).is_err(),
            "row too short"
        );
        let mut p3 = desc(&bytes, 2, 2, 2, 1, ALPHA_NONE);
        p3.color_space = 2;
        assert!(HostImage::ingest(p3).unwrap_err().contains("sRGB"));
    }

    #[test]
    fn provider_outputs_are_validated() {
        assert!(
            HostImage::from_rgb(Image {
                width: 2,
                height: 1,
                pixels: vec![0; 5]
            })
            .is_err()
        );
        let ok = HostImage::from_rgba(RgbaImage {
            width: 1,
            height: 1,
            pixels: vec![1, 2, 3, 4],
        })
        .unwrap();
        assert_eq!((ok.channels, ok.alpha()), (4, Alpha::Straight));
        assert!(
            HostImage::from_rgba(RgbaImage {
                width: 1,
                height: 1,
                pixels: vec![1, 2, 3]
            })
            .is_err()
        );
        assert!(HostImage::mask(2, 2, vec![0; 3]).is_err());
    }

    #[test]
    fn mask_resize_maps_grid_onto_source_pixels() {
        // Left half set on a 4x4 grid → left half of an 8x6 frame.
        let grid: Vec<f32> = (0..16).map(|i| if i % 4 < 2 { 1.0 } else { 0.0 }).collect();
        let mask = resize_binary_mask(&grid, 4, 4, 8, 6);
        assert_eq!(mask.len(), 48);
        for row in mask.chunks(8) {
            assert_eq!(row, &[255, 255, 255, 255, 0, 0, 0, 0]);
        }
    }
}
