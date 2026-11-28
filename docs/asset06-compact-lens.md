# Asset 06 — compact mirror-lens atlas

Derived locally from Candidate 04 (Asset 05 model) SHA-256 e287533d912d8f46bd0af4df795f71e73d19ddea3ea632cf644a582859f4e5e2. Output GLB SHA-256 743c79ae479c5fdac48ad9069418b633f635cbfa89435aef9347375ed7cefbf6.

## Measured
- GLB 110485464 -> 93819948 bytes.
- Lens-only PNG 17438135 -> 772618 bytes.
- Full 4096 x 4096 image dimensions, 2030 lens triangles, original UVs and all 93042200 binary prefix bytes unchanged.
- Conservative UV triangle raster plus 128 px guard, then aligned 128 x 128 tiles. 688128 texels (4.1015625%) retained exactly. Other tiles filled with rounded sRGB representation of their original linear-light mean.
- CPU linear-light box-filter mip chain, sampled raster footprint dilated by one texel: maximum RGB channel errors LOD 0–7 all zero; LOD 8 0.00192681; LOD 9 0.00121242; LOD 10 0.00043756; LOD 11 0.00016084; LOD 12 0.00007311.
- PNG roundtrip decoding verified exactly equal to newly constructed atlas.

## Limits
This is storage optimization, not a reduced GPU allocation or proven rendering improvement. CPU footprint and mip algorithm do not guarantee equality under real GPU mip generation, anisotropy, or other sampling paths. Distant/coarse mip levels have small differences. Candidate 04 and original assets unchanged. No private texture or model upload. V8.0 release unchanged.
Asset 06 is an unsigned local GLB candidate; no signed package has been produced in this turn. Historical signing information lookup did not return the unlock password, and STARLING_PASSWORD was absent in the current runtime. No new signing key generated. Next: sign with original permanent certificate when available, test on-device import/visual A/B before acceptance.
