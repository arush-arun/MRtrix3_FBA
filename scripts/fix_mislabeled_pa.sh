#!/bin/bash
# Fix mislabeled PA b0 files where the PA b0 is incorrectly labeled as dir-AP
# This script renames them to dir-PA and moves them to fmap/ as epi fieldmaps
#
# Usage: bash fix_mislabeled_pa.sh <subject_number> [subject_number ...]
#   e.g.: bash fix_mislabeled_pa.sh 118 121 122

BIDS_DIR="${BIDS_DIR:-$(dirname "$(dirname "$0")")/bids_data}"

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <subject_number> [subject_number ...]"
    echo "  e.g.: $0 118 121 122"
    exit 1
fi

for sub_num in "$@"; do
    sub="sub-${sub_num}"
    ses="ses-01"
    dwi_dir="${BIDS_DIR}/${sub}/${ses}/dwi"
    fmap_dir="${BIDS_DIR}/${sub}/${ses}/fmap"

    echo "=== ${sub}/${ses} ==="

    # Check the mislabeled PA file exists
    pa_nii="${dwi_dir}/${sub}_${ses}_acq-cmrrmbep2ddiffB0PA_dir-AP_dwi.nii.gz"
    if [[ ! -f "$pa_nii" ]]; then
        echo "  Mislabeled PA file not found, skipping"
        continue
    fi

    mkdir -p "$fmap_dir"

    # Find the real AP DWI for IntendedFor
    ap_dwi=$(ls "${dwi_dir}"/*_acq-cmrrmbep2ddiff9660b250030b10006b0_dir-AP_dwi.nii.gz 2>/dev/null | head -1)
    intended_for="${ses}/dwi/$(basename "$ap_dwi")"

    # Move and rename each extension
    for ext in nii.gz json bval bvec; do
        src="${dwi_dir}/${sub}_${ses}_acq-cmrrmbep2ddiffB0PA_dir-AP_dwi.${ext}"
        dst="${fmap_dir}/${sub}_${ses}_acq-cmrrmbep2ddiffB0PA_dir-PA_epi.${ext}"
        if [[ -f "$src" ]]; then
            mv "$src" "$dst"
            echo "  Moved: $(basename "$src") -> fmap/$(basename "$dst")"
        fi
    done

    # Add IntendedFor to JSON
    epi_json="${fmap_dir}/${sub}_${ses}_acq-cmrrmbep2ddiffB0PA_dir-PA_epi.json"
    if [[ -f "$epi_json" ]] && [[ -n "$ap_dwi" ]]; then
        python3 -c "
import json
with open('${epi_json}') as f:
    data = json.load(f)
data['IntendedFor'] = '${intended_for}'
with open('${epi_json}', 'w') as f:
    json.dump(data, f, indent=4)
"
        echo "  Added IntendedFor: ${intended_for}"
    fi

    echo ""
done

echo "Done. These subjects can now be added to the participant list for qsiprep."
