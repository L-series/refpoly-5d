#!/bin/bash
#SBATCH --job-name=galecasc
#SBATCH --partition=all
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=64
#SBATCH --mem=110G
#SBATCH --time=01:30:00
#SBATCH --output=/home/ahat01/.claude/jobs/d651e2f4/tmp/cascade.out
#SBATCH --error=/home/ahat01/.claude/jobs/d651e2f4/tmp/cascade.err
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 NUMEXPR_NUM_THREADS=1
echo "cpus=$SLURM_CPUS_PER_TASK host=$(hostname) mem=${SLURM_MEM_PER_NODE}"
python3 /home/ahat01/.claude/jobs/d651e2f4/tmp/cascade_job.py
