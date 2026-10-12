#pragma once
#include "dng_exceptions.h"
#include "decode.h"
#include <memory>
#include <mutex>
#include <cstdlib>
#include <cstdint>
#include <cstddef>
#include <new>
#include <limits>

// A process decode has one scoped SDK allocation authority. SDK area-task
// threads see the same owner; a thread-local allocator would miss those tasks.
// A retained allocation keeps its budget alive until its actual final free.
class PcDngBudget {
    std::mutex mutex;
    uint64_t used=0;
    const PcDecodeControl *control=nullptr;
    bool closed=false;
public:
    const uint64_t maximum;
    explicit PcDngBudget(uint64_t value):maximum(value) {}
    void setControl(const PcDecodeControl *value) {std::lock_guard<std::mutex> guard(mutex);control=value;}
    void close() noexcept {std::lock_guard<std::mutex> guard(mutex);closed=true;control=nullptr;}
    void check() {std::lock_guard<std::mutex> guard(mutex);if(closed||pc_canceled(control))ThrowUserCanceled();}
    void reserve(uint64_t bytes) {
        std::lock_guard<std::mutex> guard(mutex);
        if(closed||pc_canceled(control))ThrowUserCanceled();
        if(bytes>maximum || used>maximum-bytes) ThrowMemoryFull("DNG shared scratch admission");
        used+=bytes;
    }
    void release(uint64_t bytes) noexcept {
        std::lock_guard<std::mutex> guard(mutex);
        // Charges are owned, never clamped/adopted from another generation.
        if(bytes>used)std::terminate();
        used-=bytes;
    }
    uint64_t current() {std::lock_guard<std::mutex> guard(mutex);return used;}
};
namespace pc_dng_allocation {
inline std::mutex decodeGate,ownerMutex;
inline std::shared_ptr<PcDngBudget> active;
struct alignas(std::max_align_t) Header {
    std::shared_ptr<PcDngBudget> owner;
    uint64_t charge;
};
}
class PcDngSourceScope {
    std::unique_lock<std::mutex> gate;
public:
    explicit PcDngSourceScope(std::shared_ptr<PcDngBudget> owner):gate(pc_dng_allocation::decodeGate) {
        std::lock_guard<std::mutex> lock(pc_dng_allocation::ownerMutex);
        pc_dng_allocation::active=std::move(owner);
    }
    ~PcDngSourceScope() {
        std::lock_guard<std::mutex> lock(pc_dng_allocation::ownerMutex);
        if(pc_dng_allocation::active)pc_dng_allocation::active->close();
        pc_dng_allocation::active.reset();
    }
};
// Only generated dng_memory.cpp calls these. This is not a global malloc
// interposer and does not change LibRaw/AVIF/framework allocator contracts.
inline void *pc_dng_malloc(size_t bytes) {
    using Header=pc_dng_allocation::Header;
    if(bytes>std::numeric_limits<size_t>::max()-sizeof(Header))ThrowMemoryFull("DNG SDK allocation overflow");
    const size_t charge=bytes+sizeof(Header);
    std::shared_ptr<PcDngBudget> owner;
    {std::lock_guard<std::mutex> lock(pc_dng_allocation::ownerMutex);owner=pc_dng_allocation::active;}
    if(owner)owner->reserve(charge);
    void *raw=std::malloc(charge);
    if(!raw){if(owner)owner->release(charge);ThrowMemoryFull("DNG SDK allocation failed");}
    auto *header=new(raw)Header{std::move(owner),uint64_t(charge)};
    return header+1;
}
inline void pc_dng_free(void *pointer) noexcept {
    using Header=pc_dng_allocation::Header;
    if(!pointer)return;
    auto *header=static_cast<pc_dng_allocation::Header *>(pointer)-1;
    auto owner=std::move(header->owner);const uint64_t charge=header->charge;
    header->~Header();std::free(header);if(owner)owner->release(charge);
}

class PcDngReservation {
    std::shared_ptr<PcDngBudget> owner;uint64_t bytes;
public:
    PcDngReservation(std::shared_ptr<PcDngBudget> value,uint64_t count):owner(std::move(value)),bytes(count){owner->reserve(bytes);}
    ~PcDngReservation(){owner->release(bytes);}
};
