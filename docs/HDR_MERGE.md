# Merge to HDR (S43 / sc-25321)

**Merge to HDR…** (registered command `catalog.hdr.merge`, catalog toolbar) merges 2–9 selected catalog photos into one new linear floating-point DNG. It is unavailable, and says why, unless a catalog is open, no other catalog action, import or merge is running, and 2–9 photos are selected. While a merge runs, the toolbar shows its progress and **Cancel Merge to HDR** (`catalog.hdr.cancel`). Cancelling stops the work and leaves no file. Once the merged photo is being added to the catalog the merge can no longer be cancelled, and the command says so.

An AI agent connected over automation runs all three commands (`catalog.hdr.merge` with an optional `deghost` boolean, `catalog.hdr.cancel`, and `catalog.hdr.selectSources` with a `photo` id). Merge to HDR… acts on the current selection, as the sheet's Merge button does. Every source original it reads and the folder it writes the DNG into must lie inside a folder granted to automation, checked before anything is read, and the merge runs only while the selection still reaches exactly those originals. The merge never replaces a file, so it needs no confirmation. Rebuilding a lost merge link for an agent reads only files inside the granted folders.

## Pipeline

1. **Development.** Each source original is developed by the editor's own managed source development (`LWSourceDeveloper.createPlane`), RAW or raster, to extended-linear sRGB float. The developed plane is read in row strips of about 32 MiB into the merge's own frame storage (`LWMergeFrame`: packed RGB half floats, 6 bytes per pixel), so a frame of any size passes through the 512 MiB float working set a strip at a time. Originals are read only. Their SHA-256 is taken before development and checked again before the DNG is put in place; if any source changed, nothing is written or imported.
2. **Reference.** The reference is the frame with the median mean luminance, so the middle exposure of a bracket.
3. **Alignment.** Each frame gets an integer translation found with median-threshold bitmaps (Ward 2003). Two searches run:
   - a coarse-to-fine pyramid search over up to six levels: ±1 at the coarsest level, then ±2 at each finer level, for large handheld shifts;
   - a full-resolution search within ±2 px of zero, which uses fine texture that averaging removes from the coarse levels.

   Both are scored by the disagreement rate over the pixels they actually compare, so a larger shift is not rewarded for comparing fewer pixels. The lower rate wins; on ties the smaller shift wins, so a static scene stays at (0, 0). Pixels shifted in from outside the frame get no weight.
4. **Exposure.** Each frame's linear exposure relative to the reference is the median of log2(Y_frame / Y_ref) over pixels that are well exposed in both frames. The median ignores the minority of pixels that moved. Frames that share too few well-exposed pixels are refused.
5. **Weights.** Weight = hat(peak / clip) × exposure.
   - hat(t) = 1 − (2t − 1)^12.
   - clip is per channel. For camera RAW it comes from the source: 0.98 × the level at which the decoder says a neutral subject's first sensor channel saturates. The decode worker reports that level with each development (`RenderProvenance.neutral_clip`) from what it knows of the sensor:
     - DNG: the profile matrix applied to the camera white, which the DNG SDK scales so its largest channel is the white level;
     - other RAW (LibRaw): the camera matrix applied to the balanced level at which the channel with the smallest white-balance multiplier reaches the sensor maximum.

     RAW development leaves highlights unclipped. Above that level a neutral highlight is colour-shifted (DNG) or synthesized by highlight blending (LibRaw), while a fully saturated sensor or a saturated coloured subject can read far higher in one channel and lower in another (the procedural test DNG's saturated block develops to about 2.23, 0.91, 1.37). The frame's own maximum therefore says nothing about where clipping starts, and the level is whatever the source says, not 1.0 by assumption.
   - A raster source (PNG, JPEG, TIFF) has no sensor white level, and neither does a floating-point DNG or a DNG with a spatial gain map. For these the clip level is an estimate from the frame: 0.98 × max(1, that channel's brightest sample). Raster data saturates at 1.0, so the estimate is exact for it.
   - peak / clip is the largest of the three channel ratios. A pixel gets weight 0 where any channel reaches its clip or its luminance is below 0.2 % of the clip's luminance.
   - A pixel no frame can supply takes its value from the darkest frame if it is clipped, from the brightest frame if it is in shadow, and from the reference when deghosting is on.
6. **Deghosting (default on).** Each non-reference frame gets a motion mask. A pixel is masked when either:
   - both frames are valid and their radiances differ by more than 0.75 stop; or
   - the reference is clipped or underexposed there, and the frame breaks the lower or upper bound that the clipped or underexposed reference implies.

   The mask is dilated by 2 px and feathered by 2 px. Masked weight is removed, so the reference frame alone supplies the region where something moved. Each mask is built for one frame, folded into that frame's weights and released.
7. **DNG.** The output goes beside the first source as `<reference>-HDR.dng`, with `-2`, `-3`… added if that name is taken. It is streamed to a hidden temporary name and then moved into place with an exclusive rename, so an existing file is never replaced and a failed or cancelled write leaves nothing. The format is an uncompressed DNG 1.4 LinearRaw file with 3 × 32-bit IEEE float samples (SampleFormat 3).
   - **Color.** The camera space is linear sRGB D65: ColorMatrix1 is XYZ→sRGB, ForwardMatrix1 is Bradford sRGB→XYZ D50, AsShotNeutral is 1,1,1 and CalibrationIlluminant1 is D65.
   - **Samples.** Samples are normalized so the brightest channel is 1.0. BaselineExposure = log2(peak radiance) restores the reference exposure in renderers that apply it.
   - **XMP.** The XMP packet holds the provenance:
     - `xmpMM:Ingredients`, one per source, with `stRef:filePath` (the source's file name only), catalog image, asset and variant IDs, SHA-256, relative exposure (EV), alignment offset and embedded profile name;
     - the deghost setting and the reference index;
     - the reference frame's Make, Model, Lens and DateTimeOriginal.

     The file is meant to be shared, so the packet holds no local path: no source folder, no catalog path.
8. **Catalog.** Only the written file is imported, through the engine's single-file import route (`ImportStart` with a regular file as its source: the file's folder is the import root, and nothing else in it or below it is walked). Other photos in that folder that the catalog has not imported stay out of the catalog, and the folder-import resume source is not replaced. The new catalog photo is found by its original's location, never by file name alone, and becomes the selected photo; the browse scope, filters and search text stay as they were, even when the merged photo falls outside them. If the import ends without admitting the file, the file is removed.
9. **Link.** The merged photo's sources are recorded against it in the catalog: the LensWorks catalog index (`derived_sources`: catalog, merged photo, position, source image, asset and variant IDs, source file name, missing flag, kind of merge) holds them, and `LensWorksCatalog.hdrMergeSources(of:)` reads them back. The photo details show "HDR merge of N photos" with the source names, and **Select HDR Source Photos** (`catalog.hdr.selectSources`) makes the sources the catalog selection. The DNG's XMP carries the same record so it travels with the file.

   The index is rebuildable. When it has no link for a DNG (it was deleted or rebuilt, or the file was merged in another catalog), `hdrMergeSources(of:)` reads the XMP record from the file's first IFD, without reading its samples, and matches each source to the catalog by asset ID and by the SHA-256 of its original. A source that is no longer in the catalog, or whose original no longer has the recorded bytes, is kept as missing under its recorded file name; the details mark it and Select HDR Source Photos skips it. The rebuilt link is stored again. If a matched source's original is offline its bytes cannot be checked, so the link is shown but not stored until they can.
10. **Editing.** The toolbar command then creates a working version, so the merge opens in the editor as a live RAW source with Camera Raw controls under editable layers.

What is not particular to an exposure bracket is shared with Merge to Panorama… (docs/PANORAMA_MERGE.md): the developed frame and its loader (`LWMergeFrame`), the memory budget (`LWMergeBudget`), the linear float DNG writer and the XMP packet (`LWLinearDNGWriter`, `LWDerivedXMP`), and the catalog side of a merge with its progress, cancel and source-link views (`LensWorksDerivedMerge.swift`). The two merges exclude each other while one runs.

## Memory

The merge holds, per pixel:

| What | Bytes per pixel |
| --- | --- |
| Each loaded frame (packed RGB half floats) | 6 |
| Radiance sum, which becomes the result in place | 12 |
| Weight total and flags | 5 |
| One frame's motion-mask scratch | 9 |
| Alignment scratch the allocator still holds after it is freed | about 6 |

Working memory is budgeted as pixels × (6 × frames + 32). The exposure estimate reads a regular grid of at most about 8 million pixels, and the DNG is streamed to disk from the result, so neither adds a per-pixel buffer.

The 32 is measured, not only counted: a release build of the merger and writer on generated 8192 × 5464 (44.8 MP) brackets had a peak memory footprint of 2.20 GB with 3 frames, 2.74 GB with 5 and 3.82 GB with 9, which is 31.1 to 31.3 bytes per pixel above the frames. macOS keeps freed large blocks in the process, so the peak is the sum of what the merge ever holds at once plus that retained scratch. Those merges took 12 s, 22 s and 47 s on one core, and each write about 3 s. The figures exclude source development, which runs in the decode helper and the 512 MiB float working set.

The budget is 3/8 of physical memory and never less than 6 GiB, the figure for the product-minimum 16 GB Mac. `LWHDRMerger.admit` checks it as soon as the first photo's dimensions are known, before any frame is loaded, and refuses with the photo count, the dimensions, the memory needed and the budget. Catalog rows carry no pixel dimensions, so the command cannot be disabled for this in advance.

On the 16 GB Mac's 6 GiB budget the largest brackets admitted are:

| Frames | Bytes per pixel | Largest frame |
| --- | --- | --- |
| 2 | 44 | 146 MP |
| 3 | 50 | 128 MP |
| 5 | 62 | 103 MP |
| 7 | 74 | 87 MP |
| 9 | 86 | 74 MP |

A 9-frame bracket of 45 MP files is budgeted at 3.8 GB and a 5-frame bracket at 2.8 GB.

## Ghosting metric

The ghosting metric G compares the merge with the reference frame over a region S:

G = mean over p ∈ S, counting only pixels where the reference frame is valid (unclipped and above its noise floor), of |log2(Y_merged(p) + ε) − log2(Y_ref(p) + ε)|

- Y is Rec. 709 luminance of linear values, in the merge's radiance unit (the reference exposure).
- ε = 1e-4.

A ghost-free merge reproduces the reference frame's scene where the subject moved, so G → 0. Copies of the subject blended in from other frames raise G, as does background showing through where the reference has the subject. `LWHDRGhostingMetric` implements G.

For the S47 generated bracket (seed 25316), S is the union of the three declared subject rectangles. `HDRMergeTests.deghostingLowersTheGhostingMetricOnTheMovingSubject` requires G(deghost on) < 0.5 × G(deghost off) on that region. It also requires the two settings to agree outside the region. The measured values are printed in the test log.
