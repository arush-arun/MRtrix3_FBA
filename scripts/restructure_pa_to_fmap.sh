#!/bin/bash
# Restructure MeDALS BIDS: move PA b0 files from dwi/ to fmap/ as epi fieldmaps
#
# Usage: bash restructure_pa_to_fmap.sh
#
# This moves the single-volume PA b0 files from dwi/ into fmap/ and renames
# them from *_dir-PA_dwi.* to *_dir-PA_epi.* per BIDS convention.
# The JSON sidecar also gets an IntendedFor field pointing to the AP DWI.

BIDS_DIR="/home/uqahonne/uq/ALS/MeDALS_DWI/bids_data"

count=0
for pa_nii in "$BIDS_DIR"/sub-*/ses-*/dwi/*_dir-PA_dwi.nii.gz; do
    [[ -f "$pa_nii" ]] || continue

    dwi_dir=$(dirname "$pa_nii")
    ses_dir=$(dirname "$dwi_dir")
    fmap_dir="${ses_dir}/fmap"
    mkdir -p "$fmap_dir"

    # Extract subject and session
    sub=$(basename "$ses_dir" | sed 's|/.*||')
    sub=$(basename "$(dirname "$ses_dir")")
    ses=$(basename "$ses_dir")

    # Get the base filename and rename dwi -> epi
    base=$(basename "$pa_nii")
    epi_base=$(echo "$base" | sed 's/_dwi\.nii\.gz$/_epi.nii.gz/')

    # Move nii.gz
    mv "$pa_nii" "${fmap_dir}/${epi_base}"

    # Move and rename json
    pa_json="${pa_nii%.nii.gz}.json"
    if [[ -f "$pa_json" ]]; then
        epi_json=$(echo "$(basename "$pa_json")" | sed 's/_dwi\.json$/_epi.json/')

        # Find the AP DWI file for IntendedFor (BIDS relative path from subject root)
        ap_dwi=$(ls "$dwi_dir"/*_dir-AP_dwi.nii.gz 2>/dev/null | head -1)
        if [[ -n "$ap_dwi" ]]; then
            # IntendedFor is relative to subject directory
            intended_for=$(echo "$ap_dwi" | sed "s|.*/${sub}/||")

            # Add IntendedFor to JSON using python
            python3 -c "
import json, sys
with open('${pa_json}') as f:
    data = json.load(f)
data['IntendedFor'] = '${intended_for}'
with open('${fmap_dir}/${epi_json}', 'w') as f:
    json.dump(data, f, indent=4)
"
            rm "$pa_json"
        else
            # No AP found, just move the json as-is
            mv "$pa_json" "${fmap_dir}/${epi_json}"
        fi
    fi

    # Move bval and bvec (if they exist)
    for ext in bval bvec; do
        pa_file="${pa_nii%.nii.gz}.${ext}"
        if [[ -f "$pa_file" ]]; then
            epi_file=$(echo "$(basename "$pa_file")" | sed "s/_dwi\.${ext}$/_epi.${ext}/")
            mv "$pa_file" "${fmap_dir}/${epi_file}"
        fi
    done

    # Remove macOS ._ files if present
    rm -f "$dwi_dir"/._*dir-PA* 2>/dev/null

    count=$((count + 1))
    echo "  Moved: ${sub}/${ses} PA -> fmap/"
done

echo ""
echo "Done. Restructured ${count} PA b0 fieldmaps."
