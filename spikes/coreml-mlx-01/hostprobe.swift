import CoreML
import Foundation
func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
let devices = MLComputeDevice.allComputeDevices
log("count = \(devices.count)")
for d in devices {
    switch d {
    case .cpu(let c): log("cpu: \(c)")
    case .gpu(let g): log("gpu: \(g)")
    case .neuralEngine(let ne): log("neuralEngine: totalCoreCount = \(ne.totalCoreCount)")
    @unknown default: log("unknown: \(d)")
    }
}
log("physicalMemory = \(ProcessInfo.processInfo.physicalMemory)")
