#!/bin/bash

# MeDALS DWI — MRtrix3 FBA Preprocessing Pipeline
# Adapted from MRtrix3_FBA/fba_enhanced_configurable.sh for MeDALS dataset
#
# Key differences from original FBA repo:
#   - PA b0 is in fmap/ directory (not dwi/) with _epi suffix
#   - Long acquisition label in filenames (glob-matched, not hardcoded)
#   - Session label is ses-01
#   - Designed for single-subject execution via SLURM array jobs
#
# Usage:
#   CONFIG_FILE=fba_config_medals.conf ./run_fba_preproc_medals.sh sub-001

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-$(dirname "$0")/fba_config_medals.conf}"

# =============================================================================
# CONFIGURATION
# =============================================================================

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "ERROR: Configuration file not found: $CONFIG_FILE"
        exit 1
    fi

    echo "Loading configuration from: $CONFIG_FILE"

    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        export "$line"
    done < <(grep -E '^[A-Z_].*=' "$CONFIG_FILE")

    # Set derived path
    if [[ "$DERIVATIVES_PATH" =~ ^/ ]]; then
        der_path="$DERIVATIVES_PATH"
    else
        der_path="${INPUT_PATH}/${DERIVATIVES_PATH}"
    fi

    echo "Configuration loaded: INPUT=$INPUT_PATH, DERIVATIVES=$der_path"
}

# =============================================================================
# CHECKPOINT FUNCTIONS
# =============================================================================

create_checkpoint() {
    [[ "$ENABLE_CHECKPOINTS" != "true" ]] && return 0
    local subject="$1" step="$2"
    mkdir -p "$CHECKPOINT_DIR"
    touch "${CHECKPOINT_DIR}/${subject}_${step}.done"
    echo "Checkpoint created: ${subject} - ${step}"
}

check_checkpoint() {
    [[ "$ENABLE_CHECKPOINTS" != "true" ]] && return 1
    local subject="$1" step="$2"
    [[ -f "${CHECKPOINT_DIR}/${subject}_${step}.done" ]]
}

# =============================================================================
# FILE DISCOVERY
# =============================================================================

# Find AP DWI files (in dwi/ directory) using glob matching
find_ap_files() {
    local subject="$1"
    local dwi_dir="${INPUT_PATH}/${subject}/${SESSION}/dwi"

    AP_NII=$(ls "${dwi_dir}"/${subject}_${SESSION}_*_dir-${MAIN_PE_DIR}_dwi.nii.gz 2>/dev/null | head -1)
    AP_BVAL=$(ls "${dwi_dir}"/${subject}_${SESSION}_*_dir-${MAIN_PE_DIR}_dwi.bval 2>/dev/null | head -1)
    AP_BVEC=$(ls "${dwi_dir}"/${subject}_${SESSION}_*_dir-${MAIN_PE_DIR}_dwi.bvec 2>/dev/null | head -1)
    AP_JSON=$(ls "${dwi_dir}"/${subject}_${SESSION}_*_dir-${MAIN_PE_DIR}_dwi.json 2>/dev/null | head -1)

    if [[ -z "$AP_NII" || -z "$AP_BVAL" || -z "$AP_BVEC" ]]; then
        echo "ERROR: Missing AP DWI files in $dwi_dir"
        return 1
    fi
    if [[ -z "$AP_JSON" ]]; then
        echo "WARNING: Missing AP JSON sidecar — readout time will use default"
    fi
    echo "AP DWI:  $AP_NII"
    echo "AP JSON: $AP_JSON"
}

# Find PA b0 files (in fmap/ directory) using glob matching
find_pa_files() {
    local subject="$1"
    local fmap_dir="${INPUT_PATH}/${subject}/${SESSION}/fmap"

    PA_NII=$(ls "${fmap_dir}"/${subject}_${SESSION}_*_dir-${BLIPPED_PE_DIR}_epi.nii.gz 2>/dev/null | head -1)
    PA_BVAL=$(ls "${fmap_dir}"/${subject}_${SESSION}_*_dir-${BLIPPED_PE_DIR}_epi.bval 2>/dev/null | head -1)
    PA_BVEC=$(ls "${fmap_dir}"/${subject}_${SESSION}_*_dir-${BLIPPED_PE_DIR}_epi.bvec 2>/dev/null | head -1)
    PA_JSON=$(ls "${fmap_dir}"/${subject}_${SESSION}_*_dir-${BLIPPED_PE_DIR}_epi.json 2>/dev/null | head -1)

    if [[ -z "$PA_NII" ]]; then
        echo "ERROR: Missing PA fieldmap in $fmap_dir"
        return 1
    fi
    echo "PA b0:   $PA_NII"
    echo "PA JSON: ${PA_JSON:-not found}"
}

# =============================================================================
# PREPROCESSING
# =============================================================================

process_subject() {
    local subject="$1"
    local out="${der_path}/${subject}/${SESSION}/dwi"

    echo "=============================================="
    echo "Processing ${subject}"
    echo "Start time: $(date)"
    echo "=============================================="

    # Discover input files
    find_ap_files "$subject" || exit 1
    find_pa_files "$subject" || exit 1

    mkdir -p "$out"

    # --- Step 1: Convert to MIF ---
    if check_checkpoint "$subject" "convert"; then
        echo "SKIP: conversion (checkpoint exists)"
    else
        echo "Step 1/9: Converting to MIF format"
        mrconvert "$AP_NII" "${out}/data.mif" \
            -fslgrad "$AP_BVEC" "$AP_BVAL" \
            -json_import "$AP_JSON" -force
        create_checkpoint "$subject" "convert"
    fi

    # --- Step 2: Denoise ---
    if check_checkpoint "$subject" "denoise"; then
        echo "SKIP: denoising (checkpoint exists)"
    else
        echo "Step 2/9: Denoising (MP-PCA)"
        dwidenoise "${out}/data.mif" "${out}/dwi_denoised.mif" \
            -noise "${out}/noise.mif" -force

        # Residual for QC
        mrcalc "${out}/data.mif" "${out}/dwi_denoised.mif" \
            -subtract "${out}/residual.mif" -force

        # SNR estimation
        dwiextract "${out}/data.mif" -no_bzero -singleshell "${out}/dwi_singleshell.mif" -force
        mrcalc "${out}/dwi_singleshell.mif" "${out}/noise.mif" \
            -div "${out}/snr.mif" -force

        # Approximate WM mask for SNR calculation
        dwiextract "${out}/data.mif" -no_bzero -singleshell - | \
            amp2sh - - | sh2power - -spectrum - | \
            mrconvert - -coord 3 1 - | \
            mrthreshold - "${out}/wm_mask.mif" -force

        SNR=$(mrstats "${out}/snr.mif" -mask "${out}/wm_mask.mif" -output mean -allvolumes)
        echo "${subject} SNR = ${SNR}"

        if (( $(echo "$SNR < $MIN_SNR" | bc -l 2>/dev/null || echo "0") )); then
            echo "WARNING: Low SNR for $subject: $SNR (threshold: $MIN_SNR)"
        fi

        create_checkpoint "$subject" "denoise"
    fi

    # --- Step 3: Gibbs unringing ---
    if check_checkpoint "$subject" "unring"; then
        echo "SKIP: Gibbs unringing (checkpoint exists)"
    else
        echo "Step 3/9: Gibbs ringing correction"
        mrdegibbs -axes 0,1 "${out}/dwi_denoised.mif" "${out}/dwi_unr.mif" -force
        create_checkpoint "$subject" "unring"
    fi

    # --- Step 4: Prepare PE pair for TOPUP/eddy ---
    if check_checkpoint "$subject" "prepair"; then
        echo "SKIP: PE pair preparation (checkpoint exists)"
    else
        echo "Step 4/9: Preparing b0 volumes for TOPUP/eddy"

        # Extract all AP b0s for TOPUP — more volumes give better field estimate
        # (TOPUP handles motion internally, no need to pre-average)
        dwiextract "${out}/dwi_unr.mif" "${out}/ap_b0s.mif" -bzero -force
        local n_ap_b0s
        n_ap_b0s=$(mrinfo "${out}/ap_b0s.mif" -size | awk '{print $4}')
        echo "Found ${n_ap_b0s} AP b0 volumes"

        # Convert PA b0 from fmap/ with JSON sidecar for PE metadata
        if [[ -n "${PA_BVAL:-}" && -f "${PA_BVAL}" && -n "${PA_BVEC:-}" && -f "${PA_BVEC}" ]]; then
            mrconvert "$PA_NII" "${out}/pa_b0_raw.mif" \
                -fslgrad "$PA_BVEC" "$PA_BVAL" \
                ${PA_JSON:+-json_import "$PA_JSON"} -force
        else
            mrconvert "$PA_NII" "${out}/pa_b0_raw.mif" \
                ${PA_JSON:+-json_import "$PA_JSON"} -force
        fi

        # Regrid PA b0 to match AP grid (PA often has different slice count)
        mrconvert "${out}/ap_b0s.mif" -coord 3 0 "${out}/ap_b0_ref.mif" -force
        mrgrid "${out}/pa_b0_raw.mif" regrid -template "${out}/ap_b0_ref.mif" \
            "${out}/pa_b0.mif" -force

        # Concatenate all AP b0s + PA b0 for TOPUP
        # First half (AP) matches main DWI PE direction, second half (PA) is reverse
        mrcat "${out}/ap_b0s.mif" "${out}/pa_b0.mif" \
            "${out}/bzero_cat.mif" -axis 3 -force
        echo "TOPUP input: $(mrinfo "${out}/bzero_cat.mif" -size)"

        create_checkpoint "$subject" "prepair"
    fi

    # --- Step 5: dwifslpreproc (eddy + TOPUP) ---
    if check_checkpoint "$subject" "preproc"; then
        echo "SKIP: dwifslpreproc (checkpoint exists)"
    else
        echo "Step 5/9: Motion and distortion correction (eddy + TOPUP)"

        dwifslpreproc "${out}/dwi_unr.mif" "${out}/dwi_preproc.mif" \
            -rpe_header \
            -se_epi "${out}/bzero_cat.mif" \
            -align_seepi \
            -eddy_options " --slm=linear --repol --cnr_maps --fep --data_is_shelled --ol_type=both --mb=2" \
            -eddyqc_all "${out}/eddyqc" \
            -force
        create_checkpoint "$subject" "preproc"
    fi

    # --- Step 6: Bias field correction ---
    if check_checkpoint "$subject" "bias"; then
        echo "SKIP: bias correction (checkpoint exists)"
    else
        echo "Step 6/9: Bias field correction (ANTs)"
        dwibiascorrect ants "${out}/dwi_preproc.mif" \
            "${out}/dwi_unbiased_preproc.mif" \
            -bias "${out}/bias.mif" -force
        create_checkpoint "$subject" "bias"
    fi

    # --- Step 7: Upsample ---
    if check_checkpoint "$subject" "upsample"; then
        echo "SKIP: upsampling (checkpoint exists)"
    else
        echo "Step 7/9: Upsampling to ${VOXEL_SIZE}mm isotropic"
        mrgrid "${out}/dwi_unbiased_preproc.mif" regrid \
            -vox "$VOXEL_SIZE" "${out}/dwi_upsampled.mif" -force
        create_checkpoint "$subject" "upsample"
    fi

    # --- Step 8: Brain mask ---
    if check_checkpoint "$subject" "mask"; then
        echo "SKIP: brain masking (checkpoint exists)"
    else
        echo "Step 8/9: Brain mask extraction (SynthStrip)"

        # Extract mean b0 from upsampled DWI
        dwiextract "${out}/dwi_upsampled.mif" - -bzero | \
            mrmath - mean "${out}/dwi_upsampled_meanb0.nii.gz" -axis 3 -force

        # SynthStrip — contrast-agnostic deep learning brain extraction
        mri_synthstrip -i "${out}/dwi_upsampled_meanb0.nii.gz" \
            -m "${out}/dwi_mask_synthstrip.nii.gz"

        mrconvert "${out}/dwi_mask_synthstrip.nii.gz" "${out}/dwi_mask.mif" -force

        create_checkpoint "$subject" "mask"
    fi

    # --- Step 9: Response function estimation ---
    if check_checkpoint "$subject" "response"; then
        echo "SKIP: response function (checkpoint exists)"
    else
        echo "Step 9/9: Response function estimation (dhollander)"
        dwi2response dhollander "${out}/dwi_upsampled.mif" \
            "${out}/wm.txt" "${out}/gm.txt" "${out}/csf.txt" \
            -voxels "${out}/voxels.mif" \
            -mask "${out}/dwi_mask.mif" -force
        create_checkpoint "$subject" "response"
    fi

    echo "=============================================="
    echo "Completed ${subject}"
    echo "End time: $(date)"
    echo "=============================================="
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    load_config

    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <subject-id>"
        echo "  e.g.: $0 sub-001"
        exit 1
    fi

    local subject="$1"

    # Validate input directory
    if [[ ! -d "${INPUT_PATH}/${subject}/${SESSION}" ]]; then
        echo "ERROR: Subject directory not found: ${INPUT_PATH}/${subject}/${SESSION}"
        exit 1
    fi

    process_subject "$subject"
}

main "$@"
