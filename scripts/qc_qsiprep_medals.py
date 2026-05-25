#!/usr/bin/env python3
"""
QSIPrep QC Metrics Extraction for MeDALS DWI Dataset.

Extracts and aggregates QC metrics from qsiprep outputs across all subjects.
Produces:
  1. qsiprep_qc_metrics.csv       — full metrics per subject
  2. qsiprep_qc_summary.txt       — text report with flagged subjects

Usage:
  python qc_qsiprep_medals.py [--output-dir /path/to/qsiprep_output]
"""

import argparse
import csv
import glob
import json
import os
import sys

import numpy as np

# Default paths
DEFAULT_OUTPUT_DIR = "/scratch/user/uqahonne/als/MeDALS_DWI/qsiprep_output"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RESULTS_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), "data")

# QC thresholds
THRESHOLDS = {
    "mean_fd_high": 1.0,
    "mean_fd_review": 0.5,
    "max_fd_high": 3.0,
    "max_fd_review": 2.0,
    "t1_dice_distance_poor": 0.10,
    "t1_dice_distance_review": 0.05,
    "neighbor_corr_fail": 0.70,
    "neighbor_corr_review": 0.85,
    "bad_slices_high": 5,
    "cnr_low": 1.5,
    "cnr_review": 2.0,
    "eddy_stdev_severe": 100,
    "pct_high_motion_vols": 0.30,
}


def parse_confounds(tsv_path):
    """Parse confounds TSV and extract motion/eddy summary metrics."""
    metrics = {}
    try:
        with open(tsv_path) as f:
            reader = csv.DictReader(f, delimiter="\t")
            rows = list(reader)

        if not rows:
            return metrics

        fd_vals = [float(r["framewise_displacement"]) for r in rows
                   if r["framewise_displacement"] not in ("", "n/a", "NaN")]
        eddy_vals = [float(r["eddy_stdevs"]) for r in rows
                     if r["eddy_stdevs"] not in ("", "n/a", "NaN")]

        if fd_vals:
            metrics["mean_fd"] = round(np.mean(fd_vals), 4)
            metrics["median_fd"] = round(np.median(fd_vals), 4)
            metrics["max_fd"] = round(np.max(fd_vals), 4)
            metrics["num_volumes"] = len(rows)
            metrics["num_vols_fd_gt_0.5"] = sum(1 for v in fd_vals if v > 0.5)
            metrics["num_vols_fd_gt_1.0"] = sum(1 for v in fd_vals if v > 1.0)
            metrics["num_vols_fd_gt_2.0"] = sum(1 for v in fd_vals if v > 2.0)
            metrics["pct_vols_fd_gt_0.5"] = round(
                metrics["num_vols_fd_gt_0.5"] / len(fd_vals) * 100, 1)

        if eddy_vals:
            metrics["max_eddy_stdev"] = round(np.max(np.abs(eddy_vals)), 2)
            metrics["num_severe_eddy_vols"] = sum(
                1 for v in eddy_vals if abs(v) > THRESHOLDS["eddy_stdev_severe"])

        # Denoising effectiveness
        p2s_pre = [float(r["Patch2Self_pre"]) for r in rows
                   if r.get("Patch2Self_pre", "") not in ("", "n/a", "NaN")]
        p2s_post = [float(r["Patch2Self_post"]) for r in rows
                    if r.get("Patch2Self_post", "") not in ("", "n/a", "NaN")]
        if p2s_pre and p2s_post:
            metrics["mean_patch2self_change"] = round(
                np.mean(np.array(p2s_post) - np.array(p2s_pre)), 4)

    except Exception as e:
        metrics["confounds_error"] = str(e)

    return metrics


def parse_image_qc(tsv_path):
    """Parse the image QC TSV (single row with all metrics)."""
    metrics = {}
    try:
        with open(tsv_path) as f:
            reader = csv.DictReader(f, delimiter="\t")
            rows = list(reader)

        if not rows:
            return metrics

        row = rows[0]

        # Map columns to cleaner names
        field_map = {
            # Raw image quality
            "raw_neighbor_corr": "raw_neighbor_corr",
            "raw_masked_neighbor_corr": "raw_masked_neighbor_corr",
            "raw_dwi_contrast": "raw_dwi_contrast",
            "raw_num_bad_slices": "raw_num_bad_slices",
            "raw_coherence_index": "raw_coherence_index",
            "raw_dimension_x": "raw_dim_x",
            "raw_dimension_y": "raw_dim_y",
            "raw_dimension_z": "raw_dim_z",
            "raw_voxel_size_x": "raw_vox_x",
            "raw_voxel_size_y": "raw_vox_y",
            "raw_voxel_size_z": "raw_vox_z",
            # T1-registered quality
            "t1_neighbor_corr": "t1_neighbor_corr",
            "t1_masked_neighbor_corr": "t1_masked_neighbor_corr",
            "t1_dwi_contrast": "t1_dwi_contrast",
            "t1_num_bad_slices": "t1_num_bad_slices",
            "t1_coherence_index": "t1_coherence_index",
            # Post-processed quality
            "t1post_neighbor_corr": "t1post_neighbor_corr",
            "t1post_masked_neighbor_corr": "t1post_masked_neighbor_corr",
            "t1post_dwi_contrast": "t1post_dwi_contrast",
            "t1post_num_bad_slices": "t1post_num_bad_slices",
            "t1post_coherence_index": "t1post_coherence_index",
            # Registration and motion
            "t1_dice_distance": "t1_dice_distance",
            "mean_fd": "iq_mean_fd",
            "max_fd": "iq_max_fd",
            "max_rotation": "max_rotation",
            "max_translation": "max_translation",
            "max_rel_rotation": "max_rel_rotation",
            "max_rel_translation": "max_rel_translation",
            # CNR
            "CNR0_mean": "cnr_b0_mean",
            "CNR1_mean": "cnr_b1000_mean",
            "CNR2_mean": "cnr_b2500_mean",
            "CNR0_median": "cnr_b0_median",
            "CNR1_median": "cnr_b1000_median",
            "CNR2_median": "cnr_b2500_median",
            "CNR0_standard_deviation": "cnr_b0_std",
            "CNR1_standard_deviation": "cnr_b1000_std",
            "CNR2_standard_deviation": "cnr_b2500_std",
            # Fieldmap
            "fieldmap_hz_mean": "fieldmap_hz_mean",
            "fieldmap_hz_median": "fieldmap_hz_median",
            "fieldmap_hz_minimum": "fieldmap_hz_min",
            "fieldmap_hz_maximum": "fieldmap_hz_max",
            "fieldmap_hz_standard_deviation": "fieldmap_hz_std",
        }

        for src, dst in field_map.items():
            val = row.get(src, "")
            if val not in ("", "n/a", "NaN"):
                try:
                    metrics[dst] = float(val)
                except ValueError:
                    metrics[dst] = val

    except Exception as e:
        metrics["image_qc_error"] = str(e)

    return metrics


def check_completeness(sub_dir, session="ses-01"):
    """Check if critical output files exist."""
    ses_dwi = os.path.join(sub_dir, session, "dwi")
    anat_dir = os.path.join(sub_dir, "anat")

    critical_files = {
        "preproc_dwi": glob.glob(os.path.join(ses_dwi, "*_desc-preproc_dwi.nii.gz")),
        "preproc_bval": glob.glob(os.path.join(ses_dwi, "*_desc-preproc_dwi.bval")),
        "preproc_bvec": glob.glob(os.path.join(ses_dwi, "*_desc-preproc_dwi.bvec")),
        "brain_mask": glob.glob(os.path.join(ses_dwi, "*_desc-brain_mask.nii.gz")),
        "confounds": glob.glob(os.path.join(ses_dwi, "*_desc-confounds_timeseries.tsv")),
        "image_qc": glob.glob(os.path.join(ses_dwi, "*_desc-image_qc.tsv")),
        "t1w": glob.glob(os.path.join(anat_dir, "*_desc-preproc_T1w.nii.gz")),
        "t1_mask": glob.glob(os.path.join(anat_dir, "*_desc-brain_mask.nii.gz")),
    }

    status = {}
    missing = []
    for name, files in critical_files.items():
        if files:
            status[name] = True
            if name == "preproc_dwi":
                size_mb = os.path.getsize(files[0]) / (1024 * 1024)
                status["preproc_dwi_size_mb"] = round(size_mb, 1)
                if size_mb < 10:
                    missing.append(f"{name}_suspicious_size({size_mb:.0f}MB)")
        else:
            status[name] = False
            missing.append(name)

    status["complete"] = len(missing) == 0
    status["missing_files"] = "; ".join(missing) if missing else ""
    return status


def classify_qc(metrics):
    """Assign QC classification: PASS, REVIEW, or EXCLUDE."""
    flags_exclude = []
    flags_review = []

    # Motion
    mean_fd = metrics.get("mean_fd")
    max_fd = metrics.get("max_fd")
    if mean_fd is not None:
        if mean_fd > THRESHOLDS["mean_fd_high"]:
            flags_exclude.append(f"excessive_mean_fd({mean_fd:.2f})")
        elif mean_fd > THRESHOLDS["mean_fd_review"]:
            flags_review.append(f"high_mean_fd({mean_fd:.2f})")
    if max_fd is not None:
        if max_fd > THRESHOLDS["max_fd_high"]:
            flags_exclude.append(f"excessive_max_fd({max_fd:.2f})")
        elif max_fd > THRESHOLDS["max_fd_review"]:
            flags_review.append(f"high_max_fd({max_fd:.2f})")

    # High motion volume percentage
    pct = metrics.get("pct_vols_fd_gt_0.5")
    if pct is not None and pct > THRESHOLDS["pct_high_motion_vols"] * 100:
        flags_review.append(f"high_pct_motion_vols({pct:.0f}%)")

    # Registration
    dice = metrics.get("t1_dice_distance")
    if dice is not None:
        if dice > THRESHOLDS["t1_dice_distance_poor"]:
            flags_exclude.append(f"poor_registration({dice:.3f})")
        elif dice > THRESHOLDS["t1_dice_distance_review"]:
            flags_review.append(f"borderline_registration({dice:.3f})")

    # Neighbor correlation (post-processed)
    ncorr = metrics.get("t1post_neighbor_corr")
    if ncorr is not None:
        if ncorr < THRESHOLDS["neighbor_corr_fail"]:
            flags_exclude.append(f"low_neighbor_corr({ncorr:.3f})")
        elif ncorr < THRESHOLDS["neighbor_corr_review"]:
            flags_review.append(f"borderline_neighbor_corr({ncorr:.3f})")

    # Bad slices (post-processed)
    bad_slices = metrics.get("t1post_num_bad_slices")
    if bad_slices is not None and bad_slices > THRESHOLDS["bad_slices_high"]:
        flags_review.append(f"bad_slices_post({int(bad_slices)})")

    # CNR
    for shell, key in [("b1000", "cnr_b1000_mean"), ("b2500", "cnr_b2500_mean")]:
        cnr = metrics.get(key)
        if cnr is not None:
            if cnr < THRESHOLDS["cnr_low"]:
                flags_exclude.append(f"low_cnr_{shell}({cnr:.2f})")
            elif cnr < THRESHOLDS["cnr_review"]:
                flags_review.append(f"borderline_cnr_{shell}({cnr:.2f})")

    # Eddy
    severe = metrics.get("num_severe_eddy_vols", 0)
    if severe > 5:
        flags_exclude.append(f"many_severe_eddy_vols({severe})")
    elif severe > 0:
        flags_review.append(f"severe_eddy_vols({severe})")

    # Classification
    if flags_exclude:
        qc_status = "EXCLUDE"
    elif len(flags_review) >= 2:
        qc_status = "REVIEW"
    elif flags_review:
        qc_status = "REVIEW"
    else:
        qc_status = "PASS"

    return qc_status, flags_exclude + flags_review


def process_subject(sub_dir, session="ses-01"):
    """Process a single subject and return all QC metrics."""
    sub_id = os.path.basename(sub_dir)
    ses_dwi = os.path.join(sub_dir, session, "dwi")

    metrics = {"subject": sub_id, "session": session}

    # Completeness
    completeness = check_completeness(sub_dir, session)
    metrics.update(completeness)

    if not completeness["complete"]:
        metrics["qc_status"] = "INCOMPLETE"
        metrics["qc_flags"] = completeness["missing_files"]
        return metrics

    # Image QC (from qsiprep's own TSV)
    iq_files = glob.glob(os.path.join(ses_dwi, "*_desc-image_qc.tsv"))
    if iq_files:
        iq_metrics = parse_image_qc(iq_files[0])
        metrics.update(iq_metrics)

    # Confounds (motion, eddy, denoising)
    conf_files = glob.glob(os.path.join(ses_dwi, "*_desc-confounds_timeseries.tsv"))
    if conf_files:
        conf_metrics = parse_confounds(conf_files[0])
        metrics.update(conf_metrics)

    # QC classification
    qc_status, qc_flags = classify_qc(metrics)
    metrics["qc_status"] = qc_status
    metrics["qc_flags"] = "; ".join(qc_flags) if qc_flags else ""

    return metrics


def generate_summary(all_metrics, output_path):
    """Generate a text summary report."""
    total = len(all_metrics)
    complete = sum(1 for m in all_metrics if m.get("complete", False))
    incomplete = total - complete

    status_counts = {}
    for m in all_metrics:
        s = m.get("qc_status", "UNKNOWN")
        status_counts[s] = status_counts.get(s, 0) + 1

    # Collect numeric metrics for stats
    fds = [m["mean_fd"] for m in all_metrics if "mean_fd" in m]
    dices = [m["t1_dice_distance"] for m in all_metrics
             if "t1_dice_distance" in m]
    cnr1s = [m["cnr_b1000_mean"] for m in all_metrics
             if "cnr_b1000_mean" in m]
    cnr2s = [m["cnr_b2500_mean"] for m in all_metrics
             if "cnr_b2500_mean" in m]

    lines = []
    lines.append("=" * 70)
    lines.append("  MeDALS DWI — QSIPrep QC Summary Report")
    lines.append("=" * 70)
    lines.append("")
    lines.append(f"Total subjects:    {total}")
    lines.append(f"Complete:          {complete}")
    lines.append(f"Incomplete:        {incomplete}")
    lines.append("")
    lines.append("QC Classification:")
    for status in ["PASS", "REVIEW", "EXCLUDE", "INCOMPLETE"]:
        count = status_counts.get(status, 0)
        lines.append(f"  {status:12s}  {count:3d}  ({count/total*100:.0f}%)")
    lines.append("")

    if fds:
        lines.append("Motion (Framewise Displacement, mm):")
        lines.append(f"  Mean FD:  {np.mean(fds):.3f} ± {np.std(fds):.3f}  "
                     f"[{np.min(fds):.3f} — {np.max(fds):.3f}]")
    if dices:
        lines.append(f"T1-DWI Registration (Dice distance, lower=better):")
        lines.append(f"  Dice:     {np.mean(dices):.4f} ± {np.std(dices):.4f}  "
                     f"[{np.min(dices):.4f} — {np.max(dices):.4f}]")
    if cnr1s:
        lines.append(f"CNR b=1000:")
        lines.append(f"  Mean:     {np.mean(cnr1s):.2f} ± {np.std(cnr1s):.2f}  "
                     f"[{np.min(cnr1s):.2f} — {np.max(cnr1s):.2f}]")
    if cnr2s:
        lines.append(f"CNR b=2500:")
        lines.append(f"  Mean:     {np.mean(cnr2s):.2f} ± {np.std(cnr2s):.2f}  "
                     f"[{np.min(cnr2s):.2f} — {np.max(cnr2s):.2f}]")

    lines.append("")
    lines.append("-" * 70)

    # List flagged subjects
    for status in ["EXCLUDE", "REVIEW"]:
        subs = [m for m in all_metrics if m.get("qc_status") == status]
        if subs:
            lines.append(f"\n{status} subjects ({len(subs)}):")
            for m in subs:
                lines.append(f"  {m['subject']:12s}  {m.get('qc_flags', '')}")

    incomplete_subs = [m for m in all_metrics
                       if m.get("qc_status") == "INCOMPLETE"]
    if incomplete_subs:
        lines.append(f"\nINCOMPLETE subjects ({len(incomplete_subs)}):")
        for m in incomplete_subs:
            lines.append(f"  {m['subject']:12s}  missing: {m.get('missing_files', '')}")

    # PASS subjects
    pass_subs = [m for m in all_metrics if m.get("qc_status") == "PASS"]
    lines.append(f"\nPASS subjects ({len(pass_subs)}):")
    for m in pass_subs:
        lines.append(f"  {m['subject']}")

    lines.append("")
    lines.append("=" * 70)

    report = "\n".join(lines)

    with open(output_path, "w") as f:
        f.write(report)

    return report


def main():
    parser = argparse.ArgumentParser(description="QSIPrep QC for MeDALS DWI")
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR,
                        help="QSIPrep output directory")
    parser.add_argument("--results-dir", default=RESULTS_DIR,
                        help="Where to save QC results")
    parser.add_argument("--session", default="ses-01",
                        help="Session to QC")
    args = parser.parse_args()

    output_dir = args.output_dir
    results_dir = args.results_dir
    os.makedirs(results_dir, exist_ok=True)

    # Find all subject directories
    sub_dirs = sorted(glob.glob(os.path.join(output_dir, "sub-*")))
    sub_dirs = [d for d in sub_dirs if os.path.isdir(d)]

    if not sub_dirs:
        print(f"ERROR: No subject directories found in {output_dir}")
        sys.exit(1)

    print(f"Found {len(sub_dirs)} subjects in {output_dir}")

    # Process each subject
    all_metrics = []
    for i, sub_dir in enumerate(sub_dirs):
        sub_id = os.path.basename(sub_dir)
        print(f"  [{i+1}/{len(sub_dirs)}] {sub_id}...", end="", flush=True)
        metrics = process_subject(sub_dir, args.session)
        all_metrics.append(metrics)
        print(f" {metrics.get('qc_status', 'UNKNOWN')}")

    # Determine all columns from all subjects
    all_keys = []
    seen = set()
    # Ensure key columns come first
    priority_keys = [
        "subject", "session", "qc_status", "qc_flags", "complete",
        "missing_files", "preproc_dwi_size_mb",
        "mean_fd", "median_fd", "max_fd", "num_volumes",
        "num_vols_fd_gt_0.5", "num_vols_fd_gt_1.0", "num_vols_fd_gt_2.0",
        "pct_vols_fd_gt_0.5",
        "max_eddy_stdev", "num_severe_eddy_vols",
        "t1_dice_distance",
        "t1post_neighbor_corr", "t1post_masked_neighbor_corr",
        "t1post_num_bad_slices",
        "cnr_b0_mean", "cnr_b1000_mean", "cnr_b2500_mean",
        "cnr_b0_median", "cnr_b1000_median", "cnr_b2500_median",
        "fieldmap_hz_mean", "fieldmap_hz_std",
        "raw_num_bad_slices", "raw_neighbor_corr",
        "mean_patch2self_change",
    ]
    for k in priority_keys:
        if k not in seen:
            all_keys.append(k)
            seen.add(k)
    for m in all_metrics:
        for k in m:
            if k not in seen:
                all_keys.append(k)
                seen.add(k)

    # Write CSV
    csv_path = os.path.join(results_dir, "qsiprep_qc_metrics.csv")
    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=all_keys, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(all_metrics)

    print(f"\nCSV written to: {csv_path}")

    # Generate summary report
    summary_path = os.path.join(results_dir, "qsiprep_qc_summary.txt")
    report = generate_summary(all_metrics, summary_path)
    print(f"Summary written to: {summary_path}")
    print("")
    print(report)


if __name__ == "__main__":
    main()
