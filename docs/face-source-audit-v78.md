# Source asset face diagnostic — V7.8 / next asset revision

Date: 2026-11-28. Local CPU orthographic triangle rasterization of native_full.glb from the existing asset backup, with perspective-independent UV interpolation, depth test and bilinear sampling. Rendered front/side/back views and face close-up channels: base color alone (no lighting), interpolated geometry normals with simple directional diffuse, normal texture RGB, metallic-roughness texture G, candidate material IDs. Reference crop is not camera-matched. Private images and geometry remain local.

## Observed results
- Base-color-only output retains conspicuous white/cyan/pink highlights on the goggles, painted mechanical spheres, and directional shading on the face. These are baked or authored appearance signals rather than reflections computed by the diagnostic renderer. Whether each signal is baked lighting or intended color requires review; do not remove globally.
- Gray diffuse geometry pass shows broad eye-region surfaces, simplified eyelid/iris shape, and simplified hair strand ridges compared with the reference. It does not establish the exact topology of hidden surfaces. The previous eye test is not an anatomical reconstruction.
- Candidate ID pass shows pink front hair tips assigned to Skin_candidate, significant blue hair portions assigned to General, and discontinuous segmentation in the vicinity of hair, eyes and clothing. This is a direct visual counterexample to the assumption that candidate materials represent correct anatomical boundaries.
- Raw normal and roughness channels show large-scale shape patterns. These are not independent measured material properties or evidence of correct microstructure. Inspect at original pixels before deciding whether to reconstruct.

## Prioritize
P0: establish true source comparison (V7.8 compiled; not signed/published at the time of this audit). Keep raw original reference and source files.
P1: create verified semantic face/eye/hair/fabric/shell mask on a separate candidate asset; inspect pink tips and blue hair, general region, eye boundaries in multiple views. Do not classify solely on color. Preserve original mesh/UV data during segmentation.
P2: distinguish color from baked illumination/reflections region by region; start with a reversible goggles candidate, comparing against raw color with no light and PBR at same camera. Do not globally erase highlights or invent recovered albedo.
P3: repair eye geometry and dedicated material/texture after semantic approval. Compare true source and candidate at the same pose, lens, lighting, output dimensions and crop.
P4: only then calibrate material optics, hair reflection and close-up detail.

## Release
V7.8 build run 46124493405 passed. Build archive SHA-256 c910958349bdc978da711ced035efc964fa6b97959bd54efa8664762baedc23d verified locally. Existing offline signing program and expected certificate are available, but its STARLING_PASSWORD environment variable was missing at execution; no signature was produced. No new signing key or public asset upload. Maintain current official update manifest until a valid signed V7.8 is produced. This report records diagnostic observations, not a visual acceptance or asset modification.
