param(
    [string]$Process = $null,      # optional substring filter
    [int]$Duration = 15,            # seconds
    [int]$SampleInterval = 200,    # ms
    [double]$WeightSM = 1.0,       # Weight for shader/compute utilization
    [double]$WeightMem = 0.5,      # Weight for memory bandwidth utilization
    [double]$WeightEnc = 0.25,     # Weight for video encoder utilization
    [double]$WeightDec = 0.15      # Weight for video decoder utilization
)

class GPUMultiMetricMonitor {

    [double]$GpuIdlePower = 15.0
    [hashtable]$ProcessEnergy = @{}
    [datetime]$LastSampleTime
    [double]$TotalGpuEnergy = 0.0
    [double]$WeightA  # SM weight
    [double]$WeightB  # Memory weight
    [double]$WeightC  # Encoder weight
    [double]$WeightD  # Decoder weight

    GPUMultiMetricMonitor([double]$wSM, [double]$wMem, [double]$wEnc, [double]$wDec) {
        $this.LastSampleTime = Get-Date
        $this.WeightA = $wSM
        $this.WeightB = $wMem
        $this.WeightC = $wEnc
        $this.WeightD = $wDec
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

    [double] ParseUtil([string]$value) {
        if ($value -eq '-' -or [string]::IsNullOrWhiteSpace($value)) {
            return 0.0
        }
        try {
            return [double]$value
        } catch {
            return 0.0
        }
    }

    [array] GetGpuProcesses() {
        $procs = @()

        # Use pmon to get process IDs and all utilization metrics
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
                
                # Parse all utilization metrics
                $smUtil = $this.ParseUtil($parts[3])
                $memUtil = $this.ParseUtil($parts[4])
                $encUtil = $this.ParseUtil($parts[5])
                $decUtil = $this.ParseUtil($parts[6])

                $procs += [PSCustomObject]@{
                    ProcessId = $procId
                    Name      = $name
                    SmUtil    = $smUtil
                    MemUtil   = $memUtil
                    EncUtil   = $encUtil
                    DecUtil   = $decUtil
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

        # Calculate weighted utilization for each process
        # Formula: weighted_util = (a * SM) + (b * Mem) + (c * Enc) + (d * Dec)
        $totalWeighted = 0.0
        foreach ($p in $processes) {
            $weighted = ($this.WeightA * $p.SmUtil) + 
                       ($this.WeightB * $p.MemUtil) + 
                       ($this.WeightC * $p.EncUtil) + 
                       ($this.WeightD * $p.DecUtil)
            $p | Add-Member -NotePropertyName 'WeightedUtil' -NotePropertyValue $weighted -Force
            $totalWeighted += $weighted
        }

        if ($totalWeighted -le 0) {
            # No activity, split idle power equally
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

        $gpuActive = $gpuPower - $this.GpuIdlePower
        if ($gpuActive -lt 0) { $gpuActive = 0 }

        # Attribute power proportionally based on weighted utilization
        foreach ($p in $processes) {
            if ($p.WeightedUtil -le 0) {
                # Inactive process gets small idle share
                $power = ($this.GpuIdlePower * 0.05) / $processes.Count
            } else {
                # Active process gets proportional share
                $fraction = $p.WeightedUtil / $totalWeighted
                $power = ($this.GpuIdlePower / $processes.Count) + ($fraction * $gpuActive)
            }
            
            $energyJ = $power * $dt

            if (-not $this.ProcessEnergy.ContainsKey($p.Name)) {
                $this.ProcessEnergy[$p.Name] = 0.0
            }

            $this.ProcessEnergy[$p.Name] += $energyJ
        }
    }

    [void] Run([int]$Duration, [int]$IntervalMs, [string]$TargetProcess) {
        $end = (Get-Date).AddSeconds($Duration)

        Write-Host "Monitoring GPU for $Duration seconds..."
        Write-Host "Idle power assumed: $($this.GpuIdlePower) W"
        Write-Host "Attribution weights: SM=$($this.WeightA), Mem=$($this.WeightB), Enc=$($this.WeightC), Dec=$($this.WeightD)"
        
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
            Write-Host ("  PID {0}: {1,-20} SM:{2,3}% Mem:{3,3}% Enc:{4,3}% Dec:{5,3}%" -f `
                $p.ProcessId, $p.Name, $p.SmUtil, $p.MemUtil, $p.EncUtil, $p.DecUtil)
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
        
        Write-Host "`n==== PROCESS POWER ATTRIBUTION (Multi-Metric) ===="

        if ($this.ProcessEnergy.Count -eq 0) {
            Write-Host "No process energy data recorded."
            return
        }

        $entries = $this.ProcessEnergy.GetEnumerator()

        if ($TargetProcess) {
            $entries = $entries | Where-Object { $_.Key -like "*$TargetProcess*" }
            if (-not $entries) {
                Write-Host "No matching GPU processes recorded."
                return
            }
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
Write-Host @"

WEIGHT LOGIC EXPLANATION:
=========================
SM (Shader/Compute) Weight = $WeightSM
  - Primary GPU compute/rendering workload
  - High for games, 3D rendering, ML workloads
  - Weight: 1.0 (baseline reference)

Mem (Memory Bandwidth) Weight = $WeightMem
  - Memory bandwidth usage (reading/writing VRAM)
  - Important for all GPU tasks but less power-hungry than compute
  - Weight: 0.5 (moderate impact)

Enc (Video Encoder) Weight = $WeightEnc
  - Hardware video encoding (NVENC)
  - Used by streaming software, screen recording, video export
  - Weight: 0.25 (dedicated hw block, lower power)

Dec (Video Decoder) Weight = $WeightDec
  - Hardware video decoding (NVDEC)
  - Used by video playback, streaming input
  - Weight: 0.15 (dedicated hw block, lowest power)

Power Attribution Formula:
Process_Weighted_Util = (SM × $WeightSM) + (Mem × $WeightMem) + (Enc × $WeightEnc) + (Dec × $WeightDec)
Process_Power = (Idle_Power / N_processes) + (Process_Weighted_Util / Total_Weighted_Util) × Active_Power

Example Workloads:
- Gaming: High SM, moderate Mem, low Enc/Dec
- Streaming: Moderate SM, high Enc, low Dec
- Video Playback: Low SM, high Dec, low Enc
- Video Export: High SM + Enc depending on codec

"@

$monitor = [GPUMultiMetricMonitor]::new($WeightSM, $WeightMem, $WeightEnc, $WeightDec)
$monitor.Run($Duration, $SampleInterval, $Process)