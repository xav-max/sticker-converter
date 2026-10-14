# Sticker Converter Pro - Design Concept & Algorithms

This document outlines the core architecture, algorithmic strategies, and resizing logic behind **Sticker Converter Pro**. The app is designed to take raw, unoptimized GIF files or specific static assets and automatically convert them into platform-compliant sticker formats for WhatsApp, WeChat, Telegram, Signal, and LINE.

---

## 1. Core Workflow

1. **Upload & Extract:** The user uploads a `.zip` file containing GIF and optionally specific PNG files via the web interface. The Node.js server extracts the ZIP to a temporary processing directory.
2. **Detection & Processing:** A Bash script (`process_stickers.sh`) scans the directory. It identifies special files (`main.gif`, `tab.png`, `cover.png`, `icon.png`) for exclusive formatting, and treats all other `.gif` files as standard inputs.
3. **Platform-Specific Conversion:** For standard GIFs, the script invokes FFmpeg to convert the file into 5 different formats, applying specific size limits, resolutions, and codecs tailored to each messaging platform.
4. **Fallback Size Correction:** If a generated file exceeds the platform's strict maximum file size constraint, a procedural degradation algorithm shrinks the color palette and reduces the frame rate step-by-step until the file fits within the limits.
5. **Node.js Post-Processing:** For platforms like LINE that possess severe metadata restrictions, an in-line Node.js buffer scraper scrubs forbidden header chunks natively before validation.
6. **Zipping & Delivery:** The optimized, strict-compliant outputs are zipped and pushed back to the user on the frontend.

---

## 2. Platform Formats & Constraints

Each target platform imposes strict limitations. The baseline parameters configured for initial conversions are:

- **WhatsApp:** 512x512, `.gif` format, Max Size: 500 KB.
- **WeChat:** 240x240, `.gif` format, Max Size: 500 KB.
- **Telegram:** 512x512, `.webm` (VP9 codec, no audio), Max Size: 256 KB.
- **Signal:** 512x512, `.apng` (Animated PNG), Max Size: 300 KB.
- **LINE:** 320x270 (bounded, even dimensions only), `.apng` format, Max Size: 300 KB.

---

## 3. The Fallback Degradation Algorithm (Size Correction)

If the first-pass high-quality conversion exceeds the platform's `Max Size`, the app triggers a procedural "Fallback Array" to gradually decrease the visual payload. This guarantees that *every* sticker ultimately fits the requirement without outright crashing.

### Fallback Array Steps:
The fallback array calculates target configurations based on the file's native frame rate (`ORIG_FPS`), strictly prioritizing quality over jittery low framerates.

1. **Iterative Color Dropping:** The system cycles downward through fixed color palette constraints (128, 64, 32, 16, 8, 4, 2).
2. **Independent FPS Reduction:** For *each* color level, the algorithm resets to the high `ORIG_FPS` and drops the framerate smoothly by `1 FPS` at a time, down to `HALF_FPS`. 
3. **Hard 5 FPS Floor Limit:** The framerate is completely forbidden from dropping below 5 FPS. If half the original framerate dips under 5, the math strictly caps at 5 FPS to ensure the sticker animation remains legible. 
4. **No Simultaneous Degradation:** It naturally avoids dropping both framerate *and* color depth simultaneously. If all FPS steps fail for a specific color level, the script fully resets the framerate back to maximum before beginning the next, lower color tier.
 
The system attempts to re-convert the file against these target pairs consecutively. The loop breaks at the first successful pass where `Output File Size <= Max Size`.

---

## 4. LINE-Specific Complex Handling

LINE has the strictest requirements of all messaging platforms. The app employs unique logic to satisfy LINE’s idiosyncratic APNG validators:

### Frame Rate & Playback Duration
LINE requires the playback time to be strictly **1s, 2s, 3s, or 4s** (no decimals) and strictly between **5 and 20 frames** total.
- **Interpolation:** The app extracts the original duration, rounds it to the nearest valid integer (`LINE_DUR`), and forces FFmpeg to rubber-band the playback timestamps using `setpts=($LINE_DUR/$NATIVE_DUR)*PTS`.
- **Frame Clamping:** The script calculates `TOTAL_FRAMES`. If the frames exceed `20`, the FPS is mathematically crushed; if under `5`, the FPS is artificially boosted to hit the threshold natively.
- **Loop Adjustments (`-plays`):** Standard APNG loops infinitely or a hardcoded amount, but LINE requires the total looping playtime to never exceed 4 seconds. The script calculates `4 / LINE_DUR` to assign the exact number of times the sticker should loop on screen.

### Dimensional Geometry
LINE strictly forbids odd-numbered coordinate boundaries and internal padding offsets. 
- The app utilizes an FFmpeg math formula: `scale='trunc(iw/2)*2':'trunc(ih/2)*2'` to force any dimension cleanly onto an even number.

### Byte-Level Metadata Erasure (Node.js Scraper)
LINE outright rejects files if the APNG contains a `pHYs` chunk (Physical Pixel Dimensions) or EXIF metadata. However, FFmpeg forces `pHYs` natively and cannot disable it.
- **Solution:** Immediately after FFmpeg creates the APNG, a temporary Node script triggers. It converts the `.apng` string to a 32-bit Buffer and splits it. It checks an explicitly allowed list (`IHDR`, `acTL`, `fcTL`, `fdAT`, `IDAT`, `IEND`, `PLTE`, `tRNS`). Any byte chunk outside of this whitelisted scope is surgically erased from the file buffer, creating a cleanly sanitized file that passes LINE validators.

---

## 5. Special File Routing

If you name your uploaded assets with specific filenames, they bypass standard multi-platform rendering and get hard-routed for exclusive platform integrations:

1. **`main.gif`** -> **LINE Main Image:** Bypasses normal channels. Scales to exactly `240x240 APNG` applying the same tight animation loops, but retains a high-fidelity **1 MB** file size limit instead of the standard 300 KB.
2. **`tab.png`** -> **LINE Tab Icon:** Confirms/rescales strictly to `96x74` standard `.png`. Output routed strictly to LINE.
3. **`cover.png`** -> **WeChat Album Cover:** Confirms/rescales strictly to `240x240` standard `.png`. Output routed strictly to WeChat.
4. **`icon.png`** -> **WeChat Tab Icon:** Confirms/rescales strictly to `50x50` standard `.png`. Output routed strictly to WeChat.