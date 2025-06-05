#!/bin/bash

#Author- Arush Arun (arush.getseven@gmail.com)
#Enhanced version with input validation and resume capability

# Set paths - modify these for your environment
input_path="${INPUT_PATH:-/path/to/your/bids/folder}"
der_path="${DER_PATH:-${input_path}/derivatives}"
sublist_file="${SUBLIST_FILE:-./sublist.txt}"

# Checkpoint directory for resume capability
CHECKPOINT_DIR="./fba_checkpoints"
mkdir -p "$CHECKPOINT_DIR"

#=============================================================================
# VALIDATION FUNCTIONS
#=============================================================================

# Validate BIDS structure for a subject
validate_subject_files() {
    local subject="$1"
    local subject_dir="${input_path}/${subject}/ses-1/dwi"
    
    echo "Validating files for $subject..."
    
    # Check if subject directory exists
    if [[ ! -d "$subject_dir" ]]; then
        echo "ERROR: Subject directory not found: $subject_dir"
        return 1
    fi
    
    # Check required DWI files
    local dwi_file="${subject_dir}/${subject}_ses-1_dwi.nii.gz"
    local bval_file="${subject_dir}/${subject}_ses-1_dwi.bval"
    local bvec_file="${subject_dir}/${subject}_ses-1_dwi.bvec"
    
    if [[ ! -f "$dwi_file" ]]; then
        echo "ERROR: DWI file not found: $dwi_file"
        return 1
    fi
    
    if [[ ! -f "$bval_file" ]]; then
        echo "ERROR: bval file not found: $bval_file"
        return 1
    fi
    
    if [[ ! -f "$bvec_file" ]]; then
        echo "ERROR: bvec file not found: $bvec_file"
        return 1
    fi
    
    # Check for blipped images (dir-* files)
    local blipped_files=($(ls "${subject_dir}/${subject}_ses-1_dir"*.nii.gz 2>/dev/null || true))
    if [[ ${#blipped_files[@]} -eq 0 ]]; then
        echo "ERROR: No blipped images found for $subject (looking for ${subject}_ses-1_dir*.nii.gz)"
        return 1
    fi
    
    # Check corresponding .bval and .bvec for blipped images
    for blipped_file in "${blipped_files[@]}"; do
        local base_name=$(basename "$blipped_file" .nii.gz)
        local blipped_bval="${subject_dir}/${base_name}.bval"
        local blipped_bvec="${subject_dir}/${base_name}.bvec"
        
        if [[ ! -f "$blipped_bval" ]]; then
            echo "ERROR: Blipped bval file not found: $blipped_bval"
            return 1
        fi
        
        if [[ ! -f "$blipped_bvec" ]]; then
            echo "ERROR: Blipped bvec file not found: $blipped_bvec"
            return 1
        fi
    done
    
    echo "✓ All required files found for $subject"
    return 0
}

# Validate all subjects before starting processing
validate_all_subjects() {
    echo "=============================================="
    echo "VALIDATING BIDS STRUCTURE FOR ALL SUBJECTS"
    echo "=============================================="
    
    if [[ ! -f "$sublist_file" ]]; then
        echo "ERROR: Subject list file not found: $sublist_file"
        exit 1
    fi
    
    local validation_failed=0
    while IFS= read -r subject; do
        # Skip empty lines and comments
        [[ -z "$subject" || "$subject" =~ ^[[:space:]]*# ]] && continue
        
        if ! validate_subject_files "$subject"; then
            validation_failed=1
        fi
    done < "$sublist_file"
    
    if [[ $validation_failed -eq 1 ]]; then
        echo "ERROR: Validation failed for one or more subjects. Please fix the issues above."
        exit 1
    fi
    
    echo "✓ All subjects passed validation"
}

#=============================================================================
# CHECKPOINT FUNCTIONS
#=============================================================================

# Create checkpoint for a subject and processing step
create_checkpoint() {
    local subject="$1"
    local step="$2"
    local checkpoint_file="${CHECKPOINT_DIR}/${subject}_${step}.done"
    touch "$checkpoint_file"
    echo "✓ Checkpoint created: ${subject} - ${step}"
}

# Check if checkpoint exists
check_checkpoint() {
    local subject="$1"
    local step="$2"
    local checkpoint_file="${CHECKPOINT_DIR}/${subject}_${step}.done"
    [[ -f "$checkpoint_file" ]]
}

# List completed checkpoints for a subject
list_subject_checkpoints() {
    local subject="$1"
    echo "Checkpoints for $subject:"
    for checkpoint in "${CHECKPOINT_DIR}/${subject}"_*.done; do
        if [[ -f "$checkpoint" ]]; then
            local step=$(basename "$checkpoint" .done | sed "s/${subject}_//")
            echo "  ✓ $step"
        fi
    done
}

# Resume capability - show what can be skipped
show_resume_status() {
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
        
        if check_checkpoint "$subject" "fod_computation"; then
            echo "  ✓ FOD computation completed"
        else
            echo "  ⏳ FOD computation pending"
        fi
        echo ""
    done < "$sublist_file"
}

#=============================================================================
# MAIN PROCESSING WITH CHECKPOINTS
#=============================================================================

# Validate initial setup
validate_setup() {
    echo "=============================================="
    echo "VALIDATING SETUP"
    echo "=============================================="
    
    # Check if paths are set correctly
    if [[ "$input_path" == "/path/to/your/bids/folder" ]]; then
        echo "ERROR: Please set INPUT_PATH environment variable or modify input_path in script"
        exit 1
    fi
    
    # Check if input directory exists
    if [[ ! -d "$input_path" ]]; then
        echo "ERROR: Input directory not found: $input_path"
        exit 1
    fi
    
    # Check if we can write to derivatives path
    mkdir -p "$der_path" 2>/dev/null || {
        echo "ERROR: Cannot create derivatives directory: $der_path"
        exit 1
    }
    
    echo "✓ Setup validation passed"
    echo "  Input path: $input_path"
    echo "  Derivatives path: $der_path"
    echo "  Subject list: $sublist_file"
}

# Main script execution starts here
echo "=============================================="
echo "FBA PIPELINE WITH VALIDATION & RESUME"
echo "=============================================="

# Validate setup and all subjects first
validate_setup
validate_all_subjects

# Show resume status
show_resume_status

# Ask user if they want to continue
read -p "Do you want to continue with processing? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Processing cancelled by user."
    exit 0
fi

# Create directory structure
mkdir -p ${der_path}/group-level/template/fod_input
mkdir -p ${der_path}/group-level/template/mask_input
mkdir -p ${der_path}/group-level/template/scratch
mkdir -p ${der_path}/group-level/template/scratch/warp_dir
mkdir -p ${der_path}/group-level/ses-1

# Subject-level processing loop
while read p; do
    [[ -z "$p" || "$p" =~ ^[[:space:]]*# ]] && continue
    
    sub=$p
    echo "################# Processing ${sub} ##################"
    
    # Check if preprocessing is already done
    if check_checkpoint "$sub" "preprocessing"; then
        echo "⏭️  Preprocessing already completed for $sub, skipping..."
    else
        echo "🔄 Starting preprocessing for $sub"
        
        # Create directory for each subject in derivatives folder
        mkdir -p ${der_path}/${sub}/ses-1/dwi
        
        # Converting the raw data to .mif file
        mrconvert ${input_path}/${sub}/ses-1/dwi/${sub}_ses-1_dwi.nii.gz ${der_path}/${sub}/ses-1/dwi/data.mif -fslgrad ${input_path}/${sub}/ses-1/dwi/${sub}_ses-1_dwi.bvec ${input_path}/${sub}/ses-1/dwi/${sub}_ses-1_dwi.bval -debug
        
        echo "################# Running denoising ${sub} ##################"
        
        # Denoising
        dwidenoise ${der_path}/${sub}/ses-1/dwi/data.mif ${der_path}/${sub}/ses-1/dwi/dwi_denoised.mif -noise ${der_path}/${sub}/ses-1/dwi/noise.mif
        mrcalc ${der_path}/${sub}/ses-1/dwi/data.mif ${der_path}/${sub}/ses-1/dwi/dwi_denoised.mif -subtract ${der_path}/${sub}/ses-1/dwi/residual.mif
        
        # Calculating SNR using the outshell of the DWI
        dwiextract ${der_path}/${sub}/ses-1/dwi/data.mif -no_bzero -singleshell ${der_path}/${sub}/ses-1/dwi/dwi_singleshell.mif 
        mrcalc ${der_path}/${sub}/ses-1/dwi/dwi_singleshell.mif ${der_path}/${sub}/ses-1/dwi/noise.mif -div ${der_path}/${sub}/ses-1/dwi/snr.mif 
        
        # Creating approx WM-mask using dwi data to calculate SNR only in the WM region
        dwiextract ${der_path}/${sub}/ses-1/dwi/data.mif -no_bzero -singleshell - | amp2sh - - | sh2power - -spectrum - | mrconvert - -coord 3 1 - | mrthreshold - ${der_path}/${sub}/ses-1/dwi/wm_mask.mif
        SNR=$(mrstats ${der_path}/${sub}/ses-1/dwi/snr.mif -mask ${der_path}/${sub}/ses-1/dwi/wm_mask.mif -output mean -allvolumes)
        echo "${sub} has an SNR of ${SNR}"
        
        echo "################# Running gibbs unringing  ${sub} ##################"
        
        # Gibbs ringing
        mrdegibbs -axes 0,1 ${der_path}/${sub}/ses-1/dwi/dwi_denoised.mif  ${der_path}/${sub}/ses-1/dwi/dwi_unr.mif -force
        mrcalc ${der_path}/${sub}/ses-1/dwi/dwi_denoised.mif ${der_path}/${sub}/ses-1/dwi/dwi_unr.mif  -subtract ${der_path}/${sub}/ses-1/dwi/residualunringed.mif
        
        # Convert blipped down to .mif
        mrconvert ${input_path}/${sub}/ses-1/dwi/${sub}_ses-1_dir*.nii.gz ${der_path}/${sub}/ses-1/dwi/blipped_data.mif -fslgrad ${input_path}/${sub}/ses-1/dwi/${sub}_ses-1_dir*.bvec ${input_path}/${sub}/ses-1/dwi/${sub}_ses-1_dir*.bval
        
        # Prep for dwifslpreproc
        dwiextract ${der_path}/${sub}/ses-1/dwi/dwi_unr.mif ${der_path}/${sub}/ses-1/dwi/dwi_bzero.mif -bzero
        mrmath ${der_path}/${sub}/ses-1/dwi/dwi_bzero.mif  mean  ${der_path}/${sub}/ses-1/dwi/dwi_mean_bzero.mif -axis 3
        dwiextract ${der_path}/${sub}/ses-1/dwi/blipped_data.mif -bzero - | mrmath - mean ${der_path}/${sub}/ses-1/dwi/blipped_mean_bzero.mif -axis 3
        mrcat ${der_path}/${sub}/ses-1/dwi/dwi_mean_bzero.mif ${der_path}/${sub}/ses-1/dwi/blipped_mean_bzero.mif ${der_path}/${sub}/ses-1/dwi/bzero_cat.mif -axis 3
        
        # FSL preprocessing
        dwifslpreproc ${der_path}/${sub}/ses-1/dwi/dwi_unr.mif ${der_path}/${sub}/ses-1/dwi/dwi_preproc.mif -pe_dir AP -rpe_pair -se_epi ${der_path}/${sub}/ses-1/dwi/bzero_cat.mif -eddy_options "--slm=linear --cnr_maps " -eddyqc_all ${der_path}/${sub}/ses-1/dwi/eddyqc_AP_cnrmaps 
        
        # Bias correction using ANTS
        dwibiascorrect ants ${der_path}/${sub}/ses-1/dwi/dwi_preproc.mif ${der_path}/${sub}/ses-1/dwi/dwi_unbiased_preproc.mif -bias ${der_path}/${sub}/ses-1/dwi/bias.mif
        
        echo "################# Finished pre-processing ${sub} ##################"
        
        # Upsampling
        mrgrid ${der_path}/${sub}/ses-1/dwi/dwi_unbiased_preproc.mif  regrid -vox 1.25 ${der_path}/${sub}/ses-1/dwi/dwi_unbiased_preproc_upsampled.mif
        
        # Generate mask using FSL's BET
        mrconvert ${der_path}/${sub}/ses-1/dwi/dwi_unbiased_preproc_upsampled.mif ${der_path}/${sub}/ses-1/dwi/dwi_unbiased_preproc_upsampled.nii.gz
        bet2 ${der_path}/${sub}/ses-1/dwi/dwi_unbiased_preproc_upsampled.nii.gz ${der_path}/${sub}/ses-1/dwi/dwi_bet_mask.nii.gz -m
        mrconvert ${der_path}/${sub}/ses-1/dwi/dwi_bet_mask.nii.gz ${der_path}/${sub}/ses-1/dwi/dwi_bet_mask_use.mif
        
        create_checkpoint "$sub" "preprocessing"
    fi
    
    # Check if response function is already done
    if check_checkpoint "$sub" "response_function"; then
        echo "⏭️  Response function already computed for $sub, skipping..."
    else
        echo "🔄 Computing response function for $sub"
        
        # Response function generation using dhollander algorithm
        dwi2response dhollander ${der_path}/${sub}/ses-1/dwi/dwi_unbiased_preproc.mif ${der_path}/${sub}/ses-1/dwi/wm.txt ${der_path}/${sub}/ses-1/dwi/gm.txt ${der_path}/${sub}/ses-1/dwi/csf.txt -voxels ${der_path}/${sub}/ses-1/dwi/voxels.mif
        
        echo "################# completed response function gen for  ${sub} ##################"
        
        # Upsampling DWI images to vox size 1.25 as per recommendation of FBA pipeline
        mrgrid ${der_path}/${sub}/ses-1/dwi/dwi_unbiased_preproc.mif  regrid -vox 1.25 ${der_path}/${sub}/ses-1/dwi/dwi_unbiased_preproc_upsampled.mif
        
        create_checkpoint "$sub" "response_function"
    fi

done < "$sublist_file"

echo "################# Subject-level processing completed ##################"
echo "Next: Run group-level analysis (response averaging, FOD computation, etc.)"
echo "Resume status saved in: $CHECKPOINT_DIR"