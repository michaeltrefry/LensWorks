#include <libraw/libraw.h>
#include <avif/avif.h>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <exception>
#include <cmath>
#include <algorithm>
#include <vector>
#include "pc_private_file.h"
#include <string>
#include "decode.h"

// This ABI contains no vendor structs. Compile against the linked library's headers.
extern "C" {
void pc_free(PcImage *out) { free(out->pixels); free(out->icc); out->pixels = nullptr; out->icc = nullptr; }
const char *pc_raw_version() { return libraw_version(); }
const char *pc_avif_version() { return avifVersion(); }
}
int fail(PcImage *out, const char *message) {
    pc_free(out); snprintf(out->error, sizeof(out->error), "%s", message); return -1;
}
bool allocate(PcImage *out, const PcDecodeLimits *limits) {
    uint64_t count = uint64_t(out->width) * out->height;
    if (!count || out->width > 40000 || out->height > 40000 || count > 100000000 || count > limits->max_intermediate_pixels || count*16 > limits->max_allocation_bytes) return false;
    out->pixels = static_cast<float *>(malloc(size_t(count) * 4 * sizeof(float)));
    return out->pixels != nullptr;
}
// Preserve metadata crop before LibRaw rounds CFA origins for demosaicing.
// Crop the developed RGB afterwards, where arbitrary pixel origins are valid.
class OriginalCropRaw : public LibRaw {
public:
    libraw_raw_inset_crop_t vendor_crop{};
    // Same inherited serializer as dcraw_ppm_tiff_writer, but the caller's
    // exclusive FILE is retained throughout. No /dev/fd alias or path reopen.
    void writeHeldRows(FILE *file) {
        FILE *previous=libraw_internal_data.internal_data.output;
        libraw_internal_data.internal_data.output=file;
        try{write_ppm_tiff();}catch(...){libraw_internal_data.internal_data.output=previous;throw;}
        libraw_internal_data.internal_data.output=previous;
    }

    OriginalCropRaw() {
        callbacks.post_identify_cb=[](void *ctx) {
            auto *self=static_cast<OriginalCropRaw *>(static_cast<LibRaw *>(ctx));
            self->vendor_crop=self->imgdata.sizes.raw_inset_crops[0];
            const auto &rect=self->imgdata.makernotes.canon.DefaultCropAbsolute;
            if(self->imgdata.idata.maker_index==LIBRAW_CAMERAMAKER_Canon && rect.l>=0 && rect.t>=0 && rect.r>=rect.l && rect.b>=rect.t) {
                auto &crop=self->vendor_crop;
                if(self->imgdata.sizes.raw_aspect!=LIBRAW_IMAGE_ASPECT_UNKNOWN && crop.cwidth && crop.cheight) {
                    crop.cleft+=rect.l;crop.ctop+=rect.t;
                } else {
                    crop.cleft=rect.l;crop.ctop=rect.t;
                    crop.cwidth=rect.r-rect.l+1;crop.cheight=rect.b-rect.t+1;
                }
            }
        };
    }
};
static int raw_failure(PcImage *out,int status) {
    if(status==LIBRAW_UNSUFFICIENT_MEMORY || status==LIBRAW_TOO_BIG)
        return fail(out,"resource limit: RAW allocation ceiling");
    return fail(out,libraw_strerror(status));
}
// Recover the selected camera response from the actual camera-to-sRGB matrix,
// rather than assuming the optional cam_xyz matches an in-file camera profile.
// R maps daylight-balanced camera values to linear sRGB. Therefore the raw
// response to XYZ white is inverse(R)*XYZ_to_sRGB*white / daylight_multipliers.
static bool custom_wb(LibRaw &raw,const PcWhitePoint &white) {
    double a[3][6]{};
    for(int i=0;i<3;++i) for(int j=0;j<3;++j) { a[i][j]=raw.imgdata.color.rgb_cam[i][j];a[i][j+3]=(i==j); }
    for(int c=0;c<3;++c) {
        int best=c;for(int r=c+1;r<3;++r) if(std::abs(a[r][c])>std::abs(a[best][c])) best=r;
        if(std::abs(a[best][c])<1e-10) return false;
        for(int j=0;j<6;++j) std::swap(a[c][j],a[best][j]);
        double scale=a[c][c];for(int j=0;j<6;++j) a[c][j]/=scale;
        for(int r=0;r<3;++r) if(r!=c) {double k=a[r][c];for(int j=0;j<6;++j) a[r][j]-=k*a[c][j];}
    }
    const double xyz[3]={white.x/white.y,1.0,(1.0-white.x-white.y)/white.y};
    const double xyz_to_rgb[3][3]={{3.2404542,-1.5371385,-0.4985314},{-0.9692660,1.8760108,0.0415560},{0.0556434,-0.2040259,1.0572252}};
    double rgb[3]{};for(int c=0;c<3;++c) for(int j=0;j<3;++j) rgb[c]+=xyz_to_rgb[c][j]*xyz[j];
    for(int c=0;c<3;++c) {
        double response=0;for(int j=0;j<3;++j) response+=a[c][j+3]*rgb[j];
        double daylight=raw.imgdata.color.pre_mul[c];
        if(!std::isfinite(response)||response<=0||!std::isfinite(daylight)||daylight<=0) return false;
        raw.imgdata.params.user_mul[c]=float(daylight/response);
    }
    raw.imgdata.params.user_mul[3]=raw.imgdata.params.user_mul[1];
    raw.imgdata.params.use_camera_wb=0;raw.imgdata.params.use_auto_wb=0;
    return true;
}
// LibRaw's public PPM writer and make_mem_image both serialize the developed
// camera samples. The row route uses the writer's 16-bit binary representation
// into an already-held unlinked private file; no processed full-frame copy.
static bool ppm_token(const std::vector<unsigned char> &bytes,size_t &cursor,std::string &token,size_t &header_bytes) {
    token.clear();int c;
    auto next=[&]()->int{return cursor<bytes.size()?int(bytes[cursor++]):EOF;};
    for(;;) {
        c=next();if(c==EOF||++header_bytes>65536)return false;
        if(c=='#'){do{c=next();if(c==EOF||++header_bytes>65536)return false;}while(c!='\n');continue;}
        if(c==' '||c=='\t'||c=='\r'||c=='\n')continue;
        break;
    }
    for(;;) {
        if(token.size()>=64)return false;token.push_back(char(c));
        c=next();if(c==EOF||++header_bytes>65536)return false;
        if(c==' '||c=='\t'||c=='\r'||c=='\n')break;
    }
    return true;
}
static bool ppm_number(const std::string &token,uint32_t &value) {
    if(token.empty())return false;uint64_t n=0;
    for(char c:token){if(c<'0'||c>'9')return false;n=n*10+unsigned(c-'0');if(n>UINT32_MAX)return false;}
    value=uint32_t(n);return true;
}
static int raw_rows_from_writer(OriginalCropRaw &raw,const PcDecodeLimits *limits,PcImage *out,
    PcRowSink sink,void *context,const float matrix[3][3],float headroom,const PcDecodeControl *control) {
    int width=0,height=0,colors=0,bits=0;raw.get_mem_image_format(&width,&height,&colors,&bits);
    if(width<=0||height<=0||colors!=3||bits!=16)return fail(out,"unsupported RAW row writer format");
    uint32_t left=0,top=0;out->width=uint32_t(width);out->height=uint32_t(height);
    const auto crop=raw.vendor_crop;const auto sizes=raw.imgdata.sizes;
    if(crop.cwidth&&crop.cheight&&crop.cleft<0xffff&&crop.ctop<0xffff) {
        if(width!=sizes.width||height!=sizes.height||crop.cleft<sizes.left_margin||crop.ctop<sizes.top_margin)
            return fail(out,"unsupported RAW vendor crop with scaled or diagonal development");
        left=crop.cleft-sizes.left_margin;top=crop.ctop-sizes.top_margin;
        if(uint64_t(left)+crop.cwidth>uint32_t(width)||uint64_t(top)+crop.cheight>uint32_t(height))
            return fail(out,"unsupported RAW vendor crop outside developed area");
        out->width=crop.cwidth;out->height=crop.cheight;
    }
    const uint64_t row_bytes=uint64_t(width)*6;
    if(uint64_t(width)*height>limits->max_intermediate_pixels||row_bytes>limits->max_allocation_bytes||
        uint64_t(out->width)*16>limits->max_allocation_bytes)return fail(out,"resource limit: RAW writer row admission");
    PcPrivateFile file;
    raw.imgdata.params.output_tiff=0;raw.writeHeldRows(file.writerStream());
    const uint64_t payload=uint64_t(width)*height*6;
    file.acceptWriter(payload+65536);file.seal();const uint64_t published=file.size();
    if(published<payload)return fail(out,"RAW writer backing extent");
    // All matrix/headroom/crop/source metadata used below was captured before
    // releasing the mosaic and developed image. The immutable file is separate.
    raw.recycle();
    // Header parsing is bounded, then row reads use the checked held range API.
    std::vector<unsigned char> header_bytes(static_cast<size_t>(published-payload));
    file.read(header_bytes.data(),0,header_bytes.size());
    size_t cursor=0;
    size_t header=0;std::string token;uint32_t declared_width=0,declared_height=0,maximum=0;
    if(!ppm_token(header_bytes,cursor,token,header)||token!="P6"||!ppm_token(header_bytes,cursor,token,header)||!ppm_number(token,declared_width)||
        !ppm_token(header_bytes,cursor,token,header)||!ppm_number(token,declared_height)||!ppm_token(header_bytes,cursor,token,header)||!ppm_number(token,maximum)||
        declared_width!=uint32_t(width)||declared_height!=uint32_t(height)||maximum!=65535||header+payload!=published)
        return fail(out,"RAW writer PPM descriptor mismatch");
    std::vector<unsigned char> encoded(static_cast<size_t>(row_bytes));std::vector<float> row(size_t(out->width)*4);
    out->primaries=1;out->transfer=8;
    for(uint32_t y=0;y<out->height;++y) {
        if(pc_canceled(control))return fail(out,"RAW decode canceled");
        file.read(encoded.data(),header+(uint64_t(y+top)*width+left)*6,size_t(out->width)*6);
        for(uint32_t x=0;x<out->width;++x) {
            for(size_t c=0;c<3;++c) {
                float value=0;
                for(size_t k=0;k<3;++k) {
                    size_t sample=(size_t(x)*3+k)*2;
                    const uint16_t n=uint16_t((uint16_t(encoded[sample])<<8)|encoded[sample+1]);
                    value+=matrix[c][k]*(n/65535.0f)*headroom;
                }
                row[4*x+c]=value;
            }
            row[4*x+3]=1;
        }
        if(sink(context,out,y,row.data()))return fail(out,"RAW row consumer refused");
    }
    file.verify();
    return 0;
}
static int raw_decode(const unsigned char *bytes, size_t len, const PcDecodeLimits *limits, const PcWhitePoint *white, PcImage *out, PcRowSink sink, void *context,const PcDecodeControl *control=nullptr) {
    try {
        if(pc_canceled(control))return fail(out,"RAW decode canceled");
        OriginalCropRaw raw;
        if(control)raw.set_progress_handler([](void *value,enum LibRaw_progress,int,int)->int {
            return pc_canceled(static_cast<const PcDecodeControl *>(value))?1:0;
        },const_cast<PcDecodeControl *>(control));
        raw.imgdata.rawparams.max_raw_memory_mb = unsigned(limits->max_allocation_bytes==UINT64_MAX ? 768 : std::min<uint64_t>(4096, limits->max_allocation_bytes/(1024*1024)));
        if (!raw.imgdata.rawparams.max_raw_memory_mb) return fail(out,"resource limit: RAW allocation allowance below 1 MiB");
        raw.imgdata.rawparams.options &= ~LIBRAW_RAWOPTIONS_CONVERTFLOAT_TO_INT;
        int status = raw.open_buffer(const_cast<unsigned char *>(bytes), len);
        if (status) return raw_failure(out, status);
        out->width = raw.imgdata.sizes.width; out->height = raw.imgdata.sizes.height;
        if (!sink && uint64_t(out->width) * out->height > 100000000) return fail(out, "resource limit: RAW exceeds 100 megapixels");
        uint64_t sensor_pixels=uint64_t(raw.imgdata.sizes.raw_width)*raw.imgdata.sizes.raw_height;
        uint64_t developed_pixels=uint64_t(out->width)*out->height;
        if(sensor_pixels>limits->max_intermediate_pixels || developed_pixels>limits->max_intermediate_pixels ||
           sensor_pixels*8>limits->max_allocation_bytes || developed_pixels*16>limits->max_allocation_bytes)
            return fail(out,"resource limit: RAW sensor/development exceeds configured admission");
        snprintf(out->make, sizeof(out->make), "%s", raw.imgdata.idata.make);
        snprintf(out->model, sizeof(out->model), "%s", raw.imgdata.idata.model);
        out->bits = raw.imgdata.color.raw_bps;
        int flip = raw.imgdata.sizes.flip;
        const uint32_t orientations[] = {1,2,4,3,5,8,6,7};
        out->orientation = (flip >= 0 && flip < 8) ? orientations[flip] : 1;
        // Stable full sensor development, not an embedded JPEG. Orientation is applied in Rust once.
        auto &p = raw.imgdata.params;
        float camera_to_rgb[3][3];
        for (int c=0;c<3;++c) {
            if (!white->y && (!(raw.imgdata.color.cam_mul[c]>0) || !std::isfinite(raw.imgdata.color.cam_mul[c])))
                return fail(out,"unsupported RAW missing as-shot white balance");
            for(int k=0;k<3;++k) camera_to_rgb[c][k]=raw.imgdata.color.rgb_cam[c][k];
        }
        // WB belongs before demosaic and highlight handling. With highlight=2,
        // LibRaw scales by the largest WB multiplier to retain sensor headroom,
        // then blends clipped chroma in camera space (dcraw's documented -H 2).
        // Applying WB after clipping instead creates false magenta/green highlights.
        p.half_size = 0; p.user_flip = 0; p.use_camera_wb = 1; p.use_auto_wb = 0;
        p.use_camera_matrix = 1; p.output_color = 0; p.output_bps = 16;
        p.gamm[0] = 1.0; p.gamm[1] = 1.0; p.no_auto_bright = 1;
        p.user_qual = 3; p.highlight = 2;
        if(white->y && !custom_wb(raw,*white)) return fail(out,"unsupported RAW custom white point for selected camera matrix");
        status = raw.unpack(); if (status) return raw_failure(out, status);
        if (raw.imgdata.rawdata.float_image || raw.imgdata.rawdata.float3_image || raw.imgdata.rawdata.float4_image)
            return fail(out, "unsupported floating DNG: requires validated ForwardMatrix/profile and transparency-mask rendering; integer conversion is forbidden");
        status = raw.dcraw_process(); if (status) return raw_failure(out, status);
        // scale_colors normalizes the actual WB (including camera white-patch or
        // already-balanced RAW handling) into pre_mul. Undo only its common
        // headroom scale in float; never apply the channel WB twice. The 3-channel
        // output uses merged green, so the fourth CFA multiplier is not a channel.
        float minimum_wb=1.f;
        for(int c=0;c<3;++c) {
            float wb=raw.imgdata.color.pre_mul[c];
            if (!(wb>0) || !std::isfinite(wb))
                return fail(out,"unsupported RAW invalid developed white balance");
            minimum_wb=std::min(minimum_wb,wb);
        }
        const float headroom=1.f/minimum_wb;
        if (!std::isfinite(headroom)) return fail(out,"unsupported RAW white balance range");
        // The channel with the smallest multiplier is the first to saturate for a neutral subject,
        // at a balanced camera level of minimum_wb*headroom in every channel; highlight blending
        // synthesizes neutral values above it.
        {
            bool finite=true;
            for(int c=0;c<3;++c) {
                float value=0;for(int k=0;k<3;++k) value+=camera_to_rgb[c][k]*minimum_wb*headroom;
                finite=finite&&std::isfinite(value)&&value>0;out->neutral_clip[c]=value;
            }
            out->neutral_clip_valid=finite;
        }
        if(sink)return raw_rows_from_writer(raw,limits,out,sink,context,camera_to_rgb,headroom,control);
        auto *processed = raw.dcraw_make_mem_image(&status);
        if (!processed) return raw_failure(out, status);
        std::unique_ptr<libraw_processed_image_t, decltype(&LibRaw::dcraw_clear_mem)> image(processed, LibRaw::dcraw_clear_mem);
        if (processed->type != LIBRAW_IMAGE_BITMAP || processed->colors != 3 || processed->bits != 16)
            return fail(out, "unsupported RAW development output");
        out->width = processed->width; out->height = processed->height;
        uint32_t crop_left=0,crop_top=0;
        const auto &crop=raw.vendor_crop;
        if(crop.cwidth && crop.cheight && crop.cleft<0xffff && crop.ctop<0xffff) {
            const auto &sizes=raw.imgdata.sizes;
            if(processed->width!=sizes.width || processed->height!=sizes.height)
                return fail(out,"unsupported RAW vendor crop with scaled or diagonal development");
            if(crop.cleft<sizes.left_margin||crop.ctop<sizes.top_margin)
                return fail(out,"unsupported RAW vendor crop outside developed area");
            crop_left=crop.cleft-sizes.left_margin;crop_top=crop.ctop-sizes.top_margin;
            if(uint64_t(crop_left)+crop.cwidth>processed->width || uint64_t(crop_top)+crop.cheight>processed->height)
                return fail(out,"unsupported RAW vendor crop outside developed area");
            out->width=crop.cwidth;out->height=crop.cheight;
        }
        if (!sink && !allocate(out, limits)) return fail(out, "resource limit: RAW output allocation");
        if (uint64_t(out->width)*16>limits->max_allocation_bytes) return fail(out,"resource limit: RAW row allocation");
        std::vector<float> row(sink ? size_t(out->width)*4 : 0);
        const auto *samples = reinterpret_cast<const uint16_t *>(processed->data);
        out->primaries = 1; out->transfer = 8; // linear sRGB primaries
        for (uint32_t y=0;y<out->height;++y) {
            float *destination=sink ? row.data() : out->pixels+size_t(y)*out->width*4;
            for(uint32_t x=0;x<out->width;++x) {
                size_t source=size_t(y+crop_top)*processed->width+x+crop_left;
                for(size_t c=0;c<3;++c) {
                    float value=0;
                    for(size_t k=0;k<3;++k) value+=camera_to_rgb[c][k]*(samples[3*source+k]/65535.0f)*headroom;
                    destination[4*x+c]=value;
                }
                destination[4*x+3]=1;
            }
            if(sink && sink(context,out,y,row.data())) return fail(out,"RAW row consumer refused");
        }
        return 0;
    } catch (const std::bad_alloc &) { return fail(out,"resource limit: RAW allocation failed"); }
    catch (const std::exception &error) { return fail(out, error.what()); }
    catch (...) { return fail(out, "RAW decoder exception"); }
}
extern "C" int pc_raw(const unsigned char *bytes,size_t len,const PcDecodeLimits *limits,const PcWhitePoint *white,PcImage *out) { return raw_decode(bytes,len,limits,white,out,nullptr,nullptr); }
extern "C" int pc_raw_rows(const unsigned char *bytes,size_t len,const PcDecodeLimits *limits,const PcWhitePoint *white,PcImage *out,PcRowSink sink,void *context,const PcDecodeControl *control) { if(!sink) return fail(out,"missing RAW row consumer");return raw_decode(bytes,len,limits,white,out,sink,context,control); }
static int avif_decode(const unsigned char *bytes, size_t len, const PcDecodeLimits *limits, PcImage *out,PcRowSink sink,void *context,const PcDecodeControl *control=nullptr) {
    try {
    std::unique_ptr<avifDecoder, decltype(&avifDecoderDestroy)> decoder(avifDecoderCreate(), avifDecoderDestroy);
    if (!decoder) return fail(out, "resource limit: AVIF allocation failed");
    decoder->maxThreads = 1; decoder->imageSizeLimit = sink ? uint32_t(std::min<uint64_t>(limits->max_intermediate_pixels,UINT32_MAX)) : 100000000; decoder->imageDimensionLimit = 40000;
    decoder->imageCountLimit = 1;
    if(pc_canceled(control))return fail(out,"AVIF decode canceled");
    auto result = avifDecoderSetIOMemory(decoder.get(), bytes, len);
    if (result == AVIF_RESULT_OK) result = avifDecoderParse(decoder.get());
    if (result == AVIF_RESULT_OK) {
        uint64_t pixels=uint64_t(decoder->image->width)*decoder->image->height;
        if(pixels>limits->max_intermediate_pixels || pixels*16>limits->max_allocation_bytes)
            return fail(out,"resource limit: AVIF exceeds configured admission");
        result = avifDecoderNextImage(decoder.get());
    }
    if (result != AVIF_RESULT_OK) return fail(out, result==AVIF_RESULT_OUT_OF_MEMORY ? "resource limit: AVIF allocation failed" : avifResultToString(result));
    if(pc_canceled(control))return fail(out,"AVIF decode canceled");
    const avifImage *img = decoder->image;
    avifCropRect crop{0,0,img->width,img->height};
    if ((img->transformFlags & AVIF_TRANSFORM_CLAP) && !avifCropRectConvertCleanApertureBox(&crop,&img->clap,img->width,img->height,img->yuvFormat,&decoder->diag))
        return fail(out,"unsupported AVIF fractional or invalid clean aperture");
    if ((img->transformFlags & AVIF_TRANSFORM_PASP) && img->pasp.hSpacing!=img->pasp.vSpacing)
        return fail(out,"unsupported AVIF non-square pixels");
    out->width = crop.width; out->height = crop.height; out->bits = img->depth;
    out->primaries = img->colorPrimaries; out->transfer = img->transferCharacteristics;
    out->orientation = 1;
    unsigned angle = (img->transformFlags & AVIF_TRANSFORM_IROT) ? img->irot.angle : 0;
    // irot describes counter-clockwise quarter turns; EXIF is clockwise.
    const uint32_t rotations[] = {1,8,3,6}; out->orientation = rotations[angle & 3];
    if (img->transformFlags & AVIF_TRANSFORM_IMIR) {
        const uint32_t horizontal[]={2,7,4,5},vertical[]={4,5,2,7};
        out->orientation=(img->imir.axis==1?horizontal:vertical)[angle&3];
    }
    if (!sink && !allocate(out, limits)) return fail(out, "resource limit: AVIF output allocation");
    if(uint64_t(out->width)*16>limits->max_allocation_bytes) return fail(out,"resource limit: AVIF row allocation");
    std::vector<float> output_row(sink ? size_t(out->width)*4 : 0);
    if (img->icc.size) {
        if (img->icc.size > 16*1024*1024) return fail(out, "resource limit: ICC profile");
        out->icc = static_cast<unsigned char *>(malloc(img->icc.size));
        if (!out->icc) return fail(out, "ICC allocation failed");
        memcpy(out->icc, img->icc.data, img->icc.size); out->icc_size = img->icc.size;
    }
    avifRGBImage rgb; avifRGBImageSetDefaults(&rgb, img);
    rgb.depth = 16; rgb.format = AVIF_RGB_FORMAT_RGBA; rgb.alphaPremultiplied = AVIF_FALSE;
    (void)avifRGBImageAllocatePixels(&rgb);
    if (!rgb.pixels) return fail(out, "resource limit: AVIF RGB allocation failed");
    result = avifImageYUVToRGB(img, &rgb);
    if (result == AVIF_RESULT_OK) {
        for (size_t y = 0; y < out->height; ++y) {
            if(pc_canceled(control)){avifRGBImageFreePixels(&rgb);return fail(out,"AVIF row decode canceled");}
            const auto *row = reinterpret_cast<const uint16_t *>(rgb.pixels + (y+crop.y) * rgb.rowBytes)+crop.x*4;
            float *destination=sink ? output_row.data() : out->pixels+y*out->width*4;
            for(size_t x=0;x<size_t(out->width)*4;++x) destination[x]=row[x]/65535.0f;
            if(sink && sink(context,out,uint32_t(y),output_row.data())) {
                avifRGBImageFreePixels(&rgb);return fail(out,"AVIF row consumer refused");
            }
        }
    }
    avifRGBImageFreePixels(&rgb);
    if (result != AVIF_RESULT_OK) return fail(out, result==AVIF_RESULT_OUT_OF_MEMORY ? "resource limit: AVIF allocation failed" : avifResultToString(result));
    return 0;
    }catch(const std::bad_alloc &){return fail(out,"resource limit: AVIF row allocation failed");}
    catch(const std::exception &error){return fail(out,error.what());}
    catch(...){return fail(out,"AVIF decoder exception");}
}

extern "C" int pc_avif(const unsigned char *bytes,size_t len,const PcDecodeLimits *limits,PcImage *out) { return avif_decode(bytes,len,limits,out,nullptr,nullptr); }
extern "C" int pc_avif_rows(const unsigned char *bytes,size_t len,const PcDecodeLimits *limits,PcImage *out,PcRowSink sink,void *context,const PcDecodeControl *control) { if(!sink) return fail(out,"missing AVIF row consumer");return avif_decode(bytes,len,limits,out,sink,context,control); }
