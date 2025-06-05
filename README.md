
# Fixel-Based Analysis (FBA) Pipeline

**Author:** Arush Honnedevasthana Arun  
**Email:** arush.getseven@gmail.com  
**Last Updated:** 05/06/2025

This shell script performs a comprehensive Fixel-Based Analysis (FBA) on diffusion MRI data using MRtrix3 and FSL. It supports BIDS-formatted datasets and runs subject-level as well as group-level processing steps.

---

## 📦 Requirements

- **MRtrix3** version 3.0.2 or later
- **FSL** version 6.0.3 or later
- BIDS-formatted DWI data with `blip-up/blip-down` acquisitions
- A `sublist.txt` file containing subject IDs (one per line)

---

## Directory Structure

```
bids/
├── sub-01/
│   └── ses-1/
│       └── dwi/
│           ├── sub-01_ses-1_dwi.nii.gz
│           ├── sub-01_ses-1_dwi.bval
│           ├── sub-01_ses-1_dwi.bvec
│           └── sub-01_ses-1_dir-*.nii.gz (blip-down)
├── derivatives/
    ├── sub-01/
    ├── group-level/
        ├── template/
        ├── ses-1/
```

---

## How to Run

### Option 1: Using environment variables (recommended)
1. Set environment variables:
    ```bash
    export INPUT_PATH="/path/to/your/bids/folder"
    export DER_PATH="/path/to/your/bids/folder/derivatives"
    ```

2. Make the script executable and run:
    ```bash
    chmod +x final_script_FBA_corrected.sh
    ./final_script_FBA_corrected.sh
    ```

### Option 2: Modify script directly
1. Edit lines 17-20 in the script to set your paths:
    ```bash
    input_path="/path/to/your/bids/folder"
    der_path="/path/to/your/bids/folder/derivatives"
    ```

2. Make executable and run:
    ```bash
    chmod +x final_script_FBA_corrected.sh
    ./final_script_FBA_corrected.sh
    ```

---

## 🔄 Processing Steps

- Convert raw DWI to `.mif`
- Denoising, Gibbs ringing correction
- Preprocessing with `dwifslpreproc` using blipped images
- Bias field correction with ANTs
- Response function estimation using Dhollander algorithm
- FOD estimation and normalization
- Group-level template creation and registration
- Fixel segmentation, metrics extraction (FD, FC, FDC)
- Tractography, fixel-fixel connectivity
- Smoothing and statistical preparation

---

## 📌 Notes

- Be sure to verify masks visually using `mrview`.
- The script assumes `ses-1` as session folder name.
- Statistical analysis (`fixelcfestats`) is commented out. You need to prepare `files.txt`, `design_matrix.txt`, and `contrast_matrix.txt` before running those steps.

