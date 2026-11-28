# Asset 07 — Eye surface geometry audit and isolated material trial

2026-11-28. Source Asset06 GLB SHA256 743c79ae479c5fdac48ad9069418b633f635cbfa89435aef9347375ed7cefbf6. Output GLB SHA256 7828cf76dc83e0b3a946977b8d4ed6b7c1f18505771bbd88af69d382f698ae6b, 93819872 bytes.

Measured existing Eye_surface_candidate primitive: 51 triangles, 50 unique indexed vertices, 43 shared by General/Skin primitives, one index-connected component. Native-coordinate bounds x=-0.02836041..-0.01335529, y=0.78491205..0.79199213, z=0.05860529..0.06241617. Three-view depth-tested ID raster at azimuths 0/25/335 shows 509/402/492 visible pixels, all within the image-left eye's lower region, not a complete eye. Other eye not separated. No independent eyeball topology established. Existing face/eye textures visibly differ from original reference. No claim about hidden anatomy.

204 barycentric point samples of MR map: roughness median 0.5333333, 10th/90th quantiles 0.5215686/0.5439216; metallic median 0, max 0.0078431. The previous assumption that this region is heavily metallic is unsupported.

Experimental GLB changes only material index 7: retains baseColorTexture, sets metallicFactor=0, roughnessFactor=0.24, removes shared MR and normal maps. All other materials and JSON fields unchanged; entire GLB BIN byte-identical. The value 0.24 is an unvalidated test choice, not an inferred physical property. Incomplete masks can create optical seams; not recommended for production. CPU overlay is not an actual PBR before/after. No geometry, UV or texture edits, no new eye anatomy. Private files remain local. Asset07 unsigned, not a release.

Next: complete exposed left-eye mask with verified topology and review other eye/hair occlusion from additional angles. Establish safe geometry repair before adding eyeballs/corneas. Perform matched actual PBR comparison. V8.0 remains official; preserve original certificate and assets.
