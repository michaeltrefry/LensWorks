// Standalone actual-code controls. Not included in the production decoder build.
// Root must compile against the exact admitted SDK/header candidate before use.
#include "dng_stage_plane.h"
#include <cassert>
#include <vector>
#include <string>
static dng_pixel_buffer buffer(dng_rect area,float *data) {
    dng_pixel_buffer b;b.fArea=area;b.fPlane=0;b.fPlanes=4;
    b.fRowStep=area.W()*4;b.fColStep=4;b.fPlaneStep=1;
    b.fPixelType=ttFloat;b.fPixelSize=4;b.fData=data;b.fDirty=true;return b;
}
static void global_tiles_clone_and_transform_preserve_samples() {
    PcDngAllocator allocator(1024*1024);auto failure=std::make_shared<std::atomic<bool>>(false);
    PcDngStagePlane plane(dng_rect(3,130),4,ttFloat,allocator,failure);
    std::vector<float> row(130*4);
    for(int y=0;y<3;++y) {
        for(int x=0;x<130;++x){row[4*x]=float(y*130+x)-3;row[4*x+1]=4;row[4*x+2]=0.25f;row[4*x+3]=0.5f;}
        auto b=buffer(dng_rect(y,0,y+1,130),row.data());plane.Put(b);plane.verify();
    }
    std::unique_ptr<dng_image> copy(plane.Clone());
    plane.Trim(dng_rect(1,64,3,130));plane.Rotate(dng_orientation::Rotate90CW());
    std::vector<float> transformed(2*66*4);auto b=buffer(plane.Bounds(),transformed.data());plane.Get(b);plane.verify();
    for(int y=0;y<66;++y)for(int x=0;x<2;++x){size_t i=size_t(y*2+x)*4;
        assert(transformed[i]==float((2-x)*130+64+y)-3);assert(transformed[i+1]==4);assert(transformed[i+3]==0.5f);}
    auto original=buffer(dng_rect(0,0,1,130),row.data());copy->Get(original);
    assert(row[0]==-3&&row[4*129]==126&&row[4*64+3]==0.5f);
}
static void shared_allocator_release_and_sticky_failure_refuse() {
    PcDngAllocator allocator(1024);auto failure=std::make_shared<std::atomic<bool>>(false);
    {std::unique_ptr<dng_memory_block> first(allocator.Allocate(512));
        bool refused=false;try{std::unique_ptr<dng_memory_block> second(allocator.Allocate(512));}
        catch(const dng_exception &e){refused=e.ErrorCode()==dng_error_memory;}assert(refused);}
    {std::unique_ptr<dng_memory_block> replacement(allocator.Allocate(512));assert(replacement->LogicalSize()==512);}
    PcDngStagePlane plane(dng_rect(1,2),4,ttFloat,allocator,failure);failure->store(true);
    float samples[8]{};auto b=buffer(dng_rect(1,2),samples);bool refused=false;
    try{plane.Get(b);}catch(const dng_exception &){refused=true;}assert(refused);
}
static void sdk_bypass_allocations_share_budget_and_final_owner() {
    auto budget=std::make_shared<PcDngBudget>(1024);void *retained=nullptr;
    {PcDngSourceScope scope(budget);
        dng_memory_data data(256);const auto first=budget->current();assert(first>=256);
        std::unique_ptr<dng_memory_block> block(gDefaultDNGMemoryAllocator.Allocate(256));
        assert(budget->current()>first);
        retained=gDefaultDNGMemoryAllocator.Malloc(32);
        bool refused=false;try{dng_memory_data excess(1024);}catch(const dng_exception &e){refused=e.ErrorCode()==dng_error_memory;}
        assert(refused);data.Clear();block.reset();assert(budget->current()>0);
    }
    // A retained SDK object frees against its original owner after scope exit.
    assert(budget->current()>0);gDefaultDNGMemoryAllocator.Free(retained);assert(budget->current()==0);
    auto next=std::make_shared<PcDngBudget>(1024);
    {PcDngSourceScope scope(next);dng_memory_data replacement(512);assert(next->current()>=512);}
    assert(next->current()==0);
}

static void private_scratch_seal_range_and_budget_cancel_refuse() {
    PcPrivateFile file;file.resize(32);unsigned char original[32]{};original[7]=99;
    file.transfer(original,0,32,true);file.seal();unsigned char copied[32]{};file.read(copied,0,32);assert(copied[7]==99);
    bool refused=false;try{file.transfer(original,0,1,true);}catch(const std::runtime_error &e){refused=std::string(e.what()).find("range/state")!=std::string::npos;}assert(refused);
    refused=false;try{file.read(copied,31,2);}catch(const std::runtime_error &e){refused=std::string(e.what()).find("range/state")!=std::string::npos;}assert(refused);
    std::atomic<bool> canceled(false);PcDecodeControl control{[](void *v)->int{return static_cast<std::atomic<bool> *>(v)->load()?1:0;},&canceled};
    auto budget=std::make_shared<PcDngBudget>(1024);budget->setControl(&control);
    {PcDngSourceScope scope(budget);dng_memory_data held(16);canceled.store(true);
        refused=false;try{dng_memory_data next(16);}catch(const dng_exception &e){refused=e.ErrorCode()==dng_error_user_canceled;}assert(refused);}
    assert(budget->current()==0);
}
int main(){global_tiles_clone_and_transform_preserve_samples();shared_allocator_release_and_sticky_failure_refuse();sdk_bypass_allocations_share_budget_and_final_owner();private_scratch_seal_range_and_budget_cancel_refuse();}
