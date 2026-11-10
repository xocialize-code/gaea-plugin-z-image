# gaea-plugin-z-image

Tongyi-MAI's **Z-Image** (6B single-stream DiT, Apache-2.0) as a [Gaea](https://github.com/xocialize-code/gaea) plugin,
with **NitroFusion2** (Chen & Song, Apache-2.0), Z-Image Turbo distilled to 1–4 steps. It is built on [GaeaPluginKit](https://github.com/xocialize-code/gaea-plugin-kit) over
[z-image-swift](https://github.com/xocialize/z-image-swift), runs in its own process, and speaks the Gaea Plugin
Protocol v1. Add it to Gaea by its repo URL:

```bash
gaea plugins add https://github.com/xocialize-code/gaea-plugin-z-image
```

## What it offers

| Model | MES operation | Quality tiers | Notes |
|---|---|---|---|
| `z-image-turbo` | `image.generate` (Gaea's default) | draft, standard | Distilled to 8 steps without CFG. A negative prompt does nothing and is reported `negative_prompt_ignored`. |
| `z-image` | `image.generate` | best | The base model: 28 steps, CFG 4, honours negative prompts. Slower, with finer detail. |
| `z-image-nitrofusion2` | `image.generate` (named-only) | draft | NitroFusion2: Turbo in 1–4 steps, two by default. About a third of Turbo's time at the same memory. Text-to-image only. Since 0.2.0. |
| Turbo and base | `image.edit` (named-only) | as above | Image-to-image: re-generates the first image toward the instruction at `strength` 0–1 (default 0.75). It isn't an instruction editor, so a client asks for it by name. |

**NitroFusion2** runs when a client names it. On an M5 Max at 1024² it takes 3.6 to 4.2 s at two steps and about 2.3 s
at one, against Turbo's 11 to 12 s (z-image-swift's measurements, AB-R-0818 and AB-R-0819).
- Two steps apply the authors' de-distillation LoRA and render short text reliably; one step is the fastest, and its
  text is the least reliable. Small text is weaker than Turbo's at any step count.
- `x-zimage.steps` is 1 to 4; any other count is refused.
- No CFG: a negative prompt does nothing and is reported `negative_prompt_ignored`.

- **Sizes.** 256–2048 px a side, at most 1536² in area, in multiples of 16. Anything else is fitted and reported
  `size_snapped`. `aspect` with `megapixels` works too. `image.edit` keeps the input's size.
- **`count`.** 1–8 images, each with `seed + i`. A request without a seed gets one, reported in `effective`.
- **Options**, as MES extensions: `x-zimage.steps` (every model) and `x-zimage.guidance` (base only).

## Lanes and memory

Each model has three lanes, one per DiT quant. The encoder stays bf16 and the VAE fp32. The footprints are
z-image-swift's measured ones, declared at the 1536² cap:

| Lane | Resident | Peak while running | Gaea schedules |
|---|---|---|---|
| `int4` (default) | 11.9 GB | 28 GB | 39.9 GB |
| `int8` | 15 GB | 28 GB | 43 GB |
| `bf16` | 20.5 GB | 28 GB | 48.5 GB |

NitroFusion2's lanes hold its LoRA too: 12.3, 15.4 and 20.9 GB resident, with the same 28 GB peak (its int8 figure is
Turbo's plus the LoRA, not measured).

When the default lane doesn't fit, Gaea loads a smaller one and warns (`lane_fallback`, G-23). A request naming a lane
(`x-gaea.lane`) never falls back.

## Weights

Gaea sends its models root in `configure` (MLXEngine's store by default, `gaea models root` to change it). The
worker looks for `mlx-community/Z-Image-Turbo-bf16` and `mlx-community/Z-Image-bf16` there and downloads a missing
snapshot on `prepare` or `materialize`. The int8 and int4 lanes quantize the bf16 DiT on load.

NitroFusion2 reads its transformer (12.3 GB) and LoRA (381 MB) from `ChenDY/NitroFusion2`, and its text encoder and VAE
from Turbo's snapshot. `gaea plugins warm com.xocialize.gaea.z-image z-image-nitrofusion2` downloads them ahead.

## Build and check locally

```bash
scripts/build-plugin.sh
```

```bash
scripts/check-plugin.sh
```

`zimage-inproc` (its header lists the options) is not part of the plugin. It runs the same lane in-process through
MLXServeEngine, with the worker's request: the reference Gaea's runs are compared against.

```bash
scripts/golden.sh <out-dir>
```

`golden.sh` makes images over GPP on the signed bundle and through `zimage-inproc`, and needs each pair to be the same
PNG, byte for byte: NitroFusion2 at two steps (int4 and bf16), at one and at four, and Turbo as the control.

`check-plugin.sh` generates one 512² image with Turbo int4 against the weights in MLXEngine's store
(`CHECK_MODELS_ROOT` moves it), with every `.build` folder hidden so MLX can find its metallib only inside the
bundle. A control then shows that the bare worker, outside the bundle, can't. `scripts/release.sh` builds, checks,
notarizes with the fleet's `mlx-notary` profile, and publishes the GitHub release. See the
[demo plugin](https://github.com/xocialize-code/gaea-plugin-demo) for signing, notarization and CI secrets.

## Licence

The plugin is Apache-2.0 (Gaea G-21). Z-Image's weights are Apache-2.0 (Tongyi-MAI), NitroFusion2's are
Apache-2.0 (Chen & Song, arXiv 2611.05648), and z-image-swift is MIT.
