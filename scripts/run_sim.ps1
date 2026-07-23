# run_sim.ps1 — run the cocotb testbench fast, without WSL's slow /mnt/c<->OneDrive path
#
# Problem: this repo lives under OneDrive. WSL accessing it via /mnt/c goes through the
# 9P protocol plus OneDrive's placeholder/sync hooks, which makes iverilog/cocotb's many
# small file + VPI round trips extremely slow (a test run can hang long enough to look
# stuck, or get OOM/SIGKILL'd — see the "Killed" failure that used to show up in
# test_out.log). Fix: rsync the repo into the WSL distro's native ext4 filesystem
# (~/work/<repo>) and run make there. rsync of a few hundred KB of RTL/test sources takes
# well under a second, and the simulation itself then runs at native speed.
#
# Usage:
#   scripts/run_sim.ps1                # RTL sim, all tests
#   scripts/run_sim.ps1 -Gates         # gate-level sim
#   scripts/run_sim.ps1 -Distro Ubuntu-22.04 -WslDir '~/work/BackscatterRadioBaseband'

param(
    [string]$Distro = "Ubuntu-22.04",
    [string]$WslDir = "~/work/BackscatterRadioBaseband",
    [switch]$Gates
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$drive = $repoRoot.Substring(0,1).ToLower()
$rest = $repoRoot.Substring(2) -replace '\\','/'
$wslSrcPath = "/mnt/$drive$rest"

$makeArgs = ""
if ($Gates) { $makeArgs = "GATES=yes" }

# NOTE: $WslDir (default starts with ~) must stay UNQUOTED in the bash command so
# bash performs tilde expansion; only the OneDrive source path (has spaces) is quoted.
$cmd = "mkdir -p $WslDir && " +
       "rsync -a --delete --exclude '.git' --exclude 'sim_build' --exclude '*.fst' --exclude '*.vcd' --exclude '__pycache__' " +
       "`"$wslSrcPath/`" $WslDir/ && " +
       "cd $WslDir/test && make $makeArgs"

wsl -d $Distro -- bash -lc $cmd
