# V7.9 semantic correction candidate 01

Local candidate only; source asset and release manifest remain unchanged.

## Method
A front orthographic depth-tested triangle ID raster was generated at 760 x 760, scale 3300 pixels per GLB coordinate unit, center Y=0.78. Two manually traced interior polygons identify the visible pink front hair locks. Only existing Skin_candidate triangles with at least one visible pixel and at least 90% of their visible pixels inside the polygons are reassigned to Hair_candidate. No color classifier and no propagation to hidden surfaces.

## Verified output
- Source SHA256: 97c80d3a7f5b8e6412687ab30574fa4efdb5cd4db0a3115356de426ae411e379
- Candidate SHA256: 3de6ab627ac3fb85b046f863e4372104d0c8979662ac3f5e766dd87df3f0f9d6
- Triangle count: 1,960,652 unchanged.
- Skin_candidate: 95,246 -> 93,372.
- Hair_candidate: 68,411 -> 70,285.
- 1,874 triangles reassigned; 6,644 visible pixels changed in ID pass.
- Binary bytes outside the two contiguous index partitions are identical, including all position, normal, UV and texture data.
- Exact oriented triangle multiset for the affected partitions verified unchanged by lexicographic comparison.
- No source file overwritten. No private texture, geometry or preview uploaded to GitHub.

## Review
The local before/after ID preview shows reassignment in the two intended visible hair locks. Residual pink-tip skin labels and blue hair assigned to General remain. This is a conservative partial correction, not complete semantic segmentation. No PBR render or device validation has been performed with the candidate. Existing app requires trusted asset hashes; do not replace the installed asset or publish a new hash before validation.

Next: annotate rear and side views, handle hidden surfaces using mesh adjacency and geometric constraints, audit goggles and eye boundaries, then perform controlled original/candidate PBR renders. V7.8 remains compiled but not permanently signed; V7.6 stays official.
