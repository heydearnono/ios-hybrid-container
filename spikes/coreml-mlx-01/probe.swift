import CoreML
import Foundation

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

log("=== MLComputeDevice.allComputeDevices ===")
let devices = MLComputeDevice.allComputeDevices
log("count = \(devices.count)")
for d in devices {
    switch d {
    case .cpu(let c):
        log("cpu: \(c)")
    case .gpu(let g):
        log("gpu: \(g)")
    case .neuralEngine(let ne):
        log("neuralEngine: totalCoreCount = \(ne.totalCoreCount)")
    @unknown default:
        log("unknown device: \(d)")
    }
}
log("=== MLModel.availableComputeDevices ===")
log("count = \(MLModel.availableComputeDevices.count)")
log("descriptions = \(MLModel.availableComputeDevices.map(\.description))")

log("=== os_proc_available_memory ===")
log("value = \(os_proc_available_memory())")
log("physicalMemory = \(ProcessInfo.processInfo.physicalMemory)")
log("thermalState = \(ProcessInfo.processInfo.thermalState.rawValue)")
log("DONE")
