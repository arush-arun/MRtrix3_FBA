#!/usr/bin/env bash

# Usage:
#   ./review_fba_qc.sh /path/to/derivatives participant_list.txt [session] [opacity]
#
# participant_list.txt: one per line; either "sub-001" or "001"
# session default: ses-01
# opacity default: 0.4
#
# For each subject, launches mrview with:
#   1. Upsampled DWI + brain mask overlay
#   2. Denoising residuals (noise QC)
#   3. Bias field
# Close mrview to advance to next subject. Ctrl+C to quit.

#Load Neurodesk modules for MRtrix3, FSL
module use /sw/local/rocky8/noarch/neuro/software/neurocommand/local/containers/modules/
export APPTAINER_BINDPATH=/scratch,/QRISdata
ml mrtrix/3.0.8


DERIV="${1:?Usage: $0 <derivatives_dir> <participant_list> [session] [opacity]}"
LIST="${2:?Usage: $0 <derivatives_dir> <participant_list> [session] [opacity]}"
SESSION="${3:-ses-01}"
OPACITY="${4:-0.4}"

# Fail fast if GUI isn't available
if [[ -z "${DISPLAY:-}" ]]; then
  echo "ERROR: DISPLAY is empty. Use an X/desktop session." >&2
  exit 1
fi
if ! command -v mrview >/dev/null 2>&1; then
  echo "ERROR: mrview not found on PATH." >&2
  exit 1
fi

echo "Scanning: $DERIV"
echo "Session:  $SESSION"

# Clean list: drop blanks and comments, trim whitespace
CLEAN_LIST="$(mktemp)"
sed -e 's/^[[:space:]]*//;s/[[:space:]]*$//' "$LIST" | grep -vE '^(#|$)' > "$CLEAN_LIST"
count=$(wc -l < "$CLEAN_LIST" | tr -d '[:space:]')
echo "Found $count subjects in list. Close mrview to advance. Ctrl+C to quit."

i=0
while IFS= read -r raw; do
  i=$((i+1))
  # ensure sub- prefix
  if [[ "$raw" == sub-* ]]; then
    sid="$raw"
  else
    sid="sub-$raw"
  fi

  dwidir="$DERIV/$sid/$SESSION/dwi"

  # Key files from FBA preprocessing
  dwi_up="$dwidir/dwi_upsampled.mif"
  mask="$dwidir/dwi_mask.mif"
  residual="$dwidir/residual.mif"
  bias="$dwidir/bias.mif"
  dwi_preproc="$dwidir/dwi_preproc.mif"
  dwi_unbiased="$dwidir/dwi_unbiased_preproc.mif"

  echo
  echo "[$i/$count] $sid ($SESSION)"
  echo "  DWI upsampled : $dwi_up"
  echo "  Brain mask    : $mask"

  if [[ ! -f "$dwi_up" ]]; then
    # Fall back to pre-upsampled DWI
    if [[ -f "$dwi_unbiased" ]]; then
      echo "  -> No upsampled DWI, using unbiased preproc"
      dwi_up="$dwi_unbiased"
    elif [[ -f "$dwi_preproc" ]]; then
      echo "  -> No upsampled/unbiased DWI, using preproc"
      dwi_up="$dwi_preproc"
    else
      echo "  -> Missing DWI outputs. Skipping."
      continue
    fi
  fi

  # View 1: DWI + mask overlay
  echo "  -> [View 1/3] DWI + brain mask (opacity $OPACITY)"
  if [[ -f "$mask" ]]; then
    mrview "$dwi_up" -overlay.load "$mask" -overlay.opacity "$OPACITY"
  else
    echo "     (no mask found, showing DWI only)"
    mrview "$dwi_up"
  fi

  # View 2: Denoising residuals (RMS across volumes)
  # RMS collapses all volumes into one 3D map — anatomical leakage is much easier to spot
  if [[ -f "$residual" ]]; then
    rms_residual="$dwidir/rms_residual.mif"
    if [[ ! -f "$rms_residual" ]]; then
      echo "  -> Computing RMS residual..."
      mrmath "$residual" rms -axis 3 "$rms_residual" -force
    fi
    echo "  -> [View 2/3] RMS denoising residual (look for anatomical leakage)"
    mrview "$rms_residual"
  else
    echo "  -> [View 2/3] No residual map. Skipping."
  fi

  # View 3: Bias field
  if [[ -f "$bias" ]]; then
    echo "  -> [View 3/3] Bias field"
    mrview "$bias"
  else
    echo "  -> [View 3/3] No bias field. Skipping."
  fi

  echo "  -> Done with $sid. Moving on."
done < "$CLEAN_LIST"

rm -f "$CLEAN_LIST"
echo "Done. Reviewed $i subjects."
