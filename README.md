
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
│           ├── sub-001_ses-1_dir-AP_dwi.nii.gz
│           ├── sub-001_ses-1_dir-AP_dwi.bval
│           ├── sub-001_ses-1_dir-AP_dwi.bvec
│           └── sub-01_ses-1_dir-*.nii.gz (blip-down)
├── derivatives/
    ├── sub-01/
    ├── group-level/
        ├── template/
        ├── ses-1/
```

---

## How to Run

### 🚀 Enhanced Version with Configuration (Recommended)

**Use `fba_enhanced_configurable.sh` for the most robust experience with validation and resume capability.**

1. **Configure the pipeline:**
   Edit `fba_config.conf` to match your data:
   ```bash
   # Example configuration for dir-AP/dir-PA data
   INPUT_PATH="/path/to/your/bids/folder"
   MAIN_PE_DIR="AP"        # Your main DWI direction
   BLIPPED_PE_DIR="PA"     # For distortion correction
   PHASE_ENCODING_DIR="AP" # For preprocessing
   ```

2. **Create subject list:**
   ```bash
   # Create sublist.txt with your subject IDs
   echo -e "sub-001\nsub-002\nsub-003" > sublist.txt
   ```

3. **Run the enhanced pipeline:**
   ```bash
   ./fba_enhanced_configurable.sh
   ```

**Features:**
- ✅ **Input validation** - Checks all required files before processing
- ✅ **Resume capability** - Skip completed steps automatically  
- ✅ **Config file support** - Easy parameter management
- ✅ **Progress tracking** - Clear status reporting
- ✅ **Error handling** - Robust failure detection

### 📁 Expected BIDS Structure
```
bids/
├── sub-001/
│   └── ses-1/
│       └── dwi/
│           ├── sub-001_ses-1_dir-AP_dwi.nii.gz    # Main DWI
│           ├── sub-001_ses-1_dir-AP_dwi.bval
│           ├── sub-001_ses-1_dir-AP_dwi.bvec
│           ├── sub-001_ses-1_dir-PA_dwi.nii.gz    # Blipped (distortion correction)
│           ├── sub-001_ses-1_dir-PA_dwi.bval
│           └── sub-001_ses-1_dir-PA_dwi.bvec
```

### 🔄 Original Version (Legacy)

**For basic usage without advanced features:**

#### Option 1: Using environment variables
```bash
export INPUT_PATH="/path/to/your/bids/folder"
export DER_PATH="/path/to/your/bids/folder/derivatives"
chmod +x final_script_FBA_corrected.sh
./final_script_FBA_corrected.sh
```

#### Option 2: Modify script directly  
Edit lines 17-20 in `final_script_FBA_corrected.sh` to set your paths, then run.

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

