# V7.8–V7.9: texel-density audit

Source: local native_full.glb from the existing asset backup. No private texture or geometry bytes are included.

Method: triangle UV area divided by 3D triangle surface area; linear density = 4096 * sqrt(UV area / surface area). Percentiles weighted by 3D triangle area; zero-area UV triangles excluded from percentile calculations. GLB coordinates are not calibrated physical units. UV area sum is not unique atlas occupancy.

| Region | Triangles | UV area sum % | Surface area (native units squared) | P10 | P50 | P90 | UV degenerate triangles (area <= 1e-16) |
|---|---:|---:|---:|---:|---:|---:|---:|
| General | 1075281 | 28.104 | 0.885219 | 1704.5 | 2270.3 | 2829.6 | 27846 |
| Skin_candidate | 95246 | 3.390 | 0.112950 | 1667.1 | 2228.9 | 2650.0 | 671 |
| Hair_candidate | 68411 | 1.548 | 0.041203 | 1733.7 | 2471.7 | 3123.0 | 1837 |
| Blue_fabric_candidate | 316564 | 8.603 | 0.270796 | 1784.4 | 2247.7 | 2788.3 | 5795 |
| Painted_shell_candidate | 405150 | 15.310 | 0.475544 | 1930.4 | 2302.9 | 2691.1 | 7301 |

Five used primitives share POSITION/NORMAL/TEXCOORD_0 accessors with 1,026,647 vertices. All use baseColorTexture index 0; the sixth Metal_candidate material has no used primitive. No zero-area 3D triangles were detected at the threshold above. UV degeneracy warrants inspection, but triangle counts alone do not establish visual damage.

## Decision
The smaller skin and hair atlas fractions primarily reflect their smaller surface areas. Regional median density is comparable with the other materials. Do not claim globally low relative texel density from atlas fractions alone; a dedicated face atlas could improve close-up allocation only if additional faithful source detail is available. Do not enlarge an existing texture and call the new pixels recovered detail.

Next: map UV degeneracy and low-density outliers to actual image-space face/hair/mechanical crops, compare original albedo/normal/MR channels and controlled source-versus-refined GPU renders. Establish actual eye and hair topology before changing assets. No new textures or geometry have been produced by this audit.

V7.8 native CI run 46124493405 succeeded. The permanent signing stage and device visual acceptance are pending; current update manifest is still V7.6 (78).
