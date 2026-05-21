#!/usr/bin/env python3
"""
Automated FBA preprocessing QC using Claude Vision API.

Captures screenshots of RMS denoising residuals and bias field images
using mrview, sends them to Claude for visual assessment, and generates
a structured CSV report with PASS/FAIL/REVIEW ratings.

Usage:
    export ANTHROPIC_API_KEY="your-key"
    python3 ai_review_fba_qc.py <derivatives_dir> <participant_list> [--session ses-01]

Requires: MRtrix3 (mrview, mrmath, mrinfo) on PATH, anthropic Python SDK.
"""

import argparse
import base64
import csv
import json
import os
import re
import subprocess
import sys
import tempfile
import time

import anthropic

MODEL = "claude-sonnet-4-20250514"

QC_SYSTEM_PROMPT = """You are a neuroimaging quality control expert reviewing MRtrix3 FBA preprocessing outputs.
You will be shown brain MRI screenshots and must assess their quality.

Respond ONLY with valid JSON in this exact format:
{"rating": "PASS|FAIL|REVIEW", "notes": "brief explanation"}

No other text outside the JSON."""

RESIDUAL_PROMPT = """These are axial, coronal, and sagittal slices of an RMS denoising residual map
from MP-PCA denoising of diffusion MRI data.

QC Criteria:
- PASS: Uniform salt-and-pepper noise pattern (TV static). No recognizable anatomical structures.
- FAIL: Visible ventricles, cortex folds, tissue boundaries, or sharp CSF/WM/GM interfaces.
  This means denoising removed actual brain signal, not just noise.
- REVIEW: Slightly higher intensity near brain surface is acceptable (coil sensitivity).
  Faint edge structures are tolerable. Some Gibbs ringing artifacts are expected.

Assess this residual map and rate it PASS, FAIL, or REVIEW."""

BIAS_PROMPT = """These are axial, coronal, and sagittal slices of a bias field image
from dwibiascorrect (ANTs N4) applied to diffusion MRI data.

The bias field represents B1 field inhomogeneity (RF coil sensitivity).
It is a multiplicative correction factor that should be centered around 1.0.

QC Criteria:
- PASS: Spatially smooth gentle gradient or dome shape. No anatomical structure visible.
  Values near 1.0 (typically 0.8-1.2). Pattern plausible for receive coil geometry.
- FAIL: Anatomical features visible in the field. Extreme values far from 1.0 (e.g., 3.0 or 0.2).
  Cerebellar/brainstem hyperintensity (most common N4 failure). Hard edges at mask boundaries.
- REVIEW: Mild asymmetry or slightly wider value range (up to ~2.0) but still smooth and featureless.

Assess this bias field and rate it PASS, FAIL, or REVIEW."""


def run_cmd(cmd, check=True):
    """Run a shell command and return stdout."""
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if check and result.returncode != 0:
        print(f"  WARNING: command failed: {cmd}", file=sys.stderr)
        print(f"  stderr: {result.stderr.strip()}", file=sys.stderr)
        return None
    return result.stdout.strip()


def get_center_voxel(image_path):
    """Get center voxel coordinates from mrinfo."""
    size_str = run_cmd(f"mrinfo -size \"{image_path}\"")
    if not size_str:
        return None
    dims = size_str.split()
    cx = int(dims[0]) // 2
    cy = int(dims[1]) // 2
    cz = int(dims[2]) // 2
    return cx, cy, cz


def capture_slices(image_path, output_dir, prefix):
    """Capture axial, coronal, sagittal slices using mrview.

    Returns list of PNG file paths, or empty list on failure.
    """
    center = get_center_voxel(image_path)
    if center is None:
        return []

    cx, cy, cz = center
    voxel_str = f"{cx},{cy},{cz}"
    planes = {"axial": 2, "coronal": 1, "sagittal": 0}
    pngs = []

    for name, plane_idx in planes.items():
        out_prefix = f"{prefix}_{name}"
        cmd = (
            f"mrview -platform offscreen \"{image_path}\" "
            f"-plane {plane_idx} -voxel {voxel_str} "
            f"-capture.folder \"{output_dir}\" -capture.prefix \"{out_prefix}\" "
            f"-capture.grab -exit"
        )
        result = run_cmd(cmd, check=False)

        # Check if offscreen failed, try xvfb-run fallback
        if result is None:
            cmd_xvfb = (
                f"xvfb-run -a mrview \"{image_path}\" "
                f"-plane {plane_idx} -voxel {voxel_str} "
                f"-capture.folder \"{output_dir}\" -capture.prefix \"{out_prefix}\" "
                f"-capture.grab -exit"
            )
            run_cmd(cmd_xvfb, check=False)

        # mrview appends 0000.png
        expected = os.path.join(output_dir, f"{out_prefix}0000.png")
        if os.path.isfile(expected):
            pngs.append(expected)
        else:
            # Try without zero-padding
            alt = os.path.join(output_dir, f"{out_prefix}0.png")
            if os.path.isfile(alt):
                pngs.append(alt)

    return pngs


def encode_images(png_paths):
    """Encode PNG files as base64 for the API."""
    encoded = []
    for p in png_paths:
        with open(p, "rb") as f:
            data = base64.standard_b64encode(f.read()).decode("utf-8")
        encoded.append({
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": "image/png",
                "data": data,
            },
        })
    return encoded


def assess_images(client, png_paths, prompt):
    """Send images to Claude API and parse the rating response."""
    if not png_paths:
        return "SKIP", "No images available"

    content = encode_images(png_paths)
    content.append({"type": "text", "text": prompt})

    try:
        response = client.messages.create(
            model=MODEL,
            max_tokens=256,
            system=QC_SYSTEM_PROMPT,
            messages=[{"role": "user", "content": content}],
        )
        raw = response.content[0].text.strip()
        # Parse JSON from response
        match = re.search(r'\{.*\}', raw, re.DOTALL)
        if match:
            parsed = json.loads(match.group())
            return parsed.get("rating", "REVIEW"), parsed.get("notes", raw)
        return "REVIEW", raw
    except Exception as e:
        return "ERROR", str(e)


def load_completed(csv_path):
    """Load already-reviewed subjects from existing CSV."""
    done = set()
    if os.path.isfile(csv_path):
        with open(csv_path, "r") as f:
            reader = csv.DictReader(f)
            for row in reader:
                done.add(row["subject"])
    return done


def load_participant_list(list_path):
    """Read participant list, return list of sub-XXX IDs."""
    subjects = []
    with open(list_path, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            sid = line if line.startswith("sub-") else f"sub-{line}"
            subjects.append(sid)
    return subjects


def main():
    parser = argparse.ArgumentParser(description="Automated FBA QC with Claude Vision")
    parser.add_argument("derivatives_dir", help="Path to FBA derivatives directory")
    parser.add_argument("participant_list", help="Path to participant list file")
    parser.add_argument("--session", default="ses-01", help="Session label (default: ses-01)")
    parser.add_argument("--output", default=None, help="Output CSV path (default: data/ai_fba_qc_review.csv)")
    args = parser.parse_args()

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("ERROR: Set ANTHROPIC_API_KEY environment variable.", file=sys.stderr)
        sys.exit(1)

    client = anthropic.Anthropic(api_key=api_key)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.dirname(script_dir)
    output_csv = args.output or os.path.join(project_dir, "data", "ai_fba_qc_review.csv")
    os.makedirs(os.path.dirname(output_csv), exist_ok=True)

    subjects = load_participant_list(args.participant_list)
    completed = load_completed(output_csv)
    remaining = [s for s in subjects if s not in completed]

    print(f"Derivatives: {args.derivatives_dir}")
    print(f"Session:     {args.session}")
    print(f"Subjects:    {len(subjects)} total, {len(remaining)} remaining")
    print(f"Output:      {output_csv}")

    if not remaining:
        print("All subjects already reviewed.")
        return

    write_header = not os.path.isfile(output_csv)

    with open(output_csv, "a", newline="") as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=[
            "subject", "session", "residual_rating", "residual_notes",
            "bias_rating", "bias_notes",
        ])
        if write_header:
            writer.writeheader()

        for i, sid in enumerate(remaining):
            print(f"\n[{i+1}/{len(remaining)}] {sid}")
            dwidir = os.path.join(args.derivatives_dir, sid, args.session, "dwi")

            if not os.path.isdir(dwidir):
                print(f"  -> No dwi directory. Skipping.")
                writer.writerow({
                    "subject": sid, "session": args.session,
                    "residual_rating": "SKIP", "residual_notes": "No dwi directory",
                    "bias_rating": "SKIP", "bias_notes": "No dwi directory",
                })
                continue

            residual = os.path.join(dwidir, "residual.mif")
            rms_residual = os.path.join(dwidir, "rms_residual.mif")
            bias = os.path.join(dwidir, "bias.mif")

            # Compute RMS residual if needed
            if os.path.isfile(residual) and not os.path.isfile(rms_residual):
                print("  -> Computing RMS residual...")
                run_cmd(f"mrmath \"{residual}\" rms -axis 3 \"{rms_residual}\" -force")

            with tempfile.TemporaryDirectory() as tmpdir:
                # Capture residual slices
                res_rating, res_notes = "SKIP", "No residual file"
                if os.path.isfile(rms_residual):
                    print("  -> Capturing residual slices...")
                    res_pngs = capture_slices(rms_residual, tmpdir, "residual")
                    print(f"     Captured {len(res_pngs)} slices")
                    if res_pngs:
                        print("  -> Sending to Claude for residual assessment...")
                        res_rating, res_notes = assess_images(client, res_pngs, RESIDUAL_PROMPT)
                        print(f"     Rating: {res_rating} — {res_notes}")

                # Capture bias slices
                bias_rating, bias_notes = "SKIP", "No bias file"
                if os.path.isfile(bias):
                    print("  -> Capturing bias field slices...")
                    bias_pngs = capture_slices(bias, tmpdir, "bias")
                    print(f"     Captured {len(bias_pngs)} slices")
                    if bias_pngs:
                        print("  -> Sending to Claude for bias assessment...")
                        bias_rating, bias_notes = assess_images(client, bias_pngs, BIAS_PROMPT)
                        print(f"     Rating: {bias_rating} — {bias_notes}")

            writer.writerow({
                "subject": sid, "session": args.session,
                "residual_rating": res_rating, "residual_notes": res_notes,
                "bias_rating": bias_rating, "bias_notes": bias_notes,
            })
            csvfile.flush()

            # Small delay to avoid rate limits
            time.sleep(1)

    print(f"\nDone. Results saved to {output_csv}")

    # Print summary
    print("\n--- Summary ---")
    with open(output_csv, "r") as f:
        reader = list(csv.DictReader(f))
    for check in ["residual", "bias"]:
        key = f"{check}_rating"
        counts = {}
        for row in reader:
            r = row[key]
            counts[r] = counts.get(r, 0) + 1
        print(f"{check.capitalize()}: {counts}")
    flagged = [r["subject"] for r in reader
               if r["residual_rating"] == "FAIL" or r["bias_rating"] == "FAIL"]
    if flagged:
        print(f"Flagged subjects: {', '.join(flagged)}")


if __name__ == "__main__":
    main()
