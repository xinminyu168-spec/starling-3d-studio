# V7.7 asset and rendering fidelity audit — 2026-11-28

## Scope
Read-only audit of the existing private asset backup and native-v3/bootstrap.sh at commit 15030ee73ff07bebc09c123dda41378d70a37f18. No character assets are included in this document. Native CI run 46123782304 passed; visual acceptance and permanent signing/publication of V7.7 are not established.

## Measured asset facts
- Reference PNG: 1153 x 1536.
- Source archive includes a Tripo-converted FBX and five 4096 x 4096 JPEG maps (base color, normal, roughness, metallic, combined RM).
- full.glb: 1,960,652 triangles, one mesh, one material, three 4K images.
- mobile.glb: 307,425 triangles, one mesh, three 2K images.
- native_full.glb: 1,960,652 triangles, one mesh, six material definitions, five used primitives, three shared 4K images (base JPEG, MR PNG, normal JPEG). POSITION, NORMAL and TEXCOORD_0; no explicit TANGENT accessor. This does not rule out runtime tangent generation or disconnected geometry.
- UV triangle area sum relative to atlas (not unique pixel occupancy, may include overlap): General 28.10%, shell 15.31%, fabric 8.60%, skin 3.39%, hair 1.55%. Candidate partition is not anatomical ground truth.
- The base color preview visibly contains varying illumination-like gradients; baked illumination separation has not been validated.

## Implementation findings
1. bindAtlas() rejects dimensions above 4096 and binds shared atlas textures to all compatible material instances.
2. refineMaterialMap() modifies roughness channel in memory based on color heuristics; refineRegions() also sets normal scale and roughness factors. restoreSafeMaterials() swaps custom instances off but does not undo all these baseline changes. A/B original should be a genuinely unmodified source baseline.
3. setEnvironment(a,r) changes only indirect light intensity using a; r (reflectPower) is unused. Do not claim independent specular environment control until implemented and tested.
4. applyTransform() scales the asset root to zoom. Light-space distances can change, particularly for positional spots. Separate camera dolly/lens from model scale.
5. Current environment uses a generic Lightroom HDR with 256 cubemap generation and ACES grading. Reference HDRI, lighting, lens, and tone mapping are unknown. Treat reference matching as an inverse-rendering calibration task.
6. Dynamic resolution is disabled. Existing AA, offscreen exports and GPU readback provide a useful starting point. Do not infer visual quality from compile success or image size.
7. Skin and hair experimental enhancements are bounded approximations; they cannot recover eye anatomy, strand geometry, stitching, hard-surface bevels, UV information or physical SSS.

## Next work — recommended order
P0: Reference-aligned calibration. Establish same framing and output size; retain fixed model transform; compare true source PBR, current refined PBR and color-only diagnostic. Save deterministic settings and crop coordinates. Inspect actual rendered image before declaring improvement.
P1: Audit texture data roles and per-part texel density, normal maps, tangent basis, baked illumination and geometric silhouette. Build local candidate asset variants only; keep original bytes and current update channel.
P2: Separate eye/skin/hair/fabric/mechanical components with validated masks and dedicated local UV/maps where needed. Extend loader to per-material textures before introducing larger or multiple atlases. Do not call interpolation or AI-created details recovered source truth.
P3: Match studio light direction, softness, reflections, contact shadow, camera and tone mapping. Preserve real-time performance and full-quality static output separately.
P4: Use controlled close-up A/B comparison at 1:1 pixels, including face/eye, hair, jacket seam and mechanical shell. Capture raw source baseline, current and candidate images. A successful build is not a visual pass.

## Gate
No V7.8 asset change is approved by this audit. No real-device reference-matched pair was available for this audit; findings establish credible constraints, not the measured percentage contribution of each cause. Keep private reference and geometry out of GitHub and preserve package and signing channel.
