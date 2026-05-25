#!/bin/bash
#SBATCH --job-name=fba_cpu
#SBATCH --account=a_aibn
#SBATCH --partition=general
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=08:00:00
#SBATCH --output=/scratch/user/uqahonne/als/MeDALS_DWI/fba_logs/fba_%A_%a.out
#SBATCH --error=/scratch/user/uqahonne/als/MeDALS_DWI/fba_logs/fba_%A_%a.err
# ============================================================
# MeDALS DWI — MRtrix3 FBA Preprocessing (Session 01)
#
# Usage:
#   sbatch --array=1-1 run_fba_preproc_hpc_cpu.slurm   # pilot
#   sbatch --array=1-49 run_fba_preproc_hpc_cpu.slurm  # full batch
# No GPU — uses eddy_cpu (no --estimate_move_by_susceptibility)
#
# Excluded subjects (ses-01):
#   sub-140: missing both AP and PA files for ses-01
#
# Previously excluded, now fixed:
#   sub-113: had 2 PA runs, run-1 moved to fmap/
#   sub-118, sub-121, sub-122: PA fieldmaps relabeled
# Total: 49 subjects in participant_list_ses01.txt
# ============================================================

# Directories
SCRIPTS_DIR="/scratch/user/uqahonne/als/MeDALS_DWI/scripts"
LOG_DIR="/scratch/user/uqahonne/als/MeDALS_DWI/fba_logs"

mkdir -p "$LOG_DIR"

# Get participant from list
PARTICIPANTS_FILE="${SCRIPTS_DIR}/participant_list_ses01.txt"
if [[ ! -f "$PARTICIPANTS_FILE" ]]; then
    echo "ERROR: Participant list not found: $PARTICIPANTS_FILE"
    exit 1
fi

PARTICIPANT_LABEL=$(sed -n "${SLURM_ARRAY_TASK_ID}p" "$PARTICIPANTS_FILE")

if [[ -z "$PARTICIPANT_LABEL" ]]; then
    echo "ERROR: No participant found for array index ${SLURM_ARRAY_TASK_ID}"
    exit 1
fi

SUBJECT="sub-${PARTICIPANT_LABEL}"

echo "=========================================="
echo "FBA Preprocessing: ${SUBJECT} (ses-01)"
echo "Array task: ${SLURM_ARRAY_TASK_ID}"
echo "Node: $(hostname)"
echo "Start: $(date)"
echo "=========================================="

# Load Neurodesk modules for MRtrix3, FSL
module use /sw/local/rocky8/noarch/neuro/software/neurocommand/local/containers/modules/
export APPTAINER_BINDPATH=/scratch,/QRISdata
ml fsl/6.0.7.9
ml mrtrix/3.0.8
ml ants/2.6.0
ml freesurfer/7.4.1

echo "MRtrix3: $(mrconvert --version 2>&1 | head -1)"
echo "FSL: ${FSLDIR:-not set}"

# Set config file and run preprocessing
export CONFIG_FILE="${SCRIPTS_DIR}/fba_config_medals.conf"

bash "${SCRIPTS_DIR}/run_fba_preproc_medals_cpu.sh" "$SUBJECT"

EXIT_CODE=$?

echo "=========================================="
if [[ $EXIT_CODE -eq 0 ]]; then
    echo "FBA preprocessing completed successfully for ${SUBJECT}"
else
    echo "FBA preprocessing FAILED for ${SUBJECT} (exit code: $EXIT_CODE)"
fi
echo "End: $(date)"
echo "=========================================="

exit $EXIT_CODE
