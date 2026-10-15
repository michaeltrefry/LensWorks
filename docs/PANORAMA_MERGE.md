# Merge to Panorama (S44 / sc-25322)

**Merge to Panorama…** (registered command `catalog.panorama.merge`, catalog toolbar) stitches 2–24 selected, overlapping catalog photos into one new linear floating-point DNG. It is unavailable, and says why, unless a catalog is open, no other catalog action, import or merge is running, and 2–24 photos are selected. Its sheet asks for the projection (Spherical, Cylindrical, Perspective) and the edges (Auto Crop, Fill Edges). While a merge runs, the toolbar shows its progress and **Cancel Merge to Panorama** (`catalog.panorama.cancel`). Cancelling stops the work and leaves no file. Once the panorama is being added to the catalog the merge can no longer be cancelled, and the command says so. Merge to HDR… and Merge to Panorama… exclude each other: while one runs, the other's reason names the one that is running.

The catalog side is shared with Merge to HDR… (`LensWorksDerivedMerge.swift`; see docs/HDR_MERGE.md for what it guarantees): the selected originals are hashed and only read, developed by the editor's own source development into packed half-float frames in bounded row strips, the DNG is streamed to a hidden temporary name beside the first source and moved into place without replacing, only that one file is imported, and the new photo is found by its original's location. What follows is what is particular to a panorama.

## Pipeline

1. **Development.** As for an HDR merge: `LWSourceDeveloper.createPlane`, read a strip of about 32 MiB at a time into `LWMergeFrame` (6 bytes per pixel). The photos must all have the same pixel dimensions.
2. **Working copies.** Each frame is reduced by an integer factor, with an area average, to at most about 1 MP. Registration, exposure and the seams work on these copies; the picture is blended from the full frames.
3. **Features.** Multi-scale oriented patches (Brown, Szeliski and Winder 2005). On a display-like encoding of the luminance, at up to four pyramid levels: Harris corners (harmonic mean of the structure tensor's eigenvalues), the strongest in each cell of a grid so they spread over the frame (about 1,000 per frame), each placed to a fraction of a pixel, given an orientation from the gradient smoothed at σ = 4.5, and described by an 8 × 8 patch sampled 3 pixels apart along that orientation, normalized to zero mean and unit variance. The normalization makes the descriptor indifferent to exposure.
4. **Matching.** Every pair of frames is tried. A match is a pair of features at the same pyramid level that are each other's nearest descriptor, where the nearest is clearly nearer than the second nearest (squared distance under 0.64 of it).
5. **Pairwise registration.** RANSAC over four-point homographies, with as many draws as give a 99.9 % chance of one all-inlier sample (60 to 1,000), an inlier being a match the homography takes to within 3 working-copy pixels. The homography is refitted to its inliers by least squares. A pair is joined when it has at least 12 inliers and more than 8 + 0.3 × its matches (Brown and Lowe 2007), which separates a real overlap from chance agreement.
6. **Global alignment.** The cameras are modelled as one camera that only turns: a shared focal length and a rotation per frame. Every frame must be joined to the others, directly or through other frames; the layout is not assumed, so a single row, several rows and a full circle are all handled.
   - The focal length starts from the homographies (Szeliski and Shum 1997), from the photos' 35 mm-equivalent focal length when their metadata has one, and from five spread values; the solve that fits best is kept.
   - The rotations start along the strongest spanning tree of joined pairs, each from the rotation nearest to K⁻¹HK.
   - Bundle adjustment (Levenberg–Marquardt, Huber loss) then minimizes the distance, in pixels and both ways, between every matched point and where the other frame's camera puts it, over the focal length and every rotation but the reference frame's. Up to 300 matches per pair take part.
   - The world is then turned so the horizon is level and the centre is straight ahead: the cameras' x axes lie in the horizontal plane (Brown and Lowe's straightening). For the Perspective projection the centre is the mean viewing direction, pitch included.
7. **Exposure and vignetting.** For each joined pair, the two working copies are sampled where they see the same direction (about 3,000 samples per pair, skipping clipped and near-black ones; the clip level is the one HDR merge uses). The log ratios are fitted, by iteratively reweighted least squares, with one gain per frame and one lens falloff shared by all frames:

   log2 I_a − log2 I_b = (g_a − g_b) + c1 (ρ_a² − ρ_b²) + c2 (ρ_a⁴ − ρ_b⁴)

   where ρ is the distance from the frame centre as a fraction of the distance to the corner, and log2 V(ρ) = c1 ρ² + c2 ρ⁴ is the falloff. The gains average zero stops, so the panorama keeps the set's mean exposure. A falloff is kept only if it darkens toward the corners, by less than two stops, and is more than 0.02 stop; otherwise it is taken as none. The gains are then solved per channel, held near the luminance gains, so a white-balance difference between frames is removed too. A frame's exposure is held within 4 stops of the set's mean and each of its channels within 1 stop of its exposure; a solve that asks for more has gone wrong. Each frame's samples are divided by its gain and its falloff as they are resampled.

   **Clipped highlights.** A sample at or above its frame's clip level in any channel records neither the scene's level nor its colour, only that it was at least that bright. Dividing it by the frame's gain would put a sky blown in two differently exposed frames at two levels, and a blown white in a frame with a different white balance would be tinted. Such a sample therefore becomes one neutral ceiling, the same for every frame: the compensated clip level of the frame with the least headroom (the smallest clip ÷ gain over frames and channels). No compensated sample is brighter than the ceiling.
8. **Projection.** The canvas is the bounding box of the frames on the chosen surface, at the frames' own focal length in pixels per radian, so the centre keeps its resolution. With λ the longitude and φ the latitude of a direction:
   - **Spherical** (equirectangular): x = f λ, y = f φ.
   - **Cylindrical:** x = f λ, y = f tan φ, to at most 80° of latitude.
   - **Perspective** (rectilinear): x = f X/Z, y = f Y/Z. A set that reaches more than 70° from its centre is refused with the reason and the advice to choose another projection.

   A spherical or cylindrical set is turned about the vertical so that the widest stretch of longitude no frame sees lies at ±180°, where the canvas is cut; an uneven sweep of 280° is therefore cut in its gap, not through a photo. Only a set that leaves no gap in longitude is laid out as the whole circle. Its width is then a whole number of pixels at every pyramid level (the scale gives way by at most a part in a hundred), and the frame that straddles the ±180° cut is placed on both ends of the canvas. A frame that looks at a pole spans every longitude.
9. **Seams.** On the canvas reduced to about 0.4 MP. Each pixel first goes to the covering frame whose own edge is farthest. Then, for every pair of frames that overlap, the seam between them is moved to the path through their overlap along which their compensated luminances differ least (dynamic programming, one path position per row, or per column for frames one above the other). Which frame keeps which side is decided for each overlap from where the two frames lie relative to it, with columns measured the shorter way round a full circle, so the frame that straddles the cut keeps the right side at one end of the canvas and the left side at the other. On a full circle an overlap that crosses the cut is one piece. At full resolution a pixel takes the reduced canvas's choice where that frame really covers it, and otherwise the covering frame whose edge is farthest.
10. **Blending.** Multi-band (Burt and Adelson 1983), in linear light. Each frame is resampled onto its part of the canvas with a Catmull–Rom bicubic filter and built into a Laplacian pyramid of up to five levels above the base; its mask (the pixels the seams gave it) is built into a Gaussian pyramid. Each level of the result is the sum of the frames' bands weighted by their masks, divided by the sum of the masks, and the levels are collapsed. Fine detail therefore changes hands at the seam and broad differences over a wide band. Where a frame has no data its pyramid is filled from the level above, so nothing dark leaks in from its edge. On a full circle every reduction and expansion takes its columns round the circle, so the two ends of the picture are blended into each other like any other seam and its first and last columns continue each other. The pyramids are half floats; arithmetic is in single precision.
11. **Edges.**
    - **Auto Crop** keeps the largest axis-aligned rectangle in which every pixel is covered by a frame, found exactly at full resolution.
    - **Fill Edges** keeps the whole canvas. Each uncovered pixel takes the average of the nearest covered ones, from as coarse a pyramid level as it takes to find them (push–pull). The fill continues the picture's colour and brightness outward smoothly; it invents no detail. The merge sheet says so.

    The result is always a full rectangle of RGB samples; a DNG has no transparency.
12. **DNG.** `<first photo>-Pano.dng` beside the first source, `-2`, `-3`… if that name is taken, written by the same writer as an HDR merge (`LWLinearDNGWriter`): uncompressed DNG 1.4 LinearRaw, 3 × 32-bit float, linear sRGB D65, samples normalized so the brightest channel is 1.0 with BaselineExposure restoring the exposure. The XMP packet (`LWPanoramaProvenance`, namespace `https://lensworks.trefry.net/ns/panorama-merge/1.0/`) holds the projection, the edge setting, the solved focal length and, per source, its file name (never a path), catalog image, asset and variant IDs, SHA-256, rotation as a quaternion, relative exposure and profile name, with the first photo's Make, Model, Lens and DateTimeOriginal.
13. **Catalog and link.** The file is imported alone and becomes the selected photo. Its sources are recorded against it in the catalog index (`derived_sources`, now with the kind of merge: `hdr` or `panorama`), read back by `LensWorksCatalog.derivedLink(of:)`. The photo details show "Panorama of N photos" with the source names, and **Select Panorama Source Photos** (`catalog.panorama.selectSources`) makes them the selection. If the index has no link for a DNG, it is rebuilt from the file's XMP, as for an HDR merge, with sources that are gone or changed kept as missing. An index written before panoramas gains the kind column in place; its links stay HDR merges.
14. **Editing.** The toolbar command then creates a working version, so the panorama opens in the editor as a live RAW source with Camera Raw controls under editable layers.

## Reasons a merge is refused

Each is reported with the photos' file names.

| Reason | What it means |
| --- | --- |
| "…does not match any of the other photos" | The photo shares no recognizable detail with any other. |
| "…overlap too little to be joined" | Two photos show the same strip of the scene at their facing edges, or agree on a few points, but not enough to register them. The thin-strip check correlates the photos' local contrast over every strip up to a sixth of the frame; feature registration needs about that much. |
| "…has too little detail" | Fewer than 12 features: a blank wall, a clear sky, a black frame. |
| "…different pixel dimensions" | The model is one camera at one zoom. |
| "…can be joined in two different ways" | After the best homography, a second, different one explains at least 12 of the remaining matches and at least an eighth as many as the first: the scene repeats (a fence, bricks, windows), or near and far subjects moved against each other because the camera changed position. Either join could be wrong, so neither is used. |
| "…do not fit together as one panorama" | The pairs match, but not as views from one position (the residual after global alignment is over 4.5 working-copy pixels). When no alignment was found at all the message gives no figure. |
| "…too wide for the Perspective projection" | See Projection. |
| Memory, or a panorama over 357 MP | See Memory. |

## Limits

- Lens distortion is not estimated: the frames are taken as rectilinear, as developed.
- The camera is assumed to turn about one point. Parallax between near and far subjects is hidden by the seams and the blend where it can be, not corrected.
- Subjects that move between frames are not detected; the seam finder avoids them only in so far as they make the frames differ.
- The fill is a smooth extension, not content-aware.

## Content-aware fill of the border

The editor's content-aware fill cannot be used on a panorama's uncovered border today: it is bound to disk-backed planes and to the editor's 512 MiB working set, and a panorama is a floating-point result of up to 357 MP. Story sc-24668 (S13) owns making content-aware extend available to floating-point results, this one included. Until then **Fill Edges** extends colour and brightness smoothly and invents no detail, and **Auto Crop** is the way to a border with real content only.

## Handheld conditions

Measured by `PanoramaMergeTests.twoFramesFiveFramesAGridPortraitShuffledAndNoisyFramesStitch` and `handheldSetsStitchWithinTheToleranceOrAreRefusedWithTheReason`, on generated sets with known rotations:

| Set | Outcome | E (stops) | Worst rotation error |
| --- | --- | --- | --- |
| Five frames in a row, 25° apart | Stitched | 0.010 | 0.10° |
| The same with sensor noise of σ = 1 % of the signal, different in every frame | Stitched | 0.015 | 0.14° |
| The same five given in shuffled order (with and without noise) | Stitched | 0.009, 0.015 | 0.09°, 0.06° |
| Four portrait frames (240 × 320) | Stitched | 0.013 | 0.21° |
| Two rows of two frames | Stitched | 0.015 | 0.10° |
| Slight parallax: the camera turns about a point behind the lens, near posts shift about 1 pixel between frames | Stitched | 0.021 | 0.06° |
| A repeating pattern (every 8° of longitude) with 40 % of detail that does not repeat | Stitched, the one right way | 0.009 | 0.02° |
| A pattern that repeats exactly | Refused: "…can be joined in two different ways" | — | — |
| Strong parallax: a near wall over half of every frame shifting about 8 pixels against the scene | Refused: "…can be joined in two different ways" | — | — |
| A flat subject photographed from two positions (a homography joins them, no turn does) | Refused: "…do not fit together as one panorama (they disagree by N pixels)" | — | — |

Supported: a camera turned by hand about roughly one point, in any order, in landscape or portrait, with ordinary sensor noise, a little parallax (about a pixel of a working copy) and a scene that repeats only in part. Not supported, and refused with the reason rather than written wrong: a scene that repeats exactly across the overlap, a camera that moved enough for near and far subjects to line up differently, and photos taken from different positions. The tests assert each stitched set's E against the tolerance and its rotations within 0.5° of the truth, and each refused set's reason.

## Memory

The merge holds:

| What | Bytes |
| --- | --- |
| Each loaded frame (packed RGB half floats) | 6 per frame pixel |
| Each frame's working copy, features and matches | up to 48 MiB per frame |
| The canvas: the blend pyramid that becomes the result in place (8), its mask sums above the base (0.7) and the seam labels (1) | 10 per canvas pixel |
| One frame at a time warped onto its part of the canvas, with its coverage and mask (10) and their pyramids (3.3) | 14 per pixel of the largest such part |

Working memory is budgeted as frames × (6 × pixels + 48 MiB) + 10 × canvas pixels + 14 × largest warped part. The warp buffers are allocated once, for the largest part, and reused for every frame: allocated per frame, the previous frame's were still held by the allocator after they were freed, and the peak was up to 21 bytes per pixel of the part. The fill reuses the pyramid levels the collapse has released, and the DNG is streamed from the result, so neither adds to the peak.

The budget is the one HDR merge uses (`LWMergeBudget`): 3/8 of physical memory and never less than 6 GiB, the figure for the product-minimum 16 GB Mac. It is checked twice, and a refusal states the photo count, the dimensions, the memory needed and the budget:

- `LWPanoramaStitcher.admit`, as soon as the first photo's dimensions are known and before any frame is loaded, with the canvas the set is expected to need (each frame after the first adding 70 % of itself) and one frame as the largest warped part;
- `LWPanoramaStitcher.compose`, once the frames are aligned and the canvas is laid out, with the real canvas and the real largest part, before the canvas is allocated. A panorama of more than 357 MP is refused here too: its 32-bit float strip would pass the 4 GiB a TIFF offset can address.

Measured on generated sets (a release build of the stitcher; the peak is the process's peak memory footprint and includes the loaded frames; the figures exclude source development, which runs in the decode helper and the 512 MiB float working set). "Budgeted" is what `compose` checked.

| Set | Projection, edges | Canvas | Budgeted | Peak footprint | Align + compose |
| --- | --- | --- | --- | --- | --- |
| 4 × 24 MP (6000 × 4000) | Spherical, Auto Crop | 62 MP | 1.72 GB | 1.61 GB | 0.7 s + 4.3 s |
| 3 × 45 MP (8192 × 5464) | Spherical, Auto Crop | 90 MP | 2.45 GB | 2.37 GB | 0.8 s + 5.6 s |
| 3 × 45 MP | Perspective, Auto Crop | 304 MP | 6.04 GB | 5.91 GB | 0.6 s + 12.0 s |
| 6 × 45 MP | Spherical, Auto Crop | 167 MP | 4.19 GB | 4.00 GB | 1.4 s + 10.1 s |
| 6 × 45 MP | Spherical, Fill Edges | 167 MP | 4.19 GB | 4.00 GB | 1.4 s + 10.2 s |
| 8 × 45 MP | Cylindrical, Fill Edges | 225 MP | 5.43 GB | 5.18 GB | 2.1 s + 13.3 s |
| 2 × 102 MP (11648 × 8736) | Spherical, Auto Crop | 147 MP | 4.08 GB | 3.93 GB | 0.9 s + 8.9 s |
| 12 × 24 MP, a full circle | Spherical, Auto Crop | 140 MP | 4.06 GB | 3.65 GB | 2.2 s + 10.1 s |
| 16 × 24 MP, a full circle | Cylindrical, Auto Crop | 147 MP | 4.92 GB | 4.37 GB | 4.0 s + 16.6 s |

Every peak is under its budgeted figure, by 2 to 11 %, and every set fits the 16 GB Mac's 6 GiB (6.44 GB). The sets' frames are 34° apart in a 56° field of view, so each overlaps the next by about 40 %. The Perspective row shows what laying a wide set out flat costs: the same three frames need a 304 MP canvas instead of 90 MP.

On the 16 GB Mac's 6 GiB budget the early check admits:

| Frames | Largest frame |
| --- | --- |
| 2 | 147 MP |
| 3 | 112 MP |
| 4 | 90 MP |
| 6 | 64 MP |
| 8 | 49 MP |
| 12 | 33 MP |
| 16 | 25 MP |
| 24 | 15 MP |

So 8 frames of 45 MP, 12 of 30 MP and 16 of 24 MP are admitted. 24 frames of 24 MP need 9.1 GB, and 12 of 45 MP 8.3 GB: a Mac with 24 GB or more.

## Seam metric

The seam error E of a stitched picture, in stops, is the larger of two parts (`LWPanoramaSeamMetric`):

E = max(A, D)

- **A, agreement.** The mean, over the seam band, of the largest |log2(Y_out(p) + ε) − log2(Y_k(p) + ε)| over the frames k that see the pixel p. The seam band is every covered pixel within 8 pixels of a seam: a boundary between two frames' pixels.
- **D, step.** The mean, over neighbouring pixel pairs (p, q) that a seam separates, of max(0, |log2(Y_out(p) + ε) − log2(Y_out(q) + ε)| − the smaller of the same step in the two frames that meet there).

Y is Rec. 709 luminance of linear values. Y_k is frame k resampled at the pixel by the panorama's own alignment, with its solved exposure and falloff removed. ε = 1e-4.

A says the picture near a seam is what every frame there saw. Frames that are misregistered, or whose exposure differs, cannot all agree with one picture, however it is blended, so A catches a broken registration or exposure compensation. D says the picture does not step across the seam by more than the scene itself does, so it catches a join that was not blended. Neither needs ground truth: both are measured from the result and its sources.

The tolerance is declared in `PANORAMA_SEAM_TOLERANCE.json` at the repository root: **E < 0.04 stop**.

The fixture is the S47 generator's rotated-camera set (`scripts/generate_s47_procedural_photos.py --rotation-panorama`, seed 25322): one procedural scene on the sphere of directions, seen through a 320 × 240 pinhole camera of 300 px focal length that turns −27°, 0° and +28° with a little pitch and roll, so about half of each frame overlaps the next and every frame's rotation is known. The `plain` series is the scene as it is. The `exposure` series is exposed at −0.6, 0 and +0.5 EV with a 30 % falloff at the corners. Its manifest section records each frame's camera-to-world matrix, exposure and falloff.

Measured (`PanoramaMergeTests.generatedSetStitchesUnderEveryProjectionWithinTheSeamTolerance`, which prints each value):

| Series | Projection | E, Auto Crop | E, Fill Edges |
| --- | --- | --- | --- |
| plain | Spherical | 0.009 | 0.010 |
| plain | Cylindrical | 0.008 | 0.009 |
| plain | Perspective | 0.015 | 0.018 |
| exposure | Spherical | 0.015 | 0.016 |
| exposure | Cylindrical | 0.015 | 0.016 |
| exposure | Perspective | 0.019 | 0.021 |

The same test checks the alignment against the ground truth: the focal length within 2 %, each frame's rotation within 0.5°, and for the exposure series the frames' exposure differences and the falloff at the corner within 0.06 stop.

### Ground truth of the projections

The seam metric resamples the frames through the stitcher's own projection, so it cannot tell a wrong projection from a right one. `PanoramaMergeTests.everyProjectionShowsTheSceneWhereItsFormulaPutsIt` therefore compares the picture with the scene itself: for each covered pixel it computes the direction the projection's formula gives, with the formulas written out in the test (spherical (sin u cos v, sin v, cos u cos v), cylindrical (sin u, v, cos u), perspective (u, v, 1), with u, v = (pixel + crop offset + canvas origin) / scale), turns it by the reference frame's true rotation times the transpose of its solved rotation, and takes the mean |log2(picture / scene radiance)| over every channel. The bound is declared in `PANORAMA_SEAM_TOLERANCE.json` as `projection_error_max_stops`: **0.09 stop**. On the two-row set of four generated frames it measures 0.056 (Spherical), 0.057 (Cylindrical) and 0.060 (Perspective); the error that remains is the resampling of a scene with hard edges. Shifting the canvas by one pixel raises it to 0.12–0.14, and laying the Cylindrical canvas out with the spherical formula to 0.23. The full-circle, repeated-pattern and white-balance tests apply the same check.

That the metric fails when the stitcher is broken is checked by `theSeamMetricFailsWhenRegistrationCompensationOrBlendingIsBroken`, on the exposure series:

| What is broken | A | D | E |
| --- | --- | --- | --- |
| Nothing | 0.015 | 0.005 | 0.015 |
| Registration: one frame turned 0.25° (1.3 pixels) | 0.071 | 0.019 | 0.071 |
| Registration: one frame turned 0.5° | 0.120 | 0.025 | 0.120 |
| Compensation: one frame's gain 20 % off | 0.108 | 0.015 | 0.108 |
| Compensation: none | 0.347 | 0.021 | 0.347 |
| Compensation and blending: none, frames cut at the seam | 0.419 | 0.275 | 0.419 |

Without compensation the frames differ by half a stop. Cut at the seam, the picture steps by that much (D = 0.28); blended, the step is gone (D = 0.021) though the frames still disagree with the picture (A). A cut of compensated, registered frames has no seam to see, and measures 0.015.
