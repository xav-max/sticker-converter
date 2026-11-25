#!/bin/bash

# Fast multi-platform sticker conversion pipeline.
# Usage: ./process_stickers.sh [INPUT_DIR] [OUTPUT_DIR]

INPUT_DIR="${1:-"/input"}"
OUTPUT_DIR="${2:-"/output"}"
PROCESSED_DIR="$INPUT_DIR/processed"

mkdir -p "$PROCESSED_DIR" "$OUTPUT_DIR/whatsapp" "$OUTPUT_DIR/wechat" "$OUTPUT_DIR/telegram" "$OUTPUT_DIR/signal" "$OUTPUT_DIR/line"

HAS_GIFSICLE=0
if command -v gifsicle >/dev/null 2>&1; then
  HAS_GIFSICLE=1
fi

FAILED_CONVERSIONS=0

FILE_COUNT=$(find "$INPUT_DIR" -maxdepth 3 -type f \( -iname "*.gif" -o -iname "*.png" \) ! -path "$PROCESSED_DIR/*" ! -path "*/__MACOSX/*" ! -name ".*" | wc -l | tr -d ' ')
if [ "$FILE_COUNT" -eq 0 ]; then
  echo "No target files found in $INPUT_DIR."
  exit 0
fi

echo "Scanning $INPUT_DIR ($FILE_COUNT candidate file(s))..."
if [ "$HAS_GIFSICLE" -eq 1 ]; then
  echo "Fast encoders: ffmpeg + gifsicle (-O3 --lossy)"
else
  echo "Fast encoders: ffmpeg (gifsicle not found; using ffmpeg bisection)"
fi

strip_apng_chunks() {
  local target_file="$1"
  node -e '
    const fs = require("fs");
    const file = process.argv[1];
    const d = fs.readFileSync(file);
    if (d.length < 8) process.exit(0);
    const keep = new Set(["IHDR", "acTL", "fcTL", "fdAT", "IDAT", "IEND", "PLTE", "tRNS"]);
    const out = [d.subarray(0, 8)];
    let i = 8;
    while (i + 12 <= d.length) {
      const len = d.readUInt32BE(i);
      const type = d.toString("ascii", i + 4, i + 8);
      if (i + 12 + len > d.length) break;
      if (keep.has(type)) out.push(d.subarray(i, i + 12 + len));
      i += 12 + len;
    }
    fs.writeFileSync(file, Buffer.concat(out));
  ' "$target_file"
}

get_filesize() {
  wc -c < "$1" 2>/dev/null | tr -d ' ' || echo 0
}

# Render GIF or APNG directly from a pre-scaled lossless intermediate (.mkv)
render_paletted() {
  local src="$1"
  local out="$2"
  local fps="$3"
  local colors="$4"
  local dither="$5"
  local format="$6"
  local max_dur="$7"
  local plays="$8"

  local vf="[0:v]fps=${fps},split[s0][s1];[s0]palettegen=max_colors=${colors}:stats_mode=diff:reserve_transparent=1[p];[s1][p]paletteuse=dither=${dither}:diff_mode=rectangle"
  local dur_args=()
  if [ -n "$max_dur" ]; then
    dur_args=(-t "$max_dur")
  fi

  if [ "$format" == "apng" ]; then
    ffmpeg -nostdin -y -v error -i "$src" -filter_complex "$vf" \
      -pred mixed -compression_level 9 "${dur_args[@]}" -plays "${plays:-0}" -f apng "$out"
    strip_apng_chunks "$out"
  else
    ffmpeg -nostdin -y -v error -i "$src" -filter_complex "$vf" "${dur_args[@]}" "$out"
  fi
}

# Build a clean monotonic quality ladder (index 0 = best quality, index N-1 = smallest)
# Outputs lines of "colors:fps:dither"
build_quality_ladder() {
  local fps_max="$1"
  local fps_min="$2"
  local format="$3"
  local fixed_total_min="$4"
  local fixed_total_max="$5"
  local dur_int="$6"

  awk -v fmax="$fps_max" -v fmin="$fps_min" -v fmt="$format" \
      -v tmin="$fixed_total_min" -v tmax="$fixed_total_max" -v dint="$dur_int" '
  function clamp_fps(f,    tot) {
    if (f < fmin) f = fmin;
    if (f > fmax) f = fmax;
    if (dint > 0 && tmax > 0) {
      tot = f * dint;
      if (tot > tmax) f = int(tmax / dint);
      if (tot < tmin) f = int((tmin + dint - 1) / dint);
      if (f < 1) f = 1;
    }
    return f;
  }
  BEGIN {
    # 15 steps ordered from highest quality to smallest size.
    # Colors drop smoothly first; FPS drops in clean fractions only in the lower half.
    c[0]=256; fr[0]=1.00; d[0]="sierra2_4a";
    c[1]=192; fr[1]=1.00; d[1]="sierra2_4a";
    c[2]=128; fr[2]=1.00; d[2]="sierra2_4a";
    c[3]=96;  fr[3]=1.00; d[3]="sierra2_4a";
    c[4]=64;  fr[4]=1.00; d[4]="sierra2_4a";
    c[5]=64;  fr[5]=1.00; d[5]="none";
    c[6]=48;  fr[6]=1.00; d[6]="none";
    c[7]=32;  fr[7]=1.00; d[7]="none";
    c[8]=32;  fr[8]=0.80; d[8]="none";
    c[9]=24;  fr[9]=0.70; d[9]="none";
    c[10]=24; fr[10]=0.55; d[10]="none";
    c[11]=16; fr[11]=0.55; d[11]="none";
    c[12]=16; fr[12]=0.50; d[12]="none";
    c[13]=8;  fr[13]=0.50; d[13]="none";
    c[14]=4;  fr[14]=0.50; d[14]="none";

    prev = "";
    for (i = 0; i < 15; i++) {
      fps = int(fmax * fr[i] + 0.5);
      fps = clamp_fps(fps);
      entry = c[i] ":" fps ":" d[i];
      if (entry != prev) {
        print entry;
        prev = entry;
      }
    }
  }'
}

optimize_gif() {
  local label="$1"
  local src="$2"
  local out="$3"
  local max_size="$4"
  local fps_max="$5"
  local fps_min="$6"
  local work="$7"

  local raw_gif="$work/${label}_raw.gif"
  local best_gif="$work/${label}_best.gif"
  local cand_gif="$work/${label}_cand.gif"

  # Pass 1: 256 colors at full FPS
  render_paletted "$src" "$raw_gif" "$fps_max" 256 "sierra2_4a" "gif" "" ""
  if [ "$HAS_GIFSICLE" -eq 1 ]; then
    gifsicle -O3 "$raw_gif" -o "$out" 2>/dev/null || cp "$raw_gif" "$out"
  else
    cp "$raw_gif" "$out"
  fi

  local fsize
  fsize=$(get_filesize "$out")
  if [ "$fsize" -le "$max_size" ]; then
    echo "[$label] Passed on 1st pass: $fsize / $max_size bytes (256 colors, ${fps_max} FPS)."
    return 0
  fi

  # Stage A (fast): If gifsicle is available, binary-search --lossy (10..140) on 256-color GIF
  if [ "$HAS_GIFSICLE" -eq 1 ]; then
    gifsicle -O3 --lossy=140 "$raw_gif" -o "$cand_gif" 2>/dev/null
    local max_lossy_size
    max_lossy_size=$(get_filesize "$cand_gif")
    if [ "$max_lossy_size" -gt 0 ] && [ "$max_lossy_size" -le "$max_size" ]; then
      cp "$cand_gif" "$best_gif"
      local best_lossy=140
      local best_size="$max_lossy_size"
      local lo=10 hi=139
      while [ "$lo" -le "$hi" ]; do
        local mid=$(( (lo + hi) / 2 ))
        gifsicle -O3 --lossy="$mid" "$raw_gif" -o "$cand_gif" 2>/dev/null
        local s
        s=$(get_filesize "$cand_gif")
        if [ "$s" -gt 0 ] && [ "$s" -le "$max_size" ]; then
          cp "$cand_gif" "$best_gif"
          best_lossy="$mid"
          best_size="$s"
          hi=$((mid - 1))
        else
          lo=$((mid + 1))
        fi
      done
      cp "$best_gif" "$out"
      echo "[$label] Passed via gifsicle bisection (lossy=$best_lossy, 256 colors, ${fps_max} FPS): $best_size / $max_size bytes."
      return 0
    fi
  fi

  # Stage B: Binary search unified (colors, fps, dither) ladder
  local ladder=()
  while IFS= read -r line; do
    ladder+=("$line")
  done < <(build_quality_ladder "$fps_max" "$fps_min" "gif" 0 0 0)

  local lo=1
  local hi=$(( ${#ladder[@]} - 1 ))
  local found=0
  local best_conf=""
  local best_size=0

  while [ "$lo" -le "$hi" ]; do
    local mid=$(( (lo + hi) / 2 ))
    local conf="${ladder[$mid]}"
    local c f d
    IFS=':' read -r c f d <<< "$conf"

    render_paletted "$src" "$raw_gif" "$f" "$c" "$d" "gif" "" ""
    if [ "$HAS_GIFSICLE" -eq 1 ]; then
      gifsicle -O3 --lossy=80 "$raw_gif" -o "$cand_gif" 2>/dev/null || cp "$raw_gif" "$cand_gif"
    else
      cp "$raw_gif" "$cand_gif"
    fi

    local s
    s=$(get_filesize "$cand_gif")
    if [ "$s" -gt 0 ] && [ "$s" -le "$max_size" ]; then
      cp "$cand_gif" "$best_gif"
      found=1
      best_conf="$conf"
      best_size="$s"
      hi=$((mid - 1))
    else
      lo=$((mid + 1))
    fi
  done

  if [ "$found" -eq 1 ]; then
    cp "$best_gif" "$out"
    echo "[$label] Passed via bisection ($best_conf): $best_size / $max_size bytes."
    return 0
  fi

  # Keep smallest attempt
  cp "$cand_gif" "$out" 2>/dev/null || true
  local final_s
  final_s=$(get_filesize "$out")
  echo "[$label] WARNING: Could not shrink below $max_size bytes (best: $final_s bytes)."
  return 1
}

optimize_apng() {
  local label="$1"
  local src="$2"
  local out="$3"
  local max_size="$4"
  local fps_max="$5"
  local fps_min="$6"
  local max_dur="$7"
  local plays="$8"
  local tmin="$9"
  local tmax="${10}"
  local dur_int="${11}"
  local work="${12}"

  local best_png="$work/${label}_best.png"
  local cand_png="$work/${label}_cand.png"

  local ladder=()
  while IFS= read -r line; do
    ladder+=("$line")
  done < <(build_quality_ladder "$fps_max" "$fps_min" "apng" "$tmin" "$tmax" "$dur_int")

  # Pass 1: highest quality entry (index 0)
  local c0 f0 d0
  IFS=':' read -r c0 f0 d0 <<< "${ladder[0]}"
  render_paletted "$src" "$out" "$f0" "$c0" "$d0" "apng" "$max_dur" "$plays"
  local fsize
  fsize=$(get_filesize "$out")
  if [ "$fsize" -le "$max_size" ]; then
    echo "[$label] Passed on 1st pass: $fsize / $max_size bytes (${c0} colors, ${f0} FPS)."
    return 0
  fi

  # Binary search over remaining ladder entries
  local lo=1
  local hi=$(( ${#ladder[@]} - 1 ))
  local found=0
  local best_conf=""
  local best_size=0

  while [ "$lo" -le "$hi" ]; do
    local mid=$(( (lo + hi) / 2 ))
    local conf="${ladder[$mid]}"
    local c f d
    IFS=':' read -r c f d <<< "$conf"

    render_paletted "$src" "$cand_png" "$f" "$c" "$d" "apng" "$max_dur" "$plays"
    local s
    s=$(get_filesize "$cand_png")
    if [ "$s" -gt 0 ] && [ "$s" -le "$max_size" ]; then
      cp "$cand_png" "$best_png"
      found=1
      best_conf="$conf"
      best_size="$s"
      hi=$((mid - 1))
    else
      lo=$((mid + 1))
    fi
  done

  if [ "$found" -eq 1 ]; then
    cp "$best_png" "$out"
    echo "[$label] Passed via bisection ($best_conf): $best_size / $max_size bytes."
    return 0
  fi

  cp "$cand_png" "$out" 2>/dev/null || true
  local final_s
  final_s=$(get_filesize "$out")
  echo "[$label] WARNING: Could not shrink below $max_size bytes (best: $final_s bytes)."
  return 1
}

optimize_webm() {
  local label="$1"
  local src="$2"
  local out="$3"
  local max_size="$4"
  local dur="$5"
  local fps_max="$6"
  local work="$7"

  local passlog="$work/vp9_pass"
  local eff_dur
  eff_dur=$(awk -v d="$dur" 'BEGIN { if (d <= 0.2) d = 0.2; if (d > 3.0) d = 3.0; printf "%.3f", d }')

  # Target ~228 KB payload to leave margin for WebM muxing overhead under 256 KB
  local base_kbps
  base_kbps=$(awk -v d="$eff_dur" 'BEGIN {
    k = int((228 * 1024 * 8) / (d * 1000));
    if (k < 100) k = 100;
    if (k > 650) k = 650;
    print k;
  }')

  local attempts=(
    "${base_kbps}:${fps_max}"
    "$(( base_kbps * 70 / 100 )):${fps_max}"
    "$(( base_kbps * 50 / 100 )):$(( fps_max > 20 ? 20 : fps_max ))"
    "$(( base_kbps * 35 / 100 )):$(( fps_max > 15 ? 15 : fps_max ))"
  )

  local attempt_num=0
  for cfg in "${attempts[@]}"; do
    attempt_num=$((attempt_num + 1))
    local kbps fps
    IFS=':' read -r kbps fps <<< "$cfg"
    if [ "$kbps" -lt 60 ]; then kbps=60; fi
    if [ "$fps" -lt 5 ]; then fps=5; fi

    rm -f "${passlog}"*
    ffmpeg -nostdin -y -v error -i "$src" -vf "fps=${fps}" \
      -c:v libvpx-vp9 -pix_fmt yuva420p -auto-alt-ref 0 \
      -deadline good -cpu-used 2 -row-mt 1 -b:v "${kbps}k" \
      -pass 1 -passlogfile "$passlog" -t 3 -an -f webm /dev/null

    ffmpeg -nostdin -y -v error -i "$src" -vf "fps=${fps}" \
      -c:v libvpx-vp9 -pix_fmt yuva420p -auto-alt-ref 0 \
      -deadline good -cpu-used 2 -row-mt 1 -b:v "${kbps}k" \
      -pass 2 -passlogfile "$passlog" -t 3 -an "$out"

    local fsize
    fsize=$(get_filesize "$out")
    if [ "$fsize" -gt 0 ] && [ "$fsize" -le "$max_size" ]; then
      echo "[$label] Passed (2-pass VP9, ${kbps}k, ${fps} FPS, try #$attempt_num): $fsize / $max_size bytes."
      return 0
    fi
  done

  local final_s
  final_s=$(get_filesize "$out")
  echo "[$label] WARNING: Could not shrink below $max_size bytes (best: $final_s bytes)."
  return 1
}

while IFS= read -r -d '' INPUT; do
  FULL_BASENAME=$(basename "$INPUT")
  BASENAME="${FULL_BASENAME%.*}"
  LOWER_NAME=$(echo "$FULL_BASENAME" | tr '[:upper:]' '[:lower:]')

  if [[ "$LOWER_NAME" == "tab.png" || "$LOWER_NAME" == "tab.gif" ]]; then
    echo "=== Processing SPECIAL: $FULL_BASENAME -> LINE tab.png ==="
    ffmpeg -nostdin -y -v error -i "$INPUT" -vf "scale=96:74,format=rgba" -frames:v 1 "$OUTPUT_DIR/line/tab.png"
    mv "$INPUT" "$PROCESSED_DIR/"
    continue
  fi

  if [[ "$LOWER_NAME" == "cover.png" || "$LOWER_NAME" == "cover.gif" ]]; then
    echo "=== Processing SPECIAL: $FULL_BASENAME -> WECHAT cover.png ==="
    ffmpeg -nostdin -y -v error -i "$INPUT" -vf "scale=240:240,format=rgba" -frames:v 1 "$OUTPUT_DIR/wechat/cover.png"
    mv "$INPUT" "$PROCESSED_DIR/"
    continue
  fi

  if [[ "$LOWER_NAME" == "icon.png" || "$LOWER_NAME" == "icon.gif" ]]; then
    echo "=== Processing SPECIAL: $FULL_BASENAME -> WECHAT icon.png ==="
    ffmpeg -nostdin -y -v error -i "$INPUT" -vf "scale=50:50,format=rgba" -frames:v 1 "$OUTPUT_DIR/wechat/icon.png"
    mv "$INPUT" "$PROCESSED_DIR/"
    continue
  fi

  EXT="${FULL_BASENAME##*.}"
  LOWER_EXT=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')
  if [ "$LOWER_EXT" == "png" ]; then
    NB_FRAMES=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=noprint_wrappers=1:nokey=1 "$INPUT" 2>/dev/null | head -n1)
    if [ -z "$NB_FRAMES" ] || [ "$NB_FRAMES" -le 1 ] 2>/dev/null; then
      echo "Skipping static non-special PNG file: $FULL_BASENAME"
      mv "$INPUT" "$PROCESSED_DIR/"
      continue
    fi
  fi

  IS_MAIN=0
  if [ "$LOWER_NAME" == "main.gif" ]; then
    IS_MAIN=1
    echo "=== Processing SPECIAL: $FULL_BASENAME (LINE main) ==="
  else
    echo "=== Processing: $FULL_BASENAME ==="
  fi

  MAX_WA=$((500 * 1024))
  MAX_WC=$((500 * 1024))
  MAX_TG=$((256 * 1024))
  MAX_SIG=$((300 * 1024))

  if [ "$IS_MAIN" -eq 1 ]; then
    MAX_LINE=$((1000 * 1024))
    LINE_SCALE="240:240"
  else
    MAX_LINE=$((300 * 1024))
    LINE_SCALE="320:270"
  fi

  OUT_WA="$OUTPUT_DIR/whatsapp/${BASENAME}_whatsapp.gif"
  OUT_WC="$OUTPUT_DIR/wechat/${BASENAME}_wechat.gif"
  OUT_TG="$OUTPUT_DIR/telegram/${BASENAME}_telegram.webm"
  OUT_SIG="$OUTPUT_DIR/signal/${BASENAME}_signal.png"
  if [ "$IS_MAIN" -eq 1 ]; then
    OUT_LINE="$OUTPUT_DIR/line/main.png"
  else
    OUT_LINE="$OUTPUT_DIR/line/${BASENAME}_line.png"
  fi

  # Probe duration and FPS once
  DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$INPUT" 2>/dev/null)
  if [ -z "$DUR" ] || [ "$DUR" == "N/A" ]; then DUR="2.0"; fi

  RAW_FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$INPUT" 2>/dev/null | head -n1)
  ORIG_FPS=$(awk -v r="$RAW_FPS" 'BEGIN {
    split(r, a, "/");
    if (a[2] > 0) {
      f = int(a[1] / a[2] + 0.5);
    } else if (a[1] > 0) {
      f = int(a[1] + 0.5);
    } else {
      f = 15;
    }
    if (f < 5) f = 5;
    if (f > 60) f = 60;
    print f;
  }')

  CAP_FPS="$ORIG_FPS"
  if [ "$CAP_FPS" -gt 30 ]; then CAP_FPS=30; fi

  HALF_FPS=$((ORIG_FPS / 2))
  if [ "$HALF_FPS" -lt 5 ]; then HALF_FPS=5; fi
  CAP_HALF_FPS=$((CAP_FPS / 2))
  if [ "$CAP_HALF_FPS" -lt 5 ]; then CAP_HALF_FPS=5; fi

  LINE_DUR=$(awk -v d="$DUR" 'BEGIN {
    r = int(d + 0.5);
    if (r <= 1) r = 1;
    else if (r <= 2) r = 2;
    else if (r <= 3) r = 3;
    else r = 4;
    print r;
  }')
  LINE_FPS=$CAP_FPS
  TOTAL_FRAMES=$((LINE_FPS * LINE_DUR))
  if [ "$TOTAL_FRAMES" -gt 20 ]; then
    LINE_FPS=$((20 / LINE_DUR))
  elif [ "$TOTAL_FRAMES" -lt 5 ]; then
    LINE_FPS=$(((5 + LINE_DUR - 1) / LINE_DUR))
  fi
  LINE_PLAYS=$((4 / LINE_DUR))
  LINE_SETPTS="setpts=(${LINE_DUR}/${DUR})*PTS"

  WORK_DIR=$(mktemp -d)
  echo "Normalizing source once (${ORIG_FPS} FPS, ${DUR}s)..."

  # Decode & pre-scale ONCE per target resolution
  if [ "$IS_MAIN" -eq 0 ]; then
    ffmpeg -nostdin -y -v error -i "$INPUT" \
      -vf "fps=${ORIG_FPS},scale=512:512:flags=lanczos:force_original_aspect_ratio=decrease,pad=512:512:(ow-iw)/2:(oh-ih)/2:color=0x00000000" \
      -c:v utvideo -pix_fmt rgba "$WORK_DIR/src_512.mkv"

    ffmpeg -nostdin -y -v error -i "$WORK_DIR/src_512.mkv" \
      -vf "scale=240:240:flags=lanczos:force_original_aspect_ratio=decrease,scale='trunc(iw/2)*2':'trunc(ih/2)*2'" \
      -c:v utvideo -pix_fmt rgba "$WORK_DIR/src_240.mkv"

    ffmpeg -nostdin -y -v error -i "$WORK_DIR/src_512.mkv" -t 3 \
      -vf "fps=${CAP_FPS}" \
      -c:v utvideo -pix_fmt rgba "$WORK_DIR/src_512_3s.mkv"
  fi

  ffmpeg -nostdin -y -v error -i "$INPUT" \
    -vf "${LINE_SETPTS},fps=${LINE_FPS},scale=${LINE_SCALE}:flags=lanczos:force_original_aspect_ratio=decrease,scale='trunc(iw/2)*2':'trunc(ih/2)*2'" \
    -t "$LINE_DUR" -c:v utvideo -pix_fmt rgba "$WORK_DIR/src_line.mkv"

  # Run platform conversions in parallel
  PIDS=()

  if [ "$IS_MAIN" -eq 0 ]; then
    (
      optimize_gif "WhatsApp" "$WORK_DIR/src_512.mkv" "$OUT_WA" "$MAX_WA" "$ORIG_FPS" "$HALF_FPS" "$WORK_DIR" \
        > "$WORK_DIR/log_wa.txt" 2>&1 || touch "$WORK_DIR/fail_wa"
    ) & PIDS+=($!)

    (
      optimize_gif "WeChat" "$WORK_DIR/src_240.mkv" "$OUT_WC" "$MAX_WC" "$ORIG_FPS" "$HALF_FPS" "$WORK_DIR" \
        > "$WORK_DIR/log_wc.txt" 2>&1 || touch "$WORK_DIR/fail_wc"
    ) & PIDS+=($!)

    (
      optimize_webm "Telegram" "$WORK_DIR/src_512_3s.mkv" "$OUT_TG" "$MAX_TG" "$DUR" "$CAP_FPS" "$WORK_DIR" \
        > "$WORK_DIR/log_tg.txt" 2>&1 || touch "$WORK_DIR/fail_tg"
    ) & PIDS+=($!)

    (
      optimize_apng "Signal" "$WORK_DIR/src_512_3s.mkv" "$OUT_SIG" "$MAX_SIG" "$CAP_FPS" "$CAP_HALF_FPS" "3" "0" "0" "0" "0" "$WORK_DIR" \
        > "$WORK_DIR/log_sig.txt" 2>&1 || touch "$WORK_DIR/fail_sig"
    ) & PIDS+=($!)
  fi

  (
    optimize_apng "LINE" "$WORK_DIR/src_line.mkv" "$OUT_LINE" "$MAX_LINE" "$LINE_FPS" "1" "$LINE_DUR" "$LINE_PLAYS" "5" "20" "$LINE_DUR" "$WORK_DIR" \
      > "$WORK_DIR/log_line.txt" 2>&1 || touch "$WORK_DIR/fail_line"
  ) & PIDS+=($!)

  for pid in "${PIDS[@]}"; do
    wait "$pid"
  done

  for logf in "$WORK_DIR/log_wa.txt" "$WORK_DIR/log_wc.txt" "$WORK_DIR/log_tg.txt" "$WORK_DIR/log_sig.txt" "$WORK_DIR/log_line.txt"; do
    if [ -f "$logf" ]; then
      cat "$logf"
    fi
  done

  for failf in "$WORK_DIR"/fail_*; do
    if [ -e "$failf" ]; then
      FAILED_CONVERSIONS=$((FAILED_CONVERSIONS + 1))
    fi
  done

  rm -rf "$WORK_DIR"
  mv "$INPUT" "$PROCESSED_DIR/"
  echo "Finished $BASENAME."

done < <(find "$INPUT_DIR" -maxdepth 3 -type f \( -iname "*.gif" -o -iname "*.png" \) ! -path "$PROCESSED_DIR/*" ! -path "*/__MACOSX/*" ! -name ".*" -print0)

echo "=== All Stickers Processed! ==="
if [ "$FAILED_CONVERSIONS" -gt 0 ]; then
  echo "WARNING: $FAILED_CONVERSIONS conversions exceeded platform size limits."
fi

if [ -n "$PUID" ] && [ -n "$PGID" ]; then
  chown -R "$PUID:$PGID" "$OUTPUT_DIR"
  chown -R "$PUID:$PGID" "$PROCESSED_DIR"
fi
