#!/bin/bash

# Enhanced stress test script for MacFanAutoCtrl testing
# Supports targeting CPU, GPU, or Both

TARGET=${1:-both} # Default to both if no argument provided

print_status() {
    echo "----------------------------------------"
    echo "Current Temperatures:"
    macfan get cpu.temp
    macfan get gpu.temp
    echo "----------------------------------------"
}

stop_stress() {
    echo -e "\nStopping stress test..."
    killall yes 2>/dev/null
    killall openssl 2>/dev/null
    killall gpu_burner 2>/dev/null
    rm -f gpu_burner gpu_burner.swift
    echo "Cleaned up processes."
    print_status
    exit 0
}

trap stop_stress SIGINT

start_cpu_stress() {
    CORES=$(sysctl -n hw.ncpu)
    echo "Starting CPU stress on $CORES cores..."
    for i in $(seq 1 $CORES); do
        yes > /dev/null &
    done
    openssl speed -multi $CORES > /dev/null 2>&1 &
}

start_gpu_stress() {
    echo "Starting BRUTAL GPU stress (Metal 2D Vectorized)..."
    cat << 'EOF' > gpu_burner.swift
import Metal
import Foundation

guard let device = MTLCreateSystemDefaultDevice() else {
    print("Metal is not supported")
    exit(1)
}

let queue = device.makeCommandQueue()
let source = """
#include <metal_stdlib>
using namespace metal;
kernel void stress(uint2 id [[thread_position_in_grid]]) {
    float4 x = float4(float(id.x), float(id.y), float(id.x + id.y), float(id.x - id.y)) * 0.0001f;
    for (int i = 0; i < 2000000; i++) {
        x = sin(x) * cos(x) + tan(x);
        x = pow(abs(x), 1.1f);
        x = fract(x);
    }
}
"""

do {
    let library = try device.makeLibrary(source: source, options: nil)
    guard let function = library.makeFunction(name: "stress") else { exit(1) }
    let pipeline = try device.makeComputePipelineState(function: function)
    
    // Large 2D grid to exercise more hardware units
    let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
    let threadsPerGrid = MTLSize(width: 2048, height: 2048, depth: 1)
    
    let semaphore = DispatchSemaphore(value: 3) // Allow 3 buffers in flight
    
    while true {
        autoreleasepool {
            semaphore.wait()
            guard let commandBuffer = queue?.makeCommandBuffer() else { 
                semaphore.signal()
                return 
            }
            
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { 
                semaphore.signal()
                return 
            }
            encoder.setComputePipelineState(pipeline)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
            encoder.endEncoding()
            
            commandBuffer.addCompletedHandler { _ in
                semaphore.signal()
            }
            commandBuffer.commit()
        }
    }
} catch {
    print("Error: \(error)")
}
EOF
    # Compile for better performance
    swiftc -O gpu_burner.swift -o gpu_burner
    
    # Run 4 instances in parallel to ensure no gaps in GPU scheduling
    for i in {1..4}; do
        ./gpu_burner &
    done
    echo "4 GPU burner instances launched."
}

echo "MacFanAutoCtrl Targeted Stress Test"
echo "Usage: ./stress_test.sh [cpu|gpu|both]"
echo "Target: $TARGET"
echo "Press Ctrl+C to stop"
echo ""

case $TARGET in
    cpu)
        start_cpu_stress
        ;;
    gpu)
        start_gpu_stress
        ;;
    both)
        start_cpu_stress
        start_gpu_stress
        ;;
    *)
        echo "Invalid target: $TARGET. Use cpu, gpu, or both."
        exit 1
        ;;
esac

echo "Monitoring temperatures..."
while true; do
    print_status
    sleep 5
done
