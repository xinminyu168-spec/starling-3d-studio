# Shatter-Reassemble Intro Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On app launch, play a 4–6 s real-time intro in Starling where drifting shards assemble a road, a platform and the character itself, then hand off seamlessly (under a bloom peak) to the normal character view.

**Architecture:** Offline, a Blender script splits the character GLB into ~300 face-owned shards (no new geometry, UV/material preserved, node origin = shard centroid) and the signing tool packs it as a new `shards1` asset bound to a character and a source model hash. In the app, a pure-Kotlin logic library (`intro-logic`, unit-tested on plain JVM) owns the timeline, per-shard easing, void drift, stage Voronoi layout, manifest rules and the play/skip decision; a thin Android layer (`ShatterIntro.kt`) loads the shard GLB as a second gltfio asset, drives `TransformManager` from the existing `Choreographer` ticker, draws the stage and glow ring, toggles Filament bloom/fog, and swaps to the real model at the flash peak. The road/platform is generated at runtime from a Kotlin port of `shattered_realm.py`'s 2D Voronoi slabs (instead of the spec's Blender-generated stage asset) so no extra binary is bundled and CI needs no Blender.

**Tech Stack:** Blender 5.0.1 `bpy` (Python 3.11 venv) + pytest; Kotlin 2.0.21, Filament/gltfio 1.56.0, matc from the pinned Filament 1.56.0 release; JUnit 4.13.2; Android Gradle Plugin 8.7.3.

**Spec:** `docs/superpowers/specs/2026-11-28-shatter-reassemble-intro-design.md`

## Global Constraints

- Package `com.xs.character.viewer`; generated project via `native-v3/bootstrap.sh` (heredocs); `versionCode` bumps from 82 to 83 for this feature.
- Filament 1.56: one directional light only; do not add a second directional light.
- Never modify the character's original PBR materials or the bytes of `full.glb`, `mobile.glb`, `native_full.glb`.
- Private character assets, shard GLBs, signing keys and passwords never enter git, logs or Actions output. Tests use a generated public fixture only.
- Signing uses the existing permanent certificate, SHA-256 `065d80ddf51e5a7cbc881900351ee355cdd8aa2447fee0a959d0391ecc02c7ba`.
- Timeline (seconds): void 0–1, stage gather 1–3, character gather 3–4.5, flash peak ≈150 ms, settle ends at 5.0; void may extend while the model loads, at most +3 s.
- Shards are cut from `mobile.glb` (source SHA-256 `d55824a6514a6ab52f0e3d9d0cc0ed9ba3d346207d64e60595326db912fd66f4`); target 200–400 shards.
- `shards1` assets are never selectable as a display model and never appear in candidate lists.
- CI compile is not acceptance; device acceptance (Task 9 checklist) is required before calling it done.

## Review Focus

1. App backgrounded or rotated mid-intro → on resume the intro is gone and the normal view shows, never a half-assembled freeze (Task 4 `abortGoesDone`, Task 8 onPause hook).
2. Display model fails to load during the intro → intro ends at a hard cap (12 s) without swapping; the existing error status shows (Task 4 `holdTimesOut`).
3. Shard asset cut from a different model or another character → intro is skipped, never shows wrong pieces (Task 5 `rejectsUnknownSource`, Task 6 `skipsWhenShardSourceUnknown`).
4. System "remove animations" on (animator duration scale 0) → intro skipped (Task 6 `skipsWhenAnimationsOff`).
5. Low-RAM device on cold start → intro skipped; on warm start it plays (Task 6 `lowRamColdSkips` / `lowRamWarmPlays`).

---

### Task 1: Character fracture script (Blender)

**Files:**
- Create: `blender/shatter-intro/fracture_character.py`
- Create: `blender/shatter-intro/tests/conftest.py`, `blender/shatter-intro/tests/test_fracture.py`
- Create: `blender/shatter-intro/README.md` (usage, one paragraph)

**Interfaces:**
- Produces (Python, importable without side effects; CLI only under `if __name__ == "__main__"`):
  - `sample_seeds(centroids: list[Vector], areas: list[float], count: int, seed: int) -> list[Vector]` — area-weighted pick of triangle centroids.
  - `assign_cells(centroids: list[Vector], seeds: list[Vector]) -> list[int]` — nearest seed per face (use `mathutils.kdtree.KDTree`).
  - `fracture_object(obj: bpy.types.Object, count: int, seed: int) -> list[bpy.types.Object]` — one new object per non-empty cell, faces copied with all UV layers and material slots; mesh translated so origin = shard vertex centroid, object location = that centroid; custom props `shard_order` (centroid height normalized 0..1 over the source bbox) and `shard_index`.
  - CLI: `blender -b --python fracture_character.py -- IN.glb OUT.glb [--shards 300] [--seed 7]` → GLB with `export_extras=True`, single binary, embedded images, original material names.
- Fixture (`conftest.py`): session fixture `fixture_glb(tmp_path_factory) -> Path` building a humanoid-ish test model (UV sphere head + cube torso/limbs, ≥ 5 000 tris) with exactly the 8 semantic material names from `scripts/build-signed-asset.py` `MATERIALS`, exported to GLB.

- [ ] **Step 1: Set up the test runner.** `uv pip install --python <bvenv>/bin/python pytest` (venv with `bpy==5.0.1`, Python 3.11). Record the command in the README.
- [ ] **Step 2: Write failing tests** in `test_fracture.py`:
  - `test_union_preserves_faces`: sum of shard face counts == source face count; sorted multiset of world-space vertex positions (rounded 1e-5) equal to source.
  - `test_uv_and_materials_preserved`: every shard has the source's UV layer names; union of shard material names == source's 8 names.
  - `test_order_range_and_bottom_first`: all `shard_order` in [0, 1]; the shard with min centroid z has order 0.0 ± 1e-6.
  - `test_deterministic`: same seed → identical shard face counts list; different seed → different.
  - `test_count_bounds`: `--shards 300` yields between 200 and 300 non-empty shards on the fixture.
  - `test_cli_roundtrip`: run CLI to GLB, re-import; node count == shard count; each node has `shard_order` custom prop.
- [ ] **Step 3: Run** `<bvenv>/bin/python -m pytest blender/shatter-intro/tests -q` → FAIL (module missing).
- [ ] **Step 4: Implement** `fracture_character.py` per Interfaces. Use bmesh face copying per cell (no booleans): faces stay the original triangles, so reassembly is exact.
- [ ] **Step 5: Run tests** → PASS.
- [ ] **Step 6: Commit** `feat(intro): face-owned Voronoi character fracture script`.

### Task 2: `shards1` signing support

**Files:**
- Modify: `scripts/build-signed-asset.py`
- Create: `scripts/tests/test_build_signed_asset.py`

**Interfaces:**
- Produces:
  - `make_payload(profile: str, model_size: int, model_sha: str, asset_id: int, character_id: str | None, source_sha: str) -> bytes` — canonical JSON (`sort_keys`, compact). For `semantic8` byte-identical to today's payload (`sourceSha256` = existing `SOURCE`, no `characterId`, `minAppVersion` 82). For `shards1`: keys `schema 1, package, profile "shards1", minAppVersion 83, id, size, sha256, characterId, sourceSha256`.
  - `check_shards_model(p: Path) -> int` — GLB header checks as `check_model`; material names ⊆ `MATERIALS`; node count 50..1000; no external buffers/images.
  - CLI flags: `--profile {semantic8,shards1}` (default `semantic8`), `--character-id` (required for shards1, `[a-z0-9-]{1,32}`), `--source-sha256` (required for shards1, 64 hex).

- [ ] **Step 1: Write failing tests:** `test_semantic8_payload_unchanged` (compare to a literal expected JSON for fixed inputs), `test_shards1_payload_fields`, `test_shards1_requires_character_and_source` (argparse error), `test_check_shards_rejects_external_buffer`, `test_check_shards_node_bounds` (49 nodes rejected, 50 accepted; build GLBs in-test with `struct` + JSON).
- [ ] **Step 2: Run** `python3 -m pytest scripts/tests -q` → FAIL.
- [ ] **Step 3: Implement**, keeping the signing/openssl path untouched and still unexercised by tests.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(assets): shards1 signed asset profile`.

### Task 3: `intro-logic` JVM library scaffold + stage layout

**Files:**
- Create: `native-v3/intro-logic/settings.gradle`, `native-v3/intro-logic/build.gradle` (plugin `org.jetbrains.kotlin.jvm` 2.0.21, `testImplementation 'junit:junit:4.13.2'`, JVM 17)
- Create: `native-v3/intro-logic/src/main/kotlin/com/starling/intro/StageLayout.kt`
- Create: `native-v3/intro-logic/src/test/kotlin/com/starling/intro/StageLayoutTest.kt`
- Modify: `native-v3/bootstrap.sh` (app `build.gradle` heredoc: `android { sourceSets { main { java.srcDirs += '../intro-logic/src/main/kotlin' } } }`)

**Interfaces:**
- Produces:
  - `data class Vec2(val x: Float, val y: Float)`
  - `data class Slab(val polygon: List<Vec2>, val cx: Float, val cy: Float, val cz: Float, val thickness: Float, val tiltX: Float, val tiltZ: Float, val order: Float)` — polygon local to (cx, cz) on the ground plane, y up, meters.
  - `object StageLayout { fun build(seed: Int, platformRadius: Float = 2.6f, roadLength: Float = 9f, roadHalfWidth: Float = 1.4f): List<Slab> }` — port of `clip_halfplane` / gap-shrink logic from `blender/shattered-realm/shattered_realm.py`; platform disc centered at origin, road extending toward +z (toward camera); `order` = normalized distance from the platform center (outer slabs first).
- Kotlin library is plain JVM: no `android.*` imports in `intro-logic` (enforced by it compiling standalone).

- [ ] **Step 1: Write failing tests:** `deterministicForSeed`, `slabCountInRange` (60..400 for defaults), `polygonsConvexAndCCW`, `slabsInsideFootprint` (every vertex within platformRadius + 0.1 or within road rectangle), `gapsDoNotOverlap` (no two polygons' areas overlap: pairwise SAT test on world polygons), `orderInUnitRange`.
- [ ] **Step 2: Run** `gradle -p native-v3/intro-logic test` → FAIL.
- [ ] **Step 3: Implement** `StageLayout.build`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(intro): JVM intro-logic module with Voronoi stage layout`.

### Task 4: Intro timeline and shard motion

**Files:**
- Create: `native-v3/intro-logic/src/main/kotlin/com/starling/intro/IntroTimeline.kt`, `ShardMotion.kt`
- Create: tests `IntroTimelineTest.kt`, `ShardMotionTest.kt`

**Interfaces:**
- Produces:
  - `enum class Phase { VOID, GATHER_STAGE, GATHER_CHARACTER, HOLD, FLASH, SETTLE, DONE }`
  - `data class IntroState(val phase: Phase, val stageBlend: Float, val characterBlend: Float, val bloom: Float, val swapNow: Boolean, val cameraT: Float)` — blends 0 = scattered, 1 = assembled; `bloom` 0..1 (1 at flash peak); `swapNow` true exactly during the FLASH peak window (the caller swaps once on first true); `cameraT` 0..1 dolly progress.
  - `class IntroTimeline(val voidSec: Float = 1f, val stageSec: Float = 2f, val characterSec: Float = 1.5f, val flashSec: Float = 0.15f, val settleSec: Float = 0.35f, val maxExtraWaitSec: Float = 3f, val hardCapSec: Float = 12f)` with `fun stateAt(elapsedSec: Float, modelReadyAtSec: Float?): IntroState` and `fun reversed(elapsedSec: Float): IntroState` (shatter for transitions: blends go 1→0 over `stageSec`, then VOID; `swapNow` never true).
  - Rules: void ends at `clamp(modelReadyAtSec ?: ∞, voidSec, voidSec + maxExtraWaitSec)`; if character is assembled and model not ready → HOLD (bloom 0.4) until ready, then FLASH; if `elapsedSec ≥ hardCapSec` → DONE with `swapNow=false`.
  - `object ShardMotion { fun localBlend(phaseBlend: Float, order: Float, window: Float = 0.35f): Float; fun voidPose(seed: Int, index: Int, timeSec: Float, drift: Float): FloatArray }` — `localBlend` uses start = order·(1−window), smoothstep over `window`; `voidPose` returns `[dx, dy, dz, rx, ry, rz]` (meters, radians), deterministic, smooth in time (sum of sines; spin ≤ 0.6 rad/s).

- [ ] **Step 1: Write failing tests** (values from the Global Constraints timeline):
  - `phasesAtNominalTimes`: model ready at 0.5 s → t=0.5 VOID, 1.5 GATHER_STAGE, 3.5 GATHER_CHARACTER, 4.55 FLASH (`swapNow` true, bloom 1.0 ± 0.05), 4.8 SETTLE, 5.1 DONE.
  - `voidExtendsUntilReady`: ready at 2.5 s → t=2.4 is VOID; t=2.6 is GATHER_STAGE.
  - `voidExtensionCappedAt3s`: never ready → t=4.1 is GATHER_STAGE.
  - `holdUntilReady`: ready at 7 s → t=6.9 HOLD (`swapNow` false), t=7.05 FLASH.
  - `holdTimesOut`: never ready → t=12.0 DONE, `swapNow` false.
  - `abortGoesDone`: `stateAt(t, …)` after calling `abort()` returns DONE (add `fun abort()` to `IntroTimeline`).
  - `swapOnlyInFlash`: sampling every 10 ms over 0..13 s yields `swapNow` true only within one contiguous ≤150 ms window.
  - `reversedShatters`: `reversed(0).characterBlend == 1`, `reversed(2.0).characterBlend == 0`.
  - `localBlendOrdering`: at phaseBlend 0.3, order 0 > order 1; at 0 all 0; at 1 all 1; monotonic in phaseBlend.
  - `voidPoseDeterministicAndSmooth`: same args → same array; |pose(t+1/60) − pose(t)| < 0.05 per component.
- [ ] **Step 2: Run** `gradle -p native-v3/intro-logic test` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(intro): intro timeline and shard motion`.

### Task 5: Manifest rules for `semantic8` and `shards1`

**Files:**
- Create: `native-v3/intro-logic/src/main/kotlin/com/starling/intro/ManifestRules.kt` + `ManifestRulesTest.kt`
- Modify: `native-v3/bootstrap.sh` — `SignedAssets.kt` heredoc: `verified()` keeps signature/cert checks, then builds `PayloadFields` from the JSON and calls `ManifestRules.check`; `install()` routes `shards1` to `filesDir/studio-intro/shards-<characterId>.glb` + `.signed.json` and returns the spec; `ids()` only lists `semantic8`. Add `fun introShards(c: Context, characterId: String): File?` returning the verified shard file or null. Existing callers keep the current `Spec(id, size, hash)` type: `read()`/`ids()` map a `semantic8` `AssetSpec` to it.

**Interfaces:**
- Produces:
  - `data class PayloadFields(val schema: Int, val pkg: String, val profile: String, val minAppVersion: Int, val id: Int, val size: Long, val sha256: String, val sourceSha256: String, val characterId: String?)`
  - `data class AssetSpec(val profile: String, val id: Int, val size: Long, val sha256: String, val characterId: String?, val sourceSha256: String)`
  - `object ManifestRules { const val SEMANTIC8_SOURCE = "97c80d3a7f5b8e6412687ab30574fa4efdb5cd4db0a3115356de426ae411e379"; val SHARD_SOURCES = setOf("d55824a6514a6ab52f0e3d9d0cc0ed9ba3d346207d64e60595326db912fd66f4"); fun check(p: PayloadFields, appVersion: Long): AssetSpec }` — throws `IllegalArgumentException` with the existing Chinese messages ("资产协议不匹配", "需要更新 APP", "资产参数不合法").

- [ ] **Step 1: Write failing tests:** `semantic8AcceptedAsToday` (minAppVersion 82, app 83), `semantic8WrongSourceRejected`, `shards1Accepted` (minAppVersion 83, characterId "starling"), `shards1MissingCharacterRejected`, `rejectsUnknownSource` (shards1 with SEMANTIC8_SOURCE as source → rejected), `unknownProfileRejected`, `minAppVersionAboveAppRejected`, `characterIdPattern` (`"../x"` rejected).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** `ManifestRules`. **Step 4: Run** → PASS.
- [ ] **Step 5: Wire** `SignedAssets.kt` in `bootstrap.sh` as described; run `bash -n native-v3/bootstrap.sh`.
- [ ] **Step 6: Commit** `feat(assets): shards1 manifest rules and storage routing`.

### Task 6: Play decision

**Files:**
- Create: `native-v3/intro-logic/src/main/kotlin/com/starling/intro/IntroGate.kt` + `IntroGateTest.kt`

**Interfaces:**
- Produces: `data class DeviceFacts(val introEnabled: Boolean, val shardsPresent: Boolean, val shardSourceKnown: Boolean, val totalMemBytes: Long, val lowRamDevice: Boolean, val warmStart: Boolean, val animatorScale: Float)`; `object IntroGate { const val MIN_TOTAL_MEM = 4L shl 30; fun shouldPlay(f: DeviceFacts): Boolean }`. `warmStart` = all `StudioAssets` files already prepared before this launch. Threshold 4 GiB is the starting value; adjust after device measurement in Task 9.

- [ ] **Step 1: Write failing tests:** `playsOnCapableDevice`, `skipsWhenDisabled`, `skipsWhenNoShards`, `skipsWhenShardSourceUnknown`, `skipsWhenAnimationsOff` (scale 0f), `lowRamColdSkips`, `lowRamWarmPlays`, `lowRamDeviceFlagColdSkips`.
- [ ] **Step 2–4:** run → FAIL, implement, run → PASS.
- [ ] **Step 5: Commit** `feat(intro): intro play gate`.

### Task 7: Intro materials (matc)

**Files:**
- Modify: `native-v3/bootstrap.sh` — in the matc block next to `studio_skin.mat`, add and compile:
  - `intro_stage.mat` → `res/raw/intro_stage.filamat`: lit, params `baseColor` (float3), `roughness`, `metallic`, `seamGlow` (float, 0..1 drives cyan emissive `(0.3,0.85,1.0) * seamGlow * 4.0`), `fade` (float, alpha for dissolve; `blending: fade`).
  - `intro_nebula.mat` → `res/raw/intro_nebula.filamat`: unlit, `culling: front`, procedural fbm nebula + stars ported from the sky shader in `blender/shattered-realm/web/shattered-realm.html` (same palette constants); params `time`, `fade`.
  - `intro_glow.mat` → `res/raw/intro_glow.filamat`: unlit, `blending: add`, params `color` (float3), `intensity`.
  - Each with `test -s app/src/main/res/raw/<name>.filamat` after `matc -p mobile -a opengl`.

- [ ] **Step 1:** Add the three `.mat` heredocs and matc lines.
- [ ] **Step 2: Verify locally:** download the pinned `filament-v1.56.0-linux.tgz` (same URL as bootstrap), run its `matc -p mobile -a opengl` on each `.mat` → exit 0 and non-empty output. If the release host is blocked in the session, verification moves to the CI run in Task 8.
- [ ] **Step 3: Commit** `feat(intro): intro stage, nebula and glow materials`.

### Task 8: `ShatterIntro` Android layer and MainActivity wiring

**Files:**
- Modify: `native-v3/bootstrap.sh`:
  - New heredoc `app/src/main/java/com/starling/filament/ShatterIntro.kt`.
  - `MainActivity.kt` heredoc: field `private var intro: ShatterIntro? = null`; in `ticker.doFrame` call `intro?.tick(t)` before `viewer.render(t)`; start after `StudioAssets.prepare` succeeds and before the first model load; `onPause` → `intro?.abort()`; settings toggle `introEnabled` in `SharedPreferences("intro", 0)`; `Controls` JS bridge command `"introToggle"`.
  - `studio-controls.js` heredoc: a button "开场动画：开/关" calling `send('introToggle')`, and `window.studioIntro=on=>…` to reflect state.
  - app `build.gradle` heredoc: `versionCode 83`, `versionName '8.1'`.
- Modify: `.github/workflows/starling-native.yml`: add step `gradle -p native-v3/intro-logic test --no-daemon` before "Compile native APK"; add `pull_request` trigger on the same paths.

**Interfaces:**
- Consumes: `IntroTimeline`, `IntroState`, `Phase`, `ShardMotion`, `StageLayout`, `IntroGate`, `DeviceFacts` (Tasks 3–6); `SignedAssets.introShards(context, "starling")` (Task 5); materials from Task 7.
- Produces: `class ShatterIntro(activity: Activity, viewer: ModelViewer, shards: File, onSwap: () -> Unit, onDone: () -> Unit)` with `fun start()`, `fun tick(frameTimeNanos: Long)`, `fun modelReady()`, `fun abort()`, `fun startReverse(onShattered: () -> Unit)` (transition hook for the future character-switch project; self-tested from a debug-only JS command `"introReverse"`).
- Behavior pinned by the spec:
  - Load shards with `viewer.assetLoader` + `ResourceLoader`, add entities to `viewer.scene`; per-shard rest transform read once from `TransformManager`; shard `order` = normalized rest-position height (no reliance on glTF extras).
  - Each frame: shard transform = lerp(rest, rest + voidPose, 1 − localBlend); stage slabs from `StageLayout` built once into one vertex/index buffer per material with `intro_stage`; glow ring = 160 tiny icosahedra with `intro_glow` on a torus around the character; nebula = inward-facing sphere with `intro_nebula`.
  - During intro: hide WebView (`View.INVISIBLE`), consume touches (tap → `abort()`), set `view.bloomOptions` (enabled, strength = 0.15 + 0.6·bloom) and `view.fogOptions` (enabled, density 0.08, color (0.04,0.11,0.23)); camera dolly from (0, 1.2, 9) to the user's saved pose via `cameraT`.
  - First `swapNow` → `onSwap()` (show real model entities, hide shard entities). DONE/abort → destroy intro entities and materials, restore saved bloom/fog/skybox, call existing `applyTransform()` and `applyLensProjection()`, show WebView.
  - Model load completion in MainActivity calls `intro?.modelReady()`; load failure does nothing (timeline hard cap ends the intro).

- [ ] **Step 1:** Implement per above; `bash -n native-v3/bootstrap.sh`.
- [ ] **Step 2: Verify** in CI: push the branch and trigger the "Starling native Android" workflow (pull request or workflow_dispatch via GitHub MCP `actions_run_trigger` with this branch). Expected: `intro-logic` tests pass, `:app:assembleDebug` succeeds, apksigner verify passes.
- [ ] **Step 3: Commit** `feat(intro): ShatterIntro playback and app wiring`.

### Task 9: Shard asset production and device acceptance

**Files:**
- Create: `docs/shatter-intro-acceptance.md` (checklist + results table; no private images committed)

- [ ] **Step 1 (owner's machine, local only):** `blender -b --python blender/shatter-intro/fracture_character.py -- mobile.glb shards.glb --shards 300 --seed 7`; then `python3 scripts/build-signed-asset.py shards.glb starling-intro.zip --profile shards1 --id <new id ≥5> --character-id starling --source-sha256 d55824a6514a6ab52f0e3d9d0cc0ed9ba3d346207d64e60595326db912fd66f4 --key … --cert …`. Import via the existing local import flow.
- [ ] **Step 2: Device checks** (record pass/fail, FPS, temperature in the doc): cold start plays and lands in normal view; tap skips; no visible swap at the flash (A/B frames before/after, kept locally); background mid-intro → resume shows normal view; rotate mid-intro; delete shard asset → no intro, normal startup time; toggle off → no intro; system animations off → no intro; debug `introReverse` shatters and re-gathers; 30-run average FPS ≥ 50 on the owner's phone; tune `IntroGate.MIN_TOTAL_MEM` and shard count if not.
- [ ] **Step 3: Commit** `docs(intro): device acceptance results` (results only, no assets).

---

## Self-review notes
- Spec coverage: fracture (T1), signing/protocol + per-character binding (T2, T5), timeline/void/gather/flash/settle + load-parallel + hold (T4), stage + particle fade (T3, T8), bloom/fog/nebula/glow (T7, T8), UI hidden + gestures locked + skip + saved pose (T8), memory gate + toggle (T6, T8), reverse transition module (T4 `reversed`, T8 `startReverse`), verification (T1 tests, T8 CI, T9 device).
- Deviation from spec, stated in Architecture: stage is generated at runtime in Kotlin (same algorithm) instead of a Blender-made asset.
