import AppKit

/// Dither's quantization is intentional. Input is the actual float developed plane;
/// no intermediate byte image or browse preview defines its tones, source or alpha.
nonisolated enum LWFloatDither {
    typealias K=FloatImageAdjustmentPixels
    static let bayer2:[UInt8]=[0,2,3,1]
    static let bayer4:[UInt8]=[0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5]
    static let bayer8:[UInt8]=[0,32,8,40,2,34,10,42,48,16,56,24,50,18,58,26,12,44,4,36,14,46,6,38,60,28,52,20,62,30,54,22,3,35,11,43,1,33,9,41,51,19,59,27,49,17,57,25,15,47,7,39,13,45,5,37,63,31,55,23,61,29,53,21]
    static let patterns:[[UInt8]]=[
        [0,0,0,0,0,0,0,0],[0x80,0,0,0,8,0,0,0],[0x88,0,0x22,0,0x88,0,0x22,0],
        [0x80,0x40,0x20,0x10,8,4,2,1],[0x88,0x22,0x88,0x22,0x88,0x22,0x88,0x22],
        [0,0xff,0,0,0,0xff,0,0],[0x11,0x22,0x44,0x88,0x11,0x22,0x44,0x88],
        [0xaa,0,0xaa,0,0xaa,0,0xaa,0],[0x88,0x55,0x22,0x55,0x88,0x55,0x22,0x55],
        [0xff,0x80,0x80,0x80,0xff,8,8,8],[0xaa,0x55,0xaa,0x55,0xaa,0x55,0xaa,0x55],
        [0x81,0x42,0x24,0x18,0x18,0x24,0x42,0x81],[0x77,0xaa,0xdd,0xaa,0x77,0xaa,0xdd,0xaa],
        [0xee,0xdd,0xbb,0x77,0xee,0xdd,0xbb,0x77],[0x77,0xff,0xdd,0xff,0x77,0xff,0xdd,0xff],
        [0x7f,0xff,0xff,0xff,0xf7,0xff,0xff,0xff],[0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff]]
    static func apply(_ input:DitherSettings,plane:LWFloatPlane,workspace:LWFloatWorkspace)throws->LWFloatPlane {
        let s=input.normalized
        guard s==input,plane.workingSet===workspace.workingSet else { throw ProjectError.invalid }
        let block=s.style.usesPixelSize ? Int(s.pixelSize):1
        let working=block>1 ? try averaged(plane,block:block,workspace:workspace):plane
        let w=working.width,h=working.height,original=s.colors == .original,planes=original ? 3:1
        let source=working.sampler(),tones=try workspace.makeStateStore(format:.rgba32,width:w,height:h)
        let gamma=Float(exp2(s.density/100*1.5)),contrast=Float(s.contrast>=0 ? 1/(1-0.95*s.contrast/100):1+s.contrast/100)
        func tone(_ x:Float)->Float { min(1,max(0,(pow(min(1,max(0,x)),gamma)-0.5)*contrast+0.5)) }
        func encoded(_ p:SIMD4<Float>)->SIMD3<Float> { SIMD3(Float(K.encode(Double(p.x))),Float(K.encode(Double(p.y))),Float(K.encode(Double(p.z)))) }
        for y in 0..<h {
            try workspace.cancellation.check()
            for x in 0..<w {
                let p=try source.pixel(x:x,y:y),c=encoded(p)
                let v=original ? SIMD3(tone(c.x),tone(c.y),tone(c.z)):SIMD3(repeating:tone(c.x*0.2126+c.y*0.7152+c.z*0.0722))
                try tones.write(.rgba32(SIMD4(v.x,v.y,v.z,p.w)),x:x,y:y)
            }
        }
        func readTone(_ x:Int,_ y:Int)throws->SIMD4<Float> { guard case .rgba32(let v)=try tones.read(x:x,y:y) else { throw ProjectError.invalid };return v }
        let dark=s.colors == .twoColors ? SIMD3(Float(s.dark.red),Float(s.dark.green),Float(s.dark.blue)):SIMD3<Float>.zero
        let light=s.colors == .twoColors ? SIMD3(Float(s.light.red),Float(s.light.green),Float(s.light.blue)):SIMD3<Float>(repeating:1)
        let levels=Float(s.levels-1)
        if s.style.diffuses {
            let taps:[(Int,Int,Float)]=s.style == .atkinson ? [(1,0,1),(2,0,1),(-1,1,1),(0,1,1),(1,1,1),(0,2,1)]:[(1,0,7),(-1,1,3),(0,1,5),(1,1,1)]
            let divisor:Float=s.style == .atkinson ? 8:16
            // Same global serpentine/channel order, including across file tiles.
            for channel in 0..<planes { for y in 0..<h {
                try workspace.cancellation.check()
                let reverse=y&1 != 0
                for index in 0..<w {
                    let x=reverse ? w-1-index:index;var p=try readTone(x,y)
                    guard p.w>0 else { continue }
                    let old=p[channel],q=(min(1,max(0,old))*levels).rounded()/levels
                    p[channel]=q;try tones.write(.rgba32(p),x:x,y:y)
                    let error=(old-q)*Float(s.diffusion/100)/divisor
                    for (dx,dy,weight) in taps {
                        let xx=x+(reverse ? -dx:dx),yy=y+dy
                        guard xx>=0,xx<w,yy<h else { continue }
                        var next=try readTone(xx,yy);next[channel] += error*weight
                        try tones.write(.rgba32(next),x:xx,y:yy)
                    }
                }
            } }
        }
        // The actual existing monospaced glyph raster is retained, not a guessed
        // substitute alphabet. Admit its complete bounded maps before construction.
        let glyphs:(maps:[UInt8],coverage:[Float],width:Int,height:Int)
        var glyphLease:LWFloatWorkingSet.Lease?
        if s.style == .ascii {
            let characters=s.characters.isEmpty ? DitherSettings.defaultCharacters:s.characters
            let font=NSFont.monospacedSystemFont(ofSize:CGFloat(Int(s.textSize))/1.2,weight:.bold)
            let gw=max(1,Int(("M" as NSString).size(withAttributes:[.font:font]).width.rounded())),gh=Int(s.textSize)
            let count=Set(characters).count,maps=gw.multipliedReportingOverflow(by:gh),total=maps.partialValue.multipliedReportingOverflow(by:count)
            guard !maps.overflow,!total.overflow else { throw ProjectError.tooLarge }
            let charge=total.partialValue.multipliedReportingOverflow(by:3)
            guard !charge.overflow else { throw ProjectError.tooLarge };glyphLease=try workspace.workingSet.reserve(charge.partialValue+count*MemoryLayout<Float>.stride*3)
            glyphs=DitherSettings.glyphs(characters,lineHeight:gh)
            guard glyphs.width==gw,glyphs.height==gh,glyphs.maps.count==gw*gh*glyphs.coverage.count else { throw ProjectError.invalid }
        } else { glyphs=([],[],1,1) }
        func mark(_ v:SIMD4<Float>)->Float { original ? v.x*0.2126+v.y*0.7152+v.z*0.0722:v.x }
        let picked=try workspace.makeStateStore(format:.uint32,width:max(1,(w+glyphs.width-1)/glyphs.width),height:max(1,(h+glyphs.height-1)/glyphs.height))
        if s.style == .ascii,!glyphs.coverage.isEmpty {
            for row in 0..<(h+glyphs.height-1)/glyphs.height { for column in 0..<(w+glyphs.width-1)/glyphs.width {
                try workspace.cancellation.check();var sum:Float=0,n=0
                for y in row*glyphs.height..<min(h,(row+1)*glyphs.height) { for x in column*glyphs.width..<min(w,(column+1)*glyphs.width) {
                    let t=try readTone(x,y);if t.w>0 { sum += mark(t);n += 1 }
                } }
                let t=n>0 ? sum/Float(n):1,wanted=(s.lightOnDark ? t:1-t)*glyphs.coverage.last!
                var best=0,distance:Float=2
                for i in glyphs.coverage.indices { let d=abs(glyphs.coverage[i]-wanted);if d<distance { best=i;distance=d } }
                try picked.write(.uint32(UInt32(best)),x:column,y:row)
            } }
        }
        let kernel=LWFloatKernelWorkspace(makeBuilder:{try workspace.makeBuilder(width:$0,height:$1)},makeScratchDirectory:{try workspace.makeScratchDirectory()},fileOwner:workspace)
        var scanLine = -1,scan=[SIMD3<Float>]()
        let scanLease=try workspace.workingSet.reserve(w*MemoryLayout<SIMD3<Float>>.stride)
        let rendered=try kernel.map(working) { p,x,y,_ in
            guard p.w>0 else { return p }
            let t=try readTone(x,y),c:SIMD3<Float>
            switch s.style {
            case .atkinson,.floydSteinberg: c=original ? SIMD3(t.x,t.y,t.z):dark+(light-dark)*t.x
            case .bayer2,.bayer4,.bayer8:
                let size=s.style == .bayer2 ? 2:s.style == .bayer4 ? 4:8,matrix=s.style == .bayer2 ? bayer2:s.style == .bayer4 ? bayer4:bayer8
                let threshold=(Float(matrix[(y%size)*size+x%size])+0.5)/Float(size*size)
                func q(_ v:Float)->Float { min(levels,floor(min(1,max(0,v))*levels+threshold))/levels }
                c=original ? SIMD3(q(t.x),q(t.y),q(t.z)):dark+(light-dark)*q(t.x)
            case .scanlines:
                let spacing=Int(s.lineSpacing),line=y/spacing,middle=Float(spacing)/2
                if scanLine != line {
                    scanLine=line;scan=[SIMD3<Float>](repeating:.zero,count:w)
                    let wave=sin(Float(line)*0.45)*0.7+sin(Float(line)*1.7+1.3)*0.3,shift=Int((Float(s.wobble)*wave).rounded())
                    for xx in 0..<w {
                        let sx=xx-shift;guard sx>=0,sx<w else { continue };var sum=SIMD3<Float>.zero,n=0
                        for yy in line*spacing..<min(h,(line+1)*spacing) { let v=try readTone(sx,yy);if v.w>0 { sum += SIMD3(v.x,v.y,v.z);n += 1 } }
                        if n>0 { scan[xx]=sum/Float(n) }
                    }
                }
                let dots=Float(s.dots/100),along=Float(x)+0.5-Float((x/spacing)*spacing)-middle
                let at=min(w-1,max(0,Int((Float(x)-along*dots).rounded()))),v=scan[at]
                let brightness=original ? v.x*0.2126+v.y*0.7152+v.z*0.0722:v.x
                let rgb=(original ? v:dark+(light-dark)*brightness)*1.35
                let offset=abs(Float(y%spacing)+0.5-middle),beam=middle*(0.2+0.5*sqrt(min(1,max(0,brightness))))
                let cover=min(1,max(0,beam-hypot(offset,along*dots)+0.5)),background=original ? SIMD3<Float>.zero:dark
                c=background+(rgb-background)*cover
            case .dots,.lines,.diamonds,.patterns,.ascii:
                let amount:Float
                if s.style == .ascii,!glyphs.coverage.isEmpty {
                    guard case .uint32(let glyph)=try picked.read(x:x/glyphs.width,y:y/glyphs.height) else { throw ProjectError.invalid }
                    amount=Float(glyphs.maps[Int(glyph)*glyphs.width*glyphs.height+(y%glyphs.height)*glyphs.width+x%glyphs.width])/255
                } else if s.style == .patterns {
                    let coverage=s.lightOnDark ? mark(t):1-mark(t),index=min(patterns.count-1,max(0,Int((coverage*Float(patterns.count-1)).rounded())))
                    amount=Float((patterns[index][y&7] >> (7-(x&7)))&1)
                } else {
                    let angle=Float(s.angle * .pi/180),cosA=cos(angle),sinA=sin(angle),fx=Float(x)+0.5,fy=Float(y)+0.5,cell=Float(max(2,Int(s.cellSize)))
                    var u=(fx*cosA+fy*sinA)/cell,v=(-fx*sinA+fy*cosA)/cell;u -= floor(u)+0.5;v -= floor(v)+0.5
                    let spot=s.style == .dots ? Float.pi*(u*u+v*v):s.style == .lines ? abs(v)*2:abs(u)+abs(v)
                    amount=(s.lightOnDark ? mark(t):1-mark(t))>spot ? 1:0
                }
                if original { let paper=SIMD3<Float>(repeating:s.lightOnDark ? 0:1);c=paper+(encoded(p)-paper)*amount }
                else { let paper=s.lightOnDark ? dark:light,ink=s.lightOnDark ? light:dark;c=paper+(ink-paper)*amount }
            }
            return SIMD4(Float(K.decode(Double(c.x))),Float(K.decode(Double(c.y))),Float(K.decode(Double(c.z))),p.w)
        }
        var result=rendered
        if s.style == .scanlines,s.glow>0 {
            let sigma=s.lineSpacing*3+3,shrink=max(1,floor(sigma/4))
            let glow=try LWFloatFilter.coreImage(result,workspace:workspace) { image in
                image.clampedToExtent().transformed(by:CGAffineTransform(scaleX:1/shrink,y:1/shrink))
                    .applyingGaussianBlur(sigma:sigma/shrink).transformed(by:CGAffineTransform(scaleX:shrink,y:shrink))
            },lightPlane=glow.sampler()
            result=try kernel.rgb(result) { linear,x,y in
                let p=try lightPlane.pixel(x:x,y:y),a=SIMD3(K.encode(linear.x),K.encode(linear.y),K.encode(linear.z))
                let b=SIMD3(K.encode(Double(p.x)),K.encode(Double(p.y)),K.encode(Double(p.z)))*Double(p.w)*s.glow/100*2.5
                return SIMD3(K.decode(a.x+b.x),K.decode(a.y+b.y),K.decode(a.z+b.z))
            }
        }
        if block>1 {
            let small=result.sampler(),blank=try LWFloatCompositor.clearPlane(width:plane.width,height:plane.height,workspace:workspace)
            result=try LWFloatCompositor.map(blank,workspace:workspace) { _,x,y in
                var p=try small.pixel(x:x/block,y:y/block)
                if s.pixelShape == .dot {
                    let dx=Float(x%block)+0.5-Float(block)/2,dy=Float(y%block)+0.5-Float(block)/2
                    let cover=min(1,max(0,Float(block)*0.42-hypot(dx,dy)+0.5)),gap=s.colors == .twoColors ? dark:SIMD3<Float>.zero
                    let encoded=SIMD3(Float(K.encode(Double(p.x))),Float(K.encode(Double(p.y))),Float(K.encode(Double(p.z))))
                    let c=gap+(encoded-gap)*cover;p.x=Float(K.decode(Double(c.x)));p.y=Float(K.decode(Double(c.y)));p.z=Float(K.decode(Double(c.z)))
                };return p
            }
        }
        withExtendedLifetime(glyphLease) {};withExtendedLifetime(scanLease) {};return result
    }
    /// Intrinsic downsample in bounded global rectangles. Core Graphics retains
    /// its existing high-quality interpolation; the source provider's sticky failure
    /// is checked before any destination range is published.
    static func averaged(_ plane:LWFloatPlane,block:Int,workspace:LWFloatWorkspace)throws->LWFloatPlane {
        let width=(plane.width+block-1)/block,height=(plane.height+block-1)/block,builder=try workspace.makeBuilder(width:width,height:height)
        let provider=LWFloatPlaneImage(plane:plane,cancellation:workspace.cancellation),image=try provider.image()
        while let range=builder.nextRange {
            try workspace.cancellation.check()
            let bytes=try range.validate(frameWidth:width,frameHeight:height),lease=try workspace.workingSet.reserve(bytes*3)
            let context=try LWLinearSurface.context(width:range.width,height:range.height,maximumBytes:bytes)
            context.interpolationQuality = .high;context.setBlendMode(.copy)
            context.translateBy(x:-CGFloat(range.x),y:CGFloat(height-range.y));context.scaleBy(x:1,y:-1)
            context.draw(image,in:CGRect(x:0,y:0,width:CGFloat(plane.width)/CGFloat(block),height:CGFloat(plane.height)/CGFloat(block)))
            guard let output=context.makeImage() else { throw ExportError.render };try provider.check()
            try builder.append(LWLinearSurface.read(output,maximumBytes:bytes),at:range);withExtendedLifetime(lease) {}
        }
        return try builder.finish()
    }
}
