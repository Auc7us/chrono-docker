#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#SBATCH --job-name=chrono-build
#SBATCH --partition=mi2101x          # 1x MI210 (gfx90a), 16 cores, cheapest rate; nodes are exclusive
#SBATCH --account=dannegrut          #   (use mi2104x for a 128-core / faster build)
#SBATCH --nodes=1
#SBATCH --time=10:00:00              # mi2101x allows up to 12h; 16-core build is slower
#SBATCH --output=%x-%j.log
#
# Batch wrapper around run_chrono_build.sh, for unattended builds.
# Prefer the interactive flow (see run_chrono_build.sh header) if you want to
# watch progress and re-run on failure.
#
#   ./build_chrono_sif.sh        # once, on the login node
#   sbatch build_chrono.slurm
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
exec ./run_chrono_build.sh
