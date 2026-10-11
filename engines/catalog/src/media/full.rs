use super::{Metadata, orient};
use image::{DynamicImage, ImageDecoder, ImageReader, RgbaImage};
use lcms2::{CIExyY, CIExyYTRIPLE, Flags, Intent, PixelFormat, Profile, ToneCurve, Transform};
use serde::{Deserialize, Serialize};
use std::{
    ffi::{CStr, c_char},
    fmt,
    fs::File,
    io::{BufReader, Cursor, Read, Seek, SeekFrom},
    path::Path,
};

const MAX_ENCODED: u64 = 512 * 1024 * 1024;
const MAX_PIXELS: u64 = 100_000_000;

/// Per-request admission ceilings, checked before pixel allocation. These bound
/// individual surfaces/buffers, not total process RSS or native library scratch.
/// The preview scheduler must separately reserve measured peak memory plus margin.
#[repr(C)]
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct DecodeLimits {
    pub max_encoded_bytes: u64,
    /// Includes uncropped sensor data, DNG stages and masks. It may exceed the
    /// final output's 100 MP format ceiling because sensor margins are retained.
    pub max_intermediate_pixels: u64,
    pub max_allocation_bytes: u64,
}
impl Default for DecodeLimits {
    fn default() -> Self {
        Self {
            max_encoded_bytes: MAX_ENCODED,
            max_intermediate_pixels: u64::MAX,
            // Each decoder retains its historical built-in ceiling. A default
            // request adds no narrower cross-codec allocation policy.
            max_allocation_bytes: u64::MAX,
        }
    }
}
impl DecodeLimits {
    pub fn validate(self) -> Result<()> {
        if self.max_encoded_bytes == 0
            || self.max_intermediate_pixels == 0
            || self.max_allocation_bytes == 0
        {
            return Err(error(
                DecodeStatus::ResourceLimit,
                "decode admission ceilings must be positive",
            ));
        }
        Ok(())
    }
    fn surface(self, width: u32, height: u32) -> Result<()> {
        dimensions(width, height)?;
        let pixels = u64::from(width) * u64::from(height);
        if pixels > self.max_intermediate_pixels
            || pixels.saturating_mul(16) > self.max_allocation_bytes
        {
            return Err(error(
                DecodeStatus::ResourceLimit,
                "pixel surface exceeds configured decode admission; increase worker allowance",
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DecodeStatus {
    Unsupported,
    Corrupt,
    ResourceLimit,
    Io,
}
#[derive(Debug)]
pub struct DecodeError {
    pub status: DecodeStatus,
    pub message: String,
}
impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:?}: {}", self.status, self.message)
    }
}
impl std::error::Error for DecodeError {}
type Result<T> = std::result::Result<T, DecodeError>;
fn error(status: DecodeStatus, message: impl ToString) -> DecodeError {
    DecodeError {
        status,
        message: message.to_string(),
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ColorCalibration {
    pub table: String,
    pub applied_pixels: u64,
    pub bypassed_pixels: u64,
    pub domain_policy: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RenderProvenance {
    pub pipeline_version: String,
    pub decoder: String,
    pub source_bits_per_channel: u32,
    pub source_color: String,
    pub working_color: String,
    pub alpha: String,
    pub calibration: Option<ColorCalibration>,
    pub spatial_calibration: Option<ColorCalibration>,
    pub notes: Vec<String>,
}
/// Full-resolution, oriented, scene/display-linear sRGB-primary pixels. RGB may be
/// negative or above one; alpha is straight and in [0,1]. No thumbnail dependency.
pub struct RenderedImage {
    pub metadata: Metadata,
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<[f32; 4]>,
    pub provenance: RenderProvenance,
}
/// Summary of a streamed scene-linear source. Pixels belong to the row consumer,
/// never an empty/fabricated RenderedImage. Orientation is declared per row.
pub struct RenderedPlane {
    pub metadata: Metadata,
    pub width: u32,
    pub height: u32,
    pub provenance: RenderProvenance,
}
pub trait LinearRowSink {
    fn write_row(&mut self, width: u32, height: u32, orientation: u32,
        row: u32, pixels: &[[f32; 4]]) -> std::result::Result<(), DecodeError>;
}
#[repr(C)]
struct NativeDecodeControl {
    canceled: unsafe extern "C" fn(*mut std::ffi::c_void)->i32,
    context: *mut std::ffi::c_void,
}
struct NativeCancel<'a>(&'a dyn crate::edit::CancelCheck);
unsafe extern "C" fn native_canceled(context:*mut std::ffi::c_void)->i32 {
    // Shared Sync authority only. A user implementation panic aborts the decode,
    // never unwinds through vendor threads or mutates the row sink.
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let owner=unsafe{&*(context as *const NativeCancel<'_>)};
        i32::from(owner.0.is_canceled())
    })).unwrap_or(1)
}
struct DecodedOutput { summary: RenderedPlane, pixels: Option<Vec<[f32;4]>> }
struct NativeRowState<'a> {
    sink: &'a mut dyn LinearRowSink,
    raw: bool,
    white: Option<[f64;2]>,
    orientation: Option<u32>,
    transform: Option<Transform<[f32;4],[f32;4]>>,
    initialized: bool,
    limits:DecodeLimits,
    failure: Option<DecodeError>,
    next_row: u32,
}
unsafe extern "C" fn consume_native_row(context: *mut std::ffi::c_void, image: *const NativeImage,
    y: u32, pixels: *const f32) -> i32 {
    // C owns the source row until this returns. A panic must never cross the C ABI.
    let state=unsafe { &mut *(context as *mut NativeRowState<'_>) };
    let result=std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<()> {
        let image=unsafe { &*image };
        if pixels.is_null() || image.width==0 || y!=state.next_row || y>=image.height {
            return Err(error(DecodeStatus::Corrupt,"native row extent/order"));
        }
        let orientation=state.orientation.unwrap_or(image.orientation);
        if !(1..=8).contains(&orientation) { return Err(error(DecodeStatus::Corrupt,"native row orientation")); }
        stream_surface(state.limits,image.width,image.height)?;
        let count=image.width as usize;
        let mut row=Vec::<[f32;4]>::new();
        row.try_reserve_exact(count).map_err(|_|error(DecodeStatus::ResourceLimit,"native row allocation"))?;
        row.extend_from_slice(unsafe { std::slice::from_raw_parts(pixels.cast::<[f32;4]>(),count) });
        if !state.initialized {
            if image.icc_size>16*1024*1024 {return Err(error(DecodeStatus::ResourceLimit,"ICC profile exceeds 16 MiB"));}
            if image.icc_size>0 {
                if image.icc.is_null() {return Err(error(DecodeStatus::Corrupt,"missing native ICC"));}
                let source=Profile::new_icc(unsafe{std::slice::from_raw_parts(image.icc,image.icc_size)})
                    .map_err(|e|error(DecodeStatus::Corrupt,e))?;
                if source.color_space()!=lcms2::ColorSpaceSignature::RgbData {return Err(error(DecodeStatus::Unsupported,"non-RGB ICC profile requires matching source channel transform"));}
                let target=linear_profile().map_err(|e|error(DecodeStatus::Corrupt,e))?;
                state.transform=Some(Transform::new_flags(&source,PixelFormat::RGBA_FLT,&target,PixelFormat::RGBA_FLT,
                    Intent::RelativeColorimetric,Flags::COPY_ALPHA|Flags::NO_OPTIMIZE).map_err(|e|error(DecodeStatus::Unsupported,e))?);
            }
            state.initialized=true;
        }
        if let Some(transform)=&state.transform {transform.transform_in_place(&mut row);}
        else if !state.raw {convert_cicp_samples(&mut row,image.primaries,image.transfer)?;}
        if !state.raw {if let Some(xy)=state.white {crate::edit::color::adapt_white(&mut row,xy);}}
        validate_linear_samples(&row)?;
        state.sink.write_row(image.width,image.height,orientation,y,&row)?;
        state.next_row+=1;
        Ok(())
    }));
    match result {
        Ok(Ok(()))=>0,
        Ok(Err(e))=>{state.failure=Some(e);1},
        Err(_)=>{state.failure=Some(error(DecodeStatus::Corrupt,"native row consumer panicked"));1},
    }
}
fn validate_linear_samples(pixels: &[[f32;4]]) -> Result<()> {
    if pixels.iter().any(|p|p.iter().any(|x|!x.is_finite()) || !(0.0..=1.0).contains(&p[3])) {
        return Err(error(DecodeStatus::Corrupt,"non-finite color or invalid alpha"));
    }
    Ok(())
}
impl RenderedImage {
    /// Browse-only SDR conversion. The float editor input remains unchanged.
    pub fn srgb_preview(&self, edge: u32) -> anyhow::Result<Vec<u8>> {
        let image = self.srgb_preview_pixels(edge)?;
        let mut bytes = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut bytes, 65).encode_image(&image)?;
        Ok(bytes)
    }

    /// Shared browse preparation: composite, transfer, quantize, then resize.
    /// Orientation has already been applied by `decode_full`.
    pub fn srgb_preview_pixels(&self, edge: u32) -> anyhow::Result<image::RgbImage> {
        anyhow::ensure!((1..=8192).contains(&edge), "preview edge outside 1..8192");
        anyhow::ensure!(
            self.width > 0
                && self.height > 0
                && self.pixels.len() as u64 == u64::from(self.width) * u64::from(self.height),
            "invalid rendered dimensions"
        );
        let mut rgba = RgbaImage::new(self.width, self.height);
        for (target, source) in rgba.pixels_mut().zip(&self.pixels) {
            anyhow::ensure!(
                source.iter().all(|v| v.is_finite()) && (0.0..=1.0).contains(&source[3]),
                "invalid rendered pixel"
            );
            for c in 0..3 {
                // Composite straight alpha against a neutral white canvas in linear light.
                let v = source[c] * source[3] + 1.0 - source[3];
                target[c] = (linear_to_srgb(v).clamp(0.0, 1.0) * 255.0).round() as u8;
            }
            target[3] = 255;
        }
        Ok(DynamicImage::ImageRgba8(rgba)
            .thumbnail(edge, edge)
            .to_rgb8())
    }
}
pub fn linear_to_srgb(x: f32) -> f32 {
    if x <= 0.0031308 {
        12.92 * x
    } else {
        1.055 * x.powf(1.0 / 2.4) - 0.055
    }
}
pub fn srgb_to_linear(x: f32) -> f32 {
    if x <= 0.04045 {
        x / 12.92
    } else {
        ((x + 0.055) / 1.055).powf(2.4)
    }
}

#[repr(C)]
struct NativeImage {
    pixels: *mut f32,
    icc: *mut u8,
    icc_size: usize,
    width: u32,
    height: u32,
    bits: u32,
    orientation: u32,
    primaries: u32,
    transfer: u32,
    flags: u32,
    calibration_applied_pixels: u64,
    calibration_bypassed_pixels: u64,
    make: [c_char; 128],
    model: [c_char; 128],
    profile: [c_char; 128],
    error: [c_char; 256],
}
#[repr(C)]
struct NativeWhitePoint {
    x: f64,
    y: f64,
}
unsafe extern "C" {
    fn pc_raw(
        bytes: *const u8,
        len: usize,
        limits: *const DecodeLimits,
        white: *const NativeWhitePoint,
        out: *mut NativeImage,
    ) -> i32;
    fn pc_dng(
        bytes: *const u8,
        len: usize,
        limits: *const DecodeLimits,
        white: *const NativeWhitePoint,
        out: *mut NativeImage,
    ) -> i32;
    fn pc_avif(
        bytes: *const u8,
        len: usize,
        limits: *const DecodeLimits,
        out: *mut NativeImage,
    ) -> i32;
    fn pc_raw_rows(bytes: *const u8,len: usize,limits: *const DecodeLimits,white: *const NativeWhitePoint,out: *mut NativeImage,
        sink: unsafe extern "C" fn(*mut std::ffi::c_void,*const NativeImage,u32,*const f32)->i32,context: *mut std::ffi::c_void,control: *const NativeDecodeControl)->i32;
    fn pc_dng_rows(bytes: *const u8,len: usize,limits: *const DecodeLimits,white: *const NativeWhitePoint,out: *mut NativeImage,
        sink: unsafe extern "C" fn(*mut std::ffi::c_void,*const NativeImage,u32,*const f32)->i32,context: *mut std::ffi::c_void,control: *const NativeDecodeControl)->i32;
    fn pc_avif_rows(bytes: *const u8,len: usize,limits: *const DecodeLimits,out: *mut NativeImage,
        sink: unsafe extern "C" fn(*mut std::ffi::c_void,*const NativeImage,u32,*const f32)->i32,context: *mut std::ffi::c_void,control: *const NativeDecodeControl)->i32;
    fn pc_free(out: *mut NativeImage);
    fn pc_raw_version() -> *const c_char;
    fn pc_avif_version() -> *const c_char;
}
impl Drop for NativeImage {
    fn drop(&mut self) {
        unsafe { pc_free(self) };
    }
}
pub fn decoder_versions() -> String {
    // Vendor functions return immutable NUL-terminated static strings.
    unsafe {
        format!(
            "Adobe DNG SDK 1.7.1 (2724); LibRaw {}; libavif {}; LittleCMS {}",
            CStr::from_ptr(pc_raw_version()).to_string_lossy(),
            CStr::from_ptr(pc_avif_version()).to_string_lossy(),
            lcms2::version()
        )
    }
}

pub fn decode_full(path: &Path) -> Result<RenderedImage> {
    decode_full_limited(path, DecodeLimits::default())
}

pub fn decode_full_limited(path: &Path, limits: DecodeLimits) -> Result<RenderedImage> {
    decode_with_white_point(path, limits, None)
}
/// Absolute source illuminant xy. RAW applies this before development/profile
/// calibration; raster pixels use a D65-reference Bradford adaptation afterward.
/// None is byte-for-byte the previous as-shot path.
pub fn decode_with_white_point(path: &Path, limits: DecodeLimits, white: Option<[f64;2]>) -> Result<RenderedImage> {
    let decoded=decode_with_white_point_output(path,limits,white,None,&(),None,false)?;
    let summary=decoded.summary;
    Ok(RenderedImage{metadata:summary.metadata,width:summary.width,height:summary.height,
        pixels:decoded.pixels.ok_or_else(||error(DecodeStatus::Corrupt,"missing complete output"))?,provenance:summary.provenance})
}
pub fn decode_with_white_point_rows(path: &Path,limits: DecodeLimits,white: Option<[f64;2]>,
    sink: &mut dyn LinearRowSink) -> Result<RenderedPlane> {
    decode_with_white_point_rows_cancellable(path,limits,white,sink,&())
}
pub fn decode_with_white_point_rows_cancellable(path:&Path,limits:DecodeLimits,white:Option<[f64;2]>,
    sink:&mut dyn LinearRowSink,cancel:&dyn crate::edit::CancelCheck)->Result<RenderedPlane> {
    Ok(decode_with_white_point_output(path,limits,white,Some(sink),cancel,None,false)?.summary)
}
pub(crate) fn decode_with_white_point_held_rows(file:File,path:&Path,limits:DecodeLimits,white:Option<[f64;2]>,
    sink:&mut dyn LinearRowSink,cancel:&dyn crate::edit::CancelCheck,raw_hint:bool)->Result<RenderedPlane>{
    Ok(decode_with_white_point_output(path,limits,white,Some(sink),cancel,Some(file),raw_hint)?.summary)
}
pub(crate) fn decode_with_white_point_held_source(file:File,path:&Path,limits:DecodeLimits,white:Option<[f64;2]>,
    cancel:&dyn crate::edit::CancelCheck,raw_hint:bool)->Result<RenderedImage>{
    let decoded=decode_with_white_point_output(path,limits,white,None,cancel,Some(file),raw_hint)?;
    let summary=decoded.summary;
    Ok(RenderedImage{metadata:summary.metadata,width:summary.width,height:summary.height,
        pixels:decoded.pixels.ok_or_else(||error(DecodeStatus::Corrupt,"missing complete output"))?,provenance:summary.provenance})
}
/// Caller-owned admitted storage is filled in bounded ranges. Cancellation is
/// checked before every read, including repeated short reads; no second buffer.
fn read_source_exact<R:Read>(reader:&mut R,bytes:&mut[u8],cancel:&dyn crate::edit::CancelCheck)->Result<()> {
    let mut offset=0;
    while offset<bytes.len(){
        if cancel.is_canceled(){return Err(error(DecodeStatus::Io,"source encoded read canceled"));}
        let end=offset.saturating_add(1024*1024).min(bytes.len());
        match reader.read(&mut bytes[offset..end]) {
            Ok(0)=>return Err(error(DecodeStatus::Io,"source encoded read ended early")),
            Ok(count)=>offset+=count,
            Err(e) if e.kind()==std::io::ErrorKind::Interrupted=>continue,
            Err(e)=>return Err(error(DecodeStatus::Io,e)),
        }
    }
    if cancel.is_canceled(){return Err(error(DecodeStatus::Io,"source encoded read canceled"));}
    Ok(())
}

#[derive(Default)]
struct SourceExifText { make:Option<String>,model:Option<String>,captured:Option<String>,lens:Option<String>,orientation:Option<u32> }
/// TIFF/CR2/NEF/ARW/DNG and RW2 metadata are addressed by their original
/// offsets. Read only the persisted text/orientation fields and EXIF directory;
/// strip/tile payloads and unrelated tag arrays never become a second container.
fn source_tiff_text(file:&mut File,cancel:&dyn crate::edit::CancelCheck)->Result<SourceExifText>{
    let length=file.metadata().map_err(|e|error(DecodeStatus::Io,e))?.len();
    source_tiff_text_view(file,length,cancel)
}
fn source_tiff_text_view<R:Read+Seek>(file:&mut R,length:u64,cancel:&dyn crate::edit::CancelCheck)->Result<SourceExifText>{
    fn read<R:Read+Seek>(file:&mut R,offset:u64,out:&mut[u8],length:u64)->Result<()> {
        if offset.checked_add(out.len() as u64).is_none_or(|n|n>length){return Err(error(DecodeStatus::Corrupt,"TIFF metadata range"));}
        file.seek(SeekFrom::Start(offset)).map_err(|e|error(DecodeStatus::Io,e))?;
        file.read_exact(out).map_err(|e|error(DecodeStatus::Io,e))
    }
    let mut header=[0u8;16];
    read(file,0,&mut header[..8],length)?;
    let little=match &header[..2]{b"II"=>true,b"MM"=>false,_=>return Err(error(DecodeStatus::Corrupt,"TIFF metadata byte order"))};
    let u16v=|b:&[u8]|if little{u16::from_le_bytes(b[..2].try_into().unwrap())}else{u16::from_be_bytes(b[..2].try_into().unwrap())};
    let u32v=|b:&[u8]|if little{u32::from_le_bytes(b[..4].try_into().unwrap())}else{u32::from_be_bytes(b[..4].try_into().unwrap())};
    let u64v=|b:&[u8]|if little{u64::from_le_bytes(b[..8].try_into().unwrap())}else{u64::from_be_bytes(b[..8].try_into().unwrap())};
    let magic=u16v(&header[2..]);let big=magic==43;
    if !matches!(magic,42|43|85){return Err(error(DecodeStatus::Unsupported,"TIFF metadata dialect"));}
    let first=if big {read(file,8,&mut header[8..],length)?;
        if u16v(&header[4..])!=8||u16v(&header[6..])!=0{return Err(error(DecodeStatus::Corrupt,"BigTIFF metadata offset width"));}u64v(&header[8..])
    }else{u64::from(u32v(&header[4..]))};
    let mut result=SourceExifText::default();let mut bytes=0usize;let mut exif=None;
    // Primary and its one EXIF directory, never the thumbnail/next-IFD chain.
    for directory in 0..2 {
        let offset=if directory==0{first}else{match exif{Some(n)=>n,None=>break}};
        if offset==0{break;}if directory!=0&&offset==first{return Err(error(DecodeStatus::Corrupt,"TIFF metadata directory cycle"));}
        let mut count_bytes=[0u8;8];let count_width=if big{8}else{2};
        read(file,offset,&mut count_bytes[..count_width],length)?;
        let count=if big{u64v(&count_bytes)}else{u64::from(u16v(&count_bytes))};
        let stride=if big{20u64}else{12};
        let start=offset.checked_add(count_width as u64).ok_or_else(||error(DecodeStatus::Corrupt,"TIFF metadata offset overflow"))?;
        if count.checked_mul(stride).and_then(|n|start.checked_add(n)).is_none_or(|n|n>length){return Err(error(DecodeStatus::Corrupt,"TIFF metadata table extent"));}
        for index in 0..count {
            if index%64==0&&cancel.is_canceled(){return Err(error(DecodeStatus::Io,"source metadata canceled"));}
            let mut entry=[0u8;20];read(file,start+index*stride,&mut entry[..stride as usize],length)?;
            let tag=u16v(&entry);let kind=u16v(&entry[2..]);let n=if big{u64v(&entry[4..])}else{u64::from(u32v(&entry[4..]))};
            let value_offset=if big{12}else{8};let inline=&entry[value_offset..stride as usize];
            if tag==34665&&directory==0&&n==1 {
                exif=match kind{4|13=>Some(u64::from(u32v(inline))),16|18 if big=>Some(u64v(inline)),_=>None};continue;
            }
            if tag==274&&directory==0&&kind==3&&n!=0 {
                let mut v=[0u8;2];if n<=inline.len() as u64/2{v.copy_from_slice(&inline[..2]);}
                else{read(file,if big{u64v(inline)}else{u64::from(u32v(inline))},&mut v,length)?;}
                let orientation=u32::from(u16v(&v));if (1..=8).contains(&orientation){result.orientation=Some(orientation);}continue;
            }
            if kind!=2||!matches!(tag,271|272|36867|42036){continue;}
            let mut value=Vec::new();
            if n<=inline.len() as u64 {
                let first=&inline[..n as usize];let first=first.split(|&c|c==0).next().unwrap_or(&[]);
                bytes=bytes.checked_add(first.len()).ok_or_else(||error(DecodeStatus::ResourceLimit,"source metadata extent"))?;
                if bytes>1024*1024{return Err(error(DecodeStatus::ResourceLimit,"source metadata exceeds descriptor allowance"));}
                value.extend_from_slice(first);
            }else{
                let offset=if big{u64v(inline)}else{u64::from(u32v(inline))};
                if offset.checked_add(n).is_none_or(|end|end>length){return Err(error(DecodeStatus::Corrupt,"TIFF metadata text range"));}
                let mut position=0;let mut block=[0u8;4096];
                while position<n {
                    if cancel.is_canceled(){return Err(error(DecodeStatus::Io,"source metadata canceled"));}
                    let size=usize::try_from((n-position).min(block.len() as u64)).unwrap();
                    read(file,offset+position,&mut block[..size],length)?;
                    let used=block[..size].iter().position(|&c|c==0).unwrap_or(size);
                    bytes=bytes.checked_add(used).ok_or_else(||error(DecodeStatus::ResourceLimit,"source metadata extent"))?;
                    if bytes>1024*1024{return Err(error(DecodeStatus::ResourceLimit,"source metadata exceeds descriptor allowance"));}
                    value.try_reserve_exact(used).map_err(|e|error(DecodeStatus::ResourceLimit,e))?;
                    value.extend_from_slice(&block[..used]);position+=size as u64;if used<size{break;}
                }
            }
            // The retained parser selects the first NUL-separated ASCII value.
            // Later unused strings are not read or allocated, regardless of tag extent.
            let mut text=match String::from_utf8(value){Ok(text)=>text,
                Err(failure)=>String::from_utf8_lossy(failure.as_bytes()).into_owned()};
            // Trim in place; valid ASCII/UTF-8 keeps the admitted vector owner.
            // A lossy UTF-8 expansion is also bounded by the same descriptor.
            let start=text.len()-text.trim_start().len();let end=text.trim_end().len();
            text.truncate(end);text.drain(..start.min(end));
            if text.len()>1024*1024{return Err(error(DecodeStatus::ResourceLimit,"source metadata exceeds descriptor allowance"));}
            let text=(!text.is_empty()).then_some(text);
            match tag{271=>result.make=text,272=>result.model=text,36867=>result.captured=text,42036=>result.lens=text,_=>{}}
        }
    }
    Ok(result)
}

/// Borrowed container navigation: retained fields are read by offset from the
/// original encoded owner. No unrelated EXIF tag tree or meta/idat copy exists.
fn source_container_text(bytes:&[u8],cancel:&dyn crate::edit::CancelCheck)->Result<SourceExifText>{
    fn corrupt(message:&str)->DecodeError{error(DecodeStatus::Corrupt,message)}
    fn take<'a>(b:&'a[u8],position:&mut usize,n:usize)->Result<&'a[u8]>{
        let end=position.checked_add(n).ok_or_else(||corrupt("source metadata offset overflow"))?;
        let value=b.get(*position..end).ok_or_else(||corrupt("source metadata truncated container"))?;*position=end;Ok(value)
    }
    fn number(b:&[u8],position:&mut usize,width:usize)->Result<u64>{
        if !matches!(width,0|2|4|8){return Err(corrupt("source metadata integer width"));}
        let mut value=0u64;for c in take(b,position,width)?{value=(value<<8)|u64::from(*c);}Ok(value)
    }
    fn box_body<'a>(b:&'a[u8],position:&mut usize)->Result<([u8;4],&'a[u8])>{
        let start=*position;let length=number(b,position,4)?;
        let kind=take(b,position,4)?.try_into().unwrap();
        let length=match length{0=>(b.len()-start)as u64,1=>number(b,position,8)?,n=>n};
        let end=start.checked_add(usize::try_from(length).map_err(|_|corrupt("source metadata box length"))?)
            .ok_or_else(||corrupt("source metadata box overflow"))?;
        if end<*position{return Err(corrupt("source metadata box header extent"));}
        let body=b.get(*position..end).ok_or_else(||corrupt("source metadata truncated box"))?;*position=end;Ok((kind,body))
    }
    fn tiff(b:&[u8],cancel:&dyn crate::edit::CancelCheck)->Result<SourceExifText>{
        source_tiff_text_view(&mut Cursor::new(b),b.len()as u64,cancel)
    }
    fn jpeg<'a>(b:&'a[u8],cancel:&dyn crate::edit::CancelCheck)->Result<Option<&'a[u8]>>{
        if !b.starts_with(&[0xff,0xd8]){return Ok(None);}let mut p=2;
        while p<b.len(){
            if cancel.is_canceled(){return Err(error(DecodeStatus::Io,"source metadata canceled"));}
            // Skip fill bytes with constant storage, including a long legal run.
            while p<b.len()&&b[p]!=0xff{p+=1;if p%4096==0&&cancel.is_canceled(){return Err(error(DecodeStatus::Io,"source metadata canceled"));}}
            while p<b.len()&&b[p]==0xff{p+=1;if p%4096==0&&cancel.is_canceled(){return Err(error(DecodeStatus::Io,"source metadata canceled"));}}
            let marker=*take(b,&mut p,1)?.first().unwrap();
            if matches!(marker,0xda|0xd9){break;}
            if matches!(marker,0x00|0x01|0xd0..=0xd8){continue;}
            let n=number(b,&mut p,2)?.checked_sub(2).ok_or_else(||corrupt("source metadata JPEG segment"))?as usize;
            let payload=take(b,&mut p,n)?;
            if marker==0xe1&&payload.starts_with(b"Exif\0\0"){return Ok(Some(&payload[6..]));}
        }Ok(None)
    }
    if cancel.is_canceled(){return Err(error(DecodeStatus::Io,"source metadata canceled"));}
    if bytes.starts_with(b"FUJIFILMCCD-RAW"){
        let start=bytes.get(84..88).ok_or_else(||corrupt("RAF metadata header"))?;
        let n=bytes.get(88..92).ok_or_else(||corrupt("RAF metadata header"))?;
        let start=u32::from_be_bytes(start.try_into().unwrap())as usize;let n=u32::from_be_bytes(n.try_into().unwrap())as usize;
        let end=start.checked_add(n).ok_or_else(||corrupt("RAF metadata extent"))?;
        let segment=bytes.get(start..end).ok_or_else(||corrupt("RAF metadata segment"))?;
        return jpeg(segment,cancel)?.map_or_else(||Ok(SourceExifText::default()),|b|tiff(b,cancel));
    }
    if bytes.starts_with(&[0xff,0xd8]){return jpeg(bytes,cancel)?.map_or_else(||Ok(SourceExifText::default()),|b|tiff(b,cancel));}
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n"){
        let mut p=8;while p<bytes.len(){
            if cancel.is_canceled(){return Err(error(DecodeStatus::Io,"source metadata canceled"));}
            let n=number(bytes,&mut p,4)?as usize;let kind=take(bytes,&mut p,4)?;let payload=take(bytes,&mut p,n)?;take(bytes,&mut p,4)?;
            if kind==b"eXIf"{return tiff(payload,cancel);}if kind==b"IEND"{break;}
        }return Ok(SourceExifText::default());
    }
    if bytes.starts_with(b"RIFF")&&bytes.get(8..12)==Some(b"WEBP"){
        let length=bytes.get(4..8).map(|b|u32::from_le_bytes(b.try_into().unwrap())as usize)
            .and_then(|n|n.checked_add(8)).filter(|n|*n<=bytes.len()).ok_or_else(||corrupt("WebP metadata extent"))?;
        let b=&bytes[..length];let mut p=12;while p<b.len(){
            if cancel.is_canceled(){return Err(error(DecodeStatus::Io,"source metadata canceled"));}
            let kind=take(b,&mut p,4)?;let n=u32::from_le_bytes(take(b,&mut p,4)?.try_into().unwrap())as usize;
            let payload=take(b,&mut p,n)?;if kind==b"EXIF"{return tiff(payload.strip_prefix(b"Exif\0\0").unwrap_or(payload),cancel);}
            if n%2!=0{take(b,&mut p,1)?;}
        }return Ok(SourceExifText::default());
    }
    if bytes.starts_with(b"8BPS"){
        let mut p=26;let n=number(bytes,&mut p,4)?as usize;take(bytes,&mut p,n)?;
        let n=number(bytes,&mut p,4)?as usize;let resources=take(bytes,&mut p,n)?;let mut p=0;
        while p<resources.len(){
            if cancel.is_canceled(){return Err(error(DecodeStatus::Io,"source metadata canceled"));}
            if take(resources,&mut p,4)?!=b"8BIM"{return Err(corrupt("PSD metadata resource signature"));}
            let id=number(resources,&mut p,2)?;
            let name=take(resources,&mut p,1)?[0]as usize;take(resources,&mut p,name)?;
            if(name+1)%2!=0{take(resources,&mut p,1)?;}
            let n=number(resources,&mut p,4)?as usize;let payload=take(resources,&mut p,n)?;
            if matches!(id,1058|1059){return tiff(payload,cancel);}if n%2!=0{take(resources,&mut p,1)?;}
        }return Ok(SourceExifText::default());
    }
    // ISO-BMFF meta/iloc are navigated as slices. The retained parser admits at
    // most 65535 EXIF bytes; enforce that same bound BEFORE extent allocation.
    let mut p=0;let mut compatible=false;let mut meta=None;
    while p<bytes.len(){
        if cancel.is_canceled(){return Err(error(DecodeStatus::Io,"source metadata canceled"));}
        let(kind,body)=box_body(bytes,&mut p)?;
        if &kind==b"ftyp"{compatible=body.get(8..).is_some_and(|b|b.chunks_exact(4).any(|brand|matches!(brand,b"mif1"|b"msf1")));}
        if &kind==b"meta"{meta=Some(body);}
    }
    if !compatible{return Ok(SourceExifText::default());}
    let Some(meta)=meta else{return Ok(SourceExifText::default());};
    if meta.first()!=Some(&0){return Err(corrupt("source metadata MetaBox version"));}
    let mut p=4;let mut item=None;let mut iloc=None;let mut idat=None;
    while p<meta.len(){
        if cancel.is_canceled(){return Err(error(DecodeStatus::Io,"source metadata canceled"));}
        let(kind,body)=box_body(meta,&mut p)?;
        match &kind{b"iloc"=>iloc=Some(body),b"idat"=>idat=Some(body),b"iinf"=>{
            let mut q=0;let version=take(body,&mut q,4)?[0];let count=number(body,&mut q,if version==0{2}else{4})?;
            for _ in 0..count{
                if cancel.is_canceled(){return Err(error(DecodeStatus::Io,"source metadata canceled"));}
                let(kind,entry)=box_body(body,&mut q)?;if &kind!=b"infe"{continue;}
                let mut r=0;let v=take(entry,&mut r,4)?[0];let id=number(entry,&mut r,match v{2=>2,3=>4,_=>return Err(corrupt("source metadata ItemInfoEntry version"))})?;
                take(entry,&mut r,2)?;if take(entry,&mut r,4)?==b"Exif"{item=Some(id);}
            }
        },_=>{}}
    }
    let Some(item)=item else{return Ok(SourceExifText::default());};
    let b=iloc.ok_or_else(||corrupt("source metadata missing ItemLocationBox"))?;let mut p=0;
    let v=take(b,&mut p,4)?[0];if v>2{return Err(corrupt("source metadata ItemLocationBox version"));}
    let sizes=number(b,&mut p,2)?as usize;let offset=(sizes>>12)&15;let length=(sizes>>8)&15;
    let base=(sizes>>4)&15;let index=if v==0{0}else{sizes&15};
    if [offset,length,base,index].iter().any(|n|!matches!(n,0|4|8)){return Err(corrupt("source metadata ItemLocation widths"));}
    let count=number(b,&mut p,if v==2{4}else{2})?;
    for _ in 0..count{
        if cancel.is_canceled(){return Err(error(DecodeStatus::Io,"source metadata canceled"));}
        let id=number(b,&mut p,if v==2{4}else{2})?;
        let method=if v==0{0}else{number(b,&mut p,2)?&15};let reference=number(b,&mut p,2)?;
        let base=number(b,&mut p,base)?;let count=number(b,&mut p,2)?as usize;
        if id!=item{let skip=(index+offset+length).checked_mul(count).ok_or_else(||corrupt("source metadata extents overflow"))?;take(b,&mut p,skip)?;continue;}
        if method>1||(method==0&&reference!=0){return Err(error(DecodeStatus::Unsupported,"source metadata external/item-relative extent"));}
        let source=if method==0{bytes}else{idat.ok_or_else(||corrupt("source metadata missing ItemDataBox"))?};
        let start=p;let mut total=0usize;
        // Two fixed-storage passes: validate every extent and aggregate first.
        for _ in 0..count{
            if cancel.is_canceled(){return Err(error(DecodeStatus::Io,"source metadata canceled"));}
            number(b,&mut p,index)?;let off=base.checked_add(number(b,&mut p,offset)?).and_then(|n|usize::try_from(n).ok()).ok_or_else(||corrupt("source metadata extent offset"))?;
            let n=number(b,&mut p,length)?;let n=if n==0{source.len().checked_sub(off).ok_or_else(||corrupt("source metadata extent"))?}else{usize::try_from(n).map_err(|_|corrupt("source metadata extent length"))?};
            source.get(off..off.checked_add(n).ok_or_else(||corrupt("source metadata extent overflow"))?).ok_or_else(||corrupt("source metadata extent"))?;
            total=total.checked_add(n).ok_or_else(||corrupt("source metadata aggregate overflow"))?;
            if total>65535{return Err(error(DecodeStatus::Unsupported,"HEIF EXIF exceeds retained 65535-byte bound"));}
        }
        let mut value=Vec::new();value.try_reserve_exact(total).map_err(|e|error(DecodeStatus::ResourceLimit,e))?;p=start;
        for _ in 0..count{
            if cancel.is_canceled(){return Err(error(DecodeStatus::Io,"source metadata canceled"));}
            number(b,&mut p,index)?;let off=(base+number(b,&mut p,offset)?)as usize;let n=number(b,&mut p,length)?;
            let n=if n==0{source.len()-off}else{n as usize};value.extend_from_slice(&source[off..off+n]);
        }
        let mut q=0;let start=4usize.checked_add(number(&value,&mut q,4)?as usize).ok_or_else(||corrupt("source metadata EXIF header"))?;
        return tiff(value.get(start..).ok_or_else(||corrupt("source metadata EXIF header"))?,cancel);
    }
    Err(corrupt("source metadata missing EXIF location"))
}

/// Retained encoded input, largest conversion row, ICC and bounded source text
/// coexist with the codec. Deduct them before entering every streamed codec.
fn source_decoder_budget(limits:DecodeLimits,encoded:u64)->Result<u64>{
    let retained=encoded.checked_add(30_000*64*16+16*1024*1024+4*1024*1024)
        .ok_or_else(||error(DecodeStatus::ResourceLimit,"source retained decode admission overflow"))?;
    limits.max_allocation_bytes.checked_sub(retained).filter(|remaining|*remaining>0)
        .ok_or_else(||error(DecodeStatus::ResourceLimit,"source retained input/row allowance"))
}
fn decode_with_white_point_output(path: &Path, limits: DecodeLimits, white: Option<[f64;2]>,
    mut row_sink: Option<&mut dyn LinearRowSink>,cancel:&dyn crate::edit::CancelCheck,held:Option<File>,raw_hint:bool) -> Result<DecodedOutput> {
    if cancel.is_canceled(){return Err(error(DecodeStatus::Io,"source decode canceled"));}
    let streamed=row_sink.is_some();
    limits.validate()?;
    if let Some([x, y]) = white
        && (!x.is_finite() || !y.is_finite() || x <= 0.0 || y <= 0.0 || x + y >= 1.0)
    {
        return Err(error(
            DecodeStatus::Unsupported,
            "invalid requested white point",
        ));
    }
    let native_white = NativeWhitePoint {
        x: white.map_or(0.0, |p| p[0]),
        y: white.map_or(0.0, |p| p[1]),
    };
    let mut file = match held{Some(file)=>file,None=>File::open(path).map_err(|e|error(DecodeStatus::Io,e))?};
    file.seek(SeekFrom::Start(0)).map_err(|e|error(DecodeStatus::Io,e))?;
    let length = file
        .metadata()
        .map_err(|e| error(DecodeStatus::Io, e))?
        .len();
    let encoded_limit = limits
        .max_encoded_bytes
        .min(limits.max_allocation_bytes)
        .min(isize::MAX as u64);
    if length > encoded_limit {
        return Err(error(
            DecodeStatus::ResourceLimit,
            "encoded source exceeds configured decode admission",
        ));
    }

    let mut source_text=None;
    if streamed {
        let mut signature=[0;16];let count=file.read(&mut signature).map_err(|e|error(DecodeStatus::Io,e))?;
        file.seek(SeekFrom::Start(0)).map_err(|e|error(DecodeStatus::Io,e))?;
        let ext=path.extension().and_then(|x|x.to_str()).unwrap_or("").to_ascii_lowercase();
        let raw=raw_hint||["cr2","cr3","dng","raf","rw2","nef","arw","orf","pef"].contains(&ext.as_str())||signature.get(8..12)==Some(b"CR\x02\0");
        let tiff=count>=8&&matches!(&signature[..4],b"II*\0"|b"MM\0*"|b"II+\0"|b"MM\0+");
        if tiff&&!raw {
            return decode_tiff_file_rows(file,limits,white,row_sink.take().unwrap(),cancel);
        }
        if tiff || signature.starts_with(b"IIU\0") {
            source_text=Some(match source_tiff_text(&mut file,cancel){
                Ok(text)=>text,
                Err(failure) if failure.status==DecodeStatus::Corrupt||failure.status==DecodeStatus::Unsupported=>SourceExifText::default(),
                Err(failure)=>return Err(failure),
            });
            file.seek(SeekFrom::Start(0)).map_err(|e|error(DecodeStatus::Io,e))?;
        }
        // Reserve the existing descriptor/profile and decoder-row envelope before
        // allocating an encoded container, not only after it has been read.
        let _ = source_decoder_budget(limits,length)?;
    }
    // A known-length allocation avoids Vec growth exceeding the admitted buffer.
    let mut bytes = Vec::new();
    bytes.try_reserve_exact(length as usize).map_err(|_| {
        error(
            DecodeStatus::ResourceLimit,
            "encoded source allocation unavailable",
        )
    })?;
    bytes.resize(length as usize, 0);
    if streamed { read_source_exact(&mut file,&mut bytes,cancel)?; }
    else { file.read_exact(&mut bytes).map_err(|e|error(DecodeStatus::Io,e))?; }
    let mut extra = [0u8; 1];
    if file
        .read(&mut extra)
        .map_err(|e| error(DecodeStatus::Io, e))?
        != 0
    {
        return Err(error(
            DecodeStatus::ResourceLimit,
            "source grew beyond admitted length",
        ));
    }
    let ext = path
        .extension()
        .and_then(|x| x.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if streamed && source_text.is_none(){
        source_text=Some(match source_container_text(&bytes,cancel){
            Ok(text)=>text,
            Err(failure) if failure.status==DecodeStatus::Corrupt||failure.status==DecodeStatus::Unsupported=>SourceExifText::default(),
            Err(failure)=>return Err(failure),
        });
    }
    let exif = if source_text.is_some(){None}else{exif::Reader::new()
        .read_from_container(&mut BufReader::new(Cursor::new(&bytes)))
        .ok()
        .or_else(|| {
            if bytes.starts_with(b"FUJIFILMCCD-RAW") && bytes.len() >= 92 {
                // RAF stores source EXIF in its JPEG metadata segment. Only EXIF
                // is read here; editor pixels still come from the RAW mosaic.
                let start = u32::from_be_bytes(bytes[84..88].try_into().ok()?) as usize;
                let length = u32::from_be_bytes(bytes[88..92].try_into().ok()?) as usize;
                let segment = bytes.get(start..start.checked_add(length)?)?;
                exif::Reader::new()
                    .read_from_container(&mut Cursor::new(segment))
                    .ok()
            } else if bytes.starts_with(b"IIU\0") {
                // RW2's TIFF dialect has magic85, while its EXIF IFD layout is TIFF.
                let mut metadata_bytes = bytes.clone();
                metadata_bytes[2] = 42;
                exif::Reader::new().read_raw(metadata_bytes).ok()
            } else if bytes.starts_with(b"8BPS") {
                super::psd::source_exif(&bytes)
                    .ok()
                    .flatten()
                    .and_then(|data| exif::Reader::new().read_raw(data).ok())
            } else {
                None
            }
        })};
    if streamed {
        let mut retained=0usize;
        for tag in [exif::Tag::Make,exif::Tag::Model,exif::Tag::DateTimeOriginal,exif::Tag::LensModel] {
            if let Some(field)=exif.as_ref().and_then(|x|x.get_field(tag,exif::In::PRIMARY)) {
                if let exif::Value::Ascii(values)=&field.value {if let Some(value)=values.first() {
                    retained=retained.checked_add(value.len()).ok_or_else(||error(DecodeStatus::ResourceLimit,"source metadata extent"))?;
                }}
            }
        }
        // The existing source descriptor is capped at 1 MiB. Refuse before
        // allocating strings which could never enter that same protocol header.
        if retained>1024*1024{return Err(error(DecodeStatus::ResourceLimit,"source metadata exceeds descriptor allowance"));}
    }
    let text = |tag| {
        exif.as_ref()
            .and_then(|x| x.get_field(tag, exif::In::PRIMARY))
            .and_then(|f| match &f.value {
                exif::Value::Ascii(values) => values.first().map(|v| {
                    String::from_utf8_lossy(v)
                        .trim_end_matches('\0')
                        .trim()
                        .to_owned()
                }),
                _ => None,
            })
            .filter(|s| !s.is_empty())
    };
    let exif_orientation = source_text.as_ref().and_then(|text|text.orientation).or_else(||exif
        .as_ref()
        .and_then(|x| x.get_field(exif::Tag::Orientation, exif::In::PRIMARY))
        .and_then(|f| f.value.get_uint(0)));
    let camera_make=source_text.as_mut().and_then(|value|value.make.take()).or_else(||text(exif::Tag::Make));
    let camera_model=source_text.as_mut().and_then(|value|value.model.take()).or_else(||text(exif::Tag::Model));
    let captured_at=source_text.as_mut().and_then(|value|value.captured.take()).or_else(||text(exif::Tag::DateTimeOriginal));
    let lens=source_text.as_mut().and_then(|value|value.lens.take()).or_else(||text(exif::Tag::LensModel));
    // TIFF/RAW Exif retains its complete encoded container. Do not keep a second
    // full source buffer alive while developing the sensor/decoded image.
    drop(text);drop(exif);
    let raw_ext = [
        "cr2", "cr3", "dng", "raf", "rw2", "nef", "arw", "orf", "pef",
    ]
    .contains(&ext.as_str());
    let is_raw =
        raw_hint || raw_ext || bytes.get(8..12) == Some(b"CR\x02\0") || bytes.starts_with(b"FUJIFILMCCD-RAW");
    let is_avif = bytes.get(4..8) == Some(b"ftyp")
        && bytes
            .get(8..64.min(bytes.len()))
            .is_some_and(|b| b.windows(4).any(|x| x == b"avif" || x == b"avis"));
    let mut native_extent=None;
    let mut calibration = None;
    let mut spatial_calibration = None;
    let (mut image, format, bits, icc, orientation, source_color, decoder, make, model, mut notes) =
        if is_raw || is_avif {
            // Zeroed pointers and lengths form an empty native result; Drop frees all native allocations on every path.
            let mut out: NativeImage = unsafe { std::mem::zeroed() };
            let native_limits=if streamed {
                DecodeLimits{max_allocation_bytes:source_decoder_budget(limits,length)?,..limits}
            }else{limits};
            let mut cancel_owner=NativeCancel(cancel);
            let control=NativeDecodeControl{canceled:native_canceled,context:(&mut cancel_owner as *mut NativeCancel<'_>).cast()};
            let mut state=row_sink.take().map(|sink|NativeRowState{sink,raw:is_raw,white,
                orientation:if is_avif {None}else{exif_orientation},transform:None,initialized:false,limits,failure:None,next_row:0});
            let status = unsafe {
                if let Some(state)=state.as_mut() {
                    let context=(state as *mut NativeRowState<'_>).cast::<std::ffi::c_void>();
                    if ext=="dng" {pc_dng_rows(bytes.as_ptr(),bytes.len(),&native_limits,&native_white,&mut out,consume_native_row,context,&control)}
                    else if is_raw {pc_raw_rows(bytes.as_ptr(),bytes.len(),&native_limits,&native_white,&mut out,consume_native_row,context,&control)}
                    else {pc_avif_rows(bytes.as_ptr(),bytes.len(),&native_limits,&mut out,consume_native_row,context,&control)}
                } else if ext == "dng" {
                    pc_dng(
                        bytes.as_ptr(),
                        bytes.len(),
                        &limits,
                        &native_white,
                        &mut out,
                    )
                } else if is_raw {
                    pc_raw(
                        bytes.as_ptr(),
                        bytes.len(),
                        &limits,
                        &native_white,
                        &mut out,
                    )
                } else {
                    pc_avif(bytes.as_ptr(), bytes.len(), &limits, &mut out)
                }
            };
            if let Some(state)=state.as_mut() {
                if let Some(failure)=state.failure.take() {return Err(failure);}
                if status==0 && state.next_row!=out.height {return Err(error(DecodeStatus::Corrupt,"incomplete native row output"));}
            }
            if status != 0 {
                let message = unsafe { CStr::from_ptr(out.error.as_ptr()) }.to_string_lossy();
                let kind = if message.contains("resource limit") {
                    DecodeStatus::ResourceLimit
                } else if message.contains("unsupported") || message.contains("Unsupported") {
                    DecodeStatus::Unsupported
                } else {
                    DecodeStatus::Corrupt
                };
                return Err(error(kind, message));
            }
            if streamed {stream_surface(limits,out.width,out.height)?;}else{limits.surface(out.width,out.height)?;}
            native_extent=Some((out.width,out.height));
            if !streamed && out.pixels.is_null() {
                return Err(error(
                    DecodeStatus::Corrupt,
                    "native decoder returned no pixels",
                ));
            }
            let buffer=if streamed {None}else {
                let samples=unsafe{std::slice::from_raw_parts(out.pixels,(out.width as usize)*(out.height as usize)*4)}.to_vec();
                Some(image::Rgba32FImage::from_raw(out.width,out.height,samples)
                    .ok_or_else(||error(DecodeStatus::Corrupt,"native dimension mismatch"))?)
            };
            let icc = if out.icc_size == 0 {
                None
            } else {
                Some(unsafe { std::slice::from_raw_parts(out.icc, out.icc_size) }.to_vec())
            };
            let label = if is_raw {
                "linear sRGB camera matrix".to_string()
            } else {
                format!("CICP primaries {} transfer {}", out.primaries, out.transfer)
            };
            let make = unsafe { CStr::from_ptr(out.make.as_ptr()) }
                .to_string_lossy()
                .into_owned();
            let model = unsafe { CStr::from_ptr(out.model.as_ptr()) }
                .to_string_lossy()
                .into_owned();
            let mut dynamic=buffer.map(DynamicImage::ImageRgba32F);
            if is_avif && icc.is_none() {if let Some(dynamic)=dynamic.as_mut(){convert_cicp(dynamic,out.primaries,out.transfer)?;}}
            let mut notes = Vec::new();
            if ext == "dng" {
                let profile = unsafe { CStr::from_ptr(out.profile.as_ptr()) }.to_string_lossy();
                notes.push(format!("Adobe DNG SDK 1.7.1 original RAW stage3; camera profile matrix '{profile}', as-shot white balance, default crop and transparency mask. Display tone curves are excluded from scene-linear editor input."));
                if out.flags & 1 != 0 {
                    notes.push("Floating-point DNG sample precision retained through normalization and camera color transform.".into());
                }
                if out.flags & 2 != 0 {
                    notes.push("Source contains a separate enhanced rendition; original RAW is selected. Enhanced/AI appearance is not reproduced.".into());
                }
                if out.flags & 4 != 0 {
                    calibration = Some(ColorCalibration {
                        table: "embedded DNG HueSatMap, interpolated for as-shot white".into(),
                        applied_pixels: out.calibration_applied_pixels,
                        bypassed_pixels: out.calibration_bypassed_pixels,
                        domain_policy: if out.flags & 16 != 0 { "SDK HDR overrange encoding; negative ProPhoto input bypasses LUT without clamping" } else { "SDR LUT domain [0,1] in linear ProPhoto; negative or over-one input bypasses LUT without clamping" }.into(),
                    });
                    notes.push("Embedded profile HueSatMap calibration applied through Adobe SDK; out-of-domain pixels retain their matrix-rendered color and are counted separately.".into());
                }
                if out.flags & 32 != 0 {
                    spatial_calibration = Some(ColorCalibration {
                        table: if out.flags & 64 != 0 { "embedded profile ProfileGainTableMap" } else { "source ProfileGainTableMap/ProfileGainTableMap2" }.into(),
                        applied_pixels: u64::from(out.width)*u64::from(out.height),
                        bypassed_pixels: 0,
                        domain_policy: "SDK spatial/table interpolation after HueSatMap; baseline exposure affects lookup weight only; signed and over-one RGB retained".into(),
                    });
                    notes.push("Spatial ProfileGainTableMap calibration applied through Adobe SDK, including table gamma and source/profile precedence. No display exposure or tone curve is baked into the working surface.".into());
                }
                if out.flags & 8 != 0 {
                    notes.push("Source profile LookTable is retained in original but not applied to scene-linear editor input.".into());
                }
            } else if is_raw {
                notes.push("Camera matrix and as-shot white balance; exact vendor crop applied after full-area demosaic. Baseline exposure, automatic brightness, display tone curves and Adobe DCP looks are excluded from scene-linear editor input.".into());
                notes.push("LibRaw full-size camera RGB demosaic with camera white balance and documented highlight=2 clipped-chroma blending before the camera-to-sRGB matrix. The actual WB headroom normalization is restored in unclamped float, retaining signed and over-one RGB. This highlight treatment cannot recover clipped sensor detail; no display tone curve is applied.".into());
            }
            (
                dynamic,
                if is_raw {
                    ext.to_ascii_uppercase()
                } else {
                    "AVIF".into()
                },
                out.bits,
                icc,
                if is_avif {
                    out.orientation
                } else {
                    exif_orientation.unwrap_or(out.orientation)
                },
                label,
                decoder_versions(),
                (!make.is_empty()).then_some(make),
                (!model.is_empty()).then_some(model),
                notes,
            )
        } else if bytes.starts_with(b"8BPS") {
            let decoded = super::psd::decode(
                &bytes,
                limits.max_intermediate_pixels,
                if streamed {source_decoder_budget(limits,length)?} else {limits.max_allocation_bytes},
            )
            .map_err(|e| {
                let msg = e.to_string();
                error(
                    if msg.contains("unsupported") {
                        DecodeStatus::Unsupported
                    } else if msg.contains("limit") {
                        DecodeStatus::ResourceLimit
                    } else {
                        DecodeStatus::Corrupt
                    },
                    msg,
                )
            })?;
            (
                Some(decoded.image),
                "PSD".into(),
                decoded.bits,
                decoded.icc,
                exif_orientation.unwrap_or(1),
                "embedded ICC or untagged sRGB".into(),
                "bounded PSD composite".into(),
                None,
                None,
                vec!["Merged composite only; layers are retained in the original.".into()],
            )
        } else {
            let format =
                image::guess_format(&bytes).map_err(|e| error(DecodeStatus::Unsupported, e))?;
            if !matches!(
                format,
                image::ImageFormat::Jpeg
                    | image::ImageFormat::Png
                    | image::ImageFormat::WebP
                    | image::ImageFormat::Bmp
                    | image::ImageFormat::Tiff
            ) {
                return Err(error(DecodeStatus::Unsupported, "unsupported raster codec"));
            }
            let mut reader = ImageReader::with_format(Cursor::new(&bytes), format);
            let mut raster_limits = image::Limits::default();
            raster_limits.max_image_width = Some(40000);
            raster_limits.max_image_height = Some(40000);
            raster_limits.max_alloc = Some(if streamed {
                source_decoder_budget(limits,length)?
            }else{limits.max_allocation_bytes.min(1600 * 1024 * 1024)});
            reader.limits(raster_limits);
            let mut decoder = reader.into_decoder().map_err(image_error)?;
            if streamed {stream_surface(limits,decoder.dimensions().0,decoder.dimensions().1)?;}else{limits.surface(decoder.dimensions().0,decoder.dimensions().1)?;}
            let mut icc = decoder.icc_profile().map_err(image_error)?;
            if format == image::ImageFormat::Png && icc.is_none() {
                icc = png_profile(&bytes)?;
            }
            if format == image::ImageFormat::Tiff && icc.is_none() {
                // image 0.25.9 uses Unknown(34675), which does not match the
                // recognized IccProfile key in tiff 0.10.3. Read that tag directly
                // until the image decoder is upgraded; a malformed tag is not sRGB.
                let tag_error = |err: tiff::TiffError| {
                    error(
                        if matches!(err, tiff::TiffError::LimitsExceeded) {
                            DecodeStatus::ResourceLimit
                        } else {
                            DecodeStatus::Corrupt
                        },
                        err,
                    )
                };
                let mut tag_limits = tiff::decoder::Limits::default();
                tag_limits.decoding_buffer_size = tag_limits
                    .decoding_buffer_size
                    .min(usize::try_from(limits.max_allocation_bytes).unwrap_or(usize::MAX));
                tag_limits.ifd_value_size = 16 * 1024 * 1024;
                let mut tags = tiff::decoder::Decoder::new(Cursor::new(&bytes))
                    .map_err(tag_error)?
                    .with_limits(tag_limits);
                icc = tags
                    .find_tag(tiff::tags::Tag::IccProfile)
                    .map_err(tag_error)?
                    .map(|value| value.into_u8_vec())
                    .transpose()
                    .map_err(tag_error)?;
            }
            let orientation = exif_orientation
                .unwrap_or(decoder.orientation().map_err(image_error)?.to_exif() as u32);
            let color = decoder.original_color_type();
            let bits = color.bits_per_pixel() as u32 / u32::from(color.channel_count());
            let image=if streamed&&format==image::ImageFormat::Tiff&&matches!(color,image::ExtendedColorType::Rgb32F|image::ExtendedColorType::Rgba32F) {
                let extent=decoder.dimensions();drop(decoder);
                decode_float_tiff_direct(&bytes,extent,color,limits)?
            }else{DynamicImage::from_decoder(decoder).map_err(image_error)?};
            let format = match format {
                image::ImageFormat::Jpeg => "JPEG",
                image::ImageFormat::Png => "PNG",
                image::ImageFormat::WebP => "WEBP",
                image::ImageFormat::Bmp => "BMP",
                _ => "TIFF",
            };
            (
                Some(image),
                format.into(),
                bits,
                icc,
                orientation,
                "embedded ICC or untagged sRGB".into(),
                "image-rs".into(),
                None,
                None,
                Vec::new(),
            )
        };
    if !(1..=8).contains(&orientation) {
        return Err(error(DecodeStatus::Corrupt, "invalid orientation"));
    }
    let (width,height)=image.as_ref().map(|image|(image.width(),image.height())).or(native_extent)
        .ok_or_else(||error(DecodeStatus::Corrupt,"missing source extent"))?;
    if streamed {stream_surface(limits,width,height)?;}else{limits.surface(width,height)?;}
    let already_linear=(is_raw||is_avif)&&icc.is_none();

    if icc.is_none()&&!already_linear {
        notes.push("No embedded ICC: assumes sRGB; assignment is recorded, not inferred from filename.".into());
    }
    let (out_width,out_height)=if orientation>=5 {(height,width)}else{(width,height)};
    let mut pixels=None;
    if let Some(image)=image {
        if let Some(sink)=row_sink.as_mut() {
            write_image_rows_cancellable(&image,icc.as_deref(),already_linear,if is_raw{None}else{white},orientation,*sink,cancel)?;
        }else{
            let image=if already_linear{image}else{to_linear(image,icc.as_deref())?};
            let samples=orient(image,orientation).into_rgba32f().into_raw();
            let mut output=samples.as_chunks::<4>().0.to_vec();
            if !is_raw {if let Some(xy)=white {crate::edit::color::adapt_white(&mut output,xy);}}
            validate_linear_samples(&output)?;pixels=Some(output);
        }
    }
    if let Some(xy)=white {
        for note in &mut notes {*note=note.replace("as-shot white balance","requested camera white balance");}
        if let Some(table)=&mut calibration {table.table=table.table.replace("as-shot white","requested white");}
        notes.push(format!("Recipe white point xy {},{}; {}",xy[0],xy[1],if is_raw {"camera development/profile calibration"}else{"Bradford source-white to D65 adaptation in linear sRGB"}));
    }
    Ok(DecodedOutput {pixels,summary:RenderedPlane {
        metadata: Metadata {
            format,
            width,
            height,
            orientation,
            camera_make: camera_make.or(make),
            camera_model: camera_model.or(model),
            captured_at,
            lens,
            preview_source: "full-quality original rendering".into(),
        },
        width: out_width,
        height: out_height,
        provenance: RenderProvenance {
            pipeline_version: "photocatalog-render-4".into(),
            decoder,
            source_bits_per_channel: bits,
            source_color,
            working_color: "linear sRGB primaries, D65, f32, unclamped".into(),
            alpha: "straight alpha [0,1]".into(),
            calibration,
            spatial_calibration,
            notes,
        },
    }})
}
// Explicit typed samples avoid DynamicImage::get_pixel's RGBA8 return and a
// second full-sized f32 surface. Normalization matches image-rs float conversion.
// image-rs TIFF read_image first allocates a complete DecodingResult then
// copies it into the caller's equally-sized output. The owned row route consumes
// the pinned tiff decoder's original f32 vector directly instead.
fn decode_float_tiff_direct(bytes:&[u8],extent:(u32,u32),color:image::ExtendedColorType,
    limits:DecodeLimits)->Result<DynamicImage> {
    let channels=if color==image::ExtendedColorType::Rgb32F{3u64}else{4};
    let decoded=u64::from(extent.0).checked_mul(extent.1.into()).and_then(|n|n.checked_mul(channels*4))
        .ok_or_else(||error(DecodeStatus::ResourceLimit,"TIFF direct extent overflow"))?;
    let remaining=limits.max_allocation_bytes.checked_sub(bytes.len() as u64).and_then(|n|n.checked_sub(decoded))
        .and_then(|n|n.checked_sub(30_000*64*16+16*1024*1024+4*1024*1024))
        .ok_or_else(||error(DecodeStatus::ResourceLimit,"TIFF direct aggregate admission"))?;
    let map_error=|e:tiff::TiffError|error(if matches!(e,tiff::TiffError::LimitsExceeded){DecodeStatus::ResourceLimit}else{DecodeStatus::Corrupt},e);
    let mut tiff_limits=tiff::decoder::Limits::default();
    tiff_limits.decoding_buffer_size=usize::try_from(decoded).map_err(|e|error(DecodeStatus::ResourceLimit,e))?;
    tiff_limits.intermediate_buffer_size=usize::try_from(remaining).map_err(|e|error(DecodeStatus::ResourceLimit,e))?;
    tiff_limits.ifd_value_size=16*1024*1024;
    let mut decoder=tiff::decoder::Decoder::new(Cursor::new(bytes)).map_err(map_error)?.with_limits(tiff_limits);
    if decoder.dimensions().map_err(map_error)?!=extent{return Err(error(DecodeStatus::Corrupt,"TIFF direct dimension mismatch"));}
    let tiff::decoder::DecodingResult::F32(samples)=decoder.read_image().map_err(map_error)? else {
        return Err(error(DecodeStatus::Corrupt,"TIFF direct float representation mismatch"));
    };
    if samples.len() as u64*4!=decoded{return Err(error(DecodeStatus::Corrupt,"TIFF direct sample extent mismatch"));}
    if channels==3 {Ok(DynamicImage::ImageRgb32F(image::Rgb32FImage::from_raw(extent.0,extent.1,samples)
        .ok_or_else(||error(DecodeStatus::Corrupt,"TIFF RGB float extent"))?))}
    else{Ok(DynamicImage::ImageRgba32F(image::Rgba32FImage::from_raw(extent.0,extent.1,samples)
        .ok_or_else(||error(DecodeStatus::Corrupt,"TIFF RGBA float extent"))?))}
}

fn tiff_error(error_value:tiff::TiffError)->DecodeError {
    error(if matches!(error_value,tiff::TiffError::LimitsExceeded){DecodeStatus::ResourceLimit}else{DecodeStatus::Corrupt},error_value)
}
/// Image-rs validates the same planar/sample representation. The original is
/// then read through a seekable held file directly into tiff's sole typed result.
/// No encoded-container Vec or second full read_image output buffer is retained.
fn decode_tiff_file_rows(mut file:File,limits:DecodeLimits,white:Option<[f64;2]>,sink:&mut dyn LinearRowSink,
    cancel:&dyn crate::edit::CancelCheck)->Result<DecodedOutput> {
    let original=file.metadata().map_err(|e|error(DecodeStatus::Io,e))?;
    let mut reader=ImageReader::with_format(BufReader::new(file.try_clone().map_err(|e|error(DecodeStatus::Io,e))?),image::ImageFormat::Tiff);
    let mut image_limits=image::Limits::default();image_limits.max_image_width=Some(30000);image_limits.max_image_height=Some(30000);
    image_limits.max_alloc=Some(limits.max_allocation_bytes);reader.limits(image_limits);
    let mut checked=reader.into_decoder().map_err(image_error)?;
    let (width,height)=checked.dimensions();stream_surface(limits,width,height)?;
    let color=checked.original_color_type();
    let orientation=checked.orientation().map_err(image_error)?.to_exif() as u32;
    if !(1..=8).contains(&orientation){return Err(error(DecodeStatus::Corrupt,"invalid TIFF orientation"));}
    drop(checked);file.seek(SeekFrom::Start(0)).map_err(|e|error(DecodeStatus::Io,e))?;
    let channels=u64::from(color.channel_count());let bits=color.bits_per_pixel() as u32/u32::from(color.channel_count());
    let count=u64::from(width).checked_mul(height.into()).and_then(|n|n.checked_mul(channels))
        .ok_or_else(||error(DecodeStatus::ResourceLimit,"TIFF sample extent overflow"))?;
    // Packed 1-bit rows include each row's trailing bits. Its retained L8
    // expansion is separately admitted; CMYK compacts in its original buffer.
    let decoded_bytes=if color==image::ExtendedColorType::L1 {
        u64::from(width).div_ceil(8).checked_mul(height.into())
    }else{count.checked_mul(u64::from(bits/8))}
        .ok_or_else(||error(DecodeStatus::ResourceLimit,"TIFF decoded extent overflow"))?;
    let expanded_bytes=if color==image::ExtendedColorType::L1{u64::from(width)*u64::from(height)}else{0};
    let row_bytes=u64::from(width)*64;
    let intermediate=limits.max_allocation_bytes.checked_sub(decoded_bytes).and_then(|n|n.checked_sub(expanded_bytes))
        .and_then(|n|n.checked_sub(row_bytes+16*1024*1024+4*1024*1024))
        .ok_or_else(||error(DecodeStatus::ResourceLimit,"TIFF working/scratch admission"))?;
    let mut bounds=tiff::decoder::Limits::default();bounds.decoding_buffer_size=usize::try_from(decoded_bytes).map_err(|e|error(DecodeStatus::ResourceLimit,e))?;
    bounds.intermediate_buffer_size=usize::try_from(intermediate).unwrap_or(usize::MAX);bounds.ifd_value_size=16*1024*1024;
    let text=match source_tiff_text(&mut file,cancel){
        Ok(text)=>text,
        Err(failure) if matches!(failure.status,DecodeStatus::Corrupt|DecodeStatus::Unsupported)=>SourceExifText::default(),
        Err(failure)=>return Err(failure),
    };
    let camera_make=text.make;let camera_model=text.model;let captured_at=text.captured;let lens=text.lens;
    file.seek(SeekFrom::Start(0)).map_err(|e|error(DecodeStatus::Io,e))?;
    let mut tags=tiff::decoder::Decoder::new(BufReader::new(file.try_clone().map_err(|e|error(DecodeStatus::Io,e))?)).map_err(tiff_error)?.with_limits(bounds);
    if tags.dimensions().map_err(tiff_error)?!=(width,height){return Err(error(DecodeStatus::Corrupt,"TIFF source dimensions changed"));}
    let icc=tags.find_tag(tiff::tags::Tag::IccProfile).map_err(tiff_error)?.map(|v|v.into_u8_vec()).transpose().map_err(tiff_error)?;
    if icc.as_ref().is_some_and(|p|p.len()>16*1024*1024){return Err(error(DecodeStatus::ResourceLimit,"ICC profile exceeds 16 MiB"));}
    if cancel.is_canceled(){return Err(error(DecodeStatus::Io,"TIFF decode canceled"));}
    let result=tags.read_image().map_err(tiff_error)?;
    let expected=usize::try_from(count).map_err(|e|error(DecodeStatus::ResourceLimit,e))?;
    macro_rules! buffer {($samples:expr,$variant:ident,$type:ty)=>{{
        let samples=$samples;if samples.len()!=expected{return Err(error(DecodeStatus::Corrupt,"TIFF typed sample extent"));}
        DynamicImage::$variant(<$type>::from_raw(width,height,samples).ok_or_else(||error(DecodeStatus::Corrupt,"TIFF typed buffer"))?)
    }}}
    let image=match(color,result) {
        (image::ExtendedColorType::L1,tiff::decoder::DecodingResult::U8(v))=>{
            let row=usize::try_from(u64::from(width).div_ceil(8)).map_err(|e|error(DecodeStatus::ResourceLimit,e))?;
            if v.len()!=usize::try_from(decoded_bytes).map_err(|e|error(DecodeStatus::ResourceLimit,e))?{
                return Err(error(DecodeStatus::Corrupt,"TIFF packed grayscale extent"));
            }
            let mut expanded=Vec::new();expanded.try_reserve_exact(expected).map_err(|e|error(DecodeStatus::ResourceLimit,e))?;
            for packed in v.chunks_exact(row){
                if cancel.is_canceled(){return Err(error(DecodeStatus::Io,"TIFF grayscale expansion canceled"));}
                for x in 0..width as usize{expanded.push(if (packed[x/8]>>(7-x%8))&1==0{0}else{255});}
            }
            buffer!(expanded,ImageLuma8,image::GrayImage)
        },
        (image::ExtendedColorType::Cmyk8,tiff::decoder::DecodingResult::U8(mut v))=>{
            if v.len()!=expected{return Err(error(DecodeStatus::Corrupt,"TIFF CMYK8 extent"));}
            for pixel in 0..(expected/4){
                if pixel%(width as usize)==0&&cancel.is_canceled(){return Err(error(DecodeStatus::Io,"TIFF CMYK conversion canceled"));}
                let i=pixel*4;let c=v[i] as f32;let m=v[i+1] as f32;let y=v[i+2] as f32;let k=1.-v[i+3] as f32/255.;
                v[pixel*3]=((255.-c)*k) as u8;v[pixel*3+1]=((255.-m)*k) as u8;v[pixel*3+2]=((255.-y)*k) as u8;
            }
            v.truncate(expected/4*3);
            DynamicImage::ImageRgb8(image::RgbImage::from_raw(width,height,v).ok_or_else(||error(DecodeStatus::Corrupt,"TIFF CMYK8 output"))?)
        },
        (image::ExtendedColorType::Cmyk16,tiff::decoder::DecodingResult::U16(mut v))=>{
            if v.len()!=expected{return Err(error(DecodeStatus::Corrupt,"TIFF CMYK16 extent"));}
            for pixel in 0..(expected/4){
                if pixel%(width as usize)==0&&cancel.is_canceled(){return Err(error(DecodeStatus::Io,"TIFF CMYK conversion canceled"));}
                let i=pixel*4;let c=v[i] as f32;let m=v[i+1] as f32;let y=v[i+2] as f32;let k=1.-v[i+3] as f32/65535.;
                v[pixel*3]=((65535.-c)*k) as u16;v[pixel*3+1]=((65535.-m)*k) as u16;v[pixel*3+2]=((65535.-y)*k) as u16;
            }
            v.truncate(expected/4*3);
            DynamicImage::ImageRgb16(image::ImageBuffer::<image::Rgb<u16>,Vec<u16>>::from_raw(width,height,v).ok_or_else(||error(DecodeStatus::Corrupt,"TIFF CMYK16 output"))?)
        },
        (image::ExtendedColorType::L8,tiff::decoder::DecodingResult::U8(v))=>buffer!(v,ImageLuma8,image::GrayImage),
        (image::ExtendedColorType::La8,tiff::decoder::DecodingResult::U8(v))=>buffer!(v,ImageLumaA8,image::GrayAlphaImage),
        (image::ExtendedColorType::Rgb8,tiff::decoder::DecodingResult::U8(v))=>buffer!(v,ImageRgb8,image::RgbImage),
        (image::ExtendedColorType::Rgba8,tiff::decoder::DecodingResult::U8(v))=>buffer!(v,ImageRgba8,image::RgbaImage),
        (image::ExtendedColorType::L16,tiff::decoder::DecodingResult::U16(v))=>buffer!(v,ImageLuma16,image::ImageBuffer<image::Luma<u16>,Vec<u16>>),
        (image::ExtendedColorType::La16,tiff::decoder::DecodingResult::U16(v))=>buffer!(v,ImageLumaA16,image::ImageBuffer<image::LumaA<u16>,Vec<u16>>),
        (image::ExtendedColorType::Rgb16,tiff::decoder::DecodingResult::U16(v))=>buffer!(v,ImageRgb16,image::ImageBuffer<image::Rgb<u16>,Vec<u16>>),
        (image::ExtendedColorType::Rgba16,tiff::decoder::DecodingResult::U16(v))=>buffer!(v,ImageRgba16,image::ImageBuffer<image::Rgba<u16>,Vec<u16>>),
        (image::ExtendedColorType::Rgb32F,tiff::decoder::DecodingResult::F32(v))=>buffer!(v,ImageRgb32F,image::Rgb32FImage),
        (image::ExtendedColorType::Rgba32F,tiff::decoder::DecodingResult::F32(v))=>buffer!(v,ImageRgba32F,image::Rgba32FImage),
        _=>return Err(error(DecodeStatus::Unsupported,"TIFF sample representation differs from validated image decoder")),
    };
    drop(tags);
    write_image_rows_cancellable(&image,icc.as_deref(),false,white,orientation,sink,cancel)?;
    let after=file.metadata().map_err(|e|error(DecodeStatus::Io,e))?;
    if original.len()!=after.len()||original.modified().ok()!=after.modified().ok(){return Err(error(DecodeStatus::Io,"TIFF held source changed"));}
    if cancel.is_canceled(){return Err(error(DecodeStatus::Io,"TIFF decode canceled before publication"));}
    let mut notes=Vec::new();if icc.is_none(){notes.push("No embedded ICC: assumes sRGB; assignment is recorded, not inferred from filename.".into());}
    if let Some(xy)=white{notes.push(format!("Recipe white point xy {},{}; Bradford source-white to D65 adaptation in linear sRGB",xy[0],xy[1]));}
    let (out_width,out_height)=if orientation>=5{(height,width)}else{(width,height)};
    Ok(DecodedOutput{pixels:None,summary:RenderedPlane{
        metadata:Metadata{format:"TIFF".into(),width,height,orientation,camera_make,camera_model,captured_at,lens,
            preview_source:"full-quality original rendering".into()},width:out_width,height:out_height,
        provenance:RenderProvenance{pipeline_version:"photocatalog-render-4".into(),decoder:"tiff 0.10.3 seekable original; image-rs sample/planar validation".into(),
            source_bits_per_channel:bits,source_color:"embedded ICC or untagged sRGB".into(),working_color:"linear sRGB primaries, D65, f32, unclamped".into(),
            alpha:"straight alpha [0,1]".into(),calibration:None,spatial_calibration:None,notes},
    }})
}
fn image_sample(image:&DynamicImage,x:u32,y:u32)->Result<[f32;4]> {
    let sample=match image {
        DynamicImage::ImageLuma8(v)=>{let p=v.get_pixel(x,y).0;let g=p[0] as f32/255.;[g,g,g,1.]},
        DynamicImage::ImageLumaA8(v)=>{let p=v.get_pixel(x,y).0;let g=p[0] as f32/255.;[g,g,g,p[1] as f32/255.]},
        DynamicImage::ImageRgb8(v)=>{let p=v.get_pixel(x,y).0;[p[0] as f32/255.,p[1] as f32/255.,p[2] as f32/255.,1.]},
        DynamicImage::ImageRgba8(v)=>v.get_pixel(x,y).0.map(|v|v as f32/255.),
        DynamicImage::ImageLuma16(v)=>{let p=v.get_pixel(x,y).0;let g=p[0] as f32/65535.;[g,g,g,1.]},
        DynamicImage::ImageLumaA16(v)=>{let p=v.get_pixel(x,y).0;let g=p[0] as f32/65535.;[g,g,g,p[1] as f32/65535.]},
        DynamicImage::ImageRgb16(v)=>{let p=v.get_pixel(x,y).0;[p[0] as f32/65535.,p[1] as f32/65535.,p[2] as f32/65535.,1.]},
        DynamicImage::ImageRgba16(v)=>v.get_pixel(x,y).0.map(|v|v as f32/65535.),
        DynamicImage::ImageRgb32F(v)=>{let p=v.get_pixel(x,y).0;[p[0],p[1],p[2],1.]},
        DynamicImage::ImageRgba32F(v)=>v.get_pixel(x,y).0,
        _=>return Err(error(DecodeStatus::Unsupported,"unknown decoded sample representation")),
    };Ok(sample)
}
fn write_image_rows(image:&DynamicImage,icc:Option<&[u8]>,already_linear:bool,white:Option<[f64;2]>,
    orientation:u32,sink:&mut dyn LinearRowSink)->Result<()> {
    write_image_rows_cancellable(image,icc,already_linear,white,orientation,sink,&())
}
fn write_image_rows_cancellable(image:&DynamicImage,icc:Option<&[u8]>,already_linear:bool,white:Option<[f64;2]>,
    orientation:u32,sink:&mut dyn LinearRowSink,cancel:&dyn crate::edit::CancelCheck)->Result<()> {
    let transform=if !already_linear {if let Some(icc)=icc {
        if icc.len()>16*1024*1024{return Err(error(DecodeStatus::ResourceLimit,"ICC profile exceeds 16 MiB"));}
        let source=Profile::new_icc(icc).map_err(|e|error(DecodeStatus::Corrupt,e))?;
        if source.color_space()!=lcms2::ColorSpaceSignature::RgbData{return Err(error(DecodeStatus::Unsupported,"non-RGB ICC profile requires matching source channel transform"));}
        let target=linear_profile().map_err(|e|error(DecodeStatus::Corrupt,e))?;
        Some(Transform::<[f32;4],[f32;4]>::new_flags(&source,PixelFormat::RGBA_FLT,&target,PixelFormat::RGBA_FLT,
            Intent::RelativeColorimetric,Flags::COPY_ALPHA|Flags::NO_OPTIMIZE).map_err(|e|error(DecodeStatus::Unsupported,e))?)
    }else{None}}else{None};
    let mut row=Vec::<[f32;4]>::new();row.try_reserve_exact(image.width() as usize)
        .map_err(|_|error(DecodeStatus::ResourceLimit,"raster float row allocation"))?;
    for y in 0..image.height() {
        if cancel.is_canceled(){return Err(error(DecodeStatus::Io,"raster decode canceled"));}
        row.clear();for x in 0..image.width(){row.push(image_sample(image,x,y)?);}
        if let Some(transform)=&transform {transform.transform_in_place(&mut row);}
        else if !already_linear {for p in &mut row{for c in 0..3{p[c]=srgb_to_linear(p[c]);}}}
        if let Some(xy)=white{crate::edit::color::adapt_white(&mut row,xy);}
        validate_linear_samples(&row)?;sink.write_row(image.width(),image.height(),orientation,y,&row)?;
    }Ok(())
}
fn stream_surface(limits:DecodeLimits,width:u32,height:u32)->Result<()> {
    let pixels=u64::from(width)*u64::from(height);
    // The complete logical plane is written by a row sink. Its disk extent is
    // not a resident pixel allocation; each decoder and conversion row retains
    // its separately checked allocation budget before entering this callback.
    if width==0||height==0||width>30000||height>30000||pixels>200_000_000||pixels>limits.max_intermediate_pixels||u64::from(width).checked_mul(16).is_none_or(|n|n>limits.max_allocation_bytes) {return Err(error(DecodeStatus::ResourceLimit,"stream source extent or row exceeds declared admission"));}
    Ok(())
}
fn image_error(e: image::ImageError) -> DecodeError {
    let status = match e {
        image::ImageError::Unsupported(_) => DecodeStatus::Unsupported,
        image::ImageError::Limits(_) => DecodeStatus::ResourceLimit,
        _ => DecodeStatus::Corrupt,
    };
    error(status, e)
}
fn dimensions(w: u32, h: u32) -> Result<()> {
    if w == 0 || h == 0 || u64::from(w) * u64::from(h) > MAX_PIXELS {
        Err(error(
            DecodeStatus::ResourceLimit,
            "image exceeds 100 megapixels",
        ))
    } else {
        Ok(())
    }
}

pub fn linear_profile() -> std::result::Result<Profile, lcms2::Error> {
    let curve = ToneCurve::new(1.0);
    Profile::new_rgb(
        &CIExyY {
            x: 0.3127,
            y: 0.3290,
            Y: 1.0,
        },
        &CIExyYTRIPLE {
            Red: CIExyY {
                x: 0.64,
                y: 0.33,
                Y: 1.0,
            },
            Green: CIExyY {
                x: 0.30,
                y: 0.60,
                Y: 1.0,
            },
            Blue: CIExyY {
                x: 0.15,
                y: 0.06,
                Y: 1.0,
            },
        },
        &[&curve, &curve, &curve],
    )
}
fn to_linear(image: DynamicImage, icc: Option<&[u8]>) -> Result<DynamicImage> {
    let mut buffer = image.into_rgba32f();
    if let Some(icc) = icc {
        if icc.len() > 16 * 1024 * 1024 {
            return Err(error(
                DecodeStatus::ResourceLimit,
                "ICC profile exceeds 16 MiB",
            ));
        }
        let source = Profile::new_icc(icc).map_err(|e| error(DecodeStatus::Corrupt, e))?;
        if source.color_space() != lcms2::ColorSpaceSignature::RgbData {
            return Err(error(
                DecodeStatus::Unsupported,
                "non-RGB ICC profile requires matching source channel transform",
            ));
        }
        let target = linear_profile().map_err(|e| error(DecodeStatus::Corrupt, e))?;
        let transform: Transform<[f32; 4], [f32; 4]> = Transform::new_flags(
            &source,
            PixelFormat::RGBA_FLT,
            &target,
            PixelFormat::RGBA_FLT,
            Intent::RelativeColorimetric,
            Flags::COPY_ALPHA | Flags::NO_OPTIMIZE,
        )
        .map_err(|e| error(DecodeStatus::Unsupported, e))?;
        let (samples, _) = buffer.as_mut().as_chunks_mut::<4>();
        transform.transform_in_place(samples);
    } else {
        for p in buffer.pixels_mut() {
            for c in 0..3 {
                p[c] = srgb_to_linear(p[c]);
            }
        }
    }
    Ok(DynamicImage::ImageRgba32F(buffer))
}
fn convert_cicp(image: &mut DynamicImage, primaries: u32, transfer: u32) -> Result<()> {
    if ![1, 2, 9, 12].contains(&primaries) || ![1, 2, 6, 8, 13, 16, 18].contains(&transfer) {
        return Err(error(
            DecodeStatus::Unsupported,
            format!("unsupported AVIF CICP {primaries}/{transfer}"),
        ));
    }
    let buffer = image.as_mut_rgba32f().ok_or_else(||error(DecodeStatus::Corrupt,"CICP float surface"))?;
    convert_cicp_samples(buffer.as_mut().as_chunks_mut::<4>().0,primaries,transfer)
}
fn convert_cicp_samples(samples:&mut [[f32;4]],primaries:u32,transfer:u32)->Result<()> {
    if ![1,2,9,12].contains(&primaries)||![1,2,6,8,13,16,18].contains(&transfer) {
        return Err(error(DecodeStatus::Unsupported,format!("unsupported AVIF CICP {primaries}/{transfer}")));
    }
    for p in samples {
        for c in 0..3 {
            let v = p[c];
            p[c] = match transfer {
                8 => v,
                1 | 6 => {
                    if v < 0.081 {
                        v / 4.5
                    } else {
                        ((v + 0.099) / 1.099).powf(1.0 / 0.45)
                    }
                }
                16 => {
                    let x = v.powf(1.0 / 78.84375);
                    ((x - 0.8359375).max(0.0) / (18.851563 - 18.6875 * x)).powf(1.0 / 0.15930176)
                        * 10000.0
                        / 203.0
                }
                18 => {
                    if v <= 0.5 {
                        v * v / 3.0
                    } else {
                        ((v - 0.5599107) / 0.17883277)
                            .exp()
                            .mul_add(1.0, 0.28466892)
                            / 12.0
                    }
                }
                _ => srgb_to_linear(v),
            };
        }
        let rgb = [p[0], p[1], p[2]];
        let matrix = match primaries {
            9 => [
                [1.660491, -0.587641, -0.072850],
                [-0.124550, 1.132_9, -0.008349],
                [-0.018151, -0.100579, 1.118_73],
            ],
            12 => [
                [1.224_94, -0.224940, 0.0],
                [-0.042057, 1.042057, 0.0],
                [-0.019638, -0.078636, 1.098274],
            ],
            _ => [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],
        };
        for c in 0..3 {
            p[c] = (0..3).map(|k| matrix[c][k] * rgb[k]).sum();
        }
    }
    Ok(())
}

// PNG gAMA/chromaticities are color metadata even in the absence of an ICC packet.
fn png_profile(bytes: &[u8]) -> Result<Option<Vec<u8>>> {
    let mut offset = 8usize;
    let mut gamma = None;
    let mut chroma = None;
    let mut srgb = false;
    while let Some(header) = bytes.get(offset..offset + 8) {
        let n = u32::from_be_bytes(header[..4].try_into().unwrap()) as usize;
        let end = offset
            .checked_add(12)
            .and_then(|x| x.checked_add(n))
            .ok_or_else(|| error(DecodeStatus::Corrupt, "PNG chunk overflow"))?;
        let data = bytes
            .get(offset + 8..end - 4)
            .ok_or_else(|| error(DecodeStatus::Corrupt, "truncated PNG chunk"))?;
        match &header[4..8] {
            b"sRGB" => srgb = true,
            b"gAMA" if n == 4 => {
                gamma = Some(u32::from_be_bytes(data.try_into().unwrap()) as f64 / 100000.0)
            }
            b"cHRM" if n == 32 => {
                let mut xy = [0.0; 8];
                for (i, b) in data.as_chunks::<4>().0.iter().enumerate() {
                    xy[i] = u32::from_be_bytes(*b) as f64 / 100000.0;
                }
                chroma = Some(xy);
            }
            b"cICP" => {
                return Err(error(
                    DecodeStatus::Unsupported,
                    "PNG CICP color conversion requires an explicit HDR policy",
                ));
            }
            b"IDAT" => break,
            _ => {}
        }
        offset = end;
    }
    if srgb || (gamma.is_none() && chroma.is_none()) {
        return Ok(None);
    }
    let gamma = gamma.unwrap_or(0.45455);
    if !(0.01..=10.0).contains(&gamma) {
        return Err(error(DecodeStatus::Corrupt, "invalid PNG gamma"));
    }
    let xy = chroma.unwrap_or([0.3127, 0.3290, 0.64, 0.33, 0.30, 0.60, 0.15, 0.06]);
    let point = |i| CIExyY {
        x: xy[i],
        y: xy[i + 1],
        Y: 1.0,
    };
    let curve = ToneCurve::new(1.0 / gamma);
    Profile::new_rgb(
        &point(0),
        &CIExyYTRIPLE {
            Red: point(2),
            Green: point(4),
            Blue: point(6),
        },
        &[&curve, &curve, &curve],
    )
    .and_then(|p| p.icc())
    .map(Some)
    .map_err(|e| error(DecodeStatus::Corrupt, e))
}

#[cfg(test)]
#[path = "raw_highlight_tests.rs"]
mod raw_highlight_tests;

#[cfg(test)]
mod scene_row_tests {
    use super::*;
    use std::io::Write;
    struct Rows{pixels:Vec<[f32;4]>,order:Vec<u32>,failure:Option<u32>}
    impl LinearRowSink for Rows {
        fn write_row(&mut self,width:u32,height:u32,orientation:u32,row:u32,pixels:&[[f32;4]])->Result<()> {
            assert_eq!(width,2);assert_eq!(height,2);assert_eq!(orientation,6);
            if self.failure==Some(row){return Err(error(DecodeStatus::Io,"intentional row refusal"));}
            self.order.push(row);self.pixels.extend_from_slice(pixels);Ok(())
        }
    }
    #[test]
    fn typed_float_rows_preserve_signed_hdr_hidden_rgb_and_partial_alpha() {
        let input=vec![-3.,4.,0.25,0.,1.5,-0.2,2.,0.5,0.,0.,0.,1.,0.1,0.2,0.3,0.75];
        let image=DynamicImage::ImageRgba32F(image::Rgba32FImage::from_raw(2,2,input.clone()).unwrap());
        let mut sink=Rows{pixels:Vec::new(),order:Vec::new(),failure:None};
        write_image_rows(&image,None,true,None,6,&mut sink).unwrap();
        assert_eq!(sink.order,[0,1]);assert_eq!(sink.pixels,input.as_chunks::<4>().0);
        assert!(matches!(image,DynamicImage::ImageRgba32F(_)));
    }
    #[test]
    fn typed_sixteen_bit_profile_whitebalance_rows_match_whole_colour_operator() {
        let image=DynamicImage::ImageRgba16(image::ImageBuffer::<image::Rgba<u16>, Vec<u16>>::from_raw(2,2,
            vec![1000,2000,60000,0,40000,200,12000,32768,60000,60000,60000,65535,3,7,11,50000]).unwrap());
        let profile=Profile::new_srgb().icc().unwrap();let white=[0.3,0.32];
        let mut sink=Rows{pixels:Vec::new(),order:Vec::new(),failure:None};
        write_image_rows(&image,Some(&profile),false,Some(white),6,&mut sink).unwrap();
        let expected=to_linear(image,Some(&profile)).unwrap().into_rgba32f().into_raw();
        let mut expected=expected.as_chunks::<4>().0.to_vec();crate::edit::color::adapt_white(&mut expected,white);
        assert_eq!(sink.pixels,expected);assert_eq!(sink.order,[0,1]);
    }
    #[test]
    fn streamed_geometry_admits_full_extent_without_full_plane_allocation() {
        let limits=DecodeLimits { max_encoded_bytes:512*1024*1024,
            max_intermediate_pixels:200_000_000,max_allocation_bytes:64*1024*1024 };
        stream_surface(limits,20_000,10_000).unwrap();
        assert!(stream_surface(limits,20_000,10_001).is_err());
        assert!(stream_surface(limits,30_001,1).is_err());
        assert!(stream_surface(DecodeLimits { max_intermediate_pixels:199_999_999,..limits },20_000,10_000).is_err());
        assert!(stream_surface(DecodeLimits { max_allocation_bytes:20_000*16-1,..limits },20_000,10_000).is_err());
        // Whole-surface consumers keep their original allocation refusal.
        assert!(limits.surface(8_000,8_000).is_err());
    }
    #[test]
    fn row_consumer_failure_stops_without_publishing_later_rows() {
        let image=DynamicImage::ImageRgba32F(image::Rgba32FImage::from_pixel(2,2,image::Rgba([2.,-1.,0.,1.])));
        let mut sink=Rows{pixels:Vec::new(),order:Vec::new(),failure:Some(1)};
        let e=write_image_rows(&image,None,true,None,6,&mut sink).unwrap_err();
        assert!(e.message.contains("intentional row refusal"));assert_eq!(sink.order,[0]);assert_eq!(sink.pixels.len(),2);
    }
    #[test]
    fn float_tiff_direct_owns_one_typed_buffer_without_the_image_decoder_copy() {
        let samples=vec![-3.,4.,0.25,0.,1.5,-0.2,2.,0.5,0.,0.,0.,1.,0.1,0.2,0.3,0.75];
        let mut encoded=Cursor::new(Vec::new());
        tiff::encoder::TiffEncoder::new(&mut encoded).unwrap()
            .write_image::<tiff::encoder::colortype::RGBA32Float>(2,2,&samples).unwrap();
        let image=decode_float_tiff_direct(encoded.get_ref(),(2,2),image::ExtendedColorType::Rgba32F,
            DecodeLimits{max_encoded_bytes:512*1024*1024,max_intermediate_pixels:200_000_000,max_allocation_bytes:4*1024*1024*1024}).unwrap();
        let DynamicImage::ImageRgba32F(image)=image else{panic!("typed float TIFF must remain f32")};
        assert_eq!(image.into_raw(),samples);
        assert!(decode_float_tiff_direct(encoded.get_ref(),(2,3),image::ExtendedColorType::Rgba32F,
            DecodeLimits{max_encoded_bytes:512*1024*1024,max_intermediate_pixels:200_000_000,max_allocation_bytes:4*1024*1024*1024}).is_err());
        assert!(decode_float_tiff_direct(encoded.get_ref(),(2,2),image::ExtendedColorType::Rgba32F,
            DecodeLimits{max_encoded_bytes:512*1024*1024,max_intermediate_pixels:200_000_000,max_allocation_bytes:64}).is_err());
    }

    #[test]
    fn seekable_cmyk_tiff_matches_the_retained_decoder_and_color_operator() {
        for sixteen in [false,true]{
            let mut file=tempfile::tempfile().unwrap();
            {let mut encoder=tiff::encoder::TiffEncoder::new(&mut file).unwrap();
                if sixteen{let mut image=encoder.new_image::<tiff::encoder::colortype::CMYK16>(2,2).unwrap();
                    image.encoder().write_tag(tiff::tags::Tag::Orientation,6_u16).unwrap();
                    image.write_data(&[0,65535,30000,0,65535,0,0,20000,1200,2300,3400,65535,20000,30000,40000,50000]).unwrap();
                }else{let mut image=encoder.new_image::<tiff::encoder::colortype::CMYK8>(2,2).unwrap();
                    image.encoder().write_tag(tiff::tags::Tag::Orientation,6_u16).unwrap();
                    image.write_data(&[0,255,100,0,255,0,0,80,12,23,34,255,20,30,40,50]).unwrap();}}
            file.seek(SeekFrom::Start(0)).unwrap();
            let reference=ImageReader::with_format(BufReader::new(file.try_clone().unwrap()),image::ImageFormat::Tiff).decode().unwrap();
            let mut expected=Rows{pixels:Vec::new(),order:Vec::new(),failure:None};
            write_image_rows(&reference,None,false,None,6,&mut expected).unwrap();
            file.seek(SeekFrom::Start(0)).unwrap();let mut actual=Rows{pixels:Vec::new(),order:Vec::new(),failure:None};
            decode_tiff_file_rows(file,DecodeLimits{max_encoded_bytes:512*1024*1024,max_intermediate_pixels:200_000_000,
                max_allocation_bytes:64*1024*1024},None,&mut actual,&()).unwrap();
            assert_eq!(actual.pixels,expected.pixels);assert_eq!(actual.order,expected.order);
        }
    }

    #[test]
    fn seekable_float_tiff_rows_preserve_the_same_profile_operator_without_encoded_copy() {
        let samples=vec![-3.,4.,0.25,0.,1.5,-0.2,2.,0.5,0.,0.,0.,1.,0.1,0.2,0.3,0.75];
        let mut file=tempfile::tempfile().unwrap();
        {let mut encoder=tiff::encoder::TiffEncoder::new(&mut file).unwrap();
            let mut image=encoder.new_image::<tiff::encoder::colortype::RGBA32Float>(2,2).unwrap();
            image.encoder().write_tag(tiff::tags::Tag::Orientation,6_u16).unwrap();image.write_data(&samples).unwrap();}
        file.seek(SeekFrom::Start(0)).unwrap();let mut rows=Rows{pixels:Vec::new(),order:Vec::new(),failure:None};
        let summary=decode_tiff_file_rows(file,DecodeLimits{max_encoded_bytes:512*1024*1024,max_intermediate_pixels:200_000_000,max_allocation_bytes:64*1024*1024},None,&mut rows,&()).unwrap();
        assert!(summary.pixels.is_none());assert_eq!((summary.summary.width,summary.summary.height),(2,2));
        assert_eq!(rows.pixels.len(),4);assert_eq!(rows.pixels[0][3],0.);
        assert!(rows.pixels[0][0]<0.&&rows.pixels[0][1]>1.);
        assert!(summary.summary.provenance.decoder.contains("seekable original"));
    }

    #[test]
    fn seekable_packed_gray_preserves_row_padding_and_retained_expansion() {
        // A complete classic TIFF: two 9-pixel rows with nonzero unused bits.
        // Reference decoding uses the actual retained image-rs TIFF decoder.
        let tags=[(256_u16,4_u16,9_u32),(257,4,2),(258,3,1),(259,3,1),(262,3,1),
            (273,4,134),(274,3,6),(277,3,1),(278,4,2),(279,4,4)];
        let mut bytes=vec![b'I',b'I',42,0,8,0,0,0];bytes.extend_from_slice(&10_u16.to_le_bytes());
        for (tag,kind,value) in tags{bytes.extend_from_slice(&tag.to_le_bytes());bytes.extend_from_slice(&kind.to_le_bytes());
            bytes.extend_from_slice(&1_u32.to_le_bytes());bytes.extend_from_slice(&value.to_le_bytes());}
        bytes.extend_from_slice(&0_u32.to_le_bytes());bytes.extend_from_slice(&[0b10100101,0b11111111,0b01011010,0b01111111]);
        let reference=ImageReader::with_format(Cursor::new(bytes.clone()),image::ImageFormat::Tiff).decode().unwrap();
        struct AnyRows(Vec<[f32;4]>);impl LinearRowSink for AnyRows {
            fn write_row(&mut self,width:u32,height:u32,orientation:u32,row:u32,pixels:&[[f32;4]])->Result<()> {
                assert_eq!((width,height,orientation),(9,2,6));assert_eq!(row as usize,self.0.len()/9);
                self.0.extend_from_slice(pixels);Ok(())
            }
        }
        let mut expected=AnyRows(Vec::new());write_image_rows(&reference,None,false,None,6,&mut expected).unwrap();
        let mut file=tempfile::tempfile().unwrap();file.write_all(&bytes).unwrap();file.seek(SeekFrom::Start(0)).unwrap();
        let mut actual=AnyRows(Vec::new());decode_tiff_file_rows(file,DecodeLimits{max_encoded_bytes:512*1024*1024,
            max_intermediate_pixels:200_000_000,max_allocation_bytes:64*1024*1024},None,&mut actual,&()).unwrap();
        assert_eq!(actual.0,expected.0);assert_eq!(actual.0.len(),18);
    }

    #[test]
    fn held_tiff_decode_never_reopens_the_named_path() {
        let samples=[-3.,4.,0.25,0.,1.5,-0.2,2.,0.5,0.,0.,0.,1.,0.1,0.2,0.3,0.75];
        let mut held=tempfile::tempfile().unwrap();
        {let mut encoder=tiff::encoder::TiffEncoder::new(&mut held).unwrap();
            let mut image=encoder.new_image::<tiff::encoder::colortype::RGBA32Float>(2,2).unwrap();
            image.encoder().write_tag(tiff::tags::Tag::Orientation,6_u16).unwrap();image.write_data(&samples).unwrap();}
        let directory=tempfile::tempdir().unwrap();let absent=directory.path().join("never-opened.tif");
        let mut rows=Rows{pixels:Vec::new(),order:Vec::new(),failure:None};
        let summary=decode_with_white_point_held_rows(held,&absent,DecodeLimits{max_encoded_bytes:512*1024*1024,
            max_intermediate_pixels:200_000_000,max_allocation_bytes:64*1024*1024},None,&mut rows,&(),false).unwrap();
        assert_eq!(rows.order,[0,1]);assert_eq!(rows.pixels.len(),4);assert!(rows.pixels[0][0]<0.);
        assert!(summary.provenance.decoder.contains("seekable original"));assert!(!absent.exists());
    }

}


#[cfg(test)]
mod source_metadata_tests {
    use super::*;
    use std::io::Write;
    use std::sync::atomic::{AtomicUsize,Ordering};
    fn fixture(little:bool,big:bool,rw2:bool,tail:usize)->Vec<u8>{
        fn put(bytes:&mut[u8],at:usize,value:u64,width:usize,little:bool){
            let raw=if little{value.to_le_bytes()}else{value.to_be_bytes()};
            bytes[at..at+width].copy_from_slice(if little{&raw[..width]}else{&raw[8-width..]});
        }
        let head=if big{16}else{8};let count_width=if big{8}else{2};let stride=if big{20}else{12};
        let pointer=if big{12}else{8};let primary=head;let next_width=if big{8}else{4};
        let secondary=primary+count_width+3*stride+next_width;
        let data=secondary+count_width+2*stride+next_width;let mut bytes=vec![0;data+32+tail];
        bytes[..2].copy_from_slice(if little{b"II"}else{b"MM"});
        put(&mut bytes,2,if big{43}else if rw2{85}else{42},2,little);
        if big{put(&mut bytes,4,8,2,little);put(&mut bytes,8,primary as u64,8,little);}
        else{put(&mut bytes,4,primary as u64,4,little);}
        put(&mut bytes,primary,3,count_width,little);put(&mut bytes,secondary,2,count_width,little);
        let entries=[(primary+count_width,271,2,(5+tail)as u64,data as u64),
            (primary+count_width+stride,274,3,1,6),
            (primary+count_width+2*stride,34665,if big{18}else{4},1,secondary as u64),
            (secondary+count_width,36867,2,20,(data+8)as u64),
            (secondary+count_width+stride,42036,2,3,0)];
        for(at,tag,kind,n,value)in entries{
            put(&mut bytes,at,tag,2,little);put(&mut bytes,at+2,kind,2,little);
            put(&mut bytes,at+4,n,if big{8}else{4},little);
            put(&mut bytes,at+pointer,value,if tag==274{2}else if big{8}else{4},little);
        }
        bytes[data..data+5].copy_from_slice(b"Make\0");
        bytes[data+8..data+28].copy_from_slice(b"2026:10:09 01:02:03\0");
        let lens=secondary+count_width+stride+pointer;bytes[lens..lens+3].copy_from_slice(b"L1\0");bytes
    }
    fn held(bytes:&[u8])->File{let mut f=tempfile::tempfile().unwrap();f.write_all(bytes).unwrap();f}
    #[test]
    fn addressed_raw_metadata_preserves_endian_bigtiff_and_rw2_semantics(){
        for(little,big,rw2)in[(true,false,false),(false,false,false),(true,true,false),(false,true,false),(true,false,true)]{
            let mut file=held(&fixture(little,big,rw2,1024));let result=source_tiff_text(&mut file,&()).unwrap();
            assert_eq!(result.make.as_deref(),Some("Make"));assert_eq!(result.orientation,Some(6));
            assert_eq!(result.captured.as_deref(),Some("2026:10:09 01:02:03"));assert_eq!(result.lens.as_deref(),Some("L1"));
        }
    }
    #[test]
    fn metadata_reads_first_ascii_value_without_copying_large_unused_tail(){
        let mut file=held(&fixture(true,false,false,2*1024*1024));
        let result=source_tiff_text(&mut file,&()).unwrap();assert_eq!(result.make.as_deref(),Some("Make"));
        // With this declaration the entire unused tail is valid, but the held
        // parser consumes only the first 4096-byte block containing its NUL.
        assert!(file.metadata().unwrap().len()>2*1024*1024);assert_eq!(result.orientation,Some(6));
    }
    #[test]
    fn metadata_bad_text_extent_and_directory_cycle_refuse_the_actual_branch(){
        let mut bytes=fixture(true,false,false,16);bytes[18..22].copy_from_slice(&u32::MAX.to_le_bytes());
        let failure=source_tiff_text(&mut held(&bytes),&()).err().unwrap();
        assert_eq!(failure.status,DecodeStatus::Corrupt);assert!(failure.message.contains("text range"));
        let mut bytes=fixture(true,false,false,16);bytes[42..46].copy_from_slice(&8_u32.to_le_bytes());
        let failure=source_tiff_text(&mut held(&bytes),&()).err().unwrap();
        assert_eq!(failure.status,DecodeStatus::Corrupt);assert!(failure.message.contains("directory cycle"));
    }

    fn box_bytes(kind:&[u8;4],body:&[u8])->Vec<u8>{
        let mut out=Vec::new();out.extend_from_slice(&u32::try_from(body.len()+8).unwrap().to_be_bytes());out.extend_from_slice(kind);out.extend_from_slice(body);out
    }
    fn heif(tiff:&[u8],method:u16)->Vec<u8>{
        let mut exif=vec![0,0,0,0];exif.extend_from_slice(tiff);
        let mut infe=vec![2,0,0,0,0,7,0,0];infe.extend_from_slice(b"Exif");infe.push(0);
        let mut iinf=vec![0,0,0,0,0,1];iinf.extend_from_slice(&box_bytes(b"infe",&infe));
        let mut iloc=vec![1,0,0,0,0x44,0,0,1,0,7];iloc.extend_from_slice(&method.to_be_bytes());
        iloc.extend_from_slice(&[0,0,0,2]); // local data reference; two extents
        let cut=exif.len()/2;
        for(off,n)in[(0,cut),(cut,exif.len()-cut)]{iloc.extend_from_slice(&(off as u32).to_be_bytes());iloc.extend_from_slice(&(n as u32).to_be_bytes());}
        let mut meta=vec![0,0,0,0];meta.extend_from_slice(&box_bytes(b"iinf",&iinf));meta.extend_from_slice(&box_bytes(b"iloc",&iloc));
        let ftyp=box_bytes(b"ftyp",b"mif1\0\0\0\0mif1");
        if method==1{meta.extend_from_slice(&box_bytes(b"idat",&exif));let mut out=ftyp;out.extend_from_slice(&box_bytes(b"meta",&meta));out}
        else{
            let absolute=ftyp.len()+8+meta.len()+8;
            // Only the selected physical offsets change; all TIFF data stays exact.
            let iloc_start=4+8+iinf.len()+8;let first_offset=iloc_start+16;
            meta[first_offset..first_offset+4].copy_from_slice(&(absolute as u32).to_be_bytes());
            meta[first_offset+8..first_offset+12].copy_from_slice(&((absolute+cut)as u32).to_be_bytes());
            let mut out=ftyp;out.extend_from_slice(&box_bytes(b"meta",&meta));out.extend_from_slice(&box_bytes(b"mdat",&exif));out
        }
    }
    #[test]
    fn borrowed_container_metadata_matches_retained_exif_fields(){
        let original=fixture(true,false,false,64);
        let mut jpeg=vec![0xff,0xd8,0xff,0xe1];jpeg.extend_from_slice(&u16::try_from(original.len()+8).unwrap().to_be_bytes());jpeg.extend_from_slice(b"Exif\0\0");jpeg.extend_from_slice(&original);jpeg.extend_from_slice(&[0xff,0xd9]);
        let mut png=b"\x89PNG\r\n\x1a\n".to_vec();png.extend_from_slice(&(original.len()as u32).to_be_bytes());png.extend_from_slice(b"eXIf");png.extend_from_slice(&original);png.extend_from_slice(&[0;4]);
        let mut webp=b"RIFF\0\0\0\0WEBPEXIF".to_vec();webp.extend_from_slice(&(original.len()as u32).to_le_bytes());webp.extend_from_slice(&original);
        if original.len()%2!=0{webp.push(0);}let n=(webp.len()-8)as u32;webp[4..8].copy_from_slice(&n.to_le_bytes());
        for encoded in[jpeg,png,webp,heif(&original,0),heif(&original,1)]{
            let reference=exif::Reader::new().read_from_container(&mut Cursor::new(&encoded)).unwrap();
            let actual=source_container_text(&encoded,&()).unwrap();
            let text=|tag|match &reference.get_field(tag,exif::In::PRIMARY).unwrap().value{
                exif::Value::Ascii(v)=>String::from_utf8_lossy(&v[0]).trim().to_owned(),_=>panic!("retained ASCII field")};
            assert_eq!(actual.make.as_deref(),Some(text(exif::Tag::Make).as_str()));
            assert_eq!(actual.lens.as_deref(),Some(text(exif::Tag::LensModel).as_str()));
            assert_eq!(actual.captured.as_deref(),Some(text(exif::Tag::DateTimeOriginal).as_str()));
            assert_eq!(actual.orientation,reference.get_field(exif::Tag::Orientation,exif::In::PRIMARY).unwrap().value.get_uint(0));
        }
    }
    #[test]
    fn borrowed_psd_and_raf_metadata_keep_the_original_pixel_container(){
        let original=fixture(true,false,false,64);
        let mut resource=b"8BIM".to_vec();resource.extend_from_slice(&1058_u16.to_be_bytes());resource.extend_from_slice(&[0,0]);
        resource.extend_from_slice(&(original.len()as u32).to_be_bytes());resource.extend_from_slice(&original);if original.len()%2!=0{resource.push(0);}
        let mut psd=vec![0;26];psd[..4].copy_from_slice(b"8BPS");psd.extend_from_slice(&[0;4]);psd.extend_from_slice(&(resource.len()as u32).to_be_bytes());psd.extend_from_slice(&resource);
        let mut jpeg=vec![0xff,0xd8,0xff,0xe1];jpeg.extend_from_slice(&u16::try_from(original.len()+8).unwrap().to_be_bytes());jpeg.extend_from_slice(b"Exif\0\0");jpeg.extend_from_slice(&original);jpeg.extend_from_slice(&[0xff,0xd9]);
        let mut raf=vec![0;92];raf[..14].copy_from_slice(b"FUJIFILMCCD-RAW");raf[84..88].copy_from_slice(&92_u32.to_be_bytes());raf[88..92].copy_from_slice(&(jpeg.len()as u32).to_be_bytes());raf.extend_from_slice(&jpeg);
        for encoded in[psd,raf]{let before=encoded.clone();let actual=source_container_text(&encoded,&()).unwrap();
            assert_eq!(actual.make.as_deref(),Some("Make"));assert_eq!(actual.orientation,Some(6));assert_eq!(encoded,before);}
    }
    #[test]
    fn heif_extent_limit_and_container_cancellation_refuse_before_publication(){
        let failure=source_container_text(&heif(&fixture(true,false,false,65536),1),&()).err().unwrap();
        assert_eq!(failure.status,DecodeStatus::Unsupported);assert!(failure.message.contains("65535-byte"));
        let canceled=std::sync::atomic::AtomicBool::new(true);
        let failure=source_container_text(&heif(&fixture(true,false,false,64),1),&canceled).err().unwrap();
        assert_eq!(failure.status,DecodeStatus::Io);assert!(failure.message.contains("metadata canceled"));
        let mut malformed=heif(&fixture(true,false,false,64),1);malformed[0..4].copy_from_slice(&u32::MAX.to_be_bytes());
        let failure=source_container_text(&malformed,&()).err().unwrap();assert!(failure.message.contains("truncated box"));
    }

    struct CancelAfter(AtomicUsize);
    impl crate::edit::CancelCheck for CancelAfter{fn is_canceled(&self)->bool{self.0.fetch_add(1,Ordering::SeqCst)>=1}}
    #[test]
    fn metadata_cancel_stops_before_reading_the_first_external_text_block(){
        let failure=source_tiff_text(&mut held(&fixture(true,false,false,8192)),&CancelAfter(AtomicUsize::new(0))).err().unwrap();
        assert_eq!(failure.status,DecodeStatus::Io);assert!(failure.message.contains("metadata canceled"));
    }
    #[test]
    fn metadata_first_text_value_remains_bounded_by_descriptor_allowance(){
        let mut bytes=fixture(true,false,false,2*1024*1024);
        let data=8+2+3*12+4+2+2*12+4;bytes[data..data+1024*1024+1].fill(b'x');
        let failure=source_tiff_text(&mut held(&bytes),&()).err().unwrap();
        assert_eq!(failure.status,DecodeStatus::ResourceLimit);assert!(failure.message.contains("descriptor allowance"));
    }
}

#[cfg(test)]
mod source_encoded_read_tests {
    use super::*;
    use std::sync::atomic::{AtomicBool,Ordering};
    struct Chunks<'a>{bytes:&'a[u8],calls:usize,interrupt:bool,cancel:Option<&'a AtomicBool>}
    impl Read for Chunks<'_>{fn read(&mut self,out:&mut[u8])->std::io::Result<usize>{
        self.calls+=1;
        assert!(out.len()<=1024*1024);
        if self.interrupt{self.interrupt=false;return Err(std::io::ErrorKind::Interrupted.into());}
        let count=self.bytes.len().min(out.len()).min(137);
        out[..count].copy_from_slice(&self.bytes[..count]);self.bytes=&self.bytes[count..];
        if let Some(cancel)=self.cancel{cancel.store(true,Ordering::SeqCst);}
        Ok(count)
    }}
    #[test]
    fn encoded_read_preserves_every_short_range_and_interrupt(){
        let original=(0..2*1024*1024+13).map(|i|(i%251)as u8).collect::<Vec<_>>();
        let mut reader=Chunks{bytes:&original,calls:0,interrupt:true,cancel:None};
        let mut actual=vec![0;original.len()];read_source_exact(&mut reader,&mut actual,&()).unwrap();
        assert_eq!(actual,original);assert!(reader.calls>2);assert!(reader.bytes.is_empty());
    }
    #[test]
    fn encoded_read_refuses_short_source_and_stops_on_cancellation(){
        let mut short=Chunks{bytes:&[1,2],calls:0,interrupt:false,cancel:None};
        let failure=read_source_exact(&mut short,&mut[0;3],&()).err().unwrap();
        assert_eq!(failure.status,DecodeStatus::Io);assert!(failure.message.contains("ended early"));
        let cancel=AtomicBool::new(false);let original=[7;512];
        let mut reader=Chunks{bytes:&original,calls:0,interrupt:false,cancel:Some(&cancel)};let mut output=[0;512];
        let failure=read_source_exact(&mut reader,&mut output,&cancel).err().unwrap();
        assert_eq!(failure.status,DecodeStatus::Io);assert!(failure.message.contains("read canceled"));
        assert_eq!(reader.calls,1);assert_eq!(&output[..137],&original[..137]);assert!(output[137..].iter().all(|x|*x==0));
    }
}

#[cfg(test)]
mod explicit_source_raw_tests {
    use super::*;
    struct Sink{rows:usize}
    impl LinearRowSink for Sink {
        fn write_row(&mut self,_:u32,_:u32,_:u32,_:u32,_:&[[f32;4]])->Result<()>{self.rows+=1;Ok(())}
    }
    #[test]
    fn admitted_raw_cannot_publish_tiff_raster_pixels_through_an_unlisted_extension(){
        let mut held=tempfile::tempfile().unwrap();
        {let mut encoder=tiff::encoder::TiffEncoder::new(&mut held).unwrap();
            encoder.write_image::<tiff::encoder::colortype::RGBA32Float>(2,2,&[2.,-1.,0.,1.,2.,-1.,0.,1.,2.,-1.,0.,1.,2.,-1.,0.,1.]).unwrap();}
        held.seek(SeekFrom::Start(0)).unwrap();
        let limits=DecodeLimits{max_encoded_bytes:512*1024*1024,max_intermediate_pixels:200_000_000,max_allocation_bytes:64*1024*1024};
        let mut raster=Sink{rows:0};
        let baseline=decode_with_white_point_held_rows(held.try_clone().unwrap(),Path::new("/admitted-source.nrw"),limits,None,&mut raster,&(),false).unwrap();
        assert!(baseline.provenance.decoder.contains("seekable original"));assert_eq!(raster.rows,2);
        held.seek(SeekFrom::Start(0)).unwrap();let mut raw=Sink{rows:0};
        match decode_with_white_point_held_rows(held,Path::new("/admitted-source.nrw"),limits,None,&mut raw,&(),true){
            Ok(summary)=>{assert_eq!(summary.metadata.format,"NRW");assert!(summary.provenance.decoder.contains("LibRaw"));assert!(!summary.provenance.decoder.contains("seekable original"));}
            Err(failure)=>{assert!(!failure.message.is_empty());assert_eq!(raw.rows,0);}
        }
        // This is route/refusal conservation, not support qualification for NRW.
    }
}

#[cfg(test)]
mod source_aggregate_admission_tests {
    use super::*;
    #[test]
    fn every_streamed_codec_shares_the_retained_input_row_profile_text_allowance(){
        let encoded=1024;let retained=encoded+30_000*64*16+16*1024*1024+4*1024*1024;
        let limits=DecodeLimits{max_encoded_bytes:encoded,max_intermediate_pixels:200_000_000,max_allocation_bytes:retained+1};
        assert_eq!(source_decoder_budget(limits,encoded).unwrap(),1);
        let failure=source_decoder_budget(DecodeLimits{max_allocation_bytes:retained,..limits},encoded).err().unwrap();
        assert_eq!(failure.status,DecodeStatus::ResourceLimit);assert!(failure.message.contains("retained input/row"));
        assert_eq!(source_decoder_budget(limits,u64::MAX).err().unwrap().status,DecodeStatus::ResourceLimit);
    }
}
