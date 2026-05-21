#!/usr/bin/env python3
"""
DWI Quality Check for MeDALS BIDS dataset.

Checks file sizes, JSON metadata consistency, image dimensions/voxel sizes
(via mrinfo), and bval/bvec properties across all subjects and sessions.
Outputs a CSV summary to data/dwi_quality_check.csv.
"""

import csv
import glob
import json
import os
import subprocess
import sys
from collections import Counter

import numpy as np

BIDS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bids_data")
OUTPUT_CSV = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "dwi_quality_check.csv")

# Expected values (mode across dataset — will be computed from data)
BVAL_TOLERANCE = 50  # tolerance for grouping b-values into shells
BVEC_NORM_TOLERANCE = 0.1  # tolerance for unit norm check


def run_mrinfo(nii_path, flag):
    """Run mrinfo with a given flag and return stripped output."""
    try:
        result = subprocess.run(
            ["mrinfo", flag, nii_path],
            capture_output=True, text=True, timeout=30
        )
        return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return "N/A"


def get_file_size_mb(path):
    """Return file size in MB, or None if file doesn't exist."""
    if os.path.isfile(path):
        return round(os.path.getsize(path) / (1024 * 1024), 1)
    return None


def read_json(path):
    """Read a JSON sidecar file."""
    if not os.path.isfile(path):
        return {}
    with open(path) as f:
        return json.load(f)


def parse_bval(path):
    """Parse a .bval file and return array of b-values."""
    if not os.path.isfile(path):
        return None
    vals = np.loadtxt(path).flatten()
    return vals


def parse_bvec(path):
    """Parse a .bvec file and return (3, N) array."""
    if not os.path.isfile(path):
        return None
    vecs = np.loadtxt(path)
    if vecs.ndim == 1:
        vecs = vecs.reshape(3, -1)
    return vecs


def group_bvals(bvals, tolerance=BVAL_TOLERANCE):
    """Group b-values into shells using tolerance."""
    shells = {}
    for b in sorted(np.unique(bvals)):
        assigned = False
        for shell_center in shells:
            if abs(b - shell_center) <= tolerance:
                shells[shell_center] += int(np.sum(np.abs(bvals - b) <= tolerance))
                assigned = True
                break
        if not assigned:
            shells[b] = int(np.sum(np.abs(bvals - b) <= tolerance))
    return shells


def check_bvec_norms(bvecs, bvals):
    """Check that non-b0 gradient vectors have approximately unit norm."""
    if bvecs is None or bvals is None:
        return "N/A"
    non_b0 = bvals > BVAL_TOLERANCE
    if not np.any(non_b0):
        return "no_diffusion_vols"
    norms = np.linalg.norm(bvecs[:, non_b0], axis=0)
    if np.all(np.abs(norms - 1.0) < BVEC_NORM_TOLERANCE):
        return "OK"
    bad_count = int(np.sum(np.abs(norms - 1.0) >= BVEC_NORM_TOLERANCE))
    return f"FAIL({bad_count}_bad_norms)"


def find_dwi_files(dwi_dir, direction):
    """Find DWI nii.gz file for a given phase encoding direction."""
    pattern = os.path.join(dwi_dir, f"*_dir-{direction}_dwi.nii.gz")
    matches = glob.glob(pattern)
    # Filter out macOS ._ files
    matches = [m for m in matches if not os.path.basename(m).startswith("._")]
    return matches[0] if matches else None


def process_session(sub, ses, dwi_dir):
    """Process a single subject-session and return a dict of QC metrics."""
    row = {"subject": sub, "session": ses, "issues": []}

    # Find AP and PA files
    ap_nii = find_dwi_files(dwi_dir, "AP")
    pa_nii = find_dwi_files(dwi_dir, "PA")

    row["ap_file_exists"] = ap_nii is not None
    row["pa_file_exists"] = pa_nii is not None

    # File sizes
    row["ap_size_mb"] = get_file_size_mb(ap_nii) if ap_nii else None
    row["pa_size_mb"] = get_file_size_mb(pa_nii) if pa_nii else None

    if not ap_nii:
        row["issues"].append("missing_AP_nii")
    if not pa_nii:
        row["issues"].append("missing_PA_nii")

    # mrinfo: dimensions and voxel size
    for prefix, nii in [("ap", ap_nii), ("pa", pa_nii)]:
        if nii:
            dims = run_mrinfo(nii, "-size")
            spacing = run_mrinfo(nii, "-spacing")
            row[f"{prefix}_dimensions"] = dims.replace(" ", "x") if dims != "N/A" else "N/A"
            row[f"{prefix}_voxel_size"] = spacing.replace(" ", "x") if spacing != "N/A" else "N/A"
        else:
            row[f"{prefix}_dimensions"] = None
            row[f"{prefix}_voxel_size"] = None

    # JSON metadata
    for prefix, nii in [("ap", ap_nii), ("pa", pa_nii)]:
        if nii:
            json_path = nii.replace(".nii.gz", ".json")
            meta = read_json(json_path)
            row[f"{prefix}_phase_encoding"] = meta.get("PhaseEncodingDirection", "N/A")
            row[f"{prefix}_total_readout_time"] = meta.get("TotalReadoutTime", "N/A")
            if prefix == "ap":
                row["ap_echo_time"] = meta.get("EchoTime", "N/A")
                row["ap_repetition_time"] = meta.get("RepetitionTime", "N/A")
                row["ap_mb_factor"] = meta.get("MultibandAccelerationFactor", "N/A")
        else:
            row[f"{prefix}_phase_encoding"] = None
            row[f"{prefix}_total_readout_time"] = None
            if prefix == "ap":
                row["ap_echo_time"] = None
                row["ap_repetition_time"] = None
                row["ap_mb_factor"] = None

    # bval/bvec analysis (AP only — PA is just b0)
    if ap_nii:
        bval_path = ap_nii.replace(".nii.gz", ".bval")
        bvec_path = ap_nii.replace(".nii.gz", ".bvec")
        bvals = parse_bval(bval_path)
        bvecs = parse_bvec(bvec_path)

        if bvals is not None:
            row["num_total_volumes"] = len(bvals)
            shells = group_bvals(bvals)
            # Assign shell counts
            row["num_b0"] = 0
            row["num_b1000"] = 0
            row["num_b2500"] = 0
            for center, count in shells.items():
                if center <= BVAL_TOLERANCE:
                    row["num_b0"] = count
                elif 900 <= center <= 1100:
                    row["num_b1000"] = count
                elif 2400 <= center <= 2600:
                    row["num_b2500"] = count
            row["unique_bvals"] = ";".join(str(int(b)) for b in sorted(shells.keys()))
        else:
            row["num_total_volumes"] = None
            row["num_b0"] = None
            row["num_b1000"] = None
            row["num_b2500"] = None
            row["unique_bvals"] = None
            row["issues"].append("missing_bval")

        if bvecs is not None:
            # Non-zero directions (excluding b0 volumes)
            if bvals is not None:
                non_b0_mask = bvals > BVAL_TOLERANCE
                row["num_directions"] = int(np.sum(non_b0_mask))
            else:
                norms = np.linalg.norm(bvecs, axis=0)
                row["num_directions"] = int(np.sum(norms > 0.1))
            row["bvec_norm_ok"] = check_bvec_norms(bvecs, bvals)
        else:
            row["num_directions"] = None
            row["bvec_norm_ok"] = None
            row["issues"].append("missing_bvec")
    else:
        for key in ["num_total_volumes", "num_b0", "num_b1000", "num_b2500",
                     "unique_bvals", "num_directions", "bvec_norm_ok"]:
            row[key] = None

    return row


def flag_outliers(all_rows):
    """Compare each row against the mode values and flag deviations."""
    # Compute expected values from the mode of each field
    fields_to_check = {
        "ap_phase_encoding": "unexpected_AP_phase_encoding",
        "pa_phase_encoding": "unexpected_PA_phase_encoding",
        "ap_total_readout_time": "unexpected_AP_readout_time",
        "ap_echo_time": "unexpected_AP_echo_time",
        "ap_repetition_time": "unexpected_AP_repetition_time",
        "ap_mb_factor": "unexpected_AP_mb_factor",
        "num_total_volumes": "unexpected_num_volumes",
        "num_b0": "unexpected_num_b0",
        "num_b1000": "unexpected_num_b1000",
        "num_b2500": "unexpected_num_b2500",
        "ap_dimensions": "unexpected_AP_dimensions",
        "pa_dimensions": "unexpected_PA_dimensions",
        "ap_voxel_size": "unexpected_AP_voxel_size",
        "pa_voxel_size": "unexpected_PA_voxel_size",
    }

    # Compute mode for each field
    expected = {}
    for field in fields_to_check:
        values = [r[field] for r in all_rows if r[field] is not None and r[field] != "N/A"]
        if values:
            counter = Counter(values)
            expected[field] = counter.most_common(1)[0][0]

    # Flag deviations
    for row in all_rows:
        for field, issue_label in fields_to_check.items():
            val = row[field]
            if val is None or val == "N/A":
                continue
            if field in expected and val != expected[field]:
                row["issues"].append(f"{issue_label}({val})")

        # Flag abnormal AP file sizes (>2 SD from mean)
        ap_sizes = [r["ap_size_mb"] for r in all_rows if r["ap_size_mb"] is not None]
        if row["ap_size_mb"] is not None and ap_sizes:
            mean_size = np.mean(ap_sizes)
            std_size = np.std(ap_sizes)
            if std_size > 0 and abs(row["ap_size_mb"] - mean_size) > 2 * std_size:
                row["issues"].append(f"abnormal_AP_size({row['ap_size_mb']}MB)")

        # Flag bvec norm issues
        if row.get("bvec_norm_ok") and row["bvec_norm_ok"] not in ("OK", "N/A", None):
            row["issues"].append("bvec_norm_issue")

    return all_rows


def main():
    # Discover all subject-session-dwi directories
    dwi_dirs = sorted(glob.glob(os.path.join(BIDS_DIR, "sub-*", "ses-*", "dwi")))

    if not dwi_dirs:
        print(f"ERROR: No DWI directories found in {BIDS_DIR}")
        sys.exit(1)

    print(f"Found {len(dwi_dirs)} subject-session DWI directories")

    all_rows = []
    for i, dwi_dir in enumerate(dwi_dirs):
        parts = dwi_dir.split(os.sep)
        sub = [p for p in parts if p.startswith("sub-")][0]
        ses = [p for p in parts if p.startswith("ses-")][0]
        print(f"  [{i+1}/{len(dwi_dirs)}] Processing {sub}/{ses}...", end="", flush=True)
        row = process_session(sub, ses, dwi_dir)
        all_rows.append(row)
        n_issues = len(row["issues"])
        print(f" done ({n_issues} issue{'s' if n_issues != 1 else ''})" if n_issues else " OK")

    # Flag outliers by comparing against mode
    all_rows = flag_outliers(all_rows)

    # Convert issues list to string
    for row in all_rows:
        row["issues"] = "; ".join(row["issues"]) if row["issues"] else ""

    # Define column order
    columns = [
        "subject", "session",
        "ap_file_exists", "pa_file_exists",
        "ap_size_mb", "pa_size_mb",
        "ap_dimensions", "pa_dimensions",
        "ap_voxel_size", "pa_voxel_size",
        "ap_phase_encoding", "pa_phase_encoding",
        "ap_total_readout_time", "pa_total_readout_time",
        "ap_echo_time", "ap_repetition_time", "ap_mb_factor",
        "num_b0", "num_b1000", "num_b2500", "num_total_volumes",
        "unique_bvals", "num_directions", "bvec_norm_ok",
        "issues",
    ]

    # Write CSV
    os.makedirs(os.path.dirname(OUTPUT_CSV), exist_ok=True)
    with open(OUTPUT_CSV, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        writer.writerows(all_rows)

    print(f"\nCSV written to: {OUTPUT_CSV}")
    print(f"Total rows: {len(all_rows)}")

    # Summary
    issues_count = sum(1 for r in all_rows if r["issues"])
    print(f"Sessions with issues: {issues_count}/{len(all_rows)}")
    if issues_count:
        print("\nSessions with issues:")
        for r in all_rows:
            if r["issues"]:
                print(f"  {r['subject']}/{r['session']}: {r['issues']}")


if __name__ == "__main__":
    main()
