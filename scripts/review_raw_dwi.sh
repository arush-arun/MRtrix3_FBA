#!/usr/bin/env bash

# Review raw DWI (data.mif) for specific subjects
# Usage: bash review_raw_dwi.sh
# Close mrview to advance to next subject. Ctrl+C to quit.

module use /sw/local/rocky8/noarch/neuro/software/neurocommand/local/containers/modules/
export APPTAINER_BINDPATH=/scratch,/QRISdata
ml mrtrix/3.0.8

DERIV="/scratch/user/uqahonne/als/MeDALS_DWI/derivatives"

if [[ -z "${DISPLAY:-}" ]]; then
  echo "ERROR: DISPLAY is empty. Use an X/desktop session." >&2
  exit 1
fi

# Subject list: session|subject
SUBJECTS=(
  "ses-02|sub-031"
  "ses-02|sub-035"
  "ses-02|sub-055"
  "ses-02|sub-141"
  "ses-02|sub-142"
  "ses-01|sub-053"
  "ses-01|sub-059"
  "ses-01|sub-060"
  "ses-01|sub-062"
  "ses-01|sub-064"
  "ses-01|sub-122"
  "ses-01|sub-126"
  "ses-01|sub-013"
  "ses-01|sub-034"
  "ses-01|sub-046"
  "ses-01|sub-133"
)

total=${#SUBJECTS[@]}
echo "Reviewing raw DWI (data.mif) for $total subjects"
echo "Close mrview to advance. Ctrl+C to quit."

i=0
for entry in "${SUBJECTS[@]}"; do
  i=$((i+1))
  ses="${entry%%|*}"
  sub="${entry##*|}"
  raw="$DERIV/$sub/$ses/dwi/data.mif"

  echo
  echo "[$i/$total] $sub ($ses)"

  if [[ -f "$raw" ]]; then
    echo "  -> Opening: $raw"
    mrview "$raw"
  else
    echo "  -> MISSING: $raw — skipping"
  fi
done

echo
echo "Done. Reviewed $i subjects."
