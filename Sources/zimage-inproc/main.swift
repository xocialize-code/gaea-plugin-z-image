import Foundation
import MLXServeCore
import MLXToolKit
import MLXZImage
import ZImagePlugin

// The in-process reference for the plugin: one Z-Image lane loaded by MLXServeEngine in this process, with the lane
// configuration the worker uses (ZImagePlugin) and the request it builds. The image is written to --out, and one JSON
// line of timings is printed. Not part of the plugin bundle.
//
//   zimage-inproc [--model z-image-turbo | z-image | z-image-nitrofusion2] [--lane int4 | int8 | bf16] [--prompt <text>]
//                 [--width 1024] [--height 1024] [--steps N] [--seed 42] [--models-root <dir>] [--out <png>]

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

let modelID = option("--model") ?? Tier.turbo.modelID
guard let tier = Tier.allCases.first(where: { $0.modelID == modelID }) else { fatalError("no model \(modelID)") }
let quant = Quant(rawValue: option("--lane") ?? "int4") ?? .int4
let prompt = option("--prompt") ?? "a red fox sitting in a snowy forest at sunrise, photorealistic"
let size = try snapped((Int(option("--width") ?? "") ?? 1024, Int(option("--height") ?? "") ?? 1024))
let steps = Int(option("--steps") ?? "") ?? tier.defaultSteps
let seed = UInt64(option("--seed") ?? "") ?? 42
let modelsRoot = URL(fileURLWithPath: option("--models-root")
                     ?? NSHomeDirectory() + "/Library/Application Support/MLXEngine/Models", isDirectory: true)

// The budget Gaea sends a worker on a large Mac (wiresWeights off).
let engine = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: 64_000_000_000, wiresWeights: false))
await engine.useModelStore(ModelStore(root: modelsRoot))
let id = PackageID(tier.modelID)
_ = try await engine.register(tier.registration, configuration: tier.configuration(quant: quant), id: id)
var clock = ContinuousClock.now
_ = try await engine.prepare(.textToImage, package: id)
var result: [String: Any] = ["model": tier.modelID, "lane": quant.rawValue, "width": size.width, "height": size.height,
                             "steps": steps, "seed": seed, "prepare_s": seconds(since: clock)]
let request = textToImage(prompt: prompt, width: size.width, height: size.height, steps: steps, guidance: tier.defaultGuidance, seed: seed)
for run in ["run1", "run2"] {
    clock = ContinuousClock.now
    guard let response = try await engine.run(request, package: id) as? T2IResponse else { fatalError("no image") }
    result["\(run)_s"] = seconds(since: clock)
    if run == "run1", let out = option("--out") { try response.image.data.write(to: URL(fileURLWithPath: out)) }
}
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
