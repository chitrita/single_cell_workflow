#!/usr/bin/env bash

############################
## User Defined Variables ##
############################

# NCBI 'nt' Database Location and name (no extension)
NCBI_NT="/home/ubuntu/blast/nt/nt"
# NCBI Taxonomy Location
NCBI_TAX="/home/ubuntu/blast/taxonomy"
# CEGMA DIR
CEGMA_DIR="/home/ubuntu/single_cell_workflow/build/CEGMA_v2.5"
# BUSCO Lineage Location
BUSCO_DB="/home/ubuntu/busco/eukaryota"
# Augustus Config Path
AUGUSTUS_CONFIG_PATH="/home/ubuntu/single_cell_workflow/build/augustus-3.2.2/config"


###########################################
## Program Options - Do Not Change Below ##
###########################################
while getopts f:r:o:ptsqcbBmh FLAG; do
    case $FLAG in
        f)
	        READ1=$OPTARG
	        ;;
	    r)
	        READ2=$OPTARG
	        ;;
	    o)
            $output_dir=$OPTARG
            ;;
	    p)
            run_pear
            ;;
        t)
		    trim_galore
		    ;;
		s)
			assembly_spades
			;;
		q)
			report_quast
			;;
		c)
			report_cegma
			;;
		b)
			report_busco
			;;
		B)
			blobtools_bwa
			blobtools_samtools
			blobtools_blast
			blobtools_create
			blobtools_table
			blobtools_image
			;;
		m)
			report_multiqc
			;;
	    h)
	        help
	        ;;
	    \?)
            echo -e \\n"Option -$OPTARG not allowed."
            help
            ;;
    esac
done


#######################
## Program Functions ##
#######################

## Run Pear Overlapper
# default settings
## deprecate for bbmerge?
function run_pear () {
	overlapped_dir="$output_dir/overlapped"
    mkdir -p "$overlapped_dir"

    echo "Running PEAR Assembler"
    pear -f $READ1 -r $READ2 \
    -o $overlapped_dir/pear_overlap -j $THREADS | tee $overlapped_dir/pear.log

    ln -s $overlapped_dir/pear_overlap.assembled.fastq.gz $overlapped_dir/assembled.fastq.gz
    ln -s $overlapped_dir/pear_overlap.unassembled.forward.fastq.gz $overlapped_dir/unassembled.forward.fastq.gz
    ln -s $overlapped_dir/pear_overlap.unassembled.reverse.fastq.gz $overlapped_dir/unassembled.reverse.fastq.gz
}

## Run Trim Galore!
# Two sets of trimming:
# Assembled/overlapped reads
# Unassembled paired reads.
# Minimum length of 150
# Minimum quality of Q20
# run FASTQC on trimmed
# GZIP output
function trim_galore () {
	trimmed_dir="$output_dir/trimmed"
	mkdir -p "$trimmed_dir"

	echo "Running Trim Galore! on Untrimmed Assembled Reads"
	trim_galore -q 20 --fastqc --gzip --length 150 \
	$overlapped_dir/assembled.fastq.gz

	echo "Running Trim Galore! on Untrimmed Un-assembled Reads"
	trim_galore -q 20 --fastqc --gzip --length 150 --paired --retain_unpaired \
	$overlapped_dir/unassembled.forward.fastq.gz $overlapped_dir/unassembled.reverse.fastq.gz
}

## Run SPAdes
# single cell mode - default kmers 21,33,55
# careful mode - runs mismatch corrector
# use all 5 sets of output reads
# 1 x assembled
# 2 x unassembled
# 2 x unpaired
function assembly_spades () {
	assembly_dir="$output_dir/assembly"
	mkdir -p "$assembly_dir"

	echo "Running SPAdes"
	spades.py --sc --careful -t $THREADS \
	--s1 $trimmed_dir/assembled_trimmed.fq.gz \
	--s2 $trimmed_dir/unassembled.forward_unpaired_1.fq.gz \
	--s3 $trimmed_dir/unassembled.reverse_unpaired_2.fq.gz \
	--pe1-1 $trimmed_dir/unassembled.forward_val_1.fq.gz \
	--pe1-2 $trimmed_dir/unassembled.reverse_val_2.fq.gz \
	-o overlapped_and_paired | tee $assembly_dir/spades_overlapped_and_paired.log

	# Sometimes SPAdes, even though it is aware of the memory limits, will request more memory than is available
    # and then crash, we don't want the rest of the workflow to run through, and it would be nice to have an error message
	#if [ ! -f $assembly_dir/overlapped_and_paired/scaffolds.fasta ] ; then
	#	echo -e "[ERROR]: SPAdes did not build scaffolds. This is possibly a memory error."
	#	exit 1
	#fi
}

# Run QUAST
# eukaryote mode
# glimmer protein predictions
function report_quast () {
	quast_dir="$output_dir/reports/quast"
	mkdir -p "$quast_dir"

	if [ ! -f $assembly_dir/overlapped_and_paired/scaffolds.fasta ] ; then
		echo -e "[ERROR]: SPAdes scaffolds cannot be found."
		exit 1
	else
		echo "Running QUAST"
		quast.py -o $report_dir/quast -t $THREADS \
		--min-contig 100 -f --eukaryote --scaffolds \
		--glimmer $assembly_dir/overlapped_and_paired/scaffolds.fasta | tee quast.log
	fi
}

# Run CEGMA
# Genome mode
function report_cegma () {
	cegma_dir="$output_dir/reports/cegma"
	mkdir -p "$cegma_dir"

	if [ ! -f $assembly_dir/overlapped_and_paired/scaffolds.fasta ] ; then
		echo -e "[ERROR]: SPAdes scaffolds cannot be found."
		exit 1
	else
		echo "Running CEGMA"
		cegma -T $THREADS -g $assembly_dir/overlapped_and_paired/scaffolds.fasta -o $report_dir/cegma
	fi
}


# Run BUSCO
function report_busco () {
	busco_dir="$output_dir/reports/busco"
	mkdir -p "$busco_dir"

	if [ ! -f $assembly_dir/overlapped_and_paired/scaffolds.fasta ] ; then
		echo -e "[ERROR]: SPAdes scaffolds cannot be found."
		exit 1
	else
		BUSCO_v1.22.py \
	    -g $assembly_dir/overlapped_and_paired/scaffolds.fasta \
		-c $THREADS -l $BUSCO_DB -o $report_dir/busco -f
	fi
}

function report_multiqc () {
	multiqc $output_dir
}

function blobtools_bwa () {
	blobtools_dir="$output_dir/reports/blobtools"
	mkdir -p "$blobtools_dir"

	ln -s $assembly_dir/overlapped_and_paired/scaffolds.fasta $blobtools_map/scaffolds.fasta

	# index assembly (scaffolds.fa) with BWA
	echo "Indexing Assembly"
	bwa index -a bwtsw $blobtools_map/scaffolds.fasta | tee $blobtools_map/bwa.log

	# map reads to assembly with BWA MEM
	# we will have to do this for all 5 sets of reads and then merge
	echo "Mapping Assembled reads to Assembly"
	bwa mem -t $THREADS $blobtools_map/scaffolds.fasta \
	$trimmed_dir/assembled_trimmed.fq.gz \
	> $blobtools_map/scaffolds_mapped_assembled_reads.sam | tee -a $blobtools_map/bwa.log

    echo "Mapping Un-assembled & Un-Paired reads to Assembly - Forward"
    bwa mem -t $THREADS $blobtools_map/scaffolds.fasta \
	$trimmed_dir/unassembled.forward_unpaired_1.fq.gz \
    > $blobtools_map/scaffolds_mapped_unassembled_unpaired_forward_reads.sam | tee -a $blobtools_map/bwa.log

	echo "Mapping Un-assembled & Un-Paired reads to Assembly - Reverse"
    bwa mem -t $THREADS $blobtools_map/scaffolds.fasta \
	$trimmed_dir/unassembled.reverse_unpaired_2.fq.gz \
    > $blobtools_map/scaffolds_mapped_unassembled_unpaired_reverse_reads.sam | tee -a $blobtools_map/bwa.log

    echo "Mapping Un-assembled but still Paired reads to Assembly"
    bwa mem -t $THREADS $blobtools_map/scaffolds.fasta \
	$trimmed_dir/unassembled.forward_val_1.fq.gz \
	$trimmed_dir/unassembled.reverse_val_2.fq.gz \
    > $blobtools_map/scaffolds_mapped_unassembled_paired_reads.sam | tee -a $blobtools_map/bwa.log
}

function blobtools_samtools () {
    # sort and convert sam to bam with SAMTOOLS
    echo "Sorting Assembled SAM File and Converting to BAM"
    samtools sort -@ $THREADS -o $blobtools_map/scaffolds_mapped_assembled_reads.bam \
    $blobtools_map/scaffolds_mapped_assembled_reads.sam | tee -a $blobtools_map/samtools.log

    # sort and convert sam to bam with SAMTOOLS
    echo "Sorting Un-assembled & Un-Paired SAM Files and Converting to BAM - Forward"
    samtools sort -@ $THREADS -o $blobtools_map/scaffolds_mapped_unassembled_unpaired_forward_reads.bam \
    $blobtools_map/scaffolds_mapped_unassembled_unpaired_forward_reads.sam | tee -a $blobtools_map/samtools.log

    echo "Sorting Un-assembled & Un-Paired SAM Files and Converting to BAM - Reverse"
    samtools sort -@ $THREADS -o $blobtools_map/scaffolds_mapped_unassembled_unpaired_reverse_reads.bam \
    $blobtools_map/scaffolds_mapped_unassembled_unpaired_reverse_reads.sam | tee -a $blobtools_map/samtools.log

    # sort and convert sam to bam with SAMTOOLS
    echo "Sorting Un-assembled & Paired SAM File and Converting to BAM"
    samtools sort -@ $THREADS -o $blobtools_map/scaffolds_mapped_unassembled_paired_reads.bam \
    $blobtools_map/scaffolds_mapped_unassembled_paired_reads.sam | tee -a $blobtools_map/samtools.log

	# Merge SAM files
	echo "Merging 4 BAM files"
	samtools merge -@ $THREADS -f $blobtools_map/scaffolds_mapped_all_reads.bam \
	$blobtools_map/scaffolds_mapped_assembled_reads.bam \
	$blobtools_map/scaffolds_mapped_unassembled_paired_reads.bam \
	$blobtools_map/scaffolds_mapped_unassembled_unpaired_forward_reads.bam \
	$blobtools_map/scaffolds_mapped_unassembled_unpaired_reverse_reads.bam | tee -a $blobtools_map/samtools.log

	echo "Indexing Bam"
	samtools index $blobtools_map/scaffolds_mapped_all_reads.bam | tee -a $blobtools_map/samtools.log

	# delete sam files
	rm $blobtools_map/*.sam
}

function blobtools_blast () {
	echo "Running BLAST"
	blastn -task megablast \
	-query $blobtools_map/scaffolds.fasta \
	-db $NCBI_NT \
	-evalue 1e-10 \
	-num_threads $THREADS \
	-outfmt '6 qseqid staxids bitscore std sscinames sskingdoms stitle' \
	-culling_limit 5 \
	-out $blobtools_blast/scaffolds_vs_nt_1e-10.megablast | tee $blobtools_blast/blast.log
}

function blobtools_create () {
	echo "Running BlobTools CREATE - slow"
	blobtools create -i $blobtools_map/scaffolds.fasta \
	--nodes $NCBI_TAX/nodes.dmp --names $NCBI_TAX/names.dmp \
	-t $blobtools_blast/scaffolds_vs_nt_1e-10.megablast \
	-b $blobtools_map/scaffolds_mapped_all_reads.bam \
	-o $blobtools_dir/scaffolds_mapped_reads_nt_1e-10_megablast_blobtools | tee -a $blobtools_dir/blobtools.log
}

function blobtools_table () {
	# Standard Output - Phylum
	echo "Running BlobTools View"
	blobtools view -i $blobtools_dir/scaffolds_mapped_reads_nt_1e-10_megablast_blobtools.BlobDB.json \
	--out $blobtools_dir/scaffolds_mapped_reads_nt_1e-10_megablast_blobtools_phylum_table.csv | tee -a $blobtools_dir/blobtools.log
	
	# Other Output - Species
	blobtools view -i $blobtools_dir/scaffolds_mapped_reads_nt_1e-10_megablast_blobtools.BlobDB.json \
	--out $blobtools_dir/scaffolds_mapped_reads_nt_1e-10_megablast_blobtools_superkingdom_table.csv \
	--rank superkingdom | tee -a $blobtools_dir/blobtools.log
}

# run blobtools plot - image output
function blobtools_image () {
	# Standard Output - Phylum, 7 Taxa
	echo "Running BlobTools Plots - Standard + SVG"
	blobtools plot -i $blobtools_dir/scaffolds_mapped_reads_nt_1e-10_megablast_blobtools.BlobDB.json | tee -a $blobtools_dir/blobtools.log

	blobtools plot -i $blobtools_dir/scaffolds_mapped_reads_nt_1e-10_megablast_blobtools.BlobDB.json \
	--format svg | tee -a $blobtools_dir/blobtools.log


	# Other Output - Species, 15 Taxa
	echo "Running BlobTools Plots - SuperKingdom + SVG"
	blobtools plot -i $blobtools_dir/scaffolds_mapped_reads_nt_1e-10_megablast_blobtools.BlobDB.json \
	-r superkingdom | tee -a $blobtools_dir/blobtools.log
	
	blobtools plot -i $blobtools_dir/scaffolds_mapped_reads_nt_1e-10_megablast_blobtools.BlobDB.json \
	-r superkingdom --format svg | tee -a $blobtools_dir/blobtools.log
}


#########################
## Accessory Functions ##
#########################

function check_exe () {
    program=$1
    #https://techalicious.club/tutorials/validating-if-external-program-exists-linuxunix-based-bash-and-perl-scripts
    command -v $program >/dev/null 2>&1 || { echo "$program is required, but it is not in PATH.  Please install/ammend." >&2; exit 1;}
}

function cores () {
    cores=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || sysctl -n hw.ncpu)
    echo $(($cores / 2))
}

function export_cegma () {
    if [ ! -d "$CEGMA_DIR" ] ; then
		echo "[ERROR]: Incorrect CEGMA Path. Is your path correct?"
		echo "$CEGMA_DIR"
		exit 1
	else
	    export CEGMA=$CEGMA_DIR
	    export PATH=$PATH:$CEGMA_DIR/bin
	    export PERL5LIB=$PERL5LIB:$CEGMA_DIR/lib
	    export WISECONFIGDIR=/usr/share/wise/
	fi
}

function ncbi_nt () {
	if [ ! -f "$NCBI_NT/nt.pal" ] ; then
		echo "[ERROR]: Missing NCBI NT Libraries. Is your path correct?"
		echo "$NCBI_NT"
		exit 1
	fi
}

function ncbi_taxonomy () {
	if [ ! -f "$NCBI_TAX/taxdb.btd" ] ; then
		echo "[ERROR]: Missing NCBI Taxonomy Libraries. Is your path correct?"
		echo "$NCBI_TAX"
		exit 1
	fi
}

function busco_db () {
	if [ ! -d "$BUSCO_DB" ] ; then
		echo "[ERROR]: Missing BUSCO Lineage Directory. Is your path correct?"
		echo "$BUSCO_DB"
		exit 1
	fi
}

function augustus () {
	if [ ! -d "AUGUSTUS_CONFIG_PATH" ] ; then
		echo "[ERROR]: Missing BUSCO Lineage Directory. Is your path correct?"
		echo "$AUGUSTUS_CONFIG_PATH"
		exit 1
	else
		export AUGUSTUS_CONFIG_PATH="$AUGUSTUS_CONFIG_PATH"
	fi
}

function HELP {
    echo -e "Basic Usage:"
    echo -e "-f Read 1 FASTQ"
    echo -e "-r Read 2 FASTQ"
    echo -e "-o Output Directory"
    echo -e "Example: run_single_cell_assemblies.sh -f r1.fastq -r r2.fastq -o output_dir"
    exit 1
}


###########################
## Main Pipeline Actions ##
###########################

# Set Cores
THREADS=$(cores)

# Check that we have the required programs
exes=('pigz' 'clumpify.sh' 'trim_galore' 'pear' 'spades.py' 'quast.py' 'cegma' 'BUSCO_v1.22.py' 'bwa' 'samtools' 'blastn' 'blobtools' 'multiqc')
for program in "${exes[@]}" ; do
    check_exe "$program"
done

# Check for correct Paths and exports
export_cegma
ncbi_taxonomy
ncbi_nt
busco_db
augustus