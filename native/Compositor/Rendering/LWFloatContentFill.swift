import Foundation

/// Retained ContentFill's global frontier/patch search, using admitted disk-backed
/// typed state. It is executed only for the explicit user operation, never replayed
/// during RAW development invalidation. The completed plane becomes an owned input.
nonisolated enum LWFloatContentFill {
    static func run(_ before:LWFloatPlane,coverage:LWFloatPlane,workspace:LWFloatWorkspace)throws->LWFloatPlane {
        let w=before.width,h=before.height,n=w*h
        guard coverage.width==w,coverage.height==h,n<UInt32.max else { throw ProjectError.invalid }
        let input=before.sampler(),mask=coverage.sampler()
        let pixels=try workspace.makeStateStore(format:.rgba32,width:w,height:h),flags=try workspace.makeStateStore(format:.uint32,width:w,height:h)
        let chosen=try workspace.makeStateStore(format:.uint32,width:w,height:h),donors=try workspace.makeStateStore(format:.uint32,width:w,height:h),queue=try workspace.makeStateStore(format:.uint32,width:w,height:h)
        let known:UInt32=1,target:UInt32=2,valid:UInt32=4,queued:UInt32=8
        func flag(_ p:Int)throws->UInt32 { guard case .uint32(let value)=try flags.read(x:p%w,y:p/w) else { throw ProjectError.invalid };return value }
        func setFlag(_ value:UInt32,_ p:Int)throws { try flags.write(.uint32(value),x:p%w,y:p/w) }
        func read(_ store:LWTypedStateStore,_ p:Int)throws->Int { guard case .uint32(let value)=try store.read(x:p%w,y:p/w) else { throw ProjectError.invalid };return Int(value) }
        func write(_ store:LWTypedStateStore,_ p:Int,_ value:Int)throws { guard let v=UInt32(exactly:value) else { throw ProjectError.invalid };try store.write(.uint32(v),x:p%w,y:p/w) }
        func pixel(_ p:Int)throws->SIMD4<Float> { guard case .rgba32(let value)=try pixels.read(x:p%w,y:p/w) else { throw ProjectError.invalid };return value }
        var missing=0,donorCount=0,head=0,tail=0,scan=0
        for y in 0..<h {
            try workspace.cancellation.check()
            for x in 0..<w {
                let p=try input.pixel(x:x,y:y),selected=try mask.pixel(x:x,y:y).w>0,index=y*w+x
                try pixels.write(.rgba32(p),x:x,y:y)
                try setFlag(selected ? target:p.w==1 ? known:0,index)
                if selected { missing += 1 }
            }
        }
        if missing==0 { return before }
        let radius=w>=5 && h>=5 ? 2:0
        for y in 0..<h {
            try workspace.cancellation.check()
            for x in 0..<w {
                let p=y*w+x;guard try flag(p)&known != 0 else { continue }
                var ok=true
                for dy in -radius...radius { for dx in -radius...radius {
                    let sx=x+dx,sy=y+dy
                    if sx<0 || sy<0 || sx>=w || sy>=h { ok=false }
                    else if try flag(sy*w+sx)&known == 0 { ok=false }
                } }
                if ok { try setFlag(try flag(p)|valid,p);try write(donors,donorCount,p);donorCount += 1 }
            }
        }
        guard donorCount>0 else { throw ContentFill.Failure.noSource }
        func neighbors(_ p:Int)->[Int] { let x=p%w,y=p/w;return [x>0 ? p-1:-1,x+1<w ? p+1:-1,y>0 ? p-w:-1,y+1<h ? p+w:-1] }
        func enqueue(_ p:Int)throws {
            guard p>=0,p<n else { throw ProjectError.invalid }
            let f=try flag(p);guard f&queued==0 else { return }
            guard tail<n else { throw ProjectError.invalid };try write(queue,tail,p);tail += 1;try setFlag(f|queued,p)
        }
        for p in 0..<n {
            if p%w==0 { try workspace.cancellation.check() }
            if try flag(p)&target != 0 {
                for neighbor in neighbors(p) where neighbor>=0 { if try flag(neighbor)&known != 0 { try enqueue(p);break } }
            }
        }
        func associated(_ p:SIMD4<Float>)->SIMD4<Double> {
            typealias K=FloatImageAdjustmentPixels
            return SIMD4(K.encode(Double(p.x))*Double(p.w),K.encode(Double(p.y))*Double(p.w),K.encode(Double(p.z))*Double(p.w),Double(p.w))
        }
        func score(_ p:Int,_ q:Int)throws->Double {
            var sum=0.0,count=0;let px=p%w,py=p/w,qx=q%w,qy=q/w
            for dy in -radius...radius { for dx in -radius...radius {
                let x=px+dx,y=py+dy,sx=qx+dx,sy=qy+dy
                guard x>=0,y>=0,x<w,y<h,sx>=0,sy>=0,sx<w,sy<h,try flag(y*w+x)&known != 0 else { continue }
                let a=associated(try pixel(y*w+x)),b=associated(try pixel(sy*w+sx)),delta=a-b
                for component in 0..<4 { sum += delta[component]*delta[component] };count += 1
            } }
            return count>0 ? sum/Double(count):Double.greatestFiniteMagnitude
        }
        var seed:UInt32=0x6d2b79f5
        func next()->UInt32 { seed=seed &* 1664525 &+ 1013904223;return seed }
        while true {
            while head<tail {
                try workspace.cancellation.check();try Task.checkCancellation()
                let p=try read(queue,head);head += 1
                let near=neighbors(p);var best = -1,bestScore=Double.greatestFiniteMagnitude
                for k in 0..<28 {
                    let q:Int
                    if k<4 {
                        let t=near[k]
                        if t>=0 { let recorded=try read(chosen,t);q=(recorded>0 ? recorded-1:t)+(p-t) } else { q = -1 }
                    } else { q=try read(donors,Int(next()%UInt32(donorCount))) }
                    guard q>=0,q<n,try flag(q)&valid != 0 else { continue }
                    let s=try score(p,q);if best<0 || s<bestScore { best=q;bestScore=s }
                }
                if best<0 { best=try read(donors,0) }
                for r in [64,32,16,8,4,2,1] {
                    let qx=best%w+Int(next()%UInt32(2*r+1))-r,qy=best/w+Int(next()%UInt32(2*r+1))-r
                    guard qx>=0,qy>=0,qx<w,qy<h,try flag(qy*w+qx)&valid != 0 else { continue }
                    let q=qy*w+qx,s=try score(p,q);if s<bestScore { bestScore=s;best=q }
                }
                try pixels.write(.rgba32(try pixel(best)),x:p%w,y:p/w)
                try setFlag(try flag(p)|known,p);try write(chosen,p,best+1)
                for q in near where q>=0 { let f=try flag(q);if f&target != 0,f&known==0,f&queued==0 { try enqueue(q) } }
            }
            while scan<n {
                let f=try flag(scan);if f&target != 0,f&known==0 { break };scan += 1
            }
            if scan>=n { break };try enqueue(scan)
        }
        // Fully publish the immutable actual synthesis before any caller may attach
        // it to the source graph or history. No partial state is a retained result.
        let snapshot=try pixels.commit(),reader=snapshot.reader()
        return try LWFloatCompositor.map(before,workspace:workspace) { _,x,y in
            guard case .rgba32(let p)=try reader.read(x:x,y:y) else { throw ProjectError.invalid };return p
        }
    }
}
