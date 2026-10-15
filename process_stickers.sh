#!/bin/bash

# Accept optional input and output directory parameters from the Node server.
INPUT_DIR="${1:-"/input"}"
OUTPUT_DIR="${2:-"/output"}"
PROCESSED_DIR="$INPUT_DIR/processed"

mkdir -p "$PROCESSED_DIR" "$OUTPUT_DIR/whatsapp" "$OUTPUT_DIR/wechat" "$OUTPUT_DIR/telegram" "$OUTPUT_DIR/signal" "$OUTPUT_DIR/line"

FAILED_CONVERSIONS=0

GIF_COUNT=$(find "$INPUT_DIR" -type f \( -iname "*.gif" -o -iname "*.png" \) ! -path "*/__MACOSX/*" ! -name ".*" | wc -l)
if [ "$GIF_COUNT" -eq 0 ]; then
  echo "No target files found in $INPUT_DIR or its subdirectories."
  exit 0
fi

echo "Scanning $INPUT_DIR for target files..."

while IFS= read -r -d '' INPUT; do
  FULL_BASENAME=$(basename "$INPUT")
  BASENAME="${FULL_BASENAME%.*}"
  LOWER_NAME=$(echo "$FULL_BASENAME" | tr '[:upper:]' '[:lower:]')

  if [[ "$LOWER_NAME" == "tab.png" || "$LOWER_NAME" == "tab.gif" ]]; then
    echo "=== Processing SPECIAL: $FULL_BASENAME -> LINE tab.png ==="
    # confirm if 96x74, convert static, save only to line folder
    ffmpeg -nostdin -y -v error -i "$INPUT" -vf "scale=96:74,format=rgba" "$OUTPUT_DIR/line/tab.png"
    mv "$INPUT" "$PROCESSED_DIR/"
    echo "Moved $LOWER_NAME to processed folder."
    continue
  fi

  if [[ "$LOWER_NAME" == "cover.png" || "$LOWER_NAME" == "cover.gif" ]]; then
    echo "=== Processing SPECIAL: $FULL_BASENAME -> WECHAT cover.png ==="
    ffmpeg -nostdin -y -v error -i "$INPUT" -vf "scale=240:240,format=rgba" "$OUTPUT_DIR/wechat/cover.png"
    mv "$INPUT" "$PROCESSED_DIR/"
    echo "Moved $LOWER_NAME to processed folder."
    continue
  fi

  if [[ "$LOWER_NAME" == "icon.png" || "$LOWER_NAME" == "icon.gif" ]]; then
    echo "=== Processing SPECIAL: $FULL_BASENAME -> WECHAT icon.png ==="
    ffmpeg -nostdin -y -v error -i "$INPUT" -vf "scale=50:50,format=rgba" "$OUTPUT_DIR/wechat/icon.png"
    mv "$INPUT" "$PROCESSED_DIR/"
    echo "Moved $LOWER_NAME to processed folder."
    continue
  fi

  EXT="${FULL_BASENAME##*.}"
  LOWER_EXT=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')
  if [ "$LOWER_EXT" == "png" ]; then
    echo "Skipping non-special PNG file: $INPUT"
    mv "$INPUT" "$PROCESSED_DIR/"
    continue
  fi

  IS_MAIN=0
  if [ "$LOWER_NAME" == "main.gif" ]; then
    IS_MAIN=1
    echo "=== Processing SPECIAL: $FULL_BASENAME (LINE main) ==="
  else
    echo "=== Processing: $BASENAME ==="
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

  # GET NATIVE DURATION AND FPS
  DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$INPUT" 2>/dev/null)
  if [ -z "$DUR" ] || [ "$DUR" == "N/A" ]; then DUR="2.0"; fi
  
  RAW_FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$INPUT" 2>/dev/null | head -n1)
  if [ -n "$RAW_FPS" ] && [[ "$RAW_FPS" == *"/"* ]]; then
    NUM=$(echo $RAW_FPS | cut -d'/' -f1)
    DEN=$(echo $RAW_FPS | cut -d'/' -f2)
    if [ "$DEN" -ne 0 ]; then ORIG_FPS=$((NUM/DEN)); else ORIG_FPS=15; fi
  else
    ORIG_FPS=15
  fi
  
  if [ -z "$ORIG_FPS" ] || [ "$ORIG_FPS" -eq 0 ]; then ORIG_FPS=15; fi

  HALF_FPS=$((ORIG_FPS / 2))
  if [ "$HALF_FPS" -lt 5 ]; then HALF_FPS=5; fi
  THIRD_FPS=$((ORIG_FPS / 3))
  if [ "$THIRD_FPS" -lt 5 ]; then THIRD_FPS=5; fi

  # Ensure LINE strict duration (1, 2, 3, or 4 seconds)
  LINE_DUR=$(printf "%.0f" "$DUR")
  if [ "$LINE_DUR" -le 1 ]; then LINE_DUR=1
  elif [ "$LINE_DUR" -le 2 ]; then LINE_DUR=2
  elif [ "$LINE_DUR" -le 3 ]; then LINE_DUR=3
  else LINE_DUR=4; fi

  # BUILD FALLBACK ARRAY BASED ON EXACT RULES:
  CONFIGS=()
  
  # For each color level, drop fps 1 by 1 down to HALF_FPS (minimum 5).
  # We do not drop both colors and fps at the same time:
  # when color drops, we reset FPS to max and try reducing FPS again.
  for c in 128 64 32 16 8 4 2; do
    for (( f=ORIG_FPS; f>=HALF_FPS; f-- )); do
      # Adjust WebM bitrate based on color level approximation
      if [ "$c" -ge 64 ]; then rate="150k"
      elif [ "$c" -ge 16 ]; then rate="100k"
      else rate="50k"; fi
      
      CONFIGS+=("$c:$f:$rate")
    done
  done

  # Signal (APNG): finer color ladder starting at 256, so colors are reduced last and gradually
  APNG_CONFIGS=()
  for c in 256 224 192 160 128 96 64 48 32 16; do
    for (( f=ORIG_FPS; f>=HALF_FPS; f-- )); do
      APNG_CONFIGS+=("$c:$f:0")
    done
  done

  check_and_decimate() {
    local file=$1
    local max_size=$2
    local format=$3       
    local base=$4         
    local extra=$5        
    local filesize=$(wc -c < "$file" 2>/dev/null || echo 0)
    
    if [ "$filesize" -le "$max_size" ]; then
      echo "Size Check Passed: $file is $filesize bytes."
      return
    fi
    
    echo "Size Check Failed: $file is $filesize bytes. Executing strict scaling algorithm..."
    
    local success=0
    local CONF_LIST=("${CONFIGS[@]}")
    if [ "$format" == "apng" ]; then CONF_LIST=("${APNG_CONFIGS[@]}"); fi
    for CONF in "${CONF_LIST[@]}"; do
      if [ "$success" -eq 1 ]; then break; fi
      
      local colors=$(echo "$CONF" | cut -d':' -f1)
      local fps=$(echo "$CONF" | cut -d':' -f2)
      local rate=$(echo "$CONF" | cut -d':' -f3)

      if [ "$format" == "webm" ]; then
        echo "Trying WebM fallback: $fps FPS at $rate bitrate..."
        ffmpeg -nostdin -y -v error -i "$INPUT" -c:v libvpx-vp9 -b:v "$rate" -filter_complex "[0:v]scale=${base}:${base},fps=${fps}" $extra "$file"
        filesize=$(wc -c < "$file" 2>/dev/null || echo 0)
        if [ "$filesize" -le "$max_size" ]; then
           echo "Fallback Success: $file is $filesize bytes."
           success=1; break;
        fi
      else
        echo "Trying $format fallback: $colors colors at $fps FPS..."
        local comp_flag=""
        local dither="dither=bayer:bayer_scale=5"
        if [ "$format" == "apng" ]; then
          comp_flag="-pred mixed -compression_level 9 -f apng"
          # Dithering adds noise that PNG compresses poorly; sierra2_4a keeps smooth gradients with less noise
          dither="dither=sierra2_4a"
        fi
        
        ffmpeg -nostdin -y -v error -i "$INPUT" -filter_complex "[0:v]fps=${fps},scale=${base}:${base}:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=${colors}:stats_mode=diff[p];[s1][p]paletteuse=${dither}:diff_mode=rectangle" $comp_flag $extra "$file"
        filesize=$(wc -c < "$file" 2>/dev/null || echo 0)
        if [ "$filesize" -le "$max_size" ]; then
           echo "Fallback Success: $file is $filesize bytes."
           success=1; break;
        fi
      fi
    done
    
    if [ "$success" -eq 0 ]; then
      echo "WARNING: Could not shrink $file below $max_size"
      FAILED_CONVERSIONS=$((FAILED_CONVERSIONS + 1))
    fi
  }

  if [ "$IS_MAIN" -eq 0 ]; then
    echo "=== 1. WhatsApp ==="
    ffmpeg -nostdin -y -v error -i "$INPUT" -filter_complex "[0:v]fps=$ORIG_FPS,scale=512:512:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5" "$OUT_WA"
    check_and_decimate "$OUT_WA" "$MAX_WA" "gif" "512" ""

    echo "=== 2. WeChat ==="
    ffmpeg -nostdin -y -v error -i "$INPUT" -filter_complex "[0:v]fps=$ORIG_FPS,scale=240:240:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5" "$OUT_WC"
    check_and_decimate "$OUT_WC" "$MAX_WC" "gif" "240" ""

    echo "=== 3. Telegram ==="
    ffmpeg -nostdin -y -v error -i "$INPUT" -c:v libvpx-vp9 -b:v 200k -filter_complex "[0:v]fps=$ORIG_FPS,scale=512:512" -t 3 -an "$OUT_TG"
    check_and_decimate "$OUT_TG" "$MAX_TG" "webm" "512" "-t 3 -an"

    echo "=== 4. Signal ==="
    ffmpeg -nostdin -y -v error -i "$INPUT" -filter_complex "[0:v]fps=$ORIG_FPS,scale=512:512:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5" -pred mixed -compression_level 9 -t 3 -plays 0 -f apng "$OUT_SIG"
    check_and_decimate "$OUT_SIG" "$MAX_SIG" "apng" "512" "-t 3 -plays 0"
  fi

  echo "=== 5. Line ==="
  echo "Original duration detected as $DUR. Strict matching to LINE format: $LINE_DUR seconds."
  
  LINE_FPS=$ORIG_FPS
  TOTAL_FRAMES=$((LINE_FPS * LINE_DUR))
  if [ "$TOTAL_FRAMES" -gt 20 ]; then
    LINE_FPS=$(( 20 / LINE_DUR ))
  elif [ "$TOTAL_FRAMES" -lt 5 ]; then
    LINE_FPS=$(( (5 + LINE_DUR - 1) / LINE_DUR ))
  fi
  echo "Enforcing total frames constraint (5-20): calculated $LINE_FPS FPS for $LINE_DUR seconds."

  LINE_SETPTS="setpts='(${LINE_DUR}/${DUR})*PTS'"
  LINE_PLAYS=$(( 4 / LINE_DUR ))

  ffmpeg -nostdin -y -v error -i "$INPUT" -filter_complex "[0:v]${LINE_SETPTS},fps=$LINE_FPS,scale=${LINE_SCALE}:flags=lanczos:force_original_aspect_ratio=decrease,scale='trunc(iw/2)*2':'trunc(ih/2)*2',split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5" -pred mixed -compression_level 9 -t $LINE_DUR -plays $LINE_PLAYS -f apng "$OUT_LINE"
  
  # Strip unneeded metadata (pHYs, eXIf, etc.) to strictly satisfy LINE palette / exif requirements
  node -e "const fs=require('fs');const d=fs.readFileSync('$OUT_LINE');let out=[d.slice(0,8)];let i=8;while(i<d.length){let l=d.readUInt32BE(i);let t=d.toString('ascii',i+4,i+8);if(['IHDR','acTL','fcTL','fdAT','IDAT','IEND','PLTE','tRNS'].includes(t))out.push(d.slice(i,i+12+l));i+=12+l;}fs.writeFileSync('$OUT_LINE',Buffer.concat(out));"
  
  line_filesize=$(wc -c < "$OUT_LINE" 2>/dev/null || echo 0)
  if [ "$line_filesize" -gt "$MAX_LINE" ]; then
    echo "Line Size Check Failed: $OUT_LINE is $line_filesize. Checking fallbacks..."
    local success=0
    for CONF in "${CONFIGS[@]}"; do
      local colors=$(echo "$CONF" | cut -d':' -f1)
      local fps=$(echo "$CONF" | cut -d':' -f2)

      local cur_line_fps=$fps
      local total=$((cur_line_fps * LINE_DUR))
      if [ "$total" -gt 20 ]; then cur_line_fps=$(( 20 / LINE_DUR )); fi
      if [ "$total" -lt 5 ]; then cur_line_fps=$(( (5 + LINE_DUR - 1) / LINE_DUR )); fi

      echo "Trying Line fallback: $colors colors at $cur_line_fps FPS..."
      ffmpeg -nostdin -y -v error -i "$INPUT" -filter_complex "[0:v]${LINE_SETPTS},fps=${cur_line_fps},scale=${LINE_SCALE}:flags=lanczos:force_original_aspect_ratio=decrease,scale='trunc(iw/2)*2':'trunc(ih/2)*2',split[s0][s1];[s0]palettegen=max_colors=${colors}[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5" -pred mixed -compression_level 9 -t $LINE_DUR -plays $LINE_PLAYS -f apng "$OUT_LINE"
      
      # Strip unneeded metadata (pHYs, eXIf, etc.) again for fallbacks
      node -e "const fs=require('fs');const d=fs.readFileSync('$OUT_LINE');let out=[d.slice(0,8)];let i=8;while(i<d.length){let l=d.readUInt32BE(i);let t=d.toString('ascii',i+4,i+8);if(['IHDR','acTL','fcTL','fdAT','IDAT','IEND','PLTE','tRNS'].includes(t))out.push(d.slice(i,i+12+l));i+=12+l;}fs.writeFileSync('$OUT_LINE',Buffer.concat(out));"
      
      line_filesize=$(wc -c < "$OUT_LINE" 2>/dev/null || echo 0)
      if [ "$line_filesize" -le "$MAX_LINE" ]; then
        echo "Line Fallback Success: $OUT_LINE is $line_filesize bytes."
        success=1; break;
      fi
    done
    if [ "$success" -eq 0 ]; then
      echo "WARNING: Line Size Check STILL FAILED: $OUT_LINE is $line_filesize bytes."
      FAILED_CONVERSIONS=$((FAILED_CONVERSIONS + 1))
    fi
  else
    echo "Line Size Check Passed: $OUT_LINE is $line_filesize bytes."
  fi
  
  mv "$INPUT" "$PROCESSED_DIR/"
  echo "Moved $BASENAME to processed folder."

done < <(find "$INPUT_DIR" -type f \( -iname "*.gif" -o -iname "*.png" \) ! -path "*/__MACOSX/*" ! -name ".*" -print0)

echo "=== All Stickers Processed! ==="
if [ "$FAILED_CONVERSIONS" -gt 0 ]; then
  echo "WARNING: $FAILED_CONVERSIONS conversions failed size requirements."
fi

if [ -n "$PUID" ] && [ -n "$PGID" ]; then
  chown -R "$PUID:$PGID" "$OUTPUT_DIR"
  chown -R "$PUID:$PGID" "$PROCESSED_DIR"
fi