# gaea-plugin-z-image

Tongyi-MAI's **Z-Image** (6B single-stream DiT, Apache-2.0) as a [Gaea](https://github.com/xocialize/gaea) plugin. It
is built on [GaeaPluginKit](https://github.com/xocialize/gaea-plugin-kit) over
[z-image-swift](https://github.com/xocialize/z-image-swift), runs in its own process, and speaks the Gaea Plugin
Protocol v1. Add it to Gaea by its repo URL:

```bash
gaea plugins add https://github.com/xocialize/gaea-plugin-z-image
```

## What it offers

| Model | MES operation | Quality tiers | Notes |
|---|---|---|---|
| `z-image-turbo` | `image.generate` (Gaea's default) | draft, standard | Distilled to 8 steps without CFG. A negative prompt does nothing and is reported `negative_prompt_ignored`. |
| `z-image` | `image.generate` | best | The base model: 28 steps, CFG 4, honours negative prompts. Slower, with finer detail. |
| both | `image.edit` (named-only) | as above | Image-to-image: re-generates the first image toward the instruction at `strength` 0–1 (default 0.75). It isn't an instruction editor, so a client asks for it by name. |

- **Sizes.** 256–2048 px a side, at most 1536² in area, in multiples of 16. Anything else is fitted and reported
  `size_snapped`. `aspect` with `megapixels` works too. `image.edit` keeps the input's size.
- **`count`.** 1–8 images, each with `seed + i`. A request without a seed gets one, reported in `effective`.
- **Options**, as MES extensions: `x-zimage.steps` (both models) and `x-zimage.guidance` (base only).

## Lanes and memory

Each model has three lanes, one per DiT quant. The encoder stays bf16 and the VAE fp32. The footprints are
z-image-swift's measured ones, declared at the 1536² cap:

| Lane | Resident | Peak while running | Gaea schedules |
|---|---|---|---|
| `int4` (default) | 11.9 GB | 28 GB | 39.9 GB |
| `int8` | 15 GB | 28 GB | 43 GB |
| `bf16` | 20.5 GB | 28 GB | 48.5 GB |

When the default lane doesn't fit, Gaea loads a smaller one and warns (`lane_fallback`, G-23). A request naming a lane
(`x-gaea.lane`) never falls back.

## Weights

Gaea sends its models root in `configure` (MLXEngine's store by default, `gaea models root` to change it). The
worker looks for `mlx-community/Z-Image-Turbo-bf16` and `mlx-community/Z-Image-bf16` there and downloads a missing
snapshot on `prepare` or `materialize`. The int8 and int4 lanes quantize the bf16 DiT on load.

## Build and check locally

```bash
scripts/build-plugin.sh
```

```bash
scripts/check-plugin.sh
```

`check-plugin.sh` generates one 512² image with Turbo int4 against the weights in MLXEngine's store
(`CHECK_MODELS_ROOT` moves it), with every `.build` folder hidden so MLX can find its metallib only inside the
bundle. A control then shows that the bare worker, outside the bundle, can't. `scripts/release.sh` builds, checks,
notarizes with the fleet's `mlx-notary` profile, and publishes the GitHub release. See the
[demo plugin](https://github.com/xocialize/gaea-plugin-demo) for signing, notarization and CI secrets.

## Licence

The plugin is Apache-2.0 (Gaea G-21). Z-Image's weights are Apache-2.0 (Tongyi-MAI), and z-image-swift is MIT.
