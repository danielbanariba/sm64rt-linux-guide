# Example RT64 Configurations

Tuned config files you can drop into your Wine prefix at:
`~/.wine-sm64rt/drive_c/users/<you>/AppData/Roaming/sm64ex/sm64config.txt`

## `sm64config.example.txt` — 4K + FSR Balanced

Tested on:
- **GPU**: NVIDIA RTX 3090 Ti (driver 595.58)
- **Monitor**: 5120×2880 (downsampled via FSR 2 Quality)
- **Performance**: stable 60 FPS with GI + denoiser + sphere lights enabled

Key settings:

| Setting | Value | Notes |
|---------|-------|-------|
| `rt64_res_scale` | `50` | Render internally at 50% → FSR upscales |
| `rt64_upscaler` | `2` | FSR 2 (DLSS is broken via Wine because DXVK masks GPU vendor) |
| `rt64_upscaler_mode_common` | `0` | Quality preset |
| `rt64_upscaler_sharpness` | `80` | Higher sharpening to counteract RT noise |
| `rt64_denoiser` | `true` | Cleans remaining path-trace noise |
| `rt64_gi` | `true` | Global Illumination (indirect lighting) |
| `rt64_sphere_lights` | `true` | Dynamic lights on coins, fire, particles |
| `rt64_max_lights` | `12` | Doubled from default 6 |
| `rt64_target_fps` | `60` | 60 FPS cap |
| `rt64_motion_blur_strength` | `0` | Off (personal preference) |

## If you have a less powerful GPU

Lower `rt64_res_scale` to `33` for steep FSR upscaling on e.g. RTX 3070/4060.
Drop `rt64_max_lights` back to `6` and set `rt64_gi false` if you need more frames.
