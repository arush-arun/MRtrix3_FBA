#!/usr/bin/env bash

# Enhanced FBA Preprocessing Visual QC
#
# Usage:
#   bash review_fba_qc_enhanced.sh <derivatives_dir> <participant_list> [session] [opacity]
#
# Example (single session):
#   bash review_fba_qc_enhanced.sh /path/to/derivatives \
#        /path/to/scripts/participant_list_ses02.txt ses-02
#
# Example (mixed sessions — use session|subject format in participant list):
#   bash review_fba_qc_enhanced.sh /path/to/derivatives \
#        /path/to/scripts/participant_list_enhanced_review.txt
#
# For each subject, launches mrview with 8 sequential views:
#   1. Raw DWI (data.mif) — check acquisition quality, signal dropout
#   2. DWI upsampled + brain mask overlay — mask completeness
#   3. RMS denoising residual — anatomical leakage check
#   4. Gibbs correction diff (denoised - unringed) — verify ringing removed at edges
#   5. Eddy correction diff (unringed - preproc) — distortion/motion correction
#   6. Bias field — should be smooth, low-frequency
#   7. Pre vs post bias correction (preproc vs unbiased) — intensity uniformity
#   8. Response function voxels overlay — tissue segmentation sanity check
#
# Close mrview to advance to next view. Ctrl+C to quit.

# ── Environment ──────────────────────────────────────────────
module use /sw/local/rocky8/noarch/neuro/software/neurocommand/local/containers/modules/
export APPTAINER_BINDPATH=/scratch,/QRISdata
ml mrtrix/3.0.8

# ── Arguments ────────────────────────────────────────────────
DERIV="${1:?Usage: $0 <derivatives_dir> <participant_list> [session] [opacity]}"
LIST="${2:?Usage: $0 <derivatives_dir> <participant_list> [session] [opacity]}"
SESSION="${3:-ses-01}"
OPACITY="${4:-0.4}"

# ── Pre-checks ───────────────────────────────────────────────
if [[ -z "${DISPLAY:-}" ]]; then
  echo "ERROR: DISPLAY is empty. Use an X/desktop session." >&2
  exit 1
fi
if ! command -v mrview >/dev/null 2>&1; then
  echo "ERROR: mrview not found on PATH." >&2
  exit 1
fi

echo "============================================================"
echo " Enhanced FBA Preprocessing QC"
echo " Derivatives: $DERIV"
echo " Session:     $SESSION"
echo "============================================================"

# Clean list: drop blanks and comments, trim whitespace
CLEAN_LIST="$(mktemp)"
trap 'rm -f "$CLEAN_LIST"' EXIT
sed -e 's/^[[:space:]]*//;s/[[:space:]]*$//' "$LIST" | grep -vE '^(#|$)' > "$CLEAN_LIST"
count=$(wc -l < "$CLEAN_LIST" | tr -d '[:space:]')
echo "Found $count subjects. Close mrview to advance. Ctrl+C to quit."
echo ""

# ── Helper: show a view or skip with message ─────────────────
show_view() {
  local view_num="$1" total_views="$2" label="$3" hint="$4"
  shift 4
  # remaining args are mrview command
  echo "  -> [View ${view_num}/${total_views}] ${label}"
  [[ -n "$hint" ]] && echo "     QC: ${hint}"
  "$@"
}

i=0
while IFS= read -r raw; do
  i=$((i+1))

  # Support two formats:
  #   "session|subject"  (e.g. ses-02|031) — session per line, overrides $SESSION
  #   "subject"          (e.g. 031 or sub-031) — uses $SESSION argument
  if [[ "$raw" == *"|"* ]]; then
    line_session="${raw%%|*}"
    raw_sub="${raw##*|}"
  else
    line_session="$SESSION"
    raw_sub="$raw"
  fi

  # Ensure sub- prefix
  if [[ "$raw_sub" == sub-* ]]; then sid="$raw_sub"; else sid="sub-$raw_sub"; fi

  dwidir="$DERIV/$sid/$line_session/dwi"

  # ── File paths ─────────────────────────────────────────────
  raw_dwi="$dwidir/data.mif"
  denoised="$dwidir/dwi_denoised.mif"
  noise="$dwidir/noise.mif"
  residual="$dwidir/residual.mif"
  unringed="$dwidir/dwi_unr.mif"
  preproc="$dwidir/dwi_preproc.mif"
  unbiased="$dwidir/dwi_unbiased_preproc.mif"
  bias="$dwidir/bias.mif"
  upsampled="$dwidir/dwi_upsampled.mif"
  mask="$dwidir/dwi_mask.mif"
  voxels="$dwidir/voxels.mif"

  # Derived QC maps (computed on first run, reused afterwards)
  rms_residual="$dwidir/rms_residual.mif"
  gibbs_diff="$dwidir/qc_gibbs_diff.mif"
  eddy_diff="$dwidir/qc_eddy_diff.mif"
  bias_ratio="$dwidir/qc_bias_ratio.mif"

  TOTAL_VIEWS=8

  echo ""
  echo "============================================================"
  echo "[$i/$count] $sid ($line_session)"
  echo "============================================================"

  if [[ ! -d "$dwidir" ]]; then
    echo "  -> Directory not found: $dwidir — skipping"
    continue
  fi

  # ── View 1: Raw DWI ────────────────────────────────────────
  if [[ -f "$raw_dwi" ]]; then
    show_view 1 $TOTAL_VIEWS "Raw DWI (data.mif)" \
      "Check for signal dropout, banding, gross artifacts" \
      mrview "$raw_dwi"
  else
    echo "  -> [View 1/$TOTAL_VIEWS] Raw DWI not found — skipping"
  fi

  # ── View 2: Upsampled DWI + brain mask ─────────────────────
  # Find best available DWI for mask overlay
  dwi_for_mask="$upsampled"
  if [[ ! -f "$dwi_for_mask" ]]; then
    for fallback in "$unbiased" "$preproc"; do
      if [[ -f "$fallback" ]]; then dwi_for_mask="$fallback"; break; fi
    done
  fi

  if [[ -f "$dwi_for_mask" ]]; then
    if [[ -f "$mask" ]]; then
      show_view 2 $TOTAL_VIEWS "DWI + brain mask" \
        "Check mask covers full brain — cerebellum, temporal lobes (7T dropout areas)" \
        mrview "$dwi_for_mask" -overlay.load "$mask" -overlay.opacity "$OPACITY"
    else
      show_view 2 $TOTAL_VIEWS "DWI (no mask available)" "" \
        mrview "$dwi_for_mask"
    fi
  else
    echo "  -> [View 2/$TOTAL_VIEWS] No DWI found — skipping"
  fi

  # ── View 3: RMS denoising residual ─────────────────────────
  if [[ -f "$residual" ]]; then
    if [[ ! -f "$rms_residual" ]]; then
      echo "  -> Computing RMS residual..."
      mrmath "$residual" rms -axis 3 "$rms_residual" -force
    fi
    show_view 3 $TOTAL_VIEWS "RMS denoising residual" \
      "Should be spatially uniform noise. Anatomical structure = denoising failure" \
      mrview "$rms_residual"
  else
    echo "  -> [View 3/$TOTAL_VIEWS] No residual map — skipping"
  fi

  # ── View 4: Gibbs de-ringing difference ────────────────────
  if [[ -f "$denoised" && -f "$unringed" ]]; then
    if [[ ! -f "$gibbs_diff" ]]; then
      echo "  -> Computing Gibbs correction difference (denoised - unringed)..."
      # Extract first volume for cleaner comparison
      mrconvert "$denoised" -coord 3 0 "${dwidir}/qc_denoised_v0.mif" -force
      mrconvert "$unringed" -coord 3 0 "${dwidir}/qc_unringed_v0.mif" -force
      mrcalc "${dwidir}/qc_denoised_v0.mif" "${dwidir}/qc_unringed_v0.mif" \
        -subtract -abs "$gibbs_diff" -force
      rm -f "${dwidir}/qc_denoised_v0.mif" "${dwidir}/qc_unringed_v0.mif"
    fi
    show_view 4 $TOTAL_VIEWS "Gibbs de-ringing difference |denoised - unringed|" \
      "Signal at tissue edges/ventricles = ringing removed. Signal in parenchyma = possible artifact" \
      mrview "$gibbs_diff"
  else
    echo "  -> [View 4/$TOTAL_VIEWS] Missing denoised/unringed — skipping"
  fi

  # ── View 5: Eddy correction difference ─────────────────────
  if [[ -f "$unringed" && -f "$preproc" ]]; then
    if [[ ! -f "$eddy_diff" ]]; then
      echo "  -> Computing eddy correction difference (unringed - preproc)..."
      mrconvert "$unringed" -coord 3 0 "${dwidir}/qc_unr_v0.mif" -force
      mrconvert "$preproc" -coord 3 0 "${dwidir}/qc_preproc_v0.mif" -force
      mrcalc "${dwidir}/qc_unr_v0.mif" "${dwidir}/qc_preproc_v0.mif" \
        -subtract -abs "$eddy_diff" -force
      rm -f "${dwidir}/qc_unr_v0.mif" "${dwidir}/qc_preproc_v0.mif"
    fi
    show_view 5 $TOTAL_VIEWS "Eddy correction difference |pre - post eddy|" \
      "Large changes at brain edges = distortion correction. Internal changes = motion correction" \
      mrview "$eddy_diff"
  else
    echo "  -> [View 5/$TOTAL_VIEWS] Missing unringed/preproc — skipping"
  fi

  # ── View 6: Bias field ─────────────────────────────────────
  if [[ -f "$bias" ]]; then
    show_view 6 $TOTAL_VIEWS "Bias field" \
      "Should be smooth, low-frequency. Sharp features or bright spots = overcorrection" \
      mrview "$bias"
  else
    echo "  -> [View 6/$TOTAL_VIEWS] No bias field — skipping"
  fi

  # ── View 7: Bias correction effect ─────────────────────────
  if [[ -f "$preproc" && -f "$unbiased" ]]; then
    if [[ ! -f "$bias_ratio" ]]; then
      echo "  -> Computing bias correction ratio (unbiased / preproc)..."
      mrconvert "$preproc" -coord 3 0 "${dwidir}/qc_preproc_b0.mif" -force
      mrconvert "$unbiased" -coord 3 0 "${dwidir}/qc_unbiased_b0.mif" -force
      # Ratio map: values near 1 = little change, deviations = correction applied
      mrcalc "${dwidir}/qc_unbiased_b0.mif" "${dwidir}/qc_preproc_b0.mif" \
        -div "$bias_ratio" -force
      rm -f "${dwidir}/qc_preproc_b0.mif" "${dwidir}/qc_unbiased_b0.mif"
    fi
    show_view 7 $TOTAL_VIEWS "Bias correction ratio (unbiased / preproc)" \
      "Values ~1.0 everywhere = minimal correction. Smooth gradient = expected B1 correction" \
      mrview "$bias_ratio"
  else
    echo "  -> [View 7/$TOTAL_VIEWS] Missing preproc/unbiased — skipping"
  fi

  # ── View 8: Response function voxels ───────────────────────
  if [[ -f "$voxels" && -f "$dwi_for_mask" ]]; then
    show_view 8 $TOTAL_VIEWS "Response function voxels (WM=blue, GM=green, CSF=red)" \
      "WM voxels in deep WM, GM at cortex, CSF in ventricles. Misplaced voxels = concern" \
      mrview "$dwi_for_mask" -overlay.load "$voxels" -overlay.opacity 0.6
  else
    echo "  -> [View 8/$TOTAL_VIEWS] No voxels map — skipping"
  fi

  echo "  -> Done with $sid"
done < "$CLEAN_LIST"

echo ""
echo "============================================================"
echo "Done. Reviewed $i subjects."
echo "============================================================"
