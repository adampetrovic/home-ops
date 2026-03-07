#!/usr/bin/env bash
set -Eeuo pipefail

# ──────────────────────────────────────────────────────────────
# Post-conversion helper for WMV → MP4 conversion.
# Run on the NAS after the Kubernetes Job completes.
#
# Usage:
#   ./convert-wmv.sh --compare     # Show size comparison
#   ./convert-wmv.sh --cleanup     # Remove WMVs that have an MP4
# ──────────────────────────────────────────────────────────────

MEDIA_DIR="/volume2/stash/media/external"
COMPARE=false
CLEANUP=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Post-conversion helper — compare or clean up WMV files.

Options:
  --compare     Show file size comparison between WMV and MP4 pairs
  --cleanup     Delete WMV files that already have an MP4 counterpart
  --dir PATH    Override media directory (default: $MEDIA_DIR)
  -h, --help    Show this help
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --compare)  COMPARE=true; shift ;;
        --cleanup)  CLEANUP=true; shift ;;
        --dir)      MEDIA_DIR="$2"; shift 2 ;;
        -h|--help)  usage ;;
        *)          echo "Unknown option: $1"; usage ;;
    esac
done

if ! $COMPARE && ! $CLEANUP; then
    usage
fi

human_size() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        printf "%.2f GB" "$(echo "scale=2; $bytes / 1073741824" | bc)"
    elif (( bytes >= 1048576 )); then
        printf "%.1f MB" "$(echo "scale=1; $bytes / 1048576" | bc)"
    else
        printf "%.1f KB" "$(echo "scale=1; $bytes / 1024" | bc)"
    fi
}

if $COMPARE; then
    echo "=== Size Comparison (WMV → MP4) ==="
    echo ""
    total_wmv=0
    total_mp4=0
    pairs=0
    orphans=0

    while IFS= read -r -d '' wmv_file; do
        mp4_file="${wmv_file%.*}.mp4"
        rel_path="${wmv_file#"$MEDIA_DIR"/}"

        if [[ -f "$mp4_file" ]]; then
            wmv_size=$(stat -c%s "$wmv_file" 2>/dev/null || stat -f%z "$wmv_file")
            mp4_size=$(stat -c%s "$mp4_file" 2>/dev/null || stat -f%z "$mp4_file")
            ratio=$(echo "scale=1; $mp4_size * 100 / $wmv_size" | bc)
            printf "  %-60s  %10s → %10s  (%s%%)\n" \
                "$rel_path" "$(human_size "$wmv_size")" "$(human_size "$mp4_size")" "$ratio"
            total_wmv=$((total_wmv + wmv_size))
            total_mp4=$((total_mp4 + mp4_size))
            ((pairs++))
        else
            printf "  %-60s  %10s    NO MP4\n" \
                "$rel_path" "$(human_size "$(stat -c%s "$wmv_file" 2>/dev/null || stat -f%z "$wmv_file")")"
            ((orphans++))
        fi
    done < <(find "$MEDIA_DIR" -iname "*.wmv" -type f -print0 | sort -z)

    echo ""
    if (( pairs > 0 )); then
        overall_ratio=$(echo "scale=1; $total_mp4 * 100 / $total_wmv" | bc)
        echo "  $pairs converted: $(human_size $total_wmv) → $(human_size $total_mp4) ($overall_ratio% of original)"
    fi
    if (( orphans > 0 )); then
        echo "  $orphans WMV files without MP4 (not yet converted or failed)"
    fi
    exit 0
fi

if $CLEANUP; then
    echo "=== Cleanup: Removing WMV files with MP4 counterparts ==="
    removed=0
    freed=0

    while IFS= read -r -d '' wmv_file; do
        mp4_file="${wmv_file%.*}.mp4"
        if [[ -f "$mp4_file" ]]; then
            wmv_size=$(stat -c%s "$wmv_file" 2>/dev/null || stat -f%z "$wmv_file")
            rel_path="${wmv_file#"$MEDIA_DIR"/}"
            echo "  Removing: $rel_path ($(human_size "$wmv_size"))"
            rm -- "$wmv_file"
            freed=$((freed + wmv_size))
            ((removed++))
        fi
    done < <(find "$MEDIA_DIR" -iname "*.wmv" -type f -print0 | sort -z)

    echo ""
    echo "  Removed $removed files, freed $(human_size $freed)"
    exit 0
fi
