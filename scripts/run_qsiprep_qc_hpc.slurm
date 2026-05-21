#!/bin/bash
#SBATCH --job-name=qsiprep_qc_medals
#SBATCH --account=a_aibn
#SBATCH --output=/scratch/user/uqahonne/als/MeDALS_DWI/qc_results/logs/qsiprep_qc_%j.out
#SBATCH --error=/scratch/user/uqahonne/als/MeDALS_DWI/qc_results/logs/qsiprep_qc_%j.err
#SBATCH --time=02:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --partition=general

###############################################################################
# MeDALS DWI — QSIPrep QC Pipeline (HPC)
###############################################################################
#
# Usage:
#   sbatch run_qsiprep_qc_hpc.slurm
#
###############################################################################

# Python virtual environment
VENV_PATH="/home/uqahonne/venvs/qc_ukb_env/bin/activate"

# Paths
QSIPREP_DIR="/scratch/user/uqahonne/als/MeDALS_DWI/qsiprep_output"
RESULTS_DIR="/scratch/user/uqahonne/als/MeDALS_DWI/qc_results"
SCRIPTS_DIR="/home/uqahonne/uq/ALS/MeDALS_DWI/scripts"

###############################################################################

echo "================================================================================"
echo "MeDALS DWI — QSIPrep QC Pipeline"
echo "================================================================================"
echo "Job ID: $SLURM_JOB_ID"
echo "Start time: $(date)"
echo ""
echo "Configuration:"
echo "  QSIprep output: $QSIPREP_DIR"
echo "  Results dir:    $RESULTS_DIR"
echo "  Scripts dir:    $SCRIPTS_DIR"
echo "================================================================================"
echo ""

# Validate paths
if [ ! -d "$QSIPREP_DIR" ]; then
    echo "Error: QSIprep output directory not found: $QSIPREP_DIR"
    exit 1
fi

# Create output directories
mkdir -p "$RESULTS_DIR/logs"

###############################################################################
# Activate Python environment
###############################################################################

echo "Activating Python virtual environment..."

if [ ! -f "$VENV_PATH" ]; then
    echo "Error: Virtual environment not found at: $VENV_PATH"
    exit 1
fi

source "$VENV_PATH"

echo "Using Python: $(which python3)"

# Verify required packages
python3 -c "import numpy" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "Error: numpy not found. Install: pip install numpy"
    exit 1
fi

echo "Python environment ready"
echo ""

###############################################################################
# Run QC
###############################################################################

echo "================================================================================"
echo "Running QSIPrep QC metrics extraction"
echo "================================================================================"

python3 "${SCRIPTS_DIR}/qc_qsiprep_medals.py" \
    --output-dir "$QSIPREP_DIR" \
    --results-dir "$RESULTS_DIR" \
    --session ses-01

EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    echo "Error: QC script failed (exit code: $EXIT_CODE)"
    exit 1
fi

echo ""
echo "================================================================================"
echo "QC PIPELINE COMPLETE"
echo "================================================================================"
echo "End time: $(date)"
echo ""
echo "Output files in: $RESULTS_DIR"
echo "  - qsiprep_qc_metrics.csv"
echo "  - qsiprep_qc_summary.txt"
echo "================================================================================"

exit 0
