<#
.SYNOPSIS
    GPU Power Monitor using nvidia-smi with advanced power attribution
.DESCRIPTION
    Monitors GPU power consumption and attributes it to processes using SM, Memory, Encoder, and Decoder utilization
.PARAMETER Process
    Target process name to track (substring match)
.PARAMETER Duration
    Duration in seconds (default: 60)
.PARAMETER SampleInterval
    Sample interval in milliseconds (default: 10)
.PARAMETER WeightSM
    Weight constant for SM utilization (default: 1.0)
.PARAMETER WeightMem
    Weight constant for Memory utilization (default: 5.0)
.PARAMETER WeightEnc
    Weight constant for Encoder utilization (default: 0.25)
.PARAMETER WeightDec
    Weight constant for Decoder utilization (default: 0.15)
#>

param(
    [string]$Process = $null,
    [int]$Duration = 60,
    [int]$SampleInterval = 10,
    [double]$WeightSM = 1.0,
    [double]$WeightMem = 0.5,
    [double]$WeightEnc = 0.25,
    [double]$WeightDec = 0.15
)

class GPUPowerMonitor {
    [string]$TargetProcess
    [int]$SampleIntervalMs
    [double]$SampleIntervalSec
    [System.Collections.ArrayList]$Samples
    [hashtable]$ProcessEnergy
    [string]$GpuName
    [double]$GpuIdlePower
    [int]$IdleProcessCount
    [hashtable]$IdleProcesses
    [double]$WeightA  # SM weight
    [double]$WeightB  # Memory weight
    [double]$WeightC  # Encoder weight
    [double]$WeightD  # Decoder weight

    GPUPowerMonitor([string]$targetProcess, [int]$sampleIntervalMs, [double]$a, [double]$b, [double]$c, [double]$d) {
        $this.TargetProcess = $targetProcess
        $this.SampleIntervalMs = $sampleIntervalMs
        $this.SampleIntervalSec = $sampleIntervalMs / 1000.0
        $this.Samples = [System.Collections.ArrayList]::new()
        $this.ProcessEnergy = @{}
        $this.IdleProcesses = @{}
        $this.WeightA = $a
        $this.WeightB = $b
        $this.WeightC = $c
        $this.WeightD = $d

        # Get GPU name
        $gpuInfo = nvidia-smi --query-gpu=name --format=csv,noheader 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "nvidia-smi not found or failed to execute"
            exit 1
        }
        $this.GpuName = $gpuInfo.Trim()
        Write-Host "Monitoring GPU: $($this.GpuName)"
        Write-Host "Power attribution weights: SM=$a, Mem=$b, Enc=$c, Dec=$d"

        # Measure idle power
        $this.MeasureIdlePower()

        # If target process is given, check if it's running
        if ($this.TargetProcess) {
            if (-not $this.IsProcessRunning()) {
                Write-Host "ERROR: Target process '$($this.TargetProcess)' not found running on GPU.`n" -ForegroundColor Red
                $this.ListGpuProcesses()
                exit 1
            } else {
                Write-Host "Tracking target process: $($this.TargetProcess)"
            }
        }
    }

    [void] MeasureIdlePower() {
        Write-Host "`nMeasuring GPU idle power..."
        
        # Take multiple samples to get a stable idle measurement
        $idleSamples = @()
        for ($i = 0; $i -lt 10; $i++) {
            $powerOutput = nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>$null
            if ($powerOutput -and $powerOutput.Trim() -ne '[N/A]') {
                try {
                    $idleSamples += [double]$powerOutput.Trim()
                } catch {}
            }
            Start-Sleep -Milliseconds 100
        }

        if ($idleSamples.Count -gt 0) {
            $this.GpuIdlePower = ($idleSamples | Measure-Object -Average).Average
            $this.GpuIdlePower = 1
        } else {
            # Default fallback - conservative estimate
            $this.GpuIdlePower = 1
            Write-Host "Warning: Could not measure idle power, using default: $($this.GpuIdlePower)W" -ForegroundColor Yellow
        }

        # Record which processes were running during idle measurement
        $idleProcs = $this.GetGpuProcesses()
        $this.IdleProcessCount = $idleProcs.Count
        foreach ($proc in $idleProcs) {
            $this.IdleProcesses[$proc.ProcessName] = $true
        }

        Write-Host "GPU Idle Power: $($this.GpuIdlePower) W (with $($this.IdleProcessCount) processes)"
    }

    [bool] IsProcessRunning() {
        $processes = $this.GetGpuProcesses()
        foreach ($proc in $processes) {
            if ($proc.ProcessName -like "*$($this.TargetProcess)*") {
                return $true
            }
        }
        return $false
    }

    [array] GetGpuProcesses() {
        $processes = @()
        
        # Use nvidia-smi pmon to get per-process utilization
        try {
            $pmonOutput = nvidia-smi pmon -c 1 2>$null
            if ($pmonOutput) {
                $lines = $pmonOutput -split "`n"
                foreach ($line in $lines) {
                    # Skip header lines and empty lines
                    if ($line -match '^\s*#' -or $line -match '^-+' -or [string]::IsNullOrWhiteSpace($line)) {
                        continue
                    }
                    
                    # Parse: gpu pid type sm mem enc dec command
                    # Example: 0   1234    C   45   30    0    0   python.exe
                    if ($line -match '^\s*(\d+)\s+(\d+)\s+(\w+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(.+?)\s*$') {
                        $processId = [int]$Matches[2]
                        $smUtil = $this.ParseUtil($Matches[4])
                        $memUtil = $this.ParseUtil($Matches[5])
                        $encUtil = $this.ParseUtil($Matches[6])
                        $decUtil = $this.ParseUtil($Matches[7])
                        $command = $Matches[8].Trim()
                        
                        # Get memory usage
                        $memMB = $this.GetProcessMemory($processId)
                        
                        $processes += [PSCustomObject]@{
                            ProcessId = $processId
                            ProcessName = $command
                            UsedMemoryMB = $memMB
                            SmUtil = $smUtil
                            MemUtil = $memUtil
                            EncUtil = $encUtil
                            DecUtil = $decUtil
                        }
                    }
                }
            }
        } catch {
            Write-Host "Warning: Could not parse pmon output" -ForegroundColor Yellow
        }
        
        # Fallback if pmon parsing failed
        if ($processes.Count -eq 0) {
            $gpuProcessIds = $this.GetGpuProcessIdsFromSmi()
            foreach ($processId in $gpuProcessIds) {
                try {
                    $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
                    if ($proc) {
                        $memMB = $this.GetProcessMemory($processId)
                        $processes += [PSCustomObject]@{
                            ProcessId = $processId
                            ProcessName = $proc.ProcessName
                            UsedMemoryMB = $memMB
                            SmUtil = 0.0
                            MemUtil = 0.0
                            EncUtil = 0.0
                            DecUtil = 0.0
                        }
                    }
                } catch {
                    continue
                }
            }
        }
        
        return $processes
    }

    [double] ParseUtil([string]$value) {
        # Parse utilization value, handling '-' as 0
        if ($value -eq '-' -or [string]::IsNullOrWhiteSpace($value)) {
            return 0.0
        }
        try {
            return [double]$value
        } catch {
            return 0.0
        }
    }

    [double] GetProcessMemory([int]$processId) {
        try {
            $output = nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>$null
            if ($output) {
                foreach ($line in $output -split "`n") {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    $parts = $line -split ',\s*'
                    if ($parts.Count -ge 2 -and [int]$parts[0].Trim() -eq $processId) {
                        $mem = $parts[1].Trim()
                        if ($mem -ne '[N/A]' -and $mem -match '^\d+') {
                            return [double]$mem
                        }
                    }
                }
            }
        } catch {}
        
        return 100.0  # Default fallback
    }

    [array] GetGpuProcessIdsFromSmi() {
        $pids = @()
        try {
            $pmonOutput = nvidia-smi pmon -c 1 2>$null
            if ($pmonOutput) {
                foreach ($line in $pmonOutput -split "`n") {
                    if ($line -match '^\s*\d+\s+(\d+)') {
                        $pids += [int]$Matches[1]
                    }
                }
            }
        } catch {}
        return $pids | Select-Object -Unique
    }

    [void] ListGpuProcesses() {
        $processes = $this.GetGpuProcesses()
        Write-Host "GPU processes currently running:"
        if ($processes.Count -eq 0) {
            Write-Host "  None"
        } else {
            foreach ($proc in $processes) {
                Write-Host ("  PID {0}: {1} (Mem: {2} MB, SM: {3}%, Mem: {4}%, Enc: {5}%, Dec: {6}%)" -f `
                    $proc.ProcessId, $proc.ProcessName, $proc.UsedMemoryMB, `
                    $proc.SmUtil, $proc.MemUtil, $proc.EncUtil, $proc.DecUtil)
            }
        }
    }

    [void] Sample() {
        # Get current GPU power draw
        $powerOutput = nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>$null
        $gpuPower = 0.0
        if ($powerOutput -and $powerOutput.Trim() -ne '[N/A]') {
            try {
                $gpuPower = [double]$powerOutput.Trim()
            } catch {
                $gpuPower = 0.0
            }
        }

        # Get overall GPU utilization
        $utilOutput = nvidia-smi --query-gpu=utilization.gpu,utilization.memory --format=csv,noheader,nounits 2>$null
        $gpuSmUtil = 0.0
        $gpuMemUtil = 0.0
        if ($utilOutput) {
            $parts = $utilOutput -split ',\s*'
            if ($parts.Count -ge 2) {
                try {
                    $gpuSmUtil = [double]$parts[0].Trim()
                    $gpuMemUtil = [double]$parts[1].Trim()
                } catch {}
            }
        }

        # Get running processes with their utilizations
        $processes = $this.GetGpuProcesses()
        $currentProcessCount = $processes.Count

        # Calculate total GPU weighted utilization
        # GPU_weighted = a * GPU_SM + b * GPU_Mem + c * GPU_Enc + d * GPU_Dec
        # For overall GPU, we approximate Enc and Dec as 0 since they're not directly reported
        $gpuEncUtil = 0.0
        $gpuDecUtil = 0.0
        
        # Sum all process encoder/decoder usage to estimate total
        foreach ($proc in $processes) {
            $gpuEncUtil += $proc.EncUtil
            $gpuDecUtil += $proc.DecUtil
        }

        $gpuWeightedTotal = $this.WeightA * $gpuSmUtil + `
                           $this.WeightB * $gpuMemUtil + `
                           $this.WeightC * $gpuEncUtil + `
                           $this.WeightD * $gpuDecUtil
        
        if ($gpuWeightedTotal -eq 0) { $gpuWeightedTotal = 1.0 }

        # Record sample
        $timestamp = (Get-Date).ToUniversalTime().ToString("o")
        [void]$this.Samples.Add([PSCustomObject]@{
            Timestamp = $timestamp
            PowerW = $gpuPower
            GpuSmUtil = $gpuSmUtil
            GpuMemUtil = $gpuMemUtil
            ProcessCount = $currentProcessCount
        })

        # Calculate power for each process using the formula:
        # P_pwr = (GPU_idle/N) + ((a*P_SM + b*P_Mem + c*P_Enc + d*P_Dec) / (a*GPU_SM + b*GPU_Mem + c*GPU_Enc + d*GPU_Dec)) * (GPU_pwr - GPU_idle)
        
        $gpuActivePower = $gpuPower - $this.GpuIdlePower
        if ($gpuActivePower -lt 0) { $gpuActivePower = 0 }

        foreach ($proc in $processes) {
            $processName = $proc.ProcessName

            # Track only target process if specified
            if ($this.TargetProcess -and $processName -notlike "*$($this.TargetProcess)*") {
                continue
            }

            # Calculate idle power contribution for this process
            $idleContribution = 0.0
            if ($this.IdleProcesses.ContainsKey($processName)) {
                # This process was running during idle measurement
                $idleContribution = $this.GpuIdlePower / $this.IdleProcessCount
            } else {
                # New process - split idle among current processes
                if ($currentProcessCount -gt 0) {
                    $idleContribution = $this.GpuIdlePower / $currentProcessCount
                }
            }

            # Calculate weighted utilization for this process
            $procWeighted = $this.WeightA * $proc.SmUtil + `
                           $this.WeightB * $proc.MemUtil + `
                           $this.WeightC * $proc.EncUtil + `
                           $this.WeightD * $proc.DecUtil

            # Calculate proportional active power
            $activeFraction = if ($gpuWeightedTotal -gt 0) { $procWeighted / $gpuWeightedTotal } else { 0 }
            $activePower = $activeFraction * $gpuActivePower

            # Total process power
            $procPower = $idleContribution + $activePower

            # Calculate energy (power * time)
            $energyJ = $procPower * $this.SampleIntervalSec

            if (-not $this.ProcessEnergy.ContainsKey($processName)) {
                $this.ProcessEnergy[$processName] = 0.0
            }
            $this.ProcessEnergy[$processName] += $energyJ
        }
    }

    [void] Run([int]$durationSec) {
        $startTime = Get-Date
        $endTime = $startTime.AddSeconds($durationSec)

        Write-Host "`nMonitoring for $durationSec seconds (Ctrl+C to stop early)...`n"

        try {
            while ((Get-Date) -lt $endTime) {
                $this.Sample()
                Start-Sleep -Milliseconds $this.SampleIntervalMs
            }
        } catch {
            Write-Host "`nMonitoring interrupted" -ForegroundColor Yellow
        }

        $actualDuration = ((Get-Date) - $startTime).TotalSeconds
        $this.Report($actualDuration)
    }

    [void] Report([double]$duration) {
        # Calculate total energy
        $totalEnergyJ = ($this.Samples | Measure-Object -Property PowerW -Sum).Sum * $this.SampleIntervalSec
        $totalEnergyKwh = $totalEnergyJ / 60

        # Calculate average power
        $avgPower = if ($this.Samples.Count -gt 0) {
            ($this.Samples | Measure-Object -Property PowerW -Average).Average
        } else { 0 }

        Write-Host "`n========== GPU POWER MONITORING RESULTS =========="
        Write-Host ("GPU: {0}" -f $this.GpuName)
        Write-Host ("Duration: {0:F2} s" -f $duration)
        Write-Host ("Samples collected: {0}" -f $this.Samples.Count)
        Write-Host ("GPU Idle Power: {0:F2} W" -f $this.GpuIdlePower)
        Write-Host ("Average GPU Power: {0:F2} W" -f $avgPower)
        Write-Host ("Total GPU Energy: {0:F6} kWh ({1:F2} J)" -f $totalEnergyKwh, $totalEnergyJ)

        Write-Host "`n====== PER-PROCESS ENERGY ATTRIBUTION ======"
        if ($this.ProcessEnergy.Count -eq 0) {
            Write-Host "  No process data collected"
        } else {
            $processEnergyTotal = ($this.ProcessEnergy.Values | Measure-Object -Sum).Sum
            
            foreach ($entry in $this.ProcessEnergy.GetEnumerator() | Sort-Object Value -Descending) {
                $name = $entry.Key
                $energyJ = $entry.Value
                $energyKwh = $energyJ / 60
                $avgPowerW = if ($duration -gt 0) { $energyJ / $duration } else { 0 }
                $pct = if ($processEnergyTotal -gt 0) { ($energyJ / $processEnergyTotal * 100) } else { 0 }
                
                Write-Host ("{0,-35} {1,10:F6} kWh  ({2,6:F2} J)  Avg: {3,6:F2} W  ({4,5:F1}%)" -f `
                    $name, $energyKwh, $energyJ, $avgPowerW, $pct)
            }
            
            Write-Host "`nNote: Process percentages are relative to total attributed energy."
            Write-Host "      Some GPU power may not be attributed if processes had zero utilization."
        }

        $this.SaveCsv()
    }

    [void] SaveCsv() {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $filename = "gpu_log_$timestamp.csv"

        $this.Samples | Export-Csv -Path $filename -NoTypeInformation

        Write-Host "`nDetailed log saved to: $filename"
    }
}

# Main execution
try {
    $monitor = [GPUPowerMonitor]::new($Process, $SampleInterval, $WeightSM, $WeightMem, $WeightEnc, $WeightDec)
    $monitor.Run($Duration)
} catch {
    Write-Error "Error: $_"
    exit 1
}