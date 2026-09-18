# COND-07 condenser — reference art and derived layers

Supporting assets for [labelle-bgfx#100](https://github.com/labelle-toolkit/labelle-bgfx/issues/100)
and phase 2 of `RFC-PIXEL-WATER-PLAN.md` ("Prepare the real condenser assets").

**Everything in `layers/` is derived from a scene-composited GIF.** No layered source
file exists. Read "What is solid and what is not" before treating any of it as ground truth.

## Contents

| File | What it is |
|------|------------|
| `condenser-detail.gif` | 620x330, 72 frames. The approved reference, preserved unmodified. |
| `condenser-room.gif` | 1792x1008, 72 frames. The full room the detail is cropped from. |
| `layers/*.png` | Derived layers, native art resolution, RGBA. |

`condenser-detail.gif` is a **1:1 pixel crop** of `condenser-room.gif` at offset (100, 390).
Verified by template match: mean abs error 0.38/255 per channel over the whole 620x330 region.
It is not a zoom — both GIFs are at the same pixel scale.

## The native grid: measured, not assumed

Issue #100's preview uses 6x6 screen-pixel effect cells. That number turns out to be
**right for the animated overlay and wrong as a description of the art**.

### Method

Four independent measurements on frame 0 of both GIFs:

1. **Run lengths.** In a nearest-neighbour enlargement of a k-px canvas, every horizontal
   and vertical run of identical pixels is a multiple of k. Here run length **1** dominates
   (45,729 of ~89,000 horizontal runs). So the image is *not* an integer enlargement of
   anything: there is per-pixel grain on top.
2. **Within-cell variance sweep.** For every k in 2..12 and every phase, the mean variance
   inside a kxk block. A true grid shows a sharp minimum at its own k. There is none —
   variance rises monotonically with k, and best-phase/worst-phase spread stays in
   1.1..1.9 for every k.
3. **Edge spacing.** Column- and row-summed absolute gradient, peaks above mean+1.2σ.
   The spacings are overwhelmingly **6** (and 5 or 7), with larger gaps at near-multiples
   of 6 (13, 19, 26, 32, 51, 77). So a ~6 px block *brush* is real.
4. **Phase stability.** Splitting the room GIF into eight vertical and six horizontal bands
   and fitting the best k=6 phase per band gives phases 3,0,1,3,3,1,1,1 (X) and 4,0,0,2,0,3 (Y),
   with a contrast (best phase / mean phase) of only 1.08..1.76.
   **Control:** a genuine 6x nearest upscale of the same image scores contrast **6.00**,
   with all five non-boundary phases at exactly **0.00**.

### Conclusion

> There is no true native pixel grid in this artwork. It is a 1792x1008 raster painted
> in a pixel-art *style*, with a characteristic ~6 px block size, no globally phase-locked
> grid, and full-resolution grain on top. "6x6" is a property of the effect overlay
> that was animated on top of it, not of the art.

The **animated layer does** sit on a clean grid. All five drop columns are exactly 6 px
wide and all five start at the same phase: detail x = 152, 194, 284, 332, 416
(all ≡ 2 mod 6), which is **x ≡ 0 mod 6 in room coordinates**. Drop trails also terminate
on exact 6 px boundaries (e.g. y = 204).

### Working native canvas adopted here

Anchored to the overlay's grid, phase 0 in room coordinates:

* cell size **6x6 screen px**
* origin: room px (102, 390) = detail px (2, 0)
* canvas **103 x 55 native px** (detail px x ∈ [2, 620), y ∈ [0, 330))

Per-cell **median** downsample. Cost of resampling an unaligned image:
re-enlarging the 103x55 plate 6x and diffing against the reference frame gives
**8.50/255 mean absolute error per channel (~3.3%)**. Visually indistinguishable at 6x
(see the side-by-side), but it is a resample, not a lossless extraction.

## Reservoir: logical bounds and anchor

All coordinates in native px on the 103x55 canvas, +X right, +Y down.

| Quantity | Native | Detail-GIF px |
|---|---|---|
| Glass window interior | x 4..97, y 3..54 | x 26..584, y 18..324 |
| **Reservoir rect (max fill)** | **x 4, y 48, w 93, h 6** | x 26..584, y 288..324 |
| Reservoir anchor (local origin) | (4, 48) | (26, 288) |
| Water surface at level = 1.0 | local y 0 | y 288 |
| Basin floor at level = 0.0 | local y 6 | y 324 |

`surface_y = 6 * (1 - level)`.

**How the surface was located.** Per-column search for the strongest negative luminance
step in y ∈ [265, 305]: the answer is **y = 288** for every column from x = 60 to x = 528
(the bright highlight band is y 282..287, the dark body starts at 288). 288 / 6 = 48 exactly,
a clean cell boundary. The bottom rim brightens sharply at y = 327; 324 (cell 54) is the
nearest boundary inside the water.

**The reservoir is only 6 native rows tall.** That is a real consequence of taking the art's
own block size as the native resolution: water level has 6 quantisation steps at native scale.
If that is too coarse for the effect, halve the cell to 3 px (canvas 206x110, reservoir
93x12 at x 8, y 96) — that is a working-resolution choice, not a measurement, since the art
has no grid to violate.

## Drop emitters

Recovered from per-pixel temporal standard deviation across all 72 frames (the drop
columns are the only vertical structures that move). Five emitters, each exactly one
native px wide:

| Emitter | Native x (canvas) | Reservoir-local x | Notes |
|---|---|---|---|
| A | 25 | 21 | **behind the cooler foreground** — ripple would be occluded |
| B | 32 | 28 | clear |
| C | 47 | 43 | clear |
| D | 55 | 51 | clear |
| E | 69 | 65 | clear |

Emitters release at native y ≈ 2..5 (detail y 12..33). Drop fall is **accelerating**, not
grid-stepped: successive y positions in one column run 33, 36, 46, 59, 61, 89, 102, 122,
149, 173. The trail is 1 native px wide and about 5 tall with a brightness ramp toward
the head — that ramp is what `drop.png` reproduces.

**No drop in the reference ever reaches the water.** Residual magnitude in y ∈ [282, 300]
peaks at 2.5/765 — indistinguishable from zero. Trails fade out around y = 204 into the mist.
There are **no splash or impact frames to extract**; splash art must be authored.

## Layers

All RGBA, nearest-neighbour intended, no premultiplication applied.
Draw order: `machine_interior` → water → `mist` → drops → `cooler_foreground` → `frame_foreground`.

| File | Size | Status |
|---|---|---|
| `machine_interior.png` | 103x55 | **Extracted**, with the mist un-mixed out (see below) |
| `reservoir_mask.png` | 103x55 | **Partly reconstructed** — see below |
| `reservoir_static.png` | 103x55 | **Extracted** for x ≥ 30; **reconstructed** for x 19..29 |
| `reflection.png` | 93x6 | **Authored/reconstructed** — not extractable |
| `mist.png` | 103x55 | **Reconstructed** separation of an extracted signal |
| `drop.png` | 1x5 | **Extracted** (colour ramp measured from the reference trail) |
| `cooler_foreground.png` | 103x55 | **Extracted** pixels, **reconstructed** silhouette |
| `frame_foreground.png` | 103x55 | **Extracted** pixels, **reconstructed** silhouette |

### What is solid and what is not

**Solid (measured from the pixels):**

* The 6 px block size of the animated overlay and its phase, and the 103x55 canvas derived from it.
* The reservoir's top edge at native y 48 and its left/right extent — a hard, column-consistent
  luminance step.
* The five drop emitter X positions and the drop's colour ramp.
* That drops never reach the water in this reference.
* The whole static plate (rows y ≥ 48 have **exactly zero** temporal variance across all
  72 frames, so the reservoir is a clean single-frame extraction wherever it is visible).
* The palette.

**Reconstructed (invented, marked as such):**

* **Reservoir mask under the cooler.** The surface highlight is interrupted for
  detail x ∈ [118, 178) = native x ∈ [19, 30) by the cooler body and the khaki crate
  in front of it. `reservoir_mask.png` is a plain rectangle across that gap — the assumption
  is that the basin is continuous behind the occluders. Nothing in the image confirms it.
* **`reservoir_static.png` for native x 19..29** is the neighbouring clean water columns
  mirrored back across the gap. It is plausible filler, not data.
* **Maximum fill == observed fill.** Only one water level appears in the reference. The mask
  is the *observed* surface treated as max. If the basin actually extends higher, that is
  not visible and not recoverable.
* **`reflection.png`** is authored: the coil band above the water, vertically flipped and
  pulled 20% toward the deep-water colour. The reference has no discernible reflection to
  extract, so this is a starting point to tune, not a measurement.
* **Mist/interior separation.** Mist alpha is modelled as
  `clamp(0.55*lift + 0.45*lift*activity, 0, 0.85)` over native rows 28..48, where `lift` is
  normalised brightness above the band's 8th percentile and `activity` is normalised temporal
  standard deviation. `machine_interior.png` is then the plate with that haze algebraically
  un-mixed out, so `interior ⊕ mist` reproduces the plate. The *envelope* is measured; the
  *split between haze and what is behind it* is a model. A different plausible split exists.
* **Occluder silhouettes.** `cooler_foreground` and `frame_foreground` are cut on axis-aligned
  rectangles (cooler: native x 17..31, y 32..55). The real silhouettes have soft, irregular
  edges that cannot be separated from the background they sit on.
* **Whether the bottom band is water at all.** It reads as water — dark teal body, bright
  specular speckles, a hard bright surface line, mist plume resting on it — and #100 calls it
  a reservoir. It has not been confirmed with whoever made the art, and it could equally be a
  dark floor panel.

## Palette

Top 12 colours of the native plate (median-cut, by coverage):

`#1F3239` 10.6% · `#101516` 10.5% · `#273B43` 10.5% · `#39525B` 9.4% · `#466471` 9.3% ·
`#152022` 8.9% · `#587C8F` 8.5% · `#182529` 7.7% · `#31474E` 7.2% · `#1A2A31` 7.1% ·
`#83ACC1` 6.4% · `#151A19` 4.1%

Water-specific, sampled from the reservoir band at native x 35..95:

| Role | Hex | How |
|---|---|---|
| `deep_color` | `#0F1719` | 10th percentile of the water body |
| water body | `#182A32` | median of the water body |
| `surface_color` | `#7AA5BB` | median of the surface highlight row (native y 47) |
| `highlight_color` | `#425F6C` | 97th percentile of the water body |
| mist / drop highlight | `#ADCAC6` | measured drop-head colour (173, 202, 198) |

sRGB authoring values.

## Verification

Two separate checks, deliberately not conflated:

* **Fidelity** — the 103x55 plate re-enlarged 6x against reference frame 0:
  **8.50/255 mean absolute error per channel**. This is the meaningful number, and it is
  entirely resampling loss from the unaligned grid.
* **Consistency** — the layers recomposited against the plate they came from:
  **0.94/765 mean, max 42**, i.e. the partition and the mist un-mix round-trip. This
  check is near-tautological by construction (the layers partition the plate) and proves
  only that nothing was dropped or double-counted, *not* that the separation is correct.

## Editable sources

There are none, and that is the main caveat on this whole directory. Every layer above is a
derivation from one composited raster. Re-deriving means re-running the measurement, not
opening a file.
