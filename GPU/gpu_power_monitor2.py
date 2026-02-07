import pynvml
import time
import csv
from collections import defaultdict
from datetime import datetime
import sys
import argparse

SAMPLE_INTERVAL_MS = 10
TARGET_PROCESS = "Cyberpunk2077.exe"  # or None

class GPUPowerMonitor:
    def __init__(self, target_process=None):
        
        self.target_process = target_process
        pynvml.nvmlInit()
        self.handle = pynvml.nvmlDeviceGetHandleByIndex(0)
        self.sample_interval = SAMPLE_INTERVAL_MS / 1000.0

        self.samples = []
        self.process_energy = defaultdict(float)

        print("Monitoring GPU:", pynvml.nvmlDeviceGetName(self.handle))

        # If target process is given, check if it's running
        if self.target_process:
            if not self.is_process_running():
                print(f"ERROR: Target process '{self.target_process}' not found running on GPU.")
                sys.exit(1)
            else:
                print(f"Tracking target process: {self.target_process}")

    def is_process_running(self):
        """Check if target process is running on GPU"""
        procs = (
            pynvml.nvmlDeviceGetGraphicsRunningProcesses(self.handle)
            + pynvml.nvmlDeviceGetComputeRunningProcesses(self.handle)
        )
        for p in procs:
            try:
                name = pynvml.nvmlSystemGetProcessName(p.pid)
                if self.target_process.lower() in name.lower():
                    return True
            except:
                continue
        return False


    def sample(self):
        power_w = pynvml.nvmlDeviceGetPowerUsage(self.handle) / 1000.0
        util = pynvml.nvmlDeviceGetUtilizationRates(self.handle).gpu

        procs = (
            pynvml.nvmlDeviceGetGraphicsRunningProcesses(self.handle)
            + pynvml.nvmlDeviceGetComputeRunningProcesses(self.handle)
        )

        # Windows-safe memory handling
        mem_values = [(p.usedGpuMemory or 0) for p in procs]
        total_mem = sum(mem_values) or 1

        timestamp = time.time()
        self.samples.append((timestamp, power_w, util))

        for p in procs:
            try:
                name = pynvml.nvmlSystemGetProcessName(p.pid)
            except:
                name = f"PID_{p.pid}"

            if self.target_process and self.target_process.lower() not in name.lower():
                continue  # skip all other processes

            used_mem = p.usedGpuMemory or 0
            mem_frac = used_mem / total_mem
            proc_power = power_w * mem_frac

            self.process_energy[name] += proc_power * self.sample_interval


        


    def run(self, duration_sec):
        start = time.time()
        try:
            while time.time() - start < duration_sec:
                self.sample()
                time.sleep(self.sample_interval)
        except KeyboardInterrupt:
            pass
        self.report(time.time() - start)

    def report(self, duration):
        total_energy_j = sum(p * self.sample_interval
                             for _, p, _ in self.samples)
        total_energy_kwh = total_energy_j / 3_600_000

        print("\n========== GPU RESULTS ==========")
        print(f"Duration: {duration:.2f} s")
        print(f"Total GPU Energy: {total_energy_kwh:.6f} kWh")

        print("\n====== PER-PROCESS ENERGY ======")
        for name, e_j in self.process_energy.items():
            e_kwh = e_j / 3_600_000
            pct = (e_j / total_energy_j * 100) if total_energy_j else 0
            print(f"{name:30s} {e_kwh:.6f} kWh ({pct:.1f}%)")

        self.save_csv()

    def save_csv(self):
        fname = f"gpu_log_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
        with open(fname, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["timestamp", "power_w", "gpu_util"])
            for s in self.samples:
                w.writerow(s)
        print(f"\nSaved log to {fname}")

    def cleanup(self):
        pynvml.nvmlShutdown()



if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("-p", "--process", type=str,
                        help="Target process name to track (exact match or substring)")
    parser.add_argument("-d", "--duration", type=int, default=60,
                        help="Duration in seconds")
    args = parser.parse_args()

    monitor = GPUPowerMonitor(target_process=args.process)
    try:
        monitor.run(duration_sec=args.duration)
    finally:
        monitor.cleanup()

