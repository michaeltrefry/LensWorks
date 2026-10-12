# Merge to HDR (S43 / sc-25321)

**Merge to HDR…** (registered command `catalog.hdr.merge`, catalog toolbar) merges 2–9 selected catalog photos into one new linear floating-point DNG. It is unavailable, and says why, unless a catalog is open, no other catalog action or import is running, and 2–9 photos are selected.

## Pipeline

1. **Development.** Each source original is developed by the editor's own managed source development (`LWSourceDeveloper.createPlane`), RAW or raster, to extended-linear sRGB float. Originals are read only. Their SHA-256 is taken before development and checked again before the import; if any source changed, the DNG is deleted and nothing is imported.
2. **Reference.** The reference is the frame with the median mean luminance, so the middle exposure of a bracket.
3. **Alignment.** Each frame gets an integer translation found with median-threshold bitmaps (Ward 2003). Two searches run:
   - a coarse-to-fine pyramid search over up to six levels: ±1 at the coarsest level, then ±2 at each finer level, for large handheld shifts;
   - a full-resolution search within ±2 px of zero, which uses fine texture that averaging removes from the coarse levels.

   Both are scored by the disagreement rate over the pixels they actually compare, so a larger shift is not rewarded for comparing fewer pixels. The lower rate wins; on ties the smaller shift wins, so a static scene stays at (0, 0). Pixels shifted in from outside the frame get no weight.
4. **Exposure.** Each frame's linear exposure relative to the reference is the median of log2(Y_frame / Y_ref) over pixels that are well exposed in both frames. The median ignores the minority of pixels that moved. Frames that share too few well-exposed pixels are refused.
5. **Weights.** Weight = hat(peak / clip) × exposure.
   - hat(t) = 1 − (2t − 1)^12.
   - clip = 0.98 × max(1, the frame's brightest channel).
   - A pixel gets weight 0 where any channel is clipped or its luminance is below 0.2 % of clip.
   - A pixel no frame can supply takes its value from the darkest frame if it is clipped, from the brightest frame if it is in shadow, and from the reference when deghosting is on.
6. **Deghosting (default on).** Each non-reference frame gets a motion mask. A pixel is masked when either:
   - both frames are valid and their radiances differ by more than 0.75 stop; or
   - the reference is clipped or underexposed there, and the frame breaks the lower or upper bound that the clipped or underexposed reference implies.

   The mask is dilated by 2 px and feathered by 2 px. Masked weight is removed, so the reference frame alone supplies the region where something moved.
7. **DNG.** The output is written beside the first source as `<reference>-HDR.dng`, with `-2`, `-3`… added if that name is taken. The format is an uncompressed DNG 1.4 LinearRaw file with 3 × 32-bit IEEE float samples (SampleFormat 3).
   - **Color.** The camera space is linear sRGB D65: ColorMatrix1 is XYZ→sRGB, ForwardMatrix1 is Bradford sRGB→XYZ D50, AsShotNeutral is 1,1,1 and CalibrationIlluminant1 is D65.
   - **Samples.** Samples are normalized so the brightest channel is 1.0. BaselineExposure = log2(peak radiance) restores the reference exposure in renderers that apply it.
   - **XMP.** The XMP packet holds the provenance:
     - `xmpMM:Ingredients`, one per source, with `stRef:filePath`, catalog image, asset and variant IDs, SHA-256, relative exposure (EV), alignment offset and embedded profile name;
     - the deghost setting and the reference index;
     - the reference frame's Make, Model, Lens and DateTimeOriginal.
8. **Catalog.** The source folder is re-imported through the ordinary folder import, which leaves already-cataloged files unchanged. The one new DNG becomes the new catalog item and is selected. The menu command then creates a working version, so the merge opens in the editor as a live RAW source with Camera Raw controls under editable layers. The link from the merged item to its sources is the ingredient record inside its own original (`LWDNGInspection.provenance()`).

## Ghosting metric

The ghosting metric G compares the merge with the reference frame over a region S:

G = mean over p ∈ S, counting only pixels where the reference frame is valid (unclipped and above its noise floor), of |log2(Y_merged(p) + ε) − log2(Y_ref(p) + ε)|

- Y is Rec. 709 luminance of linear values, in the merge's radiance unit (the reference exposure).
- ε = 1e-4.

A ghost-free merge reproduces the reference frame's scene where the subject moved, so G → 0. Copies of the subject blended in from other frames raise G, as does background showing through where the reference has the subject. `LWHDRGhostingMetric` implements G.

For the S47 generated bracket (seed 25316), S is the union of the three declared subject rectangles. `HDRMergeTests.deghostingLowersTheGhostingMetricOnTheMovingSubject` requires G(deghost on) < 0.5 × G(deghost off) on that region. It also requires the two settings to agree outside the region. The measured values are printed in the test log.
