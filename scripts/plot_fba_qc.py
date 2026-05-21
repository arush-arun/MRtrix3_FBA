#!/usr/bin/env python3
"""
Box plots for FBA preprocessing QC metrics.

Usage:
    python plot_fba_qc.py <fba_qc_summary.csv> [output.png]

Reads the CSV produced by qc_fba_preproc.sh and generates a multi-panel
box plot with individual data points and flagged subjects highlighted.
"""

import sys
import csv
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# ── Configuration ──────────────────────────────────────────────
FLAGGED = {
    "sub-132": {"color": "#E24B4A", "label": "high motion"},
    "sub-121": {"color": "#D4860B", "label": "low CNR/SNR"},
    "sub-002": {"color": "#7F77DD", "label": "duplicate"},
    "sub-004": {"color": "#7F77DD", "label": "duplicate"},
}

THRESHOLDS = {
    "abs_motion":  {"val": 2.0, "label": "> 2 mm"},
    "rel_motion":  {"val": 0.5, "label": "> 0.5 mm"},
    "outlier_pct": {"val": 5.0, "label": "> 5%"},
}

METRICS = [
    ("abs_motion",  "Absolute motion (mm)"),
    ("rel_motion",  "Relative motion (mm)"),
    ("outlier_pct", "Outlier percentage (%)"),
    ("cnr_b1000",   "CNR b=1000"),
    ("cnr_b2500",   "CNR b=2500"),
]


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip())
        sys.exit(1)

    csv_path = sys.argv[1]
    out_path = sys.argv[2] if len(sys.argv) > 2 else csv_path.replace(".csv", "_boxplots.png")

    # ── Read CSV ───────────────────────────────────────────────
    subjects, data = [], {m[0]: [] for m in METRICS}
    with open(csv_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            subjects.append(row["subject"])
            for key, _ in METRICS:
                try:
                    data[key].append(float(row[key]))
                except (ValueError, KeyError):
                    data[key].append(np.nan)

    n = len(subjects)
    print(f"Read {n} subjects from {csv_path}")

    # ── Plot ───────────────────────────────────────────────────
    fig, axes = plt.subplots(1, len(METRICS), figsize=(3.2 * len(METRICS), 5))
    fig.suptitle(f"FBA Preprocessing QC  (n={n})", fontsize=14, fontweight="bold", y=0.98)

    for ax, (key, title) in zip(axes, METRICS):
        vals = np.array(data[key])
        valid = vals[~np.isnan(vals)]

        # Box plot
        bp = ax.boxplot(valid, widths=0.4, patch_artist=True,
                        boxprops=dict(facecolor="#E1F5EE", edgecolor="#1D9E75", linewidth=1),
                        medianprops=dict(color="#0F6E56", linewidth=1.5),
                        whiskerprops=dict(color="#1D9E75"),
                        capprops=dict(color="#1D9E75"),
                        flierprops=dict(marker="", linewidth=0))

        # Jittered scatter
        jitter = np.random.default_rng(42).uniform(-0.12, 0.12, n)
        for i, (sub, v) in enumerate(zip(subjects, vals)):
            if np.isnan(v):
                continue
            if sub in FLAGGED:
                c = FLAGGED[sub]["color"]
                ax.scatter(1 + jitter[i], v, s=36, color=c, edgecolors="white",
                           linewidths=0.5, zorder=5)
                ax.annotate(sub.replace("sub-", ""), (1 + jitter[i], v),
                            fontsize=7, fontweight="bold", color=c,
                            xytext=(6, 4), textcoords="offset points")
            else:
                ax.scatter(1 + jitter[i], v, s=18, color="#1D9E75", alpha=0.6,
                           edgecolors="none", zorder=4)

        # Threshold line
        if key in THRESHOLDS:
            t = THRESHOLDS[key]
            ax.axhline(t["val"], color="#E24B4A", linestyle="--", linewidth=1, alpha=0.7)
            ax.text(1.32, t["val"], t["label"], fontsize=8, color="#E24B4A",
                    va="bottom", ha="left")

        ax.set_title(title, fontsize=10, fontweight="500")
        ax.set_xticks([])
        ax.tick_params(axis="y", labelsize=9)
        ax.spines["top"].set_visible(False)
        ax.spines["right"].set_visible(False)
        ax.spines["bottom"].set_visible(False)

    # ── Legend ─────────────────────────────────────────────────
    from matplotlib.lines import Line2D
    legend_elements = [
        Line2D([0], [0], marker="o", color="w", markerfacecolor="#1D9E75",
               markersize=6, label=f"Normal (n={n - len(FLAGGED)})"),
        Line2D([0], [0], marker="o", color="w", markerfacecolor="#E24B4A",
               markersize=6, label="High motion"),
        Line2D([0], [0], marker="o", color="w", markerfacecolor="#D4860B",
               markersize=6, label="Low CNR/SNR"),
        Line2D([0], [0], marker="o", color="w", markerfacecolor="#7F77DD",
               markersize=6, label="Duplicate data"),
        Line2D([0], [0], color="#E24B4A", linestyle="--", linewidth=1,
               label="Exclusion threshold"),
    ]
    fig.legend(handles=legend_elements, loc="lower center", ncol=5,
              fontsize=8, frameon=False, bbox_to_anchor=(0.5, -0.02))

    plt.tight_layout(rect=[0, 0.04, 1, 0.95])
    fig.savefig(out_path, dpi=200, bbox_inches="tight", facecolor="white")
    print(f"Saved: {out_path}")


if __name__ == "__main__":
    main()
