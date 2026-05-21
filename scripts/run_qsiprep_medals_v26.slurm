#!/bin/bash
#SBATCH --job-name=qsiprep_medals
#SBATCH --account=a_aibn
#SBATCH --partition=general
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=10:00:00
#SBATCH --output=/scratch/user/uqahonne/als/MeDALS_DWI/qsiprep_logs/qsiprep_%A_%a.out
#SBATCH --error=/scratch/user/uqahonne/als/MeDALS_DWI/qsiprep_logs/qsiprep_%A_%a.err
# ============================================================
# MeDALS DWI QSIPrep 26.0.0 Processing (Session 01 only)
#
# Usage:
#   sbatch --array=1-45 run_qsiprep_medals_v26.slurm
#
# Excluded subjects (ses-01):
#   sub-113: missing PA (no TOPUP distortion correction possible)
#   sub-118: only 1 b0 volume, no diffusion data
#   sub-121: only 1 b0 volume, no diffusion data
#   sub-122: only 1 b0 volume, no diffusion data
#   sub-140: missing both AP and PA files for ses-01
# ============================================================

# QSIPrep 26.0.0 container
QSIPREP_SIF="/scratch/user/uqahonne/containers/qsiprep-26.0.0.sif"

# Set up directories
BIDS_DIR="/scratch/user/uqahonne/als/MeDALS_DWI/bids"
OUTPUT_DIR="/scratch/user/uqahonne/als/MeDALS_DWI/qsiprep_output"
WORK_DIR="/scratch/user/uqahonne/als/MeDALS_DWI/qsiprep_work"
FS_LICENSE="/scratch/user/uqahonne/ukb/bed_analysis/scripts/license.txt"
LOG_DIR="/scratch/user/uqahonne/als/MeDALS_DWI/qsiprep_logs"
SCRIPTS_DIR="/home/uqahonne/uq/ALS/MeDALS_DWI/scripts"

# Create directories
mkdir -p "$OUTPUT_DIR" "$WORK_DIR" "$LOG_DIR"

# Get participant from list
PARTICIPANTS_FILE="${SCRIPTS_DIR}/participant_list_ses01.txt"
if [[ ! -f "$PARTICIPANTS_FILE" ]]; then
    echo "Participant list not found: $PARTICIPANTS_FILE"
    exit 1
fi

PARTICIPANT_LABEL=$(sed -n "${SLURM_ARRAY_TASK_ID}p" "$PARTICIPANTS_FILE")

if [[ -z "$PARTICIPANT_LABEL" ]]; then
    echo "No participant found for array index ${SLURM_ARRAY_TASK_ID}"
    exit 1
fi

echo "=========================================="
echo "Processing participant: sub-${PARTICIPANT_LABEL} (ses-01)"
echo "Running on node: $(hostname)"
echo "Start time: $(date)"
echo "=========================================="

# Convert memory from SLURM format to MB for QSIprep
if [[ "$SLURM_MEM_PER_NODE" =~ ^[0-9]+G$ ]]; then
    MEM_GB=${SLURM_MEM_PER_NODE%G}
    MEM_MB=$((MEM_GB * 1024))
elif [[ "$SLURM_MEM_PER_NODE" =~ ^[0-9]+M$ ]]; then
    MEM_MB=${SLURM_MEM_PER_NODE%M}
elif [[ "$SLURM_MEM_PER_NODE" =~ ^[0-9]+$ ]]; then
    MEM_MB=$SLURM_MEM_PER_NODE
else
    MEM_MB=65536
fi

echo "Memory: ${SLURM_MEM_PER_NODE} (${MEM_MB}MB for QSIprep)"

# Create participant-specific work directory
PARTICIPANT_WORK_DIR="${WORK_DIR}/sub-${PARTICIPANT_LABEL}"
mkdir -p "$PARTICIPANT_WORK_DIR"

# Check container exists
if [[ ! -f "$QSIPREP_SIF" ]]; then
    echo "QSIprep container not found: $QSIPREP_SIF"
    exit 1
fi

echo "Using QSIprep container: $QSIPREP_SIF"

# Launch QSIprep via Apptainer
apptainer run --cleanenv \
    -B /scratch \
    -B /home \
    "$QSIPREP_SIF" \
    "$BIDS_DIR" "$OUTPUT_DIR" participant \
    --participant-label "$PARTICIPANT_LABEL" \
    --session-id 01 \
    --nthreads ${SLURM_CPUS_PER_TASK} \
    --omp-nthreads 4 \
    --mem ${MEM_MB} \
    --work-dir "$PARTICIPANT_WORK_DIR" \
    --fs-license-file "$FS_LICENSE" \
    --denoise-method patch2self \
    --dwi-denoise-window auto \
    --unringing-method mrdegibbs \
    --pepolar-method TOPUP \
    --hmc-model eddy \
    --output-resolution 1.8 \
    --write-graph \
    --notrack \
    --verbose \
    --skip-bids-validation \
    --separate-all-dwis

EXIT_CODE=$?

echo "=========================================="
if [[ $EXIT_CODE -eq 0 ]]; then
    echo "QSIprep completed successfully for sub-${PARTICIPANT_LABEL}"
    echo "Cleaning up work directory..."
    rm -rf "$PARTICIPANT_WORK_DIR"
else
    echo "QSIprep FAILED for sub-${PARTICIPANT_LABEL} (exit code: $EXIT_CODE)"
fi
echo "End time: $(date)"
echo "=========================================="

exit $EXIT_CODE
