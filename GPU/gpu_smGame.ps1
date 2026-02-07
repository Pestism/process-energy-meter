param(
    [string]$Process = $null,      # optional substring filter
    [int]$Duration = 15,            # seconds
    [int]$SampleInterval = 200      # ms
)

class GPUVramPowerMonitor {

    [double]$GpuIdlePower = 15.0
    [hashtable]$ProcessEnergy = @{}
    [datetime]$LastSampleTime
    [double]$TotalGpuEnergy = 0.0

    GPUVramPowerMonitor() {
        $this.LastSampleTime = Get-Date
    }

    [double] GetGpuPower() {
        $out = nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>$null
        if ($out -and $out.Trim() -ne '[N/A]') {
            try { return [double]$out.Trim() } catch {}
        }
        return 0.0
    }

    [double] GetTotalMemoryUsed() {
        $out = nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null
        if ($out -and $out.Trim() -ne '[N/A]') {
            try { return [double]$out.Trim() } catch {}
        }
        return 0.0
    }

    [array] GetGpuProcesses() {
        $procs = @()

        # Use pmon to get process IDs and utilization
        $pmonOutput = nvidia-smi pmon -c 1 2>$null
        if (-not $pmonOutput) { 
            return $procs 
        }

        foreach ($line in $pmonOutput -split "`n") {
            # Skip headers / separators / empty lines
            if ($line -match '^\s*#' -or $line -match '^\s*-+\s*$' -or
                [string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            # Split by whitespace
            $parts = $line -split '\s+' | Where-Object { $_ -ne '' }
            
            # Format: gpu(0) pid(1) type(2) sm(3) mem(4) enc(5) dec(6) jpg(7) ofa(8) command(9)
            if ($parts.Count -ge 10) {
                $procId = [int]$parts[1]
                $name = $parts[9]
                
                # Parse SM utilization (use as proxy for activity)
                $smUtil = 0.0
                if ($parts[3] -ne '-') {
                    try { $smUtil = [double]$parts[3] } catch {}
                }

                $procs += [PSCustomObject]@{
                    ProcessId = $procId
                    Name      = $name
                    SmUtil    = $smUtil
                }
            }
        }

        return $procs
    }

    [void] Sample() {
        $now = Get-Date
        $dt = ($now - $this.LastSampleTime).TotalSeconds
        $this.LastSampleTime = $now
        if ($dt -le 0) { return }

        $gpuPower = $this.GetGpuPower()
        if ($gpuPower -le 0) { return }

        # Track total GPU energy
        $this.TotalGpuEnergy += $gpuPower * $dt

        $processes = $this.GetGpuProcesses()
        if ($processes.Count -eq 0) { return }

        $totalMemory = $this.GetTotalMemoryUsed()
        
        # Get active processes (SM > 0)
        $activeProcs = $processes | Where-Object { $_.SmUtil -gt 0 }
        
        if ($activeProcs.Count -eq 0) {
            # No active processes, split idle power equally among all
            $idlePowerPerProc = $this.GpuIdlePower / $processes.Count
            foreach ($p in $processes) {
                $energyJ = $idlePowerPerProc * $dt
                if (-not $this.ProcessEnergy.ContainsKey($p.Name)) {
                    $this.ProcessEnergy[$p.Name] = 0.0
                }
                $this.ProcessEnergy[$p.Name] += $energyJ
            }
            return
        }

        # Calculate total SM utilization for active processes
        $totalSm = ($activeProcs | Measure-Object SmUtil -Sum).Sum
        if ($totalSm -le 0) { $totalSm = 1.0 }

        $gpuActive = $gpuPower - $this.GpuIdlePower
        if ($gpuActive -lt 0) { $gpuActive = 0 }

        # Attribute power based on SM utilization
        foreach ($p in $activeProcs) {
            $fraction = $p.SmUtil / $totalSm
            $power = ($this.GpuIdlePower / $processes.Count) + ($fraction * $gpuActive)
            $energyJ = $power * $dt

            if (-not $this.ProcessEnergy.ContainsKey($p.Name)) {
                $this.ProcessEnergy[$p.Name] = 0.0
            }

            $this.ProcessEnergy[$p.Name] += $energyJ
        }

        # Idle processes get a small share of idle power
        $inactiveProcs = $processes | Where-Object { $_.SmUtil -eq 0 }
        if ($inactiveProcs.Count -gt 0) {
            $idlePowerPerProc = ($this.GpuIdlePower * 0.1) / $inactiveProcs.Count
            foreach ($p in $inactiveProcs) {
                $energyJ = $idlePowerPerProc * $dt
                if (-not $this.ProcessEnergy.ContainsKey($p.Name)) {
                    $this.ProcessEnergy[$p.Name] = 0.0
                }
                $this.ProcessEnergy[$p.Name] += $energyJ
            }
        }
    }

    [void] Run([int]$Duration, [int]$IntervalMs, [string]$TargetProcess) {
        $end = (Get-Date).AddSeconds($Duration)

        Write-Host "Monitoring GPU for $Duration seconds..."
        Write-Host "Idle power assumed: $($this.GpuIdlePower) W"
        Write-Host "Note: Using SM utilization as proxy (Windows WDDM doesn't report per-process VRAM)"
        
        # Check what processes we can see
        Write-Host "`nChecking for GPU processes..."
        $testProcs = $this.GetGpuProcesses()
        if ($testProcs.Count -eq 0) {
            Write-Host "ERROR: No GPU processes found at all!" -ForegroundColor Red
            return
        }
        
        $totalMem = $this.GetTotalMemoryUsed()
        Write-Host "Total GPU Memory Used: $totalMem MB"
        Write-Host "Found $($testProcs.Count) GPU process(es):"
        foreach ($p in $testProcs) {
            Write-Host "  ProcessId $($p.ProcessId): $($p.Name) - SM: $($p.SmUtil)%"
        }
        Write-Host ""

        $sampleCount = 0
        while ((Get-Date) -lt $end) {
            $this.Sample()
            $sampleCount++
            Start-Sleep -Milliseconds $IntervalMs
        }

        Write-Host "Collected $sampleCount samples"
        $this.Report($Duration, $TargetProcess)
    }

    [void] Report([double]$Duration, [string]$TargetProcess) {
        Write-Host "`n==== GPU POWER SUMMARY ===="
        
        # Total GPU stats
        $avgGpuPower = $this.TotalGpuEnergy / $Duration
        Write-Host ("Total GPU - Accumulative: {0,8:F2} J  |  Average: {1,6:F2} W" -f $this.TotalGpuEnergy, $avgGpuPower)
        
        Write-Host "`n==== PROCESS POWER ATTRIBUTION (SM-based) ===="

        $entries = $this.ProcessEnergy.GetEnumerator()

        if ($TargetProcess) {
            $entries = $entries | Where-Object { $_.Key -like "*$TargetProcess*" }
        }

        if (-not $entries) {
            Write-Host "No matching GPU processes recorded."
            return
        }

        $total = ($entries | Measure-Object Value -Sum).Sum

        foreach ($e in $entries | Sort-Object Value -Descending) {
            $avgPower = $e.Value / $Duration
            $pct = if ($total -gt 0) { 100 * $e.Value / $total } else { 0 }

            Write-Host ("{0,-30} Accumulative: {1,8:F2} J  |  Average: {2,6:F2} W  ({3,5:F1}%)" -f `
                        $e.Key, $e.Value, $avgPower, $pct)
        }
        
        # Show percentage of total GPU power
        if ($TargetProcess -and $total -gt 0) {
            $targetPct = ($total / $this.TotalGpuEnergy) * 100
            Write-Host "`nTarget process used $($targetPct.ToString('F1'))% of total GPU power"
        }
    }
}

# ---- main ----
$monitor = [GPUVramPowerMonitor]::new()
$monitor.Run($Duration, $SampleInterval, $Process)