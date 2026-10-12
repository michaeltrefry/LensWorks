//! Isolated full-resolution retained decoder. No catalog handle/SQLite owner is
//! opened here. Authority is either a prepared catalog plan or an explicit
//! admitted document source revision; the two descriptor kinds cannot alias.
use anyhow::{Context, Result, ensure};
use photocatalog::{
    application::exports::{DecodeLimits, Plan},
    media, metadata_export,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    io::{Read, Seek, SeekFrom, Write},
    path::Path,
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}},
    time::{Duration, Instant},
};
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, PermissionsExt};

/// The decoder has exited before this identity is published. Whole payload
/// validation and every later range refer to this same private unlinked file,
/// including its mutation times; a new same-length generation is not adopted.
#[derive(Debug, Clone, PartialEq, Eq)]
struct HeldSourcePlaneIdentity {
    bytes: u64,
    modified: std::time::SystemTime,
    #[cfg(windows)] windows:(u32,u64,u32,u32),
    #[cfg(unix)] dev: u64,
    #[cfg(unix)] inode: u64,
    #[cfg(unix)] mode: u32,
    #[cfg(unix)] uid: u32,
    #[cfg(unix)] links: u64,
    #[cfg(unix)] changed: (i64,i64),
}
impl HeldSourcePlaneIdentity {
    fn capture(file:&std::fs::File) -> Result<Self> {
        let metadata=file.metadata()?;
        ensure!(metadata.is_file(),"source plane backing type changed");
        #[cfg(unix)]
        ensure!(metadata.nlink()==0 && metadata.mode() & 0o777 == 0o444,
            "source plane private immutable backing changed");
        Ok(Self {
            bytes:metadata.len(),modified:metadata.modified()?,
            #[cfg(windows)] windows:windows_held_identity(file)?,
            #[cfg(unix)] dev:metadata.dev(),
            #[cfg(unix)] inode:metadata.ino(),
            #[cfg(unix)] mode:metadata.mode(),
            #[cfg(unix)] uid:metadata.uid(),
            #[cfg(unix)] links:metadata.nlink(),
            #[cfg(unix)] changed:(metadata.ctime(),metadata.ctime_nsec()),
        })
    }
}
const MAGIC: &[u8; 8] = b"LWFLT002";
const MAX_HEADER: usize = 1024 * 1024;
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Input {
    plan: Option<Plan>,
    source: Option<SourceDevelopment>,
    tile: Option<SourceTileRect>,
    #[serde(default)]
    spool: bool,
    limits: DecodeLimits,
    worker_bytes: u64,
    max_output_bytes: u64,
}
/// A standalone document decode cannot manufacture a catalog export identity.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct SourceDevelopment {
    pub original: photocatalog::storage_volume::NativePath,
    pub original_revision: photocatalog::application::exports::FileRevision,
    pub white_balance: photocatalog::edit::WhiteBalance,
    pub request_id: String,
    pub raw_hint: bool,
}
/// A range of the complete oriented original, never a browse image or new authority.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct SourceTileRect { pub x: u32, pub y: u32, pub width: u32, pub height: u32 }
impl SourceTileRect {
    pub(crate) fn validate(&self, frame: Option<(u32, u32)>, maximum_bytes: u64) -> Result<u64> {
        let right = self.x.checked_add(self.width).context("source tile x overflow")?;
        let bottom = self.y.checked_add(self.height).context("source tile y overflow")?;
        let bytes = u64::from(self.width).checked_mul(self.height.into())
            .and_then(|n| n.checked_mul(16)).context("source tile extent overflow")?;
        ensure!(self.width != 0 && self.height != 0 && bytes <= maximum_bytes, "source tile result allowance");
        if let Some((width, height)) = frame { ensure!(right <= width && bottom <= height, "source tile outside oriented frame"); }
        Ok(bytes)
    }
}
impl Input {
    fn authority(&self) -> Result<Value> {
        ensure!(!self.spool || (self.source.is_some() && self.plan.is_none() && self.tile.is_none()), "spool requires complete standalone original");
        if let Some(tile) = self.tile {
            ensure!(self.plan.is_none() && self.source.is_some(), "tile requires standalone original authority");
            tile.validate(None, self.max_output_bytes)?;
        }
        match (&self.plan, &self.source) {
            (Some(plan), None) => Ok(json!({"source_identity":plan.identity,"original":plan.original,
                "original_revision":plan.original_revision,"plan_authority":plan.authority})),
            (None, Some(source)) => {
                ensure!(source.request_id.len() == 36 && source.request_id.bytes().enumerate().all(|(n, b)|
                    if [8,13,18,23].contains(&n) { b == b'-' } else { b.is_ascii_digit() || (b'a'..=b'f').contains(&b) }), "document request UUID");
                if let photocatalog::edit::WhiteBalance::TemperatureTint { kelvin, tint } = &source.white_balance {
                    ensure!((2000..=50000).contains(kelvin) && tint.is_finite() && (-150.0..=150.0).contains(tint), "camera white balance range");
                }
                let mut authority = json!({"source_authority":source});
                if let Some(tile) = self.tile { authority["tile_rect"] = serde_json::to_value(tile)?; }
                Ok(authority)
            }
            _ => anyhow::bail!("exactly one source authority required"),
        }
    }
    fn original(&self) -> Result<&photocatalog::storage_volume::NativePath> {
        match (&self.plan, &self.source) {
            (Some(plan), None) => Ok(&plan.original),
            (None, Some(source)) => Ok(&source.original),
            _ => anyhow::bail!("exactly one source authority required"),
        }
    }
    fn revision(&self) -> Result<&photocatalog::application::exports::FileRevision> {
        match (&self.plan, &self.source) {
            (Some(plan), None) => Ok(&plan.original_revision),
            (None, Some(source)) => Ok(&source.original_revision),
            _ => anyhow::bail!("exactly one source authority required"),
        }
    }
    fn kind(&self) -> &'static str { if self.spool { "source_float_plane" } else if self.tile.is_some() { "source_float_tile" } else if self.source.is_some() { "source_float" } else { "float" } }
}
fn limits(i: &Input) -> Result<media::DecodeLimits> {
    let l = media::DecodeLimits {
        max_encoded_bytes: i.limits.max_encoded_bytes.0,
        max_intermediate_pixels: i.limits.max_intermediate_pixels.0,
        max_allocation_bytes: i.limits.max_allocation_bytes.0,
    };
    l.validate()?;
    ensure!(
        [
            l.max_encoded_bytes,
            l.max_intermediate_pixels,
            l.max_allocation_bytes,
            i.worker_bytes,
            i.max_output_bytes
        ]
        .iter()
        .all(|n| *n != 0 && *n != u64::MAX),
        "explicit finite decode ceilings required"
    );
    ensure!(l.max_allocation_bytes <= i.worker_bytes,
        "decode allocations exceed worker allowance");
    if i.spool {
        ensure!(i.max_output_bytes == source_plane_disk_bytes(l.max_intermediate_pixels)?,
            "source plane disk extent must match finite geometry authority");
    } else {
        ensure!(i.max_output_bytes <= i.worker_bytes,
            "decode output allocation exceeds worker allowance");
    }
    Ok(l)
}
fn check_source(i: &Input) -> Result<metadata_export::FileRevision> {
    i.authority()?;
    let path = i.original()?.to_path()?;
    let actual = metadata_export::inspect_file_revision(&path, i.limits.max_encoded_bytes.0)?;
    let expected = i.revision()?;
    ensure!(
        actual.bytes == expected.bytes.0
            && actual.digest == expected.digest
            && actual.modified_ns == expected.modified_ns.0
            && actual.identity == (expected.identity.0.0, expected.identity.1.0),
        "source physical/content revision changed"
    );
    if let Some(plan) = &i.plan {
        ensure!(plan.identity.source.fingerprint.as_ref().is_some_and(|f| f == &actual.digest),
            "source fingerprint missing or changed");
    }
    Ok(actual)
}
// Bounded row blocks transpose the same native scene samples into one private
// disk generation. Native decoder stage allocations are separately admitted.
struct OrientedRows {
    file:std::fs::File,
    shape:Option<(u32,u32,u32)>,
    rows:Vec<[f32;4]>,
    first:u32,
    next:u32,
    block_rows:u32,
    maximum_bytes:u64,
    maximum_pixels:u64,
    payload_offset:u64,
    maximum_output_bytes:u64,
}
impl OrientedRows {
    fn new(maximum_bytes:u64,maximum_pixels:u64)->Result<Self> {
        Self::with_file(tempfile::tempfile()?,maximum_bytes,maximum_pixels,0,u64::MAX)
    }
    fn with_file(file:std::fs::File,maximum_bytes:u64,maximum_pixels:u64,payload_offset:u64,maximum_output_bytes:u64)->Result<Self>{
        let metadata=file.metadata()?;
        ensure!(metadata.is_file()&&metadata.len()==0,"scene backing must be a new empty held regular file");
        #[cfg(unix)]ensure!(metadata.nlink()==0&&metadata.mode()&0o777==0o600&&metadata.uid()==unsafe{libc::getuid()},"scene backing private owner");
        Ok(Self{file,shape:None,rows:Vec::new(),first:0,next:0,
            block_rows:64,maximum_bytes,maximum_pixels,payload_offset,maximum_output_bytes})
    }
    fn flush_block(&mut self)->Result<()> {
        let (width,height,orientation)=self.shape.context("missing scene row shape")?;
        let count=self.next-self.first;
        if count==0{return Ok(());}
        let (out_width,_)=if orientation>=5{(height,width)}else{(width,height)};
        let mut encoded=Vec::<u8>::new();
        let segment=if orientation>=5{count}else{width};
        encoded.try_reserve_exact(segment as usize*16)?;
        if orientation<=4 {
            for row in 0..count {
                encoded.clear();
                let start=row as usize*width as usize;
                for x in 0..width {
                    let sx=if matches!(orientation,2|3){width-1-x}else{x};
                    for sample in self.rows[start+sx as usize]{encoded.extend_from_slice(&sample.to_le_bytes());}
                }
                let sy=self.first+row;
                let dy=if matches!(orientation,3|4){height-1-sy}else{sy};
                self.file.seek(SeekFrom::Start(self.payload_offset+u64::from(dy)*u64::from(out_width)*16))?;
                self.file.write_all(&encoded)?;
            }
        }else{
            for sx in 0..width {
                encoded.clear();
                for row in 0..count {
                    let sy=if matches!(orientation,6|7){count-1-row}else{row};
                    for sample in self.rows[sy as usize*width as usize+sx as usize]{encoded.extend_from_slice(&sample.to_le_bytes());}
                }
                let dy=if matches!(orientation,7|8){width-1-sx}else{sx};
                let dx=if matches!(orientation,6|7){height-self.next}else{self.first};
                self.file.seek(SeekFrom::Start(self.payload_offset+(u64::from(dy)*u64::from(out_width)+u64::from(dx))*16))?;
                self.file.write_all(&encoded)?;
            }
        }
        self.rows.clear();self.first=self.next;Ok(())
    }
    fn finish(mut self,width:u32,height:u32)->Result<std::fs::File> {
        self.flush_block()?;
        let (raw_width,raw_height,orientation)=self.shape.context("missing scene rows")?;
        ensure!(self.next==raw_height,"scene row count mismatch");
        let expected=if orientation>=5{(raw_height,raw_width)}else{(raw_width,raw_height)};
        ensure!(expected==(width,height),"oriented scene shape mismatch");
        let bytes=u64::from(width)*u64::from(height)*16;
        ensure!(self.file.metadata()?.len()==self.payload_offset+bytes,"oriented scene backing extent mismatch");
        self.file.flush()?;self.file.sync_all()?;self.file.seek(SeekFrom::Start(self.payload_offset))?;Ok(self.file)
    }
}
impl media::LinearRowSink for OrientedRows {
    fn write_row(&mut self,width:u32,height:u32,orientation:u32,row:u32,pixels:&[[f32;4]])
        ->std::result::Result<(),media::DecodeError> {
        let result=(||->Result<()> {
            ensure!(width>0&&height>0&&width<=30000&&height<=30000&&u64::from(width)*u64::from(height)<=self.maximum_pixels,
                "scene row source allowance");
            ensure!((1..=8).contains(&orientation)&&row==self.next&&row<height&&pixels.len()==width as usize,"scene row order/shape");
            if let Some(shape)=self.shape {ensure!(shape==(width,height,orientation),"scene row shape changed");}
            else{
                let reserve=u64::from(width)*u64::from(self.block_rows.min(height))*16;
                ensure!(reserve<=self.maximum_bytes.min(96*1024*1024),"scene row block allowance");
                let payload=u64::from(width).checked_mul(height.into()).and_then(|n|n.checked_mul(16)).context("scene output overflow")?;
                ensure!(payload<=self.maximum_output_bytes,"scene output exceeds admitted extent");
                let extent=self.payload_offset.checked_add(payload).context("scene frame overflow")?;
                self.rows.try_reserve_exact(usize::try_from(reserve/16)?)?;
                self.file.set_len(extent)?;self.shape=Some((width,height,orientation));
            }
            ensure!(pixels.iter().all(|p|p.iter().all(|v|v.is_finite())&&(0.0..=1.0).contains(&p[3])),"invalid scene row samples");
            self.rows.extend_from_slice(pixels);self.next+=1;
            if self.next-self.first==self.block_rows||self.next==height {self.flush_block()?;}
            Ok(())
        })();
        result.map_err(|e|media::DecodeError{status:media::DecodeStatus::Io,message:e.to_string()})
    }
}

const REQUEST_MAGIC:&[u8;8]=b"LWREQ003";
const CANCEL_OFFSET:u64=16;
fn read_at(file:&std::fs::File,bytes:&mut[u8],offset:u64)->std::io::Result<usize> {
    #[cfg(unix)]{use std::os::unix::fs::FileExt;file.read_at(bytes,offset)}
    #[cfg(windows)]{use std::os::windows::fs::FileExt;file.seek_read(bytes,offset)}
}
fn write_at(file:&std::fs::File,bytes:&[u8],offset:u64)->std::io::Result<usize> {
    #[cfg(unix)]{use std::os::unix::fs::FileExt;file.write_at(bytes,offset)}
    #[cfg(windows)]{use std::os::windows::fs::FileExt;file.seek_write(bytes,offset)}
}
#[cfg(unix)]
fn held_standard(kind:i32)->Result<std::fs::File>{
    use std::os::fd::FromRawFd;
    let fd=unsafe{libc::fcntl(kind,libc::F_DUPFD_CLOEXEC,0)};
    ensure!(fd>=0,"held decode standard descriptor");Ok(unsafe{std::fs::File::from_raw_fd(fd)})
}
#[cfg(windows)]
fn held_standard(kind:i32)->Result<std::fs::File>{
    use std::os::windows::io::FromRawHandle;
    unsafe extern "system" {
        fn GetCurrentProcess()->*mut std::ffi::c_void;
        fn GetStdHandle(kind:u32)->*mut std::ffi::c_void;
        fn DuplicateHandle(source:*mut std::ffi::c_void,handle:*mut std::ffi::c_void,target:*mut std::ffi::c_void,
            duplicate:*mut *mut std::ffi::c_void,access:u32,inherit:i32,options:u32)->i32;
    }
    let mut duplicate=std::ptr::null_mut();
    let handle=if kind==0{-10_i32}else{-11_i32};
    let status=unsafe{let process=GetCurrentProcess();DuplicateHandle(process,GetStdHandle(handle as u32),process,&mut duplicate,0,0,2)};
    ensure!(status!=0&&!duplicate.is_null(),"held decode standard handle");
    Ok(unsafe{std::fs::File::from_raw_handle(duplicate)})
}
fn held_stdin()->Result<std::fs::File>{held_standard(0)}
fn held_stdout()->Result<std::fs::File>{held_standard(1)}
#[cfg(windows)]
fn windows_held_identity(file:&std::fs::File)->Result<(u32,u64,u32,u32)>{
    use std::os::windows::io::AsRawHandle;
    #[repr(C)]struct Info{attributes:u32,creation:[u32;2],access:[u32;2],write:[u32;2],volume:u32,
        size_high:u32,size_low:u32,links:u32,index_high:u32,index_low:u32}
    unsafe extern "system"{fn GetFileInformationByHandle(handle:*mut std::ffi::c_void,info:*mut Info)->i32;}
    let mut info=std::mem::MaybeUninit::<Info>::zeroed();
    ensure!(unsafe{GetFileInformationByHandle(file.as_raw_handle(),info.as_mut_ptr())}!=0,"decode held Windows file identity");
    let info=unsafe{info.assume_init()};
    ensure!(info.attributes&(0x10|0x400)==0&&info.links==1,"decode Windows private regular identity");
    Ok((info.volume,(u64::from(info.index_high)<<32)|u64::from(info.index_low),info.attributes,info.links))
}
struct WorkerCancel {
    file:std::fs::File,
    bytes:u64,
    #[cfg(unix)] identity:(u64,u64,u32,u32,u64),
    #[cfg(windows)] identity:(u32,u64,u32,u32),
}
impl WorkerCancel {
    fn new(file:std::fs::File,bytes:u64)->Result<Self> {
        let metadata=file.metadata()?;
        ensure!(metadata.is_file()&&metadata.len()==bytes,"decode request held extent/type");
        #[cfg(unix)]ensure!(metadata.nlink()==0&&metadata.mode()&0o777==0o600,"decode request private identity");
        Ok(Self{bytes,
            #[cfg(unix)]identity:(metadata.dev(),metadata.ino(),metadata.mode(),metadata.uid(),metadata.nlink()),
            #[cfg(windows)]identity:windows_held_identity(&file)?,file,
        })
    }
    fn check_held(&self)->Result<bool> {
        let metadata=self.file.metadata()?;ensure!(metadata.is_file()&&metadata.len()==self.bytes,"decode cancellation backing changed");
        #[cfg(unix)]ensure!((metadata.dev(),metadata.ino(),metadata.mode(),metadata.uid(),metadata.nlink())==self.identity,"decode cancellation identity changed");
        #[cfg(windows)]ensure!(windows_held_identity(&self.file)?==self.identity,"decode cancellation identity changed");
        let mut flag=[0];ensure!(read_at(&self.file,&mut flag,CANCEL_OFFSET)?==1,"decode cancellation short read");
        ensure!(flag[0]<=1,"decode cancellation protocol changed");Ok(flag[0]!=0)
    }
}
impl photocatalog::edit::CancelCheck for WorkerCancel {
    fn is_canceled(&self)->bool{self.check_held().unwrap_or(true)}
}
pub fn worker_main() -> Result<()> {
    let mut request=held_stdin()?;let mut prefix=[0;17];request.read_exact(&mut prefix)?;
    ensure!(&prefix[..8]==REQUEST_MAGIC&&prefix[16]==0,"decode request frame/version/cancel state");
    let length=u64::from_le_bytes(prefix[8..16].try_into()?);
    ensure!(length<=MAX_HEADER as u64,"decode request header allowance");
    let mut input=vec![0;usize::try_from(length)?];request.read_exact(&mut input)?;
    let cancel=WorkerCancel::new(request,17+length)?;
    photocatalog::edit::CancelCheck::check(&cancel)?;
    let i: Input = serde_json::from_slice(&input)?;
    let l = limits(&i)?;
    let before = check_source(&i)?;
    if i.spool {
        let source=i.source.as_ref().context("source plane requires document authority")?;
        // Random writes target the parent-held collector directly. The reserved
        // descriptor stays invalid until every row and source recheck succeeds.
        let mut rows=OrientedRows::with_file(held_stdout()?,l.max_allocation_bytes,i.limits.max_intermediate_pixels.0,
            24+MAX_HEADER as u64,i.max_output_bytes)?;
        let original=source.original.to_path()?;
        let rendered=photocatalog::edit::decode_original_source_rows(photocatalog::edit::OriginalRequest{
            path:&original,expected_fingerprint:&source.original_revision.digest,white_balance:&source.white_balance,
        },l,&cancel,&mut rows,source.raw_hint)?;
        let extent=u64::from(rendered.width).checked_mul(rendered.height.into()).and_then(|n|n.checked_mul(16)).context("scene extent overflow")?;
        ensure!(extent<=i.max_output_bytes,"scene disk extent allowance");
        ensure!(check_source(&i)?==before,"source changed during scene decode");
        let mut scene=rows.finish(rendered.width,rendered.height)?;
        let mut descriptor=json!({"source_revision":crate::SOURCE_REVISION,"protocol":2,"kind":i.kind(),"mime":"application/x-lensworks-rgba-f32le",
            "width":rendered.width,"height":rendered.height,"row_stride":(u64::from(rendered.width)*16).to_string(),"byte_length":extent.to_string(),
            "channels":4,"sample":"float32_le","color_space":"linear_srgb","alpha":"straight","orientation":"applied",
            "metadata":rendered.metadata,"provenance":rendered.provenance,
            "memory_enforcement":"bounded row publication and sampled child RSS watchdog; native decoder scratch is not a hard RSS ceiling"});
        descriptor.as_object_mut().context("scene descriptor object")?.extend(i.authority()?.as_object().context("source authority object")?.clone());
        let header=serde_json::to_vec(&descriptor)?;ensure!(header.len()<=MAX_HEADER,"scene descriptor allowance");
        publish_scene_descriptor(&mut scene,&header,extent,&cancel)?;
        return Ok(());
    }
    let rendered = if let Some(source) = &i.source {
        photocatalog::edit::decode_original_source(photocatalog::edit::OriginalRequest {
            path: &source.original.to_path()?, expected_fingerprint: &source.original_revision.digest,
            white_balance: &source.white_balance,
        }, l, &cancel, source.raw_hint)?.into_rendered()
    } else { media::decode_full_limited(&i.original()?.to_path()?, l)? };
    let full_count = u64::from(rendered.width).checked_mul(rendered.height.into()).context("pixel extent overflow")?;
    ensure!(rendered.pixels.len() as u64 == full_count, "full original pixel extent mismatch");
    let rect = i.tile.unwrap_or(SourceTileRect { x: 0, y: 0, width: rendered.width, height: rendered.height });
    let extent = rect.validate(Some((rendered.width, rendered.height)), i.max_output_bytes)?;
    ensure!(check_source(&i)? == before, "source changed during decode");
    let mut descriptor = json!({"source_revision":crate::SOURCE_REVISION,"protocol":2,"kind":i.kind(),"mime":"application/x-lensworks-rgba-f32le","width":rect.width,"height":rect.height,"row_stride":(u64::from(rect.width)*16).to_string(),"byte_length":extent.to_string(),"channels":4,"sample":"float32_le","color_space":"linear_srgb","alpha":"straight","orientation":"applied","metadata":rendered.metadata,"provenance":rendered.provenance,"memory_enforcement":"explicit per-surface limits and sampled child RSS watchdog; native scratch is not a hard RSS ceiling"});
    descriptor.as_object_mut().context("float descriptor object")?.extend(i.authority()?.as_object().context("source authority object")?.clone());
    if i.tile.is_some() { descriptor["frame_width"] = rendered.width.into(); descriptor["frame_height"] = rendered.height.into(); }
    let header = serde_json::to_vec(&descriptor)?;
    ensure!(header.len() <= MAX_HEADER, "float descriptor allowance");
    let mut output = std::io::BufWriter::new(std::io::stdout().lock());
    output.write_all(MAGIC)?;
    output.write_all(&(header.len() as u64).to_le_bytes())?;
    output.write_all(&extent.to_le_bytes())?;
    output.write_all(&header)?;
    for y in rect.y..rect.y + rect.height {
        photocatalog::edit::CancelCheck::check(&cancel)?;
        let start = (u64::from(y) * u64::from(rendered.width) + u64::from(rect.x)) as usize;
        for pixel in &rendered.pixels[start..start + rect.width as usize] {
            ensure!(pixel.iter().all(|v| v.is_finite()) && (0.0..=1.0).contains(&pixel[3]), "invalid retained float pixel");
            for sample in pixel { output.write_all(&sample.to_le_bytes())?; }
        }
    }
    output.flush()?;
    Ok(())
}
fn publish_scene_descriptor(scene:&mut std::fs::File,header:&[u8],extent:u64,
    cancel:&dyn photocatalog::edit::CancelCheck)->Result<()> {
    ensure!(header.len()<=MAX_HEADER&&scene.metadata()?.len()==24+MAX_HEADER as u64+extent,"scene publication extent");
    photocatalog::edit::CancelCheck::check(cancel)?;
    scene.seek(SeekFrom::Start(0))?;
    scene.write_all(MAGIC)?;scene.write_all(&(MAX_HEADER as u64).to_le_bytes())?;
    scene.write_all(&extent.to_le_bytes())?;scene.write_all(&header)?;
    // JSON permits trailing whitespace. Header padding is within the same
    // existing 1 MiB bound and avoids relocating/copying the full payload.
    let spaces=[b' ';65536];let mut remaining=MAX_HEADER-header.len();
    while remaining>0{photocatalog::edit::CancelCheck::check(cancel)?;
        let n=remaining.min(spaces.len());scene.write_all(&spaces[..n])?;remaining-=n;}
    scene.flush()?;scene.sync_all()?;photocatalog::edit::CancelCheck::check(cancel)?;
    Ok(())
}
/// An unsuccessful checked drain retains this exact Child, never a PID lookup.
/// Managed jobs retain this owner and their worker admission until try_drain proves exit.
#[derive(Debug)]
pub(crate) struct RetainedDecoder {
    child: Mutex<Option<Child>>,
    #[cfg(test)] refuse_drain: AtomicBool,
}
impl RetainedDecoder {
    fn new(child: Child) -> Self { Self { child:Mutex::new(Some(child)), #[cfg(test)] refuse_drain:AtomicBool::new(false) } }
    pub(crate) fn is_drained(&self)->bool{self.child.lock().unwrap_or_else(|e|e.into_inner()).is_none()}
    pub(crate) fn try_drain(&self) -> Result<()> {
        #[cfg(test)] ensure!(!self.refuse_drain.load(Ordering::Acquire), "injected owned drain uncertainty");
        let mut held=self.child.lock().unwrap_or_else(|e|e.into_inner());
        let Some(child)=held.as_mut() else { return Ok(()); };
        if child.try_wait()?.is_some(){held.take();return Ok(());}
        if let Err(failure)=child.kill(){
            if child.try_wait()?.is_none(){return Err(failure).context("owned decode termination still unverified");}
        }
        // No wait under a managed command lock: the existing Close polling/deadline
        // owns retries. Sending termination alone never proves an observed exit.
        ensure!(child.try_wait()?.is_some(), "owned decode child is still draining");
        held.take();Ok(())
    }
    #[cfg(test)] pub(crate) fn fixture(child:Child)->Arc<Self>{Arc::new(Self::new(child))}
    #[cfg(test)] pub(crate) fn refuse(&self, value:bool){self.refuse_drain.store(value,Ordering::Release);}
}
#[derive(Debug)]
pub(crate) struct RetainedDecodeFailure {
    pub(crate) owner: Arc<RetainedDecoder>,
    failure: String,
}
impl std::fmt::Display for RetainedDecodeFailure {
    fn fmt(&self, f:&mut std::fmt::Formatter<'_>)->std::fmt::Result{f.write_str(&self.failure)}
}
impl std::error::Error for RetainedDecodeFailure {}
struct ChildOwner(Arc<RetainedDecoder>);
impl ChildOwner {
    /// Runs on the job's own thread, never under a managed command lock, so it may
    /// give a just-killed child a short bounded window to be reaped. A child that
    /// still has not exited stays retained for the checked Close/JobRelease retry.
    fn stop_and_reap(&mut self)->Result<()> {
        let deadline=Instant::now()+Duration::from_secs(2);
        loop {
            match self.0.try_drain() {
                Ok(())=>return Ok(()),
                Err(failure) if Instant::now()>=deadline=>return Err(failure),
                Err(_)=>std::thread::sleep(Duration::from_millis(5)),
            }
        }
    }
}
impl Drop for ChildOwner {
    fn drop(&mut self) {
        // Exact owner is registered with the managed job before polling or any
        // result work. Unwind retries are nonblocking and never release that
        // registry owner or imply a checked exit.
        let _=self.0.try_drain();
    }
}
#[cfg(target_os = "macos")]
fn rss(pid: u32) -> Result<u64> {
    // PROC_PIDTASKINFO from the installed SDK. The first two u64 fields are
    // virtual_size/resident_size; remaining counters are irrelevant to admission.
    #[link(name = "proc")]
    unsafe extern "C" {
        fn proc_pidinfo(
            pid: i32,
            flavor: i32,
            arg: u64,
            buffer: *mut std::ffi::c_void,
            size: i32,
        ) -> i32;
    }
    let mut info = [0u64; 12];
    let n = unsafe {
        proc_pidinfo(
            pid as i32,
            4,
            0,
            info.as_mut_ptr().cast(),
            std::mem::size_of_val(&info) as i32,
        )
    };
    ensure!(
        n == std::mem::size_of_val(&info) as i32,
        "child RSS unavailable"
    );
    Ok(info[1])
}
#[cfg(target_os = "linux")]
fn rss(pid: u32) -> Result<u64> {
    let s = std::fs::read_to_string(format!("/proc/{pid}/status"))?;
    let n = s
        .lines()
        .find_map(|l| l.strip_prefix("VmRSS:"))
        .context("child RSS unavailable")?
        .split_whitespace()
        .next()
        .context("child RSS missing")?
        .parse::<u64>()?;
    Ok(n * 1024)
}
#[cfg(windows)]
fn rss(pid:u32)->Result<u64> {
    // Microsoft PROCESS_MEMORY_COUNTERS / K32GetProcessMemoryInfo. The owned
    // Child retains its process handle throughout this observation.
    #[repr(C)]struct Counters{cb:u32,page_faults:u32,peak_working_set:usize,working_set:usize,
        peak_paged:usize,paged:usize,peak_nonpaged:usize,nonpaged:usize,pagefile:usize,peak_pagefile:usize}
    #[link(name="kernel32")]
    unsafe extern "system" {
        fn OpenProcess(access:u32,inherit:i32,pid:u32)->*mut std::ffi::c_void;
        fn CloseHandle(handle:*mut std::ffi::c_void)->i32;
        fn K32GetProcessMemoryInfo(handle:*mut std::ffi::c_void,counters:*mut Counters,bytes:u32)->i32;
    }
    let handle=unsafe{OpenProcess(0x1000,0,pid)};ensure!(!handle.is_null(),"owned decode child RSS unavailable");
    struct Held(*mut std::ffi::c_void);impl Drop for Held{fn drop(&mut self){unsafe{CloseHandle(self.0);}}}
    let held=Held(handle);let mut counters=std::mem::MaybeUninit::<Counters>::zeroed();
    let bytes=u32::try_from(std::mem::size_of::<Counters>())?;
    unsafe{(*counters.as_mut_ptr()).cb=bytes;}
    ensure!(unsafe{K32GetProcessMemoryInfo(held.0,counters.as_mut_ptr(),bytes)}!=0,"owned decode child RSS read unavailable");
    let counters=unsafe{counters.assume_init()};ensure!(counters.cb==bytes,"owned decode RSS structure changed");
    Ok(u64::try_from(counters.working_set)?)
}
#[cfg(not(any(target_os = "macos", target_os = "linux",windows)))]
fn rss(_: u32) -> Result<u64> {
    anyhow::bail!("child RSS watchdog unsupported on host")
}
pub(crate) fn run(
    worker: &Path,
    plan: Plan,
    decode: DecodeLimits,
    worker_bytes: u64,
    max_output_bytes: u64,
    cancel: &AtomicBool,
    register: &dyn Fn(Arc<RetainedDecoder>),
) -> Result<(Vec<u8>, Value)> {
    run_input(worker, Input { plan: Some(plan), source: None, tile: None, spool: false, limits: decode, worker_bytes, max_output_bytes }, cancel, register)
}
pub(crate) fn run_source(worker: &Path, source: SourceDevelopment, decode: DecodeLimits,
    worker_bytes: u64, max_output_bytes: u64, cancel: &AtomicBool, register: &dyn Fn(Arc<RetainedDecoder>)) -> Result<(Vec<u8>, Value)> {
    run_input(worker, Input { plan: None, source: Some(source), tile: None, spool: false, limits: decode, worker_bytes, max_output_bytes }, cancel, register)
}
pub(crate) fn run_source_tile(worker: &Path, source: SourceDevelopment, tile: SourceTileRect,
    decode: DecodeLimits, worker_bytes: u64, max_output_bytes: u64, cancel: &AtomicBool, register: &dyn Fn(Arc<RetainedDecoder>)) -> Result<(Vec<u8>, Value)> {
    run_input(worker, Input { plan: None, source: Some(source), tile: Some(tile), spool: false, limits: decode, worker_bytes, max_output_bytes }, cancel, register)
}
fn run_output(worker: &Path, i: Input, cancel: &AtomicBool, register: &dyn Fn(Arc<RetainedDecoder>)) -> Result<SourcePlane> {
    let worker_bytes = i.worker_bytes;
    let max_output_bytes = i.max_output_bytes;
    i.authority()?;
    limits(&i)?;
    ensure!(
        !cancel.load(Ordering::Acquire),
        "decode canceled before launch"
    );
    let encoded = serde_json::to_vec(&i)?;
    ensure!(
        encoded.len() <= MAX_HEADER,
        "decode request header allowance"
    );
    let mut input = tempfile::tempfile()?;
    input.write_all(REQUEST_MAGIC)?;input.write_all(&(encoded.len() as u64).to_le_bytes())?;
    input.write_all(&[0])?;input.write_all(&encoded)?;input.flush()?;
    input.seek(SeekFrom::Start(0))?;
    let mut output = tempfile::tempfile()?;
    let stderr = tempfile::tempfile()?;
    let child = Command::new(worker)
        .arg("--lensworks-full-decode")
        .stdin(Stdio::from(input.try_clone()?))
        .stdout(Stdio::from(output.try_clone()?))
        .stderr(Stdio::from(stderr.try_clone()?))
        .spawn()?;
    let mut owner = ChildOwner(Arc::new(RetainedDecoder::new(child)));
    register(owner.0.clone());
    let start = Instant::now();
    let mut sample = Instant::now();
    let mut unsampled = 0u32;
    let exit_result=(||->Result<std::process::ExitStatus>{loop {
        let mut held=owner.0.child.lock().unwrap_or_else(|e|e.into_inner());
        let c=held.as_mut().context("owned decode child missing before terminal observation")?;
        if let Some(status) = c.try_wait()? {
            break Ok(status);
        }
        if cancel.load(Ordering::Acquire) {
            // One existing polling interval gives cooperative vendor checkpoints
            // a chance to unwind. The exact owned-child checked drain follows;
            // this adds no worker deadline or acceptance of an unobserved exit.
            ensure!(write_at(&input,&[1],CANCEL_OFFSET)?==1,"decode cancellation write");
            input.sync_data()?;std::thread::sleep(Duration::from_millis(10));
            if let Some(status)=c.try_wait()?{break Ok(status);}
            anyhow::bail!("decode canceled before owned child drain");
        }
        ensure!(
            start.elapsed() < Duration::from_secs(120),
            "decode worker deadline"
        );
        ensure!(
            output.metadata()?.len() <= max_output_bytes + MAX_HEADER as u64 + 24,
            "decode worker frame exceeded extent"
        );
        ensure!(
            stderr.metadata()?.len() <= 65536,
            "decode worker diagnostic allowance"
        );
        if sample.elapsed() >= Duration::from_millis(50) {
            match rss(c.id()) {
                Ok(resident) => ensure!(
                    resident <= worker_bytes,
                    "decode child resident memory exceeded watchdog allowance"
                ),
                // A child that exits after try_wait above loses its task info before
                // (and while) it is an unreaped zombie, so the sample fails. That is a
                // completing decode, not a watchdog fault: keep polling for its exit.
                // Only a live child whose memory stays unobservable is refused.
                Err(failure) => {
                    if let Some(status) = c.try_wait()? { break Ok(status); }
                    unsampled += 1;
                    ensure!(unsampled < 10, failure.context("decode child resident memory remained unobservable"));
                    std::thread::sleep(Duration::from_millis(10));
                    continue;
                }
            }
            unsampled = 0;
            sample = Instant::now();
        }
        std::thread::sleep(Duration::from_millis(10));
    }})();
    let exit=match exit_result {
        Ok(status)=>{owner.0.child.lock().unwrap_or_else(|e|e.into_inner()).take();status},
        Err(failure)=>{
            return match owner.stop_and_reap(){
                Ok(())=>Err(failure.context("owned decode child stopped and reaped; result refused")),
                Err(drain)=>{
                    Err(RetainedDecodeFailure { owner:owner.0.clone(),
                        failure:format!("{failure:#}; owned decode drain unverified: {drain:#}") }.into())
                },
            };
        }
    };
    ensure!(
        output.metadata()?.len() <= max_output_bytes + MAX_HEADER as u64 + 24
            && stderr.metadata()?.len() <= 65536,
        "final decode frame/diagnostic allowance"
    );
    if !exit.success() {
        // The worker reports its refusal on stderr (bounded above); forward it
        // so the caller sees the actual cause rather than only the exit status.
        let mut diagnostic = Vec::new();
        let mut held = &stderr;
        held.seek(SeekFrom::Start(0))?;
        held.take(2048).read_to_end(&mut diagnostic)?;
        anyhow::bail!(
            "decode worker failed ({exit}); source mismatch, resource admission or retained decoder failure: {}",
            String::from_utf8_lossy(&diagnostic).trim()
        );
    }
    ensure!(
        !cancel.load(Ordering::Acquire),
        "decode canceled after child drain"
    );
    output.seek(SeekFrom::Start(0))?;
    let mut prefix = [0u8; 24];
    output.read_exact(&mut prefix)?;
    ensure!(&prefix[..8] == MAGIC, "invalid float frame version");
    let header = u64::from_le_bytes(prefix[8..16].try_into()?);
    let bytes = u64::from_le_bytes(prefix[16..24].try_into()?);
    ensure!(
        header <= MAX_HEADER as u64
            && bytes <= max_output_bytes
            && output.metadata()?.len() == 24 + header + bytes,
        "float frame bounds"
    );
    let mut descriptor = vec![0; header as usize];
    output.read_exact(&mut descriptor)?;
    let descriptor: Value = serde_json::from_slice(&descriptor)?;
    let width = descriptor["width"].as_u64().context("float width")?;
    let height = descriptor["height"].as_u64().context("float height")?;
    ensure!(
        width > 0
            && height > 0
            && width.checked_mul(height).and_then(|n| n.checked_mul(16)) == Some(bytes)
            && descriptor["sample"] == "float32_le"
            && descriptor["color_space"] == "linear_srgb"
            && descriptor["alpha"] == "straight"
            && descriptor["row_stride"] == (width * 16).to_string()
            && descriptor["byte_length"] == bytes.to_string(),
        "float descriptor extent/color mismatch"
    );
    ensure!(
        descriptor["source_revision"] == crate::SOURCE_REVISION
            && descriptor["protocol"] == 2
            && descriptor["kind"] == i.kind()
            && descriptor["mime"] == "application/x-lensworks-rgba-f32le"
            && descriptor["channels"] == 4
            && descriptor["orientation"] == "applied",
        "float protocol/provenance header mismatch"
    );
    for (key, expected) in i.authority()?.as_object().context("source authority object")? {
        ensure!(descriptor[key] == *expected, "float source authority mismatch: {key}");
    }
    ensure!(if i.source.is_some() { descriptor.get("source_identity").is_none() && descriptor.get("plan_authority").is_none() }
        else { descriptor.get("source_authority").is_none() }, "mixed source authority");
    if let Some(tile) = i.tile {
        let frame_width = u32::try_from(descriptor["frame_width"].as_u64().context("source frame width")?)?;
        let frame_height = u32::try_from(descriptor["frame_height"].as_u64().context("source frame height")?)?;
        ensure!(u64::from(frame_width).checked_mul(frame_height.into()).is_some_and(|count| count <= i.limits.max_intermediate_pixels.0), "source tile full frame allowance");
        ensure!(tile.validate(Some((frame_width, frame_height)), max_output_bytes)? == bytes
            && width == u64::from(tile.width) && height == u64::from(tile.height), "source tile frame mismatch");
    } else { ensure!(descriptor.get("tile_rect").is_none() && descriptor.get("frame_width").is_none() && descriptor.get("frame_height").is_none(), "unrequested source tile authority"); }
    let _: media::Metadata = serde_json::from_value(descriptor["metadata"].clone()).context("float metadata schema")?;
    let _: media::RenderProvenance = serde_json::from_value(descriptor["provenance"].clone()).context("float provenance schema")?;
    ensure!(width.checked_mul(height).is_some_and(|n| n <= i.limits.max_intermediate_pixels.0), "complete plane pixel allowance");
    // Validate the entire retained payload without allocating its complete extent.
    let mut remaining = bytes;
    let mut digest = blake3::Hasher::new();
    let mut chunk = vec![0u8; 1024 * 1024];
    while remaining != 0 {
        ensure!(!cancel.load(Ordering::Acquire), "spool validation canceled");
        let length = usize::try_from(remaining.min(chunk.len() as u64))?;
        output.read_exact(&mut chunk[..length])?;
        validate_samples(&chunk[..length])?;
        digest.update(&chunk[..length]); remaining -= length as u64;
    }
    #[cfg(unix)]
    output.set_permissions(std::fs::Permissions::from_mode(0o444))?;
    let identity=HeldSourcePlaneIdentity::capture(&output)?;
    Ok(SourcePlane { file: std::sync::Mutex::new(output), descriptor, payload_offset: 24 + header,
        byte_length: bytes, frame_bytes: identity.bytes, identity, payload_digest: digest.finalize().to_hex().to_string() })
}
fn validate_samples(bytes: &[u8]) -> Result<()> {
    ensure!(bytes.len() % 16 == 0, "float sample byte extent");
    for pixel in bytes.chunks_exact(16) {
        let values: [f32; 4] = std::array::from_fn(|c| f32::from_le_bytes(pixel[c * 4..c * 4 + 4].try_into().unwrap()));
        ensure!(values.iter().all(|v| v.is_finite()) && (0.0..=1.0).contains(&values[3]), "invalid float samples/alpha");
    }
    Ok(())
}
/// The child is reaped before this immutable, unlinked private backing is returned.
/// The managed buffer registry owns its lifetime; reads use the same session admission/job/cancel path.
pub(crate) struct SourcePlane {
    file: std::sync::Mutex<std::fs::File>,
    pub(crate) descriptor: Value,
    payload_offset: u64,
    byte_length: u64,
    frame_bytes: u64,
    identity: HeldSourcePlaneIdentity,
    pub(crate) payload_digest: String,
}
impl SourcePlane {
    pub(crate) fn read_tile(&self, tile: SourceTileRect, maximum_bytes: u64, cancel: &AtomicBool) -> Result<(Vec<u8>, Value)> {
        ensure!(!cancel.load(Ordering::Acquire), "source tile read canceled");
        let width = u32::try_from(self.descriptor["width"].as_u64().context("plane width")?)?;
        let height = u32::try_from(self.descriptor["height"].as_u64().context("plane height")?)?;
        let count = tile.validate(Some((width, height)), maximum_bytes)?;
        let mut file = self.file.lock().map_err(|_| anyhow::anyhow!("source plane file lock poisoned"))?;
        let before = HeldSourcePlaneIdentity::capture(&file)?;
        ensure!(before.bytes == self.frame_bytes, "source plane backing extent changed");
        ensure!(before == self.identity,"source plane backing identity changed");
        ensure!(!cancel.load(Ordering::Acquire), "source tile read canceled");
        let mut bytes = vec![0; usize::try_from(count)?];
        let row_bytes = usize::try_from(u64::from(tile.width) * 16)?;
        for row in 0..tile.height {
            ensure!(!cancel.load(Ordering::Acquire), "source tile read canceled");
            let position = self.payload_offset + (u64::from(tile.y + row) * u64::from(width) + u64::from(tile.x)) * 16;
            file.seek(SeekFrom::Start(position))?;
            file.read_exact(&mut bytes[row as usize * row_bytes..(row as usize + 1) * row_bytes])?;
        }
        validate_samples(&bytes)?;
        ensure!(!cancel.load(Ordering::Acquire), "source tile read canceled");
        let after = HeldSourcePlaneIdentity::capture(&file)?;
        ensure!(after == before && after == self.identity, "source plane backing changed during range read");
        let mut descriptor = self.descriptor.clone();
        descriptor["kind"] = "source_float_tile".into();
        descriptor["frame_width"] = width.into(); descriptor["frame_height"] = height.into();
        descriptor["tile_rect"] = serde_json::to_value(tile)?;
        descriptor["width"] = tile.width.into(); descriptor["height"] = tile.height.into();
        descriptor["row_stride"] = (u64::from(tile.width) * 16).to_string().into();
        descriptor["byte_length"] = count.to_string().into();
        Ok((bytes, descriptor))
    }
}
fn run_input(worker: &Path, i: Input, cancel: &AtomicBool, register: &dyn Fn(Arc<RetainedDecoder>)) -> Result<(Vec<u8>, Value)> {
    let plane = run_output(worker, i, cancel, register)?;
    let width = u32::try_from(plane.descriptor["width"].as_u64().context("float width")?)?;
    let height = u32::try_from(plane.descriptor["height"].as_u64().context("float height")?)?;
    // Legacy complete/tile results retain their original exact descriptor rather than a plane authority.
    let mut file = plane.file.lock().map_err(|_| anyhow::anyhow!("float file lock poisoned"))?;
    file.seek(SeekFrom::Start(plane.payload_offset))?;
    let mut bytes = vec![0; usize::try_from(plane.byte_length)?]; file.read_exact(&mut bytes)?;
    ensure!(width > 0 && height > 0 && !cancel.load(Ordering::Acquire), "float result canceled");
    Ok((bytes, plane.descriptor.clone()))
}
fn source_plane_disk_bytes(maximum_pixels: u64) -> Result<u64> {
    ensure!(maximum_pixels != 0 && maximum_pixels != u64::MAX,
        "source plane requires explicit finite pixel authority");
    maximum_pixels.min(200_000_000).checked_mul(16).context("plane disk extent overflow")
}
pub(crate) fn run_source_plane(worker: &Path, source: SourceDevelopment, decode: DecodeLimits,
    worker_bytes: u64, cancel: &AtomicBool, register: &dyn Fn(Arc<RetainedDecoder>)) -> Result<SourcePlane> {
    // Private retained disk extent is derived from the existing single-surface
    // geometry bound. Managed range results, decoder allocation and sampled RSS
    // keep their separate unchanged ceilings; no full plane is read into Vec.
    let disk_bytes = source_plane_disk_bytes(decode.max_intermediate_pixels.0)?;
    run_output(worker, Input { plan: None, source: Some(source), tile: None, spool: true,
        limits: decode, worker_bytes, max_output_bytes: disk_bytes }, cancel, register)
}

#[cfg(all(test, target_os = "macos"))]
mod resident_sample_tests {
    use super::*;
    /// The S08 acceptance flake: a decode child that exits between `try_wait` and the
    /// 50 ms resident-memory sample has already lost its task info (before and while it
    /// is an unreaped zombie), so the sample fails. The poll loop must keep polling for
    /// the exit instead of refusing the decode.
    #[test]
    fn exited_unreaped_child_has_no_resident_sample() {
        let mut child = Command::new("/usr/bin/true").spawn().unwrap();
        let pid = child.id();
        assert!(rss(pid).is_ok() || child.try_wait().unwrap().is_some());
        std::thread::sleep(Duration::from_millis(300));
        let sampled = rss(pid);
        assert!(sampled.is_err(), "an exited, unreaped child has no task info: {sampled:?}");
        assert!(child.try_wait().unwrap().is_some_and(|status| status.success()));
    }
}
#[cfg(test)]
mod source_plane_admission_tests {
    use super::*;
    #[test]
    fn retained_disk_extent_is_independent_of_worker_allocation_but_geometry_bounded() {
        let mut input=Input { plan:None, source:None, tile:None, spool:true,
            limits:DecodeLimits { max_encoded_bytes:photocatalog::application::U64(1024),
                max_intermediate_pixels:photocatalog::application::U64(200_000_000),
                max_allocation_bytes:photocatalog::application::U64(64*1024*1024) },
            worker_bytes:64*1024*1024, max_output_bytes:source_plane_disk_bytes(200_000_000).unwrap() };
        assert_eq!(input.max_output_bytes,3_200_000_000);
        assert!(input.max_output_bytes>input.worker_bytes);
        limits(&input).unwrap();
        input.max_output_bytes+=1;
        assert!(limits(&input).unwrap_err().to_string().contains("finite geometry authority"));
        input.max_output_bytes-=1;input.spool=false;
        assert!(limits(&input).unwrap_err().to_string().contains("output allocation"));
        input.max_output_bytes=1024;input.spool=true;
        assert!(limits(&input).unwrap_err().to_string().contains("finite geometry authority"));
        assert_eq!(source_plane_disk_bytes(800_000_000).unwrap(),3_200_000_000);
        assert!(source_plane_disk_bytes(0).is_err());
        assert!(source_plane_disk_bytes(u64::MAX).is_err());
    }
    #[test]
    fn retained_disk_authority_never_waives_decoder_resident_allocation() {
        let input=Input { plan:None, source:None, tile:None, spool:true,
            limits:DecodeLimits { max_encoded_bytes:photocatalog::application::U64(1024),
                max_intermediate_pixels:photocatalog::application::U64(200_000_000),
                max_allocation_bytes:photocatalog::application::U64(64*1024*1024+1) },
            worker_bytes:64*1024*1024, max_output_bytes:source_plane_disk_bytes(200_000_000).unwrap() };
        assert!(limits(&input).unwrap_err().to_string().contains("decode allocations"));
    }
}

#[cfg(test)]
pub(crate) mod source_tile_tests {
    /// A real owned test child, never an external PID or executable. Only the
    /// parent retirement control selects this ignored fixture in its own test binary.
    pub(crate) fn retirement_owner()->Arc<RetainedDecoder>{
        let child=Command::new(std::env::current_exe().unwrap())
            .args(["--exact","full_decode::source_tile_tests::owned_decoder_retirement_child","--ignored","--test-threads=1"])
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap();
        RetainedDecoder::fixture(child)
    }
    #[test]
    #[ignore = "owned child fixture selected only by the retirement control"]
    fn owned_decoder_retirement_child(){std::thread::sleep(Duration::from_secs(30));}

    use super::{SourcePlane, SourceTileRect, HeldSourcePlaneIdentity, RetainedDecoder, Arc, Command, Stdio, Duration};
    #[cfg(unix)] use std::os::unix::fs::PermissionsExt;
    use std::io::{Seek, SeekFrom, Write};
    use std::sync::{atomic::AtomicBool, Mutex};
    pub(crate) fn held_plane() -> SourcePlane {
        let mut file = tempfile::tempfile().unwrap();
        file.write_all(&[0; 24]).unwrap();
        for pixel in 0..6 {
            for channel in [-2.0_f32 + pixel as f32, 4.0, 0.25, 1.0] {
                file.write_all(&channel.to_le_bytes()).unwrap();
            }
        }
        file.flush().unwrap();
        file.seek(SeekFrom::Start(0)).unwrap();
        #[cfg(unix)] file.set_permissions(std::fs::Permissions::from_mode(0o444)).unwrap();
        let identity=HeldSourcePlaneIdentity::capture(&file).unwrap();
        SourcePlane { file: Mutex::new(file), descriptor: serde_json::json!({
            "kind":"source_float_plane", "width":3, "height":2,
            "row_stride":"48", "byte_length":"96", "source_authority":{"request_id":"fixture"}
        }), payload_offset:24, byte_length:96, frame_bytes:120, identity, payload_digest:String::new() }
    }
    #[test]
    fn held_plane_range_preserves_global_rows_and_extended_float_values() {
        let plane = held_plane();
        let (bytes, descriptor) = plane.read_tile(SourceTileRect { x:1,y:0,width:2,height:2 },64,&AtomicBool::new(false)).unwrap();
        let red: Vec<f32> = bytes.chunks_exact(16).map(|pixel| f32::from_le_bytes(pixel[..4].try_into().unwrap())).collect();
        assert_eq!(red, [-1.0,0.0,2.0,3.0]);
        assert_eq!(descriptor["frame_width"],3);
        assert_eq!(descriptor["frame_height"],2);
        assert_eq!(descriptor["source_authority"],plane.descriptor["source_authority"]);
        assert_eq!(descriptor["byte_length"],"64");
    }
    #[test]
    fn held_plane_cancellation_and_result_charge_refuse_before_read() {
        let plane = held_plane();
        let rect = SourceTileRect { x:0,y:0,width:3,height:2 };
        assert!(plane.read_tile(rect,96,&AtomicBool::new(true)).unwrap_err().to_string().contains("canceled"));
        assert!(plane.read_tile(rect,95,&AtomicBool::new(false)).is_err());
        assert_eq!(plane.file.lock().unwrap().stream_position().unwrap(),0);
    }
    #[test]
    fn held_plane_rejects_short_and_long_backing_before_range_publication() {
        for length in [119,121] {
            let plane = held_plane();
            plane.file.lock().unwrap().set_len(length).unwrap();
            assert!(plane.read_tile(SourceTileRect{x:0,y:0,width:1,height:1},16,&AtomicBool::new(false))
                .unwrap_err().to_string().contains("backing extent changed"));
        }
    }
    #[test]
    fn held_plane_refuses_same_extent_mutation_before_read() {
        let plane=held_plane();
        {
            let mut file=plane.file.lock().unwrap();
            file.seek(SeekFrom::Start(24)).unwrap();file.write_all(&8.0_f32.to_le_bytes()).unwrap();file.flush().unwrap();
        }
        let error=plane.read_tile(SourceTileRect{x:0,y:0,width:1,height:1},16,&AtomicBool::new(false)).unwrap_err();
        assert!(error.to_string().contains("backing identity changed"));
    }
    #[cfg(unix)]
    #[test]
    fn held_plane_refuses_changed_private_mode_before_read() {
        let plane=held_plane();
        plane.file.lock().unwrap().set_permissions(std::fs::Permissions::from_mode(0o600)).unwrap();
        let error=plane.read_tile(SourceTileRect{x:0,y:0,width:1,height:1},16,&AtomicBool::new(false)).unwrap_err();
        assert!(error.to_string().contains("private immutable backing changed"));
    }
    #[test]
    fn source_tile_bounds_are_checked_before_worker_allocation() {
        let tile = SourceTileRect { x: 4, y: 3, width: 5, height: 7 };
        assert_eq!(tile.validate(Some((9, 10)), 560).unwrap(), 560);
        assert!(tile.validate(Some((8, 10)), 560).is_err());
        assert!(tile.validate(Some((9, 10)), 559).is_err());
        assert!(SourceTileRect { x: u32::MAX, y: 0, width: 1, height: 1 }.validate(None, 16).is_err());
        assert!(SourceTileRect { x: 0, y: 0, width: 0, height: 1 }.validate(None, 16).is_err());
    }
    #[test]
    fn source_tile_shape_refuses_unknown_or_missing_fields() {
        assert!(serde_json::from_str::<SourceTileRect>(r#"{"x":0,"y":0,"width":2,"height":3,"browse":true}"#).is_err());
        assert!(serde_json::from_str::<SourceTileRect>(r#"{"x":0,"y":0,"width":2}"#).is_err());
        assert!(serde_json::from_str::<SourceTileRect>(r#"{"x":-1,"y":0,"width":2,"height":3}"#).is_err());
    }
}

#[cfg(test)]
mod scene_row_controls {
    use super::*;
    fn rows(orientation:u32,block:u32)->Vec<[f32;4]> {
        let mut writer=OrientedRows::new(96*1024*1024,200_000_000).unwrap();writer.block_rows=block;
        for y in 0..3 {let pixels:(Vec<[f32;4]>)=(0..2).map(|x|[-2.+(y*2+x) as f32,4.,0.25,0.5]).collect();
            media::LinearRowSink::write_row(&mut writer,2,3,orientation,y,&pixels).unwrap();}
        let (w,h)=if orientation>=5{(3,2)}else{(2,3)};let mut file=writer.finish(w,h).unwrap();
        let mut bytes=Vec::new();file.read_to_end(&mut bytes).unwrap();
        bytes.chunks_exact(16).map(|p|std::array::from_fn(|c|f32::from_le_bytes(p[c*4..c*4+4].try_into().unwrap()))).collect()
    }
    #[test]
    fn scene_disk_rows_match_retained_eight_orientation_routes_across_blocks() {
        // Explicit independently specified 2x3 EXIF geometry; signed/HDR and
        // partial alpha remain exactly the original samples, without byte cast.
        let expected=[vec![0,1,2,3,4,5],vec![1,0,3,2,5,4],vec![5,4,3,2,1,0],vec![4,5,2,3,0,1],
            vec![0,2,4,1,3,5],vec![4,2,0,5,3,1],vec![5,3,1,4,2,0],vec![1,3,5,0,2,4]];
        for orientation in 1..=8 {for block in [1,2,64] {
            let actual=rows(orientation,block);assert_eq!(actual.len(),6);
            for (pixel,index) in actual.iter().zip(&expected[orientation as usize-1]) {
                assert_eq!(*pixel,[-2.+*index as f32,4.,0.25,0.5]);
            }
        }}
    }
    #[test]
    fn scene_row_shape_order_and_incomplete_generation_refuse_before_publication() {
        let sample=[[0.,2.,-1.,1.];2];let mut writer=OrientedRows::new(1024,200_000_000).unwrap();
        assert!(media::LinearRowSink::write_row(&mut writer,2,3,1,1,&sample).is_err());
        assert_eq!(writer.file.metadata().unwrap().len(),0);
        media::LinearRowSink::write_row(&mut writer,2,3,1,0,&sample).unwrap();
        assert!(media::LinearRowSink::write_row(&mut writer,2,3,2,1,&sample).is_err());
        assert!(writer.finish(2,3).is_err());
        let mut tiny=OrientedRows::new(31,200_000_000).unwrap();
        assert!(media::LinearRowSink::write_row(&mut tiny,2,1,1,0,&sample).is_err());
        assert_eq!(tiny.file.metadata().unwrap().len(),0);
    }
    #[test]
    fn held_worker_cancel_frame_refuses_corruption_and_metadata_replacement() {
        let mut file=tempfile::tempfile().unwrap();file.write_all(REQUEST_MAGIC).unwrap();
        file.write_all(&2_u64.to_le_bytes()).unwrap();file.write_all(&[0]).unwrap();file.write_all(b"{}").unwrap();file.flush().unwrap();
        let cancel=WorkerCancel::new(file.try_clone().unwrap(),19).unwrap();
        assert!(!photocatalog::edit::CancelCheck::is_canceled(&cancel));
        assert_eq!(write_at(&file,&[1],CANCEL_OFFSET).unwrap(),1);assert!(photocatalog::edit::CancelCheck::is_canceled(&cancel));
        assert_eq!(write_at(&file,&[2],CANCEL_OFFSET).unwrap(),1);assert!(cancel.check_held().unwrap_err().to_string().contains("protocol"));
        file.set_len(20).unwrap();assert!(cancel.check_held().unwrap_err().to_string().contains("backing"));
    }

    #[test]
    fn held_parent_collector_preserves_rows_and_publishes_descriptor_last() {
        let mut writer=OrientedRows::with_file(tempfile::tempfile().unwrap(),1024*1024,200_000_000,
            24+MAX_HEADER as u64,64).unwrap();
        let held=writer.file.try_clone().unwrap();
        let pixels=[[2.,-1.,0.25,0.5],[3.,-2.,0.75,0.]];
        media::LinearRowSink::write_row(&mut writer,2,2,6,0,&pixels).unwrap();
        let mut prefix=[255;24];assert_eq!(read_at(&held,&mut prefix,0).unwrap(),24);assert_eq!(prefix,[0;24]);
        media::LinearRowSink::write_row(&mut writer,2,2,6,1,&pixels).unwrap();
        let mut output=writer.finish(2,2).unwrap();let mut payload=[0;64];output.read_exact(&mut payload).unwrap();
        assert_eq!(output.metadata().unwrap().len(),24+MAX_HEADER as u64+64);
        publish_scene_descriptor(&mut output,b"{\"kind\":\"source_float_plane\"}",64,&()).unwrap();
        output.seek(SeekFrom::Start(0)).unwrap();output.read_exact(&mut prefix).unwrap();
        assert_eq!(&prefix[..8],MAGIC);assert_eq!(u64::from_le_bytes(prefix[8..16].try_into().unwrap()),MAX_HEADER as u64);
        let mut header=vec![0;MAX_HEADER];output.read_exact(&mut header).unwrap();
        let value:Value=serde_json::from_slice(&header).unwrap();assert_eq!(value["kind"],"source_float_plane");
        let mut after=[0;64];output.read_exact(&mut after).unwrap();assert_eq!(after,payload);
        // The retained collector descriptor, rather than a copied generation,
        // observes the exact same published prefix and complete oriented data.
        let mut observed=[0;24];assert_eq!(read_at(&held,&mut observed,0).unwrap(),24);assert_eq!(observed,prefix);
    }
    #[test]
    fn parent_collector_extent_and_cancel_refuse_before_valid_header() {
        let pixels=[[2.,-1.,0.,1.];2];
        let mut tiny=OrientedRows::with_file(tempfile::tempfile().unwrap(),1024,200_000_000,24+MAX_HEADER as u64,31).unwrap();
        assert!(media::LinearRowSink::write_row(&mut tiny,2,1,1,0,&pixels).unwrap_err().message.contains("admitted extent"));
        assert_eq!(tiny.file.metadata().unwrap().len(),0);
        struct Canceled;impl photocatalog::edit::CancelCheck for Canceled{fn is_canceled(&self)->bool{true}}
        let mut writer=OrientedRows::with_file(tempfile::tempfile().unwrap(),1024,200_000_000,24+MAX_HEADER as u64,32).unwrap();
        media::LinearRowSink::write_row(&mut writer,2,1,1,0,&pixels).unwrap();let mut output=writer.finish(2,1).unwrap();
        assert!(publish_scene_descriptor(&mut output,b"{}",32,&Canceled).is_err());
        let mut prefix=[255;24];assert_eq!(read_at(&output,&mut prefix,0).unwrap(),24);assert_eq!(prefix,[0;24]);
        assert!(publish_scene_descriptor(&mut output,b"{}",33,&()).unwrap_err().to_string().contains("publication extent"));
    }

}

#[cfg(test)]
mod source_raw_authority_tests {
    use super::*;
    #[test]
    fn source_raw_admission_is_required_typed_and_descriptor_bound(){
        let original=photocatalog::storage_volume::NativePath::from_path(Path::new("/source.nrw"));
        let mut authority=json!({"original":original,"original_revision":{"bytes":"4","digest":"0".repeat(64),
            "modified_ns":"0","identity":["1","2"]},"white_balance":{"mode":"as_shot"},
            "request_id":"00000000-0000-4000-8000-000000000001","raw_hint":true});
        let value:SourceDevelopment=serde_json::from_value(authority.clone()).unwrap();assert!(value.raw_hint);
        assert_eq!(serde_json::to_value(&value).unwrap(),authority);
        authority.as_object_mut().unwrap().remove("raw_hint");assert!(serde_json::from_value::<SourceDevelopment>(authority.clone()).is_err());
        authority["raw_hint"]=json!("true");assert!(serde_json::from_value::<SourceDevelopment>(authority.clone()).is_err());
        authority["raw_hint"]=json!(true);authority["unapproved"]=json!(1);assert!(serde_json::from_value::<SourceDevelopment>(authority).is_err());
    }
}
