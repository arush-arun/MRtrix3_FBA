#!/bin/bash

# Reset FBA preprocessing from step 4 onwards
# Keeps: data.mif, dwi_denoised.mif, noise.mif, residual.mif, dwi_unr.mif, SNR files
# Deletes: PE pair files, dwifslpreproc outputs, bias correction, upsample, mask, response functions
# Also clears corresponding checkpoints

set -euo pipefail

# Update these paths for your environment
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$(dirname "$0")")}"
DERIVATIVES="${PROJECT_DIR}/derivatives"
CHECKPOINTS="${PROJECT_DIR}/fba_checkpoints"
PARTICIPANT_LIST="${PROJECT_DIR}/scripts/participant_list_ses01.txt"
SESSION="ses-01"

if [[ ! -f "$PARTICIPANT_LIST" ]]; then
    echo "ERROR: Participant list not found: $PARTICIPANT_LIST"
    exit 1
fi

SUBJECTS=()
while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    SUBJECTS+=("sub-${line}")
done < "$PARTICIPANT_LIST"

echo "Will reset steps 4-9 for ${#SUBJECTS[@]} subjects"
echo "Press Ctrl+C to cancel, Enter to continue..."
read

for subject in "${SUBJECTS[@]}"; do
    out="${DERIVATIVES}/${subject}/${SESSION}/dwi"

    if [[ ! -d "$out" ]]; then
        echo "SKIP: $subject (no derivatives directory)"
        continue
    fi

    echo "Resetting ${subject}..."

    # Delete step 4 outputs (PE pair prep)
    rm -f "${out}/ap_b0s.mif" "${out}/ap_b0_ref.mif"
    rm -f "${out}/ap_b0.mif" "${out}/dwi_bzero.mif" "${out}/dwi_mean_bzero.mif"
    rm -f "${out}/pa_b0_raw.mif" "${out}/pa_b0_3d.mif" "${out}/pa_b0.mif"
    rm -f "${out}/pa_mean_bzero.mif" "${out}/blipped_data.mif" "${out}/blipped_mean_bzero.mif"
    rm -f "${out}/bzero_cat.mif"
    rm -f "${out}/se_epi_pe_table.txt"

    # Delete step 5 outputs (dwifslpreproc)
    rm -f "${out}/dwi_preproc.mif"
    rm -rf "${out}/eddyqc"

    # Delete step 6 outputs (bias correction)
    rm -f "${out}/dwi_unbiased_preproc.mif" "${out}/bias.mif"

    # Delete step 7 outputs (upsample)
    rm -f "${out}/dwi_upsampled.mif"

    # Delete step 8 outputs (brain mask)
    rm -f "${out}/dwi_upsampled_meanb0.nii.gz"
    rm -f "${out}/dwi_bet.nii.gz" "${out}/dwi_bet_mask.nii.gz" "${out}/dwi_bet_mask.mif"
    rm -f "${out}/dwi_unbiased_preproc_upsampled.nii.gz"
    rm -f "${out}/dwi_unbiased_preproc_upsampled.mif"
    rm -f "${out}/dwi_bet_mask_use.mif"

    # Delete step 9 outputs (response functions)
    rm -f "${out}/wm.txt" "${out}/gm.txt" "${out}/csf.txt" "${out}/voxels.mif"

    # Clear checkpoints for steps 4-9
    rm -f "${CHECKPOINTS}/${subject}_prepair.done"
    rm -f "${CHECKPOINTS}/${subject}_preproc.done"
    rm -f "${CHECKPOINTS}/${subject}_bias.done"
    rm -f "${CHECKPOINTS}/${subject}_upsample.done"
    rm -f "${CHECKPOINTS}/${subject}_mask.done"
    rm -f "${CHECKPOINTS}/${subject}_response.done"

    echo "  Done: ${subject}"
done

echo ""
echo "Reset complete. Steps 1-3 checkpoints and outputs preserved."
echo "Remaining files per subject: data.mif, dwi_denoised.mif, noise.mif, residual.mif, dwi_unr.mif"
