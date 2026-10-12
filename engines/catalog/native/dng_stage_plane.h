#pragma once
#include "dng_image.h"
#include "dng_memory.h"
#include "dng_orientation.h"
#include "dng_exceptions.h"
#include "dng_tag_types.h"
#include "pc_dng_allocation.h"
#include <atomic>
#include <memory>
#include <mutex>
#include <cstdio>
#include <cstdlib>
#include <cerrno>
#include "pc_private_file.h"

// Source-plane stages are global random-access disk images, not independent
// tile developments. SDK opcodes/demosaic still see the complete source extent.
// Generated SDK allocation hooks share this admission with allocator tiles.
// Framework allocator internals and process RSS remain separate watchdog evidence.
class PcDngBlock final:public dng_memory_block {
    std::shared_ptr<PcDngBudget> budget;
    void *allocation=nullptr;
    uint64_t charge=0;
public:
    PcDngBlock(uint32 size,std::shared_ptr<PcDngBudget> owner):dng_memory_block(size),budget(std::move(owner)) {
        charge=PhysicalSize();budget->reserve(charge);
        allocation=malloc(size_t(charge));
        if(!allocation){budget->release(charge);charge=0;ThrowMemoryFull("DNG charged allocation");}
        SetBuffer(allocation);
    }
    ~PcDngBlock() override {free(allocation);if(charge)budget->release(charge);}
};
class PcDngAllocator final:public dng_memory_allocator {
public:
    std::shared_ptr<PcDngBudget> budget;
    explicit PcDngAllocator(uint64_t maximum):budget(std::make_shared<PcDngBudget>(maximum)) {}
    dng_memory_block *Allocate(uint32 size) override {return new PcDngBlock(size,budget);}
};
class PcDngStagePlane final:public dng_image {
    struct Tile {std::unique_ptr<dng_memory_block> bytes;};
    std::unique_ptr<PcPrivateFile> file;
    uint64_t length=0;
    int64_t origin=0,rowStep=0,colStep=0;
    dng_memory_allocator &allocator;
    std::shared_ptr<std::atomic<bool>> failed;
    void check() const {
        if(auto *admitted=dynamic_cast<PcDngAllocator *>(&allocator))admitted->budget->check();
        if(failed->load(std::memory_order_acquire))ThrowBadFormat("DNG stage backing failed");
        file->verify();if(file->size()!=length)ThrowBadFormat("DNG stage backing extent changed");
    }
    uint64_t offset(int32 y,int32 x) const {
        const int64_t value=origin+int64_t(y-fBounds.t)*rowStep+int64_t(x-fBounds.l)*colStep;
        const uint64_t pixel=uint64_t(fPlanes)*TagTypeSize(fPixelType);
        if(value<0||uint64_t(value)>length||pixel>length-uint64_t(value)) ThrowBadFormat("DNG stage address");
        return uint64_t(value);
    }
    void transfer(void *bytes,uint64_t position,size_t count,bool write) const {
        if(position>length||count>length-position) ThrowBadFormat("DNG stage range");
        file->transfer(bytes,position,count,write);
    }
public:
    PcDngStagePlane(const dng_rect &bounds,uint32 planes,uint32 type,dng_memory_allocator &owner,
                    std::shared_ptr<std::atomic<bool>> failure):dng_image(bounds,planes,type),allocator(owner),failed(std::move(failure)) {
        if(bounds.IsEmpty()||!planes||!TagTypeSize(type))ThrowBadFormat("DNG stage extent");
        const uint64_t pixel=uint64_t(planes)*TagTypeSize(type);
        const uint64_t area=uint64_t(bounds.W())*bounds.H();
        if(area>200000000||pixel>UINT64_MAX/area)ThrowMemoryFull("DNG stage disk extent");
        length=area*pixel;if(length>uint64_t(INT64_MAX))ThrowMemoryFull("DNG stage offset extent");
        rowStep=int64_t(bounds.W())*int64_t(pixel);colStep=int64_t(pixel);
        file=std::make_unique<PcPrivateFile>();file->resize(length);check();
    }
    ~PcDngStagePlane() override = default;
    dng_rect RepeatingTile() const override {return dng_rect(64,64);}
    dng_image *Clone() const override {
        check();auto result=std::make_unique<PcDngStagePlane>(fBounds,fPlanes,fPixelType,allocator,failed);
        result->CopyArea(*this,fBounds,0,0,fPlanes);check();return result.release();
    }
    void Trim(const dng_rect &area) override {
        check();if(!fBounds.Contains(area)||area.IsEmpty())ThrowBadFormat("DNG stage trim");
        origin=int64_t(offset(area.t,area.l));fBounds=dng_rect(area.H(),area.W());
    }
    void Rotate(const dng_orientation &orientation) override {
        check();int64_t nextOrigin=origin;int64_t nextRow=rowStep,nextCol=colStep;
        int32 width=fBounds.W(),height=fBounds.H();
        if(orientation.FlipH()){nextOrigin+=int64_t(width-1)*colStep;nextCol=-colStep;}
        if(orientation.FlipV()){nextOrigin+=int64_t(height-1)*rowStep;nextRow=-rowStep;}
        if(orientation.FlipD()){std::swap(nextCol,nextRow);std::swap(width,height);}
        origin=nextOrigin;rowStep=nextRow;colStep=nextCol;
        fBounds=dng_rect(fBounds.t,fBounds.l,fBounds.t+height,fBounds.l+width);
    }
    void Offset(const dng_point &point) override {check();fBounds=fBounds+point;}
    void verify() const {check();}
protected:
    void AcquireTileBuffer(dng_tile_buffer &buffer,const dng_rect &area,bool dirty) const override {
        check();if(!fBounds.Contains(area)||area.IsEmpty())ThrowBadFormat("DNG stage tile extent");
        const uint64_t pixel=uint64_t(fPlanes)*TagTypeSize(fPixelType);
        const uint64_t count=uint64_t(area.W())*area.H()*pixel;
        if(count>UINT32_MAX)ThrowMemoryFull("DNG stage tile size");
        auto tile=std::make_unique<Tile>();tile->bytes.reset(allocator.Allocate(uint32(count)));
        auto *data=tile->bytes->Buffer_uint8();
        for(int32 y=area.t;y<area.b;++y) {
            auto *row=data+uint64_t(y-area.t)*area.W()*pixel;
            if(colStep==int64_t(pixel)) transfer(row,offset(y,area.l),size_t(area.W()*pixel),false);
            else for(int32 x=area.l;x<area.r;++x)transfer(row+uint64_t(x-area.l)*pixel,offset(y,x),size_t(pixel),false);
        }
        check();buffer.fArea=area;buffer.fPlane=0;buffer.fPlanes=fPlanes;
        buffer.fRowStep=area.W()*fPlanes;buffer.fColStep=fPlanes;buffer.fPlaneStep=1;
        buffer.fPixelType=fPixelType;buffer.fPixelSize=TagTypeSize(fPixelType);buffer.fData=data;buffer.fDirty=dirty;
        buffer.SetRefData(tile.release());
    }
    void ReleaseTileBuffer(dng_tile_buffer &buffer) const override {
        std::unique_ptr<Tile> tile(static_cast<Tile *>(buffer.GetRefData()));buffer.SetRefData(nullptr);
        if(!tile)return;
        if(buffer.fDirty) {
            // SDK calls Release from its tile destructor. Persist I/O failure as
            // sticky state instead of throwing during stack unwinding.
            try {
                check();const auto &area=buffer.fArea;const uint64_t pixel=uint64_t(fPlanes)*TagTypeSize(fPixelType);
                auto *data=tile->bytes->Buffer_uint8();
                for(int32 y=area.t;y<area.b;++y) {
                    auto *row=data+uint64_t(y-area.t)*area.W()*pixel;
                    if(colStep==int64_t(pixel))transfer(row,offset(y,area.l),size_t(area.W()*pixel),true);
                    else for(int32 x=area.l;x<area.r;++x)transfer(row+uint64_t(x-area.l)*pixel,offset(y,x),size_t(pixel),true);
                }
                check();
            }catch(...){failed->store(true,std::memory_order_release);}
        }
    }
};
