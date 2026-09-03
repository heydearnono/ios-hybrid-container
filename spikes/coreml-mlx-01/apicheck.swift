import CoreML
import Foundation

@available(iOS 18.0, *)
func devices() {
    for device in MLComputeDevice.allComputeDevices {
        switch device {
        case .cpu(let cpu): print("cpu", cpu)
        case .gpu(let gpu): print("gpu", gpu)
        case .neuralEngine(let ne): print("ANE cores:", ne.totalCoreCount)
        @unknown default: break
        }
    }
}

@available(iOS 18.0, *)
func run(modelURL: URL, compiledModelURL: URL, tokenID: Int) async throws {
    let config = MLModelConfiguration()
    config.computeUnits = .cpuAndNeuralEngine
    config.optimizationHints.reshapeFrequency = .infrequent
    config.optimizationHints.specializationStrategy = .fastPrediction

    let asset = try MLModelAsset(url: modelURL)
    config.functionName = "extend"
    let model = try await MLModel.load(asset: asset, configuration: config)

    let state = model.makeState()
    let inputs: [String: MLTensor] = [
        "tokens": MLTensor(shape: [1, 1], scalars: [Int32(tokenID)], scalarType: Int32.self)
    ]
    let outputs = try await model.prediction(from: inputs, using: state)
    print(outputs.keys)

    let plan = try await MLComputePlan.load(contentsOf: compiledModelURL, configuration: config)
    if case .program(let program) = plan.modelStructure,
       let main = program.functions["main"] {
        for op in main.block.operations {
            let usage = plan.deviceUsage(for: op)
            let cost = plan.estimatedCost(of: op)
            print(op.operatorName, usage?.preferred as Any, cost?.weight as Any)
        }
    }
}
