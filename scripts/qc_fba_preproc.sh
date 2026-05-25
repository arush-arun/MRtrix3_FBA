#!/bin/bash

# QC script for FBA preprocessing outputs
# Run after all subjects complete preprocessing
#
# Usage:
#   bash qc_fba_preproc.sh [job_id]
#   e.g.: bash qc_fba_preproc.sh 24276291

set -euo pipefail

# Load FSL for eddy_squad
module use /sw/local/rocky8/noarch/neuro/software/neurocommand/local/containers/modules/
export APPTAINER_BINDPATH=/scratch,/QRISdata
ml fsl/6.0.7.9

# Update these paths for your environment
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$(dirname "$0")")}"
DERIVATIVES="${PROJECT_DIR}/derivatives"
LOG_DIR="${PROJECT_DIR}/fba_logs"
PARTICIPANT_LIST="${PROJECT_DIR}/scripts/participant_list_ses01.txt"
SESSION="ses-01"
QC_OUTPUT="${PROJECT_DIR}/fba_qc_summary.csv"

JOB_ID="${1:-}"

echo "=============================================="
echo "FBA Preprocessing QC Summary"
echo "Date: $(date)"
echo "=============================================="

# ---------------------------------------------------------------
# 1. Job completion status
# ---------------------------------------------------------------
echo ""
echo "--- 1. Job Completion ---"
if [[ -n "$JOB_ID" ]]; then
    n_success=$( (grep -l "completed successfully" "${LOG_DIR}/fba_${JOB_ID}_"*.out 2>/dev/null || true) | wc -l)
    n_failed=$( (grep -l "FAILED" "${LOG_DIR}/fba_${JOB_ID}_"*.out 2>/dev/null || true) | wc -l)
    n_total=$((n_success + n_failed))
    echo "Job ${JOB_ID}: ${n_success}/${n_total} succeeded, ${n_failed} failed"

    if [[ $n_failed -gt 0 ]]; then
        echo "Failed subjects:"
        grep -l "FAILED" "${LOG_DIR}/fba_${JOB_ID}_"*.out 2>/dev/null | while read f; do
            grep "FBA Preprocessing:" "$f" | head -1
        done
    fi
else
    echo "No job ID provided — skipping log check"
fi

# ---------------------------------------------------------------
# 2. Check expected outputs
# ---------------------------------------------------------------
echo ""
echo "--- 2. Missing Outputs ---"
EXPECTED_FILES="data.mif dwi_denoised.mif noise.mif dwi_unr.mif dwi_preproc.mif dwi_unbiased_preproc.mif dwi_upsampled.mif dwi_mask.mif wm.txt gm.txt csf.txt"
n_complete=0
n_incomplete=0

while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    sub="sub-${line}"
    d="${DERIVATIVES}/${sub}/${SESSION}/dwi"
    missing=""
    for f in $EXPECTED_FILES; do
        [[ ! -f "${d}/${f}" ]] && missing="${missing} ${f}"
    done
    if [[ -n "$missing" ]]; then
        echo "  ${sub}: MISSING —${missing}"
        ((n_incomplete++)) || true
    else
        ((n_complete++)) || true
    fi
done < "$PARTICIPANT_LIST"

echo "Complete: ${n_complete}, Incomplete: ${n_incomplete}"

# ---------------------------------------------------------------
# 3. SNR summary
# ---------------------------------------------------------------
echo ""
echo "--- 3. SNR Summary ---"
if [[ -n "$JOB_ID" ]]; then
    echo "Subject SNR values (from logs):"
    (grep "SNR =" "${LOG_DIR}/fba_${JOB_ID}_"*.out 2>/dev/null || true) | \
        sed 's/.*\(sub-[0-9]*\) SNR = \(.*\)/  \1: \2/' | sort
    echo ""
    n_low=$( (grep "SNR =" "${LOG_DIR}/fba_${JOB_ID}_"*.out 2>/dev/null || true) | \
        sed 's/.*SNR = //' | awk '$1 < 10 {print}' | wc -l)
    echo "Subjects with SNR < 10: ${n_low}"
fi

# ---------------------------------------------------------------
# 4. Eddy QC metrics from QUAD qc.json — write CSV
# ---------------------------------------------------------------
echo ""
echo "--- 4. Eddy QC Metrics (from QUAD qc.json) ---"
echo "subject,abs_motion,rel_motion,outlier_pct,cnr_b1000,cnr_b2500" > "$QC_OUTPUT"

while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    sub="sub-${line}"
    qcjson="${DERIVATIVES}/${sub}/${SESSION}/dwi/eddyqc/quad/qc.json"

    abs_mot="NA"; rel_mot="NA"; outlier_pct="NA"; cnr_b1="NA"; cnr_b2="NA"

    if [[ -f "$qcjson" ]]; then
        read abs_mot rel_mot outlier_pct cnr_b1 cnr_b2 <<< $(python3 -c "
import json
d = json.load(open('$qcjson'))
print(round(d.get('qc_mot_abs',-1),4),
      round(d.get('qc_mot_rel',-1),4),
      round(d.get('qc_outliers_tot',-1),2),
      round(d.get('qc_cnr_avg',[0,0])[0],2),
      round(d.get('qc_cnr_avg',[0,0])[1],2))
" 2>/dev/null) || true
    fi

    echo "${sub},${abs_mot},${rel_mot},${outlier_pct},${cnr_b1},${cnr_b2}" >> "$QC_OUTPUT"
done < "$PARTICIPANT_LIST"

echo "QC metrics written to: ${QC_OUTPUT}"

# Print summary table
echo ""
printf "%-10s %10s %10s %10s %10s %10s\n" "Subject" "AbsMot" "RelMot" "Outlier%" "CNR_b1k" "CNR_b2.5k"
printf "%-10s %10s %10s %10s %10s %10s\n" "-------" "------" "------" "--------" "-------" "---------"
tail -n +2 "$QC_OUTPUT" | while IFS=, read -r sub abs rel opct cnr1 cnr2; do
    printf "%-10s %10s %10s %10s %10s %10s\n" "$sub" "$abs" "$rel" "$opct" "$cnr1" "$cnr2"
done

# ---------------------------------------------------------------
# 5. Flag subjects for review
# ---------------------------------------------------------------
echo ""
echo "--- 5. Flagged Subjects ---"
echo "Criteria: abs_motion > 2mm, rel_motion > 0.5mm, or outliers > 5%"
tail -n +2 "$QC_OUTPUT" | while IFS=, read -r sub abs rel opct cnr1 cnr2; do
    flag=""
    if [[ "$abs" != "NA" ]] && (( $(echo "$abs > 2.0" | bc -l) )); then flag="${flag} HIGH_ABS_MOTION(${abs}mm)"; fi
    if [[ "$rel" != "NA" ]] && (( $(echo "$rel > 0.5" | bc -l) )); then flag="${flag} HIGH_REL_MOTION(${rel}mm)"; fi
    if [[ "$opct" != "NA" ]] && (( $(echo "$opct > 5.0" | bc -l) )); then flag="${flag} HIGH_OUTLIERS(${opct}%)"; fi
    [[ -n "$flag" ]] && echo "  ${sub}:${flag}" || true
done

# ---------------------------------------------------------------
# 6. Response function check
# ---------------------------------------------------------------
echo ""
echo "--- 6. Response Functions ---"
echo "Checking WM response function consistency across subjects..."
n_rf=0
while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    sub="sub-${line}"
    wm="${DERIVATIVES}/${sub}/${SESSION}/dwi/wm.txt"
    if [[ -f "$wm" ]]; then
        n_lines=$(wc -l < "$wm")
        first_val=$(head -1 "$wm" | awk '{print $1}')
        echo "  ${sub}: ${n_lines} shells, b0_response=${first_val}"
        ((n_rf++)) || true
    fi
done < "$PARTICIPANT_LIST"
echo "Response functions found: ${n_rf}"

# ---------------------------------------------------------------
# 7. Group-level Eddy QC summary (from qc.json)
# ---------------------------------------------------------------
echo ""
echo "--- 7. Group-level Eddy QC Summary ---"
python3 -c "
import json, os, sys

qc_file = '$QC_OUTPUT'
# Read CSV (skip header)
abs_vals, rel_vals, out_vals = [], [], []
with open(qc_file) as f:
    next(f)
    for line in f:
        parts = line.strip().split(',')
        if len(parts) >= 4:
            try: abs_vals.append(float(parts[1]))
            except: pass
            try: rel_vals.append(float(parts[2]))
            except: pass
            try: out_vals.append(float(parts[3]))
            except: pass

def stats(vals, label):
    if not vals:
        print(f'  {label}: no data')
        return
    vals.sort()
    n = len(vals)
    mean = sum(vals)/n
    median = vals[n//2] if n%2 else (vals[n//2-1]+vals[n//2])/2
    print(f'  {label}: mean={mean:.3f}, median={median:.3f}, min={min(vals):.3f}, max={max(vals):.3f} (n={n})')

print('Group statistics:')
stats(abs_vals, 'Abs motion (mm)')
stats(rel_vals, 'Rel motion (mm)')
stats(out_vals, 'Outliers (%)')
" 2>/dev/null || echo "WARNING: Could not compute group summary"

echo ""
echo "=============================================="
echo "QC complete. Review flagged subjects above."
echo "CSV saved to: ${QC_OUTPUT}"
echo "=============================================="
