# MeDALS DWI — Data Quality Notes

**Dataset**: MeDALS DWI (7T Siemens, multi-shell b=0,1000,2500, 97 volumes, 1.8mm native)
**Session**: ses-01
**Pipeline**: MRtrix3 FBA preprocessing (denoise, unring, eddy+TOPUP, bias correction, upsample 1.25mm, SynthStrip mask, dhollander response)
**Date**: 2026-05-07
**Total subjects in BIDS**: 50 (sub-001 to sub-143)
**Subjects processed**: 49 (sub-140 excluded pre-processing)

---

## Excluded Subjects

### sub-140 — Missing raw data
- **Issue**: Missing both AP DWI and PA fieldmap for ses-01
- **Action**: Excluded from participant list; not processed

---

## Flagged Subjects

### sub-002 / sub-004 — Duplicate data
- **Issue**: NIfTI files are byte-identical (MD5: `7d636a792b394c2e10b6af81305c682b`)
- **Evidence**: Identical acquisition timestamps (`10:37:35.197500`), identical JSON sidecars, identical QC metrics (abs_motion=0.80, rel_motion=0.32, outlier_pct=3.39%, CNR_b1000=32.08)
- **Action**: Exclude both from group analysis until the correct subject-to-data mapping is confirmed with the data manager. One subject ID has incorrect data.

### sub-132 — High absolute motion
- **Issue**: Absolute motion = 2.47 mm (exceeds 2 mm threshold; group mean = 0.68 mm)
- **Other metrics**: Relative motion = 0.35 mm (within range), outliers = 1.09%, CNR_b1000 = 16.66 (low end)
- **Action**: Visually inspect dwi_preproc.mif for residual motion artefacts. Consider exclusion if artefacts are visible in FOD or fixel maps.

### sub-121 — Low SNR and CNR
- **Issue**: SNR = 8.74 (lowest; below 10 threshold), CNR_b1000 = 10.6 (lowest; group mean = 29.8), CNR_b2500 = 0.94 (lowest; group mean = 2.56)
- **Other metrics**: Absolute motion = 1.34 mm (elevated but below threshold), outliers = 0.54%
- **Action**: Visually inspect raw data and preprocessed output. Low CNR may compromise fibre orientation estimation. Consider exclusion from FBA if FODs appear noisy.

### sub-122 — Low SNR
- **Issue**: SNR = 9.20 (below 10 threshold), CNR_b1000 = 21.37, CNR_b2500 = 1.56 (both low end)
- **Other metrics**: Motion and outliers within normal range
- **Action**: Monitor during FOD estimation. Likely usable but flag if group-level results are sensitive.

### sub-052 — Low SNR
- **Issue**: SNR = 9.77 (below 10 threshold), CNR_b1000 = 25.38, CNR_b2500 = 1.30 (low)
- **Other metrics**: Motion and outliers within normal range
- **Action**: Monitor during FOD estimation.

---

## Subjects Requiring Prior Data Fixes

These subjects had BIDS structure issues that were resolved before processing:

### sub-113 — Duplicate PA fieldmaps
- **Issue**: Two PA runs (run-1 and run-2) in original data
- **Resolution**: run-1 (acquired before AP DWI) moved to fmap/ with correct `_epi` suffix and IntendedFor metadata. run-2 archived.

### sub-118, sub-121, sub-122 — Mislabelled PA fieldmaps
- **Issue**: PA fieldmaps had incorrect BIDS naming
- **Resolution**: Relabelled with correct `_dir-PA_epi` suffix in fmap/ directory

---

## Group QC Summary (n=49)

| Metric | Mean | Median | Min | Max | Threshold |
|--------|------|--------|-----|-----|-----------|
| Absolute motion (mm) | 0.68 | 0.62 | 0.34 | 2.47 | 2.0 |
| Relative motion (mm) | 0.31 | 0.30 | 0.22 | 0.48 | 0.5 |
| Outlier percentage (%) | 0.43 | 0.12 | 0.00 | 3.39 | 5.0 |
| CNR b=1000 | 29.77 | 28.64 | 10.60 | 44.25 | — |
| CNR b=2500 | 2.56 | 2.68 | 0.94 | 4.07 | — |
| SNR (WM, pre-eddy) | 12.59 | 12.54 | 8.74 | 16.59 | 10.0 |

- Subjects exceeding motion threshold: 1 (sub-132)
- Subjects exceeding outlier threshold: 0
- Subjects with SNR < 10: 3 (sub-121, sub-122, sub-052)

---

## Processing Notes

- **Eddy options (CPU)**: `--slm=linear --repol --cnr_maps --fep --data_is_shelled --ol_type=both --mb=2`
- **Eddy options (GPU)**: adds `--estimate_move_by_susceptibility`
- **Brain masking**: SynthStrip (FreeSurfer 7.4.1) — replaced BET due to poor mask quality at 7T
- **PE encoding**: AP (j-) main, PA (j) reverse. All AP b0s (n=7) + 1 PA b0 passed to TOPUP via `-rpe_header`
- **Response functions**: All 49 subjects produced 5-shell dhollander response functions (consistent)

---

## Recommendation

Exclude from FBA group analysis:
1. **sub-002 and sub-004** — duplicate data (pending data manager review)
2. **sub-132** — pending visual QC of motion artefacts

Monitor closely:
3. **sub-121** — low SNR/CNR, check FOD quality
4. **sub-122, sub-052** — borderline SNR

**Usable subjects for FBA (conservative)**: 46 of 49 processed
