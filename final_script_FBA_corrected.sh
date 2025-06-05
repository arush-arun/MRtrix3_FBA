#!/bin/bash

#Author- Arush Arun (arush.getseven@gmail.com)
#last update- 05/06/2025

#code to perform FBA on diffusion MRI data

#preequisites- FSL-6.0.3 or later  and MRTRIX3-3.02 or later

#input- dMRI and blipped data in bids format.
#have sublist ( subids that needs to processed) in the same folder as the code

#Outputs stored in the derivatives folder.

# Set paths - modify these for your environment
# BIDS folder containing all subject data
input_path="${INPUT_PATH:-/path/to/your/bids/folder}"

# Derivatives output folder
der_path="${DER_PATH:-${input_path}/derivatives}"

mkdir -p ${der_path}/group-level/template/fod_input
mkdir -p ${der_path}/group-level/template/mask_input
mkdir -p ${der_path}/group-level/template/scratch
mkdir -p ${der_path}/group-level/template/scratch/warp_dir
mkdir -p ${der_path}/group-level/ses-1


while read p; do

	sub=$p
 	
	echo "################# Processing ${sub} ##################"

#creating directory for each subject in derivatives folder
	mkdir -p ${der_path}/${sub}/ses-1/dwi

#converting the raw data to .mif file
	mrconvert ${input_path}/${sub}/ses-1/dwi/${sub}_ses-1_dwi.nii.gz ${der_path}/${sub}/ses-1/dwi/data.mif -fslgrad ${input_path}/${sub}/ses-1/dwi/${sub}_ses-1_dwi.bvec ${input_path}/${sub}/ses-1/dwi/${sub}_ses-1_dwi.bval -debug	
	echo "################# Running denoising ${sub} ##################"

# denoising 
	dwidenoise ${der_path}/${sub}/ses-1/dwi/data.mif ${der_path}/${sub}/ses-1/dwi/dwi_denoised.mif -noise ${der_path}/${sub}/ses-1/dwi/noise.mif
	mrcalc ${der_path}/${sub}/ses-1/dwi/data.mif ${der_path}/${sub}/ses-1/dwi/dwi_denoised.mif -subtract ${der_path}/${sub}/ses-1/dwi/residual.mif

#calculating SNR using the outshell of the DWI

	dwiextract ${der_path}/${sub}/ses-1/dwi/data.mif -no_bzero -singleshell ${der_path}/${sub}/ses-1/dwi/dwi_singleshell.mif 
	mrcalc ${der_path}/${sub}/ses-1/dwi/dwi_singleshell.mif ${der_path}/${sub}/ses-1/dwi/noise.mif -div ${der_path}/${sub}/ses-1/dwi/snr.mif 

#creating approx WM-mask using dwi data to calculate SNR only in the WM region

	dwiextract ${der_path}/${sub}/ses-1/dwi/data.mif -no_bzero -singleshell - | amp2sh - - | sh2power - -spectrum - | mrconvert - -coord 3 1 - | mrthreshold - ${der_path}/${sub}/ses-1/dwi/wm_mask.mif
	SNR=$(mrstats ${der_path}/${sub}/ses-1/dwi/snr.mif -mask ${der_path}/${sub}/ses-1/dwi/wm_mask.mif -output mean -allvolumes)
	echo "${sub} has an SNR of ${SNR}"

	echo "################# Running gibbs unringing  ${sub} ##################"

#gibbs ringing
	mrdegibbs -axes 0,1 ${der_path}/${sub}/ses-1/dwi/dwi_denoised.mif  ${der_path}/${sub}/ses-1/dwi/dwi_unr.mif -force
	mrcalc ${der_path}/${sub}/ses-1/dwi/dwi_denoised.mif ${der_path}/${sub}/ses-1/dwi/dwi_unr.mif  -subtract ${der_path}/${sub}/ses-1/dwi/residualunringed.mif

#convert blipped down to .mif

	mrconvert ${input_path}/${sub}/ses-1/dwi/${sub}_ses-1_dir*.nii.gz ${der_path}/${sub}/ses-1/dwi/blipped_data.mif -fslgrad ${input_path}/${sub}/ses-1/dwi/${sub}_ses-1_dir*.bvec ${input_path}/${sub}/ses-1/dwi/${sub}_ses-1_dir*.bval

# prep for dwifslpreproc
	#1. extract b0 from the DWI volume
	dwiextract ${der_path}/${sub}/ses-1/dwi/dwi_unr.mif ${der_path}/${sub}/ses-1/dwi/dwi_bzero.mif -bzero #extract b0 from dwi

	#2. Compute the mean of the bzero image
	mrmath ${der_path}/${sub}/ses-1/dwi/dwi_bzero.mif  mean  ${der_path}/${sub}/ses-1/dwi/dwi_mean_bzero.mif -axis 3 # mean b0

	#3. Extract b0 from blipped volume and compute of the mean
	dwiextract ${der_path}/${sub}/ses-1/dwi/blipped_data.mif -bzero - | mrmath - mean ${der_path}/${sub}/ses-1/dwi/blipped_mean_bzero.mif -axis 3 # extract b0 from blipped and compute mean to have regular dimensions when performing concatenation

# Concatenate blipped b0 and dwi b0 volumes
	mrcat ${der_path}/${sub}/ses-1/dwi/dwi_mean_bzero.mif ${der_path}/${sub}/ses-1/dwi/blipped_mean_bzero.mif ${der_path}/${sub}/ses-1/dwi/bzero_cat.mif -axis 3 #concatenate accroding to FSL

	#change the the phase direction depending your type of data
	dwifslpreproc ${der_path}/${sub}/ses-1/dwi/dwi_unr.mif ${der_path}/${sub}/ses-1/dwi/dwi_preproc.mif -pe_dir AP -rpe_pair -se_epi ${der_path}/${sub}/ses-1/dwi/bzero_cat.mif -eddy_options "--slm=linear --cnr_maps " -eddyqc_all ${der_path}/${sub}/ses-1/dwi/eddyqc_AP_cnrmaps 

#Bias correction using ANTS. Save the estimated the bias field
	dwibiascorrect ants ${der_path}/${sub}/ses-1/dwi/dwi_preproc.mif ${der_path}/${sub}/ses-1/dwi/dwi_unbiased_preproc.mif -bias ${der_path}/${sub}/ses-1/dwi/bias.mif

	echo "################# Finished pre-processing ${sub} ##################"

	mrgrid ${der_path}/${sub}/ses-1/dwi/dwi_unbiased_preproc.mif  regrid -vox 1.25 ${der_path}/${sub}/ses-1/dwi/dwi_unbiased_preproc_upsampled.mif


#generate mask using fsl's BET as it is better than dwi2mask
	# first step is to convert .mif file to to .nifti
	mrconvert ${der_path}/${sub}/ses-1/dwi/dwi_unbiased_preproc_upsampled.mif ${der_path}/${sub}/ses-1/dwi/dwi_unbiased_preproc_upsampled.nii.gz
#important to verify your mask, check for any irregularities and holes in the mask
	bet2 ${der_path}/${sub}/ses-1/dwi/dwi_unbiased_preproc_upsampled.nii.gz ${der_path}/${sub}/ses-1/dwi/dwi_bet_mask.nii.gz -m
	mrconvert ${der_path}/${sub}/ses-1/dwi/dwi_bet_mask.nii.gz ${der_path}/${sub}/ses-1/dwi/dwi_bet_mask_use.mif

#response function generation using dhollander algorithm. Do not use the upsampled image

	dwi2response dhollander ${der_path}/${sub}/ses-1/dwi/dwi_unbiased_preproc.mif ${der_path}/${sub}/ses-1/dwi/wm.txt ${der_path}/${sub}/ses-1/dwi/gm.txt ${der_path}/${sub}/ses-1/dwi/csf.txt -voxels ${der_path}/${sub}/ses-1/dwi/voxels.mif

	echo "################# completed response function gen for  ${sub} ##################"


# upsampling DWI images to vox size 1.25 as per recommendation of FBA pipeline

	mrgrid ${der_path}/${sub}/ses-1/dwi/dwi_unbiased_preproc.mif  regrid -vox 1.25 ${der_path}/${sub}/ses-1/dwi/dwi_unbiased_preproc_upsampled.mif

done<./sublist.txt

#calculating group mean response using a function.
cd ${der_path}
responsemean ${der_path}/*/ses-1/dwi/wm.txt ${der_path}/group-level/ses-1/group_average_response_wm.txt 
responsemean ${der_path}/*/ses-1/dwi/gm.txt ${der_path}/group-level/ses-1/group_average_response_gm.txt
responsemean ${der_path}/*/ses-1/dwi/csf.txt ${der_path}/group-level/ses-1/group_average_response_csf.txt

while read p; do
	sub=$p

	echo "#################FOD computation using group average response function for ${sub} ##################"

# FOD computation- multishell multi tissue
	dwi2fod msmt_csd ${der_path}/${sub}/ses-1/dwi/dwi_unbiased_preproc_upsampled.mif ${der_path}/group-level/ses-1/group_average_response_wm.txt ${der_path}/${sub}/ses-1/dwi/wm_fod.mif ${der_path}/group-level/ses-1/group_average_response_gm.txt ${der_path}/${sub}/ses-1/dwi/gm_fod.mif ${der_path}/group-level/ses-1/group_average_response_csf.txt ${der_path}/${sub}/ses-1/dwi/csf_fod.mif -mask ${der_path}/${sub}/ses-1/dwi/dwi_bet_mask_use.mif

#mtnormalise
 	mtnormalise ${der_path}/${sub}/ses-1/dwi/wm_fod.mif ${der_path}/${sub}/ses-1/dwi/wmfod_norm.mif ${der_path}/${sub}/ses-1/dwi/gm_fod.mif ${der_path}/${sub}/ses-1/dwi/gmfod_norm.mif ${der_path}/${sub}/ses-1/dwi/csf_fod.mif ${der_path}/${sub}/ses-1/dwi/csffod_norm.mif -mask ${der_path}/${sub}/ses-1/dwi/dwi_bet_mask_use.mif -check_norm ${der_path}/${sub}/ses-1/dwi/check_norm.mif

#creating symbolic links of wmfod and mask for each subject to create template in the next stop	
	ln -sr ${der_path}/${sub}/ses-1/dwi/wmfod_norm.mif  ${der_path}/group-level/template/fod_input/${sub}.mif
	ln -sr ${der_path}/${sub}/ses-1/dwi/dwi_bet_mask_use.mif ${der_path}/group-level/template/mask_input/${sub}.mif

done<./sublist.txt

#create a population template 
population_template ${der_path}/group-level/template/fod_input -mask_dir ${der_path}/group-level/template/mask_input ${der_path}/group-level/template/wmfod_template.mif -voxel_size 1.25 -scratch ${der_path}/group-level/template/scratch -nocleanup -warp_dir ${der_path}/group-level/template/warp_dir/

while read p; do

    sub=$p

# Register all subject FOD images to template

    mrregister ${der_path}/${sub}/ses-1/dwi/wmfod_norm.mif -mask1 ${der_path}/${sub}/ses-1/dwi/dwi_bet_mask_use.mif ${der_path}/group-level/template/wmfod_template.mif -nl_warp ${der_path}/${sub}/ses-1/dwi/subject2template_warp.mif ${der_path}/${sub}/ses-1/dwi/template2subject_warp.mif

# Compute the template mask

    mrtransform ${der_path}/${sub}/ses-1/dwi/dwi_bet_mask_use.mif  -warp ${der_path}/${sub}/ses-1/dwi/subject2template_warp.mif -interp nearest -datatype bit ${der_path}/${sub}/ses-1/dwi/dwi_mask_in_template_space.mif

done<./sublist.txt

#intersection of template mask . Please check your mask here
cd ${der_path}

#mrmath */ses-1/dwi/dwi_mask_in_template_space.mif min ${der_path}/group-level/template/template_mask.mif -datatype bit
mrview ${der_path}/group-level/template/template_mask.mif

#creating a white matter template analysis fixel mask
fod2fixel -mask ${der_path}/group-level/template/template_mask.mif -fmls_peak_value 0.06  ${der_path}/group-level/template/wmfod_template.mif ${der_path}/group-level/template/fixel_mask

while read p; do

    sub=$p
# Warping FOD images to template space

   mrtransform ${der_path}/${sub}/ses-1/dwi/wmfod_norm.mif -warp ${der_path}/${sub}/ses-1/dwi/subject2template_warp.mif -reorient_fod no ${der_path}/${sub}/ses-1/dwi/fod_in_template_space_NOT_REORIENTED.mif

#  Segment FOD images to estimate FD

   fod2fixel -mask ${der_path}/group-level/template/template_mask.mif  ${der_path}/${sub}/ses-1/dwi/fod_in_template_space_NOT_REORIENTED.mif ${der_path}/${sub}/ses-1/dwi/fixel_in_template_space_NOT_REORIENTED -afd fd.mif

# Reorient fixels of all subjects in template space

    fixelreorient ${der_path}/${sub}/ses-1/dwi/fixel_in_template_space_NOT_REORIENTED  ${der_path}/${sub}/ses-1/dwi/subject2template_warp.mif  ${der_path}/${sub}/ses-1/dwi/fixel_in_template_space -debug

# Assign subject fixels to template fixels

    fixelcorrespondence ${der_path}/${sub}/ses-1/dwi/fixel_in_template_space/fd.mif ${der_path}/group-level/template/fixel_mask ${der_path}/group-level/template/fd ${sub}.mif

# Computing FC metric

    warp2metric ${der_path}/${sub}/ses-1/dwi/subject2template_warp.mif -fc ${der_path}/group-level/template/fixel_mask ${der_path}/group-level/template/fc ${sub}.mif

done<./sublist.txt

#create log_fc directory and copy index and directions 

mkdir ${der_path}/group-level/template/log_fc
cp ${der_path}/group-level/template/fc/index.mif ${der_path}/group-level/template/fc/directions.mif ${der_path}/group-level/template/log_fc

#create FDC directory and copy index and directions from FC

mkdir  ${der_path}/group-level/template//fdc
cp  ${der_path}/group-level/template/fc/index.mif ${der_path}/group-level/template/fdc
cp  ${der_path}/group-level/template/fc/directions.mif ${der_path}/group-level/template/fdc

while read p; do

    sub=$p

# Computing Log-FC

    mrcalc ${der_path}/group-level/template/fc/${sub}.mif -log ${der_path}/group-level/template/log_fc/${sub}.mif

# computing FDC
#
    mrcalc ${der_path}/group-level/template/fd/${sub}.mif ${der_path}/group-level/template/fc/${sub}.mif -mult ${der_path}/group-level/template/fdc/${sub}.mif

done<./sublist.txt


# performing whole brain tractography on the FOD template . Change the number of streamlines generated to 20 million, as per FBA pipeline recommendation
tckgen -angle 22.5 -maxlen 250 -minlen 10 -power 1.0  ${der_path}/group-level/template/wmfod_template.mif -seed_image  ${der_path}/group-level/template/template_mask.mif -mask ${der_path}/group-level/template/template_mask.mif -select 500000 -cutoff 0.06  ${der_path}/group-level/template/tracks_500k.tck

#Reduce biases in tractogram densities
tcksift  ${der_path}/group-level/template/tracks_500k.tck  ${der_path}/group-level/template/wmfod_template.mif  ${der_path}/group-level/template/tracks_2_million_sift.tck -term_number 2000000

#Generate fixel-fixel connectivity matrix

fixelconnectivity  ${der_path}/group-level/template/fixel_mask/  ${der_path}/group-level/template/tracks_500k.tck  ${der_path}/group-level/template/matrix/

#Smooth fixel data using the connectivity matrix 
fixelfilter ${der_path}/group-level/template/fd smooth ${der_path}/group-level/template/fd_smooth -matrix ${der_path}/group-level/template/matrix/
fixelfilter ${der_path}/group-level/template/log_fc smooth ${der_path}/group-level/template/log_fc_smooth -matrix ${der_path}/group-level/template/matrix/
fixelfilter ${der_path}/group-level/template/fdc smooth ${der_path}/group-level/template/fdc_smooth -matrix ${der_path}/group-level/template/matrix/

# before runningstats create subject files, design and contrast matrix in the template folder-  ${der_path}/group-level/template/ 
#
#fixelcfestats  ${der_path}/group-level/template/fd_smooth/ ${der_path}/group-level/template/files.txt ${der_path}/group-level/template/design_matrix.txt ${der_path}/group-level/template/contrast_matrix.txt ${der_path}/group-level/template/matrix/ ${der_path}/group-level/template/stats_fd/
#
#fixelcfestats ${der_path}/group-level/template/log_fc_smooth/ ${der_path}/group-level/template/files.txt ${der_path}/group-level/template/design_matrix.txt ${der_path}/group-level/template/contrast_matrix.txt ${der_path}/group-level/template/matrix/ ${der_path}/group-level/template/stats_log_fc/
#
#fixelcfestats ${der_path}/group-level/template/fdc_smooth/ ${der_path}/group-level/template/files.txt ${der_path}/group-level/template/design_matrix.txt ${der_path}/group-level/template/contrast_matrix.txt ${der_path}/group-level/template/matrix/ ${der_path}/group-level/template/stats_fdc/
