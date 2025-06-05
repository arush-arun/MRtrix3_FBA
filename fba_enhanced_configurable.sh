#!/bin/bash

# Author: Arush Arun (arush.getseven@gmail.com)
# Enhanced FBA Pipeline with Configuration File Support
# Supports dir-AP/dir-PA BIDS naming convention

# Default config file location
CONFIG_FILE="${CONFIG_FILE:-./fba_config.conf}"

#=============================================================================
# CONFIGURATION LOADING
#=============================================================================

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "ERROR: Configuration file not found: $CONFIG_FILE"
        echo "Please create a configuration file or set CONFIG_FILE environment variable"
        exit 1
    fi
    
    echo "Loading configuration from: $CONFIG_FILE"
    
    # Source the config file (excluding comments and empty lines)
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Export the variable
        export "$line"
    done < <(grep -E '^[A-Z_].*=' "$CONFIG_FILE")
    
    # Set derived paths
    if [[ "$DERIVATIVES_PATH" =~ ^/ ]]; then
        # Absolute path
        der_path="$DERIVATIVES_PATH"
    else
        # Relative to input path
        der_path="${INPUT_PATH}/${DERIVATIVES_PATH}"
    fi
    
    echo "✓ Configuration loaded successfully"
}

# Display current configuration
show_config() {
    echo "=============================================="
    echo "CURRENT CONFIGURATION"
    echo "=============================================="
    echo "Input path: $INPUT_PATH"
    echo "Derivatives path: $der_path"
    echo "Subject list: $SUBLIST_FILE"
    echo "Session: $SESSION"
    echo "Main PE direction: $MAIN_PE_DIR"
    echo "Blipped PE direction: $BLIPPED_PE_DIR"
    echo "Phase encoding for preprocessing: $PHASE_ENCODING_DIR"
    echo "Voxel size: $VOXEL_SIZE"
    echo "Checkpoints enabled: $ENABLE_CHECKPOINTS"
    echo "=============================================="
}

#=============================================================================
# VALIDATION FUNCTIONS
#=============================================================================

# Generate file paths based on BIDS pattern and config
get_file_paths() {
    local subject="$1"
    local pe_dir="$2"
    local subject_dir="${INPUT_PATH}/${subject}/${SESSION}/dwi"
    
    # Generate file paths using the naming pattern
    local dwi_file="${subject_dir}/${subject}_${SESSION}_dir-${pe_dir}_dwi.nii.gz"
    local bval_file="${subject_dir}/${subject}_${SESSION}_dir-${pe_dir}_dwi.bval"
    local bvec_file="${subject_dir}/${subject}_${SESSION}_dir-${pe_dir}_dwi.bvec"
    
    echo "$dwi_file|$bval_file|$bvec_file"
}

# Validate BIDS structure for a subject
validate_subject_files() {
    local subject="$1"
    local subject_dir="${INPUT_PATH}/${subject}/${SESSION}/dwi"
    
    echo "Validating files for $subject..."
    
    # Check if subject directory exists
    if [[ ! -d "$subject_dir" ]]; then
        echo "ERROR: Subject directory not found: $subject_dir"
        return 1
    fi
    
    # Validate main DWI files
    echo "  Checking main DWI files (dir-${MAIN_PE_DIR})..."
    IFS='|' read -r main_dwi main_bval main_bvec <<< "$(get_file_paths "$subject" "$MAIN_PE_DIR")"
    
    if [[ ! -f "$main_dwi" ]]; then
        echo "ERROR: Main DWI file not found: $main_dwi"
        return 1
    fi
    
    if [[ ! -f "$main_bval" ]]; then
        echo "ERROR: Main bval file not found: $main_bval"
        return 1
    fi
    
    if [[ ! -f "$main_bvec" ]]; then
        echo "ERROR: Main bvec file not found: $main_bvec"
        return 1
    fi
    
    # Validate blipped DWI files (for distortion correction)
    echo "  Checking blipped DWI files (dir-${BLIPPED_PE_DIR})..."
    IFS='|' read -r blipped_dwi blipped_bval blipped_bvec <<< "$(get_file_paths "$subject" "$BLIPPED_PE_DIR")"
    
    if [[ ! -f "$blipped_dwi" ]]; then
        echo "ERROR: Blipped DWI file not found: $blipped_dwi"
        return 1
    fi
    
    if [[ ! -f "$blipped_bval" ]]; then
        echo "ERROR: Blipped bval file not found: $blipped_bval"
        return 1
    fi
    
    if [[ ! -f "$blipped_bvec" ]]; then
        echo "ERROR: Blipped bvec file not found: $blipped_bvec"
        return 1
    fi
    
    echo "  ✓ All required files found for $subject"
    return 0
}

# Validate all subjects before starting processing
validate_all_subjects() {
    echo "=============================================="
    echo "VALIDATING BIDS STRUCTURE FOR ALL SUBJECTS"
    echo "=============================================="
    
    if [[ ! -f "$SUBLIST_FILE" ]]; then
        echo "ERROR: Subject list file not found: $SUBLIST_FILE"
        exit 1
    fi
    
    local validation_failed=0
    local subject_count=0
    
    while IFS= read -r subject; do
        # Skip empty lines and comments
        [[ -z "$subject" || "$subject" =~ ^[[:space:]]*# ]] && continue
        
        ((subject_count++))
        if ! validate_subject_files "$subject"; then
            validation_failed=1
        fi
    done < "$SUBLIST_FILE"
    
    if [[ $validation_failed -eq 1 ]]; then
        echo "ERROR: Validation failed for one or more subjects. Please fix the issues above."
        exit 1
    fi
    
    echo "✓ All $subject_count subjects passed validation"
}

#=============================================================================
# CHECKPOINT FUNCTIONS
#=============================================================================

# Create checkpoint for a subject and processing step
create_checkpoint() {
    [[ "$ENABLE_CHECKPOINTS" != "true" ]] && return 0
    
    local subject="$1"
    local step="$2"
    local checkpoint_file="${CHECKPOINT_DIR}/${subject}_${step}.done"
    mkdir -p "$CHECKPOINT_DIR"
    touch "$checkpoint_file"
    echo "✓ Checkpoint created: ${subject} - ${step}"
}

# Check if checkpoint exists
check_checkpoint() {
    [[ "$ENABLE_CHECKPOINTS" != "true" ]] && return 1
    
    local subject="$1"
    local step="$2"
    local checkpoint_file="${CHECKPOINT_DIR}/${subject}_${step}.done"
    [[ -f "$checkpoint_file" ]]
}

# Resume capability - show what can be skipped
show_resume_status() {
    [[ "$ENABLE_CHECKPOINTS" != "true" ]] && return 0
    
    echo "=============================================="
    echo "RESUME STATUS"
    echo "=============================================="
    
    while IFS= read -r subject; do
        [[ -z "$subject" || "$subject" =~ ^[[:space:]]*# ]] && continue
        
        echo "Subject: $subject"
        if check_checkpoint "$subject" "preprocessing"; then
            echo "  ✓ Preprocessing completed"
        else
            echo "  ⏳ Preprocessing pending"
        fi
        
        if check_checkpoint "$subject" "response_function"; then
            echo "  ✓ Response function completed"
        else
            echo "  ⏳ Response function pending"
        fi
        echo ""
    done < "$SUBLIST_FILE"
}

#=============================================================================
# PROCESSING FUNCTIONS
#=============================================================================

process_subject() {
    local subject="$1"
    
    # Get file paths for main and blipped data
    IFS='|' read -r main_dwi main_bval main_bvec <<< "$(get_file_paths "$subject" "$MAIN_PE_DIR")"
    IFS='|' read -r blipped_dwi blipped_bval blipped_bvec <<< "$(get_file_paths "$subject" "$BLIPPED_PE_DIR")"
    
    echo "################# Processing ${subject} ##################"
    echo "Main DWI: $main_dwi"
    echo "Blipped DWI: $blipped_dwi"
    
    # Check if preprocessing is already done
    if check_checkpoint "$subject" "preprocessing"; then
        echo "⏭️  Preprocessing already completed for $subject, skipping..."
    else
        echo "🔄 Starting preprocessing for $subject"
        
        # Create directory for each subject in derivatives folder
        mkdir -p "${der_path}/${subject}/${SESSION}/dwi"
        
        # Converting the main DWI data to .mif file
        mrconvert "$main_dwi" "${der_path}/${subject}/${SESSION}/dwi/data.mif" \
                  -fslgrad "$main_bvec" "$main_bval" \
                  $([ "$DEBUG_MODE" = "true" ] && echo "-debug")
        
        echo "################# Running denoising ${subject} ##################"
        
        # Denoising
        dwidenoise "${der_path}/${subject}/${SESSION}/dwi/data.mif" \
                   "${der_path}/${subject}/${SESSION}/dwi/dwi_denoised.mif" \
                   -noise "${der_path}/${subject}/${SESSION}/dwi/noise.mif"
        
        mrcalc "${der_path}/${subject}/${SESSION}/dwi/data.mif" \
               "${der_path}/${subject}/${SESSION}/dwi/dwi_denoised.mif" \
               -subtract "${der_path}/${subject}/${SESSION}/dwi/residual.mif"
        
        # Calculating SNR using the outshell of the DWI
        dwiextract "${der_path}/${subject}/${SESSION}/dwi/data.mif" \
                   -no_bzero -singleshell "${der_path}/${subject}/${SESSION}/dwi/dwi_singleshell.mif"
        
        mrcalc "${der_path}/${subject}/${SESSION}/dwi/dwi_singleshell.mif" \
               "${der_path}/${subject}/${SESSION}/dwi/noise.mif" \
               -div "${der_path}/${subject}/${SESSION}/dwi/snr.mif"
        
        # Creating approx WM-mask using dwi data to calculate SNR only in the WM region
        dwiextract "${der_path}/${subject}/${SESSION}/dwi/data.mif" -no_bzero -singleshell - | \
        amp2sh - - | \
        sh2power - -spectrum - | \
        mrconvert - -coord 3 1 - | \
        mrthreshold - "${der_path}/${subject}/${SESSION}/dwi/wm_mask.mif"
        
        SNR=$(mrstats "${der_path}/${subject}/${SESSION}/dwi/snr.mif" \
                     -mask "${der_path}/${subject}/${SESSION}/dwi/wm_mask.mif" \
                     -output mean -allvolumes)
        echo "${subject} has an SNR of ${SNR}"
        
        # Check SNR threshold
        if (( $(echo "$SNR < $MIN_SNR" | bc -l 2>/dev/null || echo "0") )); then
            echo "⚠️  WARNING: Low SNR detected for $subject: $SNR (threshold: $MIN_SNR)"
        fi
        
        echo "################# Running gibbs unringing ${subject} ##################"
        
        # Gibbs ringing
        mrdegibbs -axes 0,1 "${der_path}/${subject}/${SESSION}/dwi/dwi_denoised.mif" \
                  "${der_path}/${subject}/${SESSION}/dwi/dwi_unr.mif" \
                  $([ "$FORCE_OVERWRITE" = "true" ] && echo "-force")
        
        mrcalc "${der_path}/${subject}/${SESSION}/dwi/dwi_denoised.mif" \
               "${der_path}/${subject}/${SESSION}/dwi/dwi_unr.mif" \
               -subtract "${der_path}/${subject}/${SESSION}/dwi/residualunringed.mif"
        
        # Convert blipped data to .mif
        mrconvert "$blipped_dwi" "${der_path}/${subject}/${SESSION}/dwi/blipped_data.mif" \
                  -fslgrad "$blipped_bvec" "$blipped_bval"
        
        # Prep for dwifslpreproc
        dwiextract "${der_path}/${subject}/${SESSION}/dwi/dwi_unr.mif" \
                   "${der_path}/${subject}/${SESSION}/dwi/dwi_bzero.mif" -bzero
        
        mrmath "${der_path}/${subject}/${SESSION}/dwi/dwi_bzero.mif" mean \
               "${der_path}/${subject}/${SESSION}/dwi/dwi_mean_bzero.mif" -axis 3
        
        dwiextract "${der_path}/${subject}/${SESSION}/dwi/blipped_data.mif" -bzero - | \
        mrmath - mean "${der_path}/${subject}/${SESSION}/dwi/blipped_mean_bzero.mif" -axis 3
        
        mrcat "${der_path}/${subject}/${SESSION}/dwi/dwi_mean_bzero.mif" \
              "${der_path}/${subject}/${SESSION}/dwi/blipped_mean_bzero.mif" \
              "${der_path}/${subject}/${SESSION}/dwi/bzero_cat.mif" -axis 3
        
        # FSL preprocessing
        dwifslpreproc "${der_path}/${subject}/${SESSION}/dwi/dwi_unr.mif" \
                      "${der_path}/${subject}/${SESSION}/dwi/dwi_preproc.mif" \
                      -pe_dir "$PHASE_ENCODING_DIR" -rpe_pair \
                      -se_epi "${der_path}/${subject}/${SESSION}/dwi/bzero_cat.mif" \
                      -eddy_options "$EDDY_OPTIONS" \
                      -eddyqc_all "${der_path}/${subject}/${SESSION}/dwi/eddyqc_${PHASE_ENCODING_DIR}_cnrmaps"
        
        # Bias correction using ANTS
        dwibiascorrect ants "${der_path}/${subject}/${SESSION}/dwi/dwi_preproc.mif" \
                       "${der_path}/${subject}/${SESSION}/dwi/dwi_unbiased_preproc.mif" \
                       -bias "${der_path}/${subject}/${SESSION}/dwi/bias.mif"
        
        echo "################# Finished pre-processing ${subject} ##################"
        
        # Upsampling
        mrgrid "${der_path}/${subject}/${SESSION}/dwi/dwi_unbiased_preproc.mif" regrid \
               -vox "$VOXEL_SIZE" "${der_path}/${subject}/${SESSION}/dwi/dwi_unbiased_preproc_upsampled.mif"
        
        # Generate mask using FSL's BET
        mrconvert "${der_path}/${subject}/${SESSION}/dwi/dwi_unbiased_preproc_upsampled.mif" \
                  "${der_path}/${subject}/${SESSION}/dwi/dwi_unbiased_preproc_upsampled.nii.gz"
        
        bet2 "${der_path}/${subject}/${SESSION}/dwi/dwi_unbiased_preproc_upsampled.nii.gz" \
             "${der_path}/${subject}/${SESSION}/dwi/dwi_bet_mask.nii.gz" -m
        
        mrconvert "${der_path}/${subject}/${SESSION}/dwi/dwi_bet_mask.nii.gz" \
                  "${der_path}/${subject}/${SESSION}/dwi/dwi_bet_mask_use.mif"
        
        create_checkpoint "$subject" "preprocessing"
    fi
    
    # Check if response function is already done
    if check_checkpoint "$subject" "response_function"; then
        echo "⏭️  Response function already computed for $subject, skipping..."
    else
        echo "🔄 Computing response function for $subject"
        
        # Response function generation using dhollander algorithm
        dwi2response dhollander "${der_path}/${subject}/${SESSION}/dwi/dwi_unbiased_preproc.mif" \
                     "${der_path}/${subject}/${SESSION}/dwi/wm.txt" \
                     "${der_path}/${subject}/${SESSION}/dwi/gm.txt" \
                     "${der_path}/${subject}/${SESSION}/dwi/csf.txt" \
                     -voxels "${der_path}/${subject}/${SESSION}/dwi/voxels.mif"
        
        echo "################# completed response function gen for ${subject} ##################"
        
        create_checkpoint "$subject" "response_function"
    fi
}

#=============================================================================
# MAIN EXECUTION
#=============================================================================

main() {
    echo "=============================================="
    echo "FBA PIPELINE WITH CONFIGURATION SUPPORT"
    echo "=============================================="
    
    # Load configuration
    load_config
    
    # Display configuration
    show_config
    
    # Validate setup
    if [[ -z "$INPUT_PATH" ]]; then
        echo "ERROR: INPUT_PATH not configured in $CONFIG_FILE"
        exit 1
    fi
    
    if [[ ! -d "$INPUT_PATH" ]]; then
        echo "ERROR: Input directory not found: $INPUT_PATH"
        echo "Please check that INPUT_PATH is correctly set in $CONFIG_FILE"
        exit 1
    fi
    
    # Check if path looks like a placeholder
    if [[ "$INPUT_PATH" =~ ^/path/to/ ]]; then
        echo "WARNING: INPUT_PATH looks like a placeholder: $INPUT_PATH"
        echo "Please verify this is your actual BIDS directory path"
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Please update INPUT_PATH in $CONFIG_FILE"
            exit 1
        fi
    fi
    
    # Validate all subjects
    validate_all_subjects
    
    # Show resume status if checkpoints enabled
    show_resume_status
    
    # Ask user confirmation
    read -p "Do you want to continue with processing? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Processing cancelled by user."
        exit 0
    fi
    
    # Create directory structure
    mkdir -p "${der_path}/group-level/template/fod_input"
    mkdir -p "${der_path}/group-level/template/mask_input"
    mkdir -p "${der_path}/group-level/template/scratch"
    mkdir -p "${der_path}/group-level/template/scratch/warp_dir"
    mkdir -p "${der_path}/group-level/${SESSION}"
    
    # Process each subject
    while IFS= read -r subject; do
        [[ -z "$subject" || "$subject" =~ ^[[:space:]]*# ]] && continue
        process_subject "$subject"
    done < "$SUBLIST_FILE"
    
    echo "################# Subject-level processing completed ##################"
    echo "Configuration used: $CONFIG_FILE"
    if [[ "$ENABLE_CHECKPOINTS" == "true" ]]; then
        echo "Checkpoints saved in: $CHECKPOINT_DIR"
    fi
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi