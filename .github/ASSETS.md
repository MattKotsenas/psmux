# Repository Assets

## Social Card Setup

To enable the social card on GitHub:

1. **Convert SVG to PNG** (if not already done):
   - Online: Upload `.github/social-card.svg` to https://cloudconvert.com/svg-to-png
   - Or install ImageMagick: `winget install ImageMagick.ImageMagick`
   - Then run: `magick .github/social-card.svg .github/social-card.png`

2. **Upload to GitHub**:
   - Go to: https://github.com/psmux/psmux/settings
   - Scroll to "Social preview"
   - Click "Edit" and upload `.github/social-card.png`
   - Dimensions: 1280x640px (optimal for social sharing)

## Repository Icon

The `icon.svg` can be used as:
- Project logo in documentation
- Favicon for project websites
- App icon if building a GUI wrapper

### Executable Icon (`assets/psmux.ico`)

`build.rs` embeds `assets/psmux.ico` and a `VS_VERSIONINFO` block into
`psmux.exe` (and its `pmux.exe` / `tmux.exe` aliases) via the `winresource`
crate, so Task Manager, the taskbar, alt+tab and third party consent dialogs
show a named, icon bearing process instead of a generic one.

`assets/psmux.ico` is generated from `icon.svg` and is checked in so the build
never needs a rasteriser. Regenerate it after changing `icon.svg`:

```powershell
winget install ImageMagick.ImageMagick   # needs the rsvg delegate
magick -background none -density 192 icon.svg -resize 1024x1024 png32:base.png
magick base.png -filter Lanczos -define icon:auto-resize=256,128,64,48,32,24,16 assets\psmux.ico
magick identify assets\psmux.ico         # expect 7 frames
```

The frame list (256, 128, 64, 48, 32, 24, 16) is asserted by
`tests/test_issue620_version_resource.ps1`.

### Design Features

**Social Card (`1280x640px`):**
- Dark gradient background (#1a1a2e → #16213e)
- Terminal window with split pane visualization
- psmux branding with cyan accent (#00d9ff)
- Feature badges: tmux-compatible, Windows-native, Rust-powered, No WSL
- PS> prompts to emphasize PowerShell support

**Icon (`512x512px`):**
- Cyan gradient circular background
- Terminal window with 3-pane split layout
- Animated cursor (blinks when viewed as SVG)
- Compact design suitable for various sizes

Both designs emphasize:
- Terminal multiplexing (split panes)
- Windows/PowerShell focus (PS> prompts)
- Modern, professional aesthetic
- Brand color consistency (#00d9ff cyan)
