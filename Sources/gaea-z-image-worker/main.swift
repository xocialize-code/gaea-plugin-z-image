import Foundation
import GaeaPluginKit
import GaeaProtocol
import ImageIO
import MLXToolKit
import MLXZImage

// gaea-plugin-z-image: Tongyi-MAI's Z-Image (6B single-stream DiT, Apache-2.0) as a Gaea plugin, on
// z-image-swift through MLXServeEngine (Gaea AB-T-0365).
//
// - z-image-turbo: the distilled 8-step tier at guidance 0. Gaea's default for draft and standard.
// - z-image: the base tier, ~28 steps with CFG and negative prompts. The one for `best`.
//
// Both offer MES image.generate, and image.edit as named-only image-to-image (a re-generation from
// the input, not an instruction editor). Each has three lanes, the DiT's quant: int4 (the default),
// int8 and bf16, with the package's measured footprints. Weights come from the models root Gaea sends
// in configure (MLXEngine's store by default); the engine materializes a missing snapshot there.

/// The output area the package's footprints cover (1536²); above it z-image-swift refuses.
let maxPixels = ZImageT2IPackage.maxOutputPixels
let minSide = 256, maxSide = 2048, grid = 16

enum Tier: Sendable {
    case turbo, base

    var defaultSteps: Int { self == .turbo ? 8 : 28 }
    var defaultGuidance: Double { self == .turbo ? 0 : 4 }
}

/// The MES size a job asks for (`size`, or `aspect` with `megapixels`, Image profile §2), else `fallback`.
func requestedSize(_ job: Job, fallback: (Int, Int)) throws -> (Int, Int) {
    if let size = job.param("size") {
        guard let w = size["width"]?.intValue, let h = size["height"]?.intValue, w > 0, h > 0 else {
            throw GPPError(.invalidRequest, "size is {width, height} in pixels.")
        }
        return (w, h)
    }
    if let aspect = job.param("aspect")?.stringValue {
        let parts = aspect.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { throw GPPError(.invalidRequest, "aspect is W:H, e.g. 16:9.") }
        let pixels = (job.param("megapixels")?.doubleValue ?? 1.0) * 1_000_000
        let height = (pixels * parts[1] / parts[0]).squareRoot()
        return (Int(height * parts[0] / parts[1]), Int(height))
    }
    return fallback
}

/// Fits a size to Z-Image's grid: scaled down to the area cap, keeping the aspect, then floored to
/// multiples of 16. A change is reported as `size_snapped`.
func snapped(_ size: (Int, Int)) throws -> (width: Int, height: Int, warning: Warning?) {
    var (w, h) = (Double(size.0), Double(size.1))
    if w * h > Double(maxPixels) {
        let scale = (Double(maxPixels) / (w * h)).squareRoot()
        w *= scale
        h *= scale
    }
    let width = Int(w) / grid * grid, height = Int(h) / grid * grid
    guard min(width, height) >= minSide, max(width, height) <= maxSide else {
        throw GPPError(.invalidRequest, "Z-Image draws \(minSide)–\(maxSide) px a side and at most 1536² in area; "
            + "\(size.0)×\(size.1) doesn't fit.", detail: ["param": "size"])
    }
    let warning = (width, height) == size ? nil : Warning(
        code: "size_snapped", message: "Drew \(width)×\(height) for \(size.0)×\(size.1): multiples of 16, at most 1536² in area.",
        param: "size")
    return (width, height, warning)
}

/// The run's settings shared by generate and edit: steps, guidance, seed, and the warnings for what
/// the tier ignores.
struct Shared {
    var steps: Int
    var guidance: Double
    var negative: String?
    var seed: UInt64
    var warnings: [Warning] = []

    init(_ job: Job, tier: Tier) throws {
        steps = job.param("x-zimage.steps")?.intValue ?? tier.defaultSteps
        guard (1...100).contains(steps) else { throw GPPError(.invalidRequest, "x-zimage.steps is 1–100.") }
        guidance = tier == .turbo ? 0 : job.param("x-zimage.guidance")?.doubleValue ?? tier.defaultGuidance
        guard (0...20).contains(guidance) else { throw GPPError(.invalidRequest, "x-zimage.guidance is 0–20.") }
        let negative = job.param("negative_prompt")?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if tier == .turbo, negative != nil {
            warnings.append(Warning(code: "negative_prompt_ignored",
                                    message: "Z-Image Turbo runs without CFG, so a negative prompt does nothing; Z-Image (best) honours it.",
                                    param: "negative_prompt"))
        }
        self.negative = tier == .turbo ? nil : negative
        if job.param("prompt_enhance")?.stringValue == "on" {
            warnings.append(Warning(code: "prompt_enhance_ignored", message: "This plugin doesn't rewrite prompts; Gaea's enhancer does.",
                                    param: "prompt_enhance"))
        }
        // Image profile §2: a request without a seed still gets one, reported in effective.
        seed = job.seed ?? UInt64.random(in: 0..<(1 << 31))
    }

    func effective(width: Int, height: Int, count: Int) -> [String: JSONValue] {
        var values: [String: JSONValue] = [
            "size": ["width": .int(Int64(width)), "height": .int(Int64(height))], "count": .int(Int64(count)),
            "seed": .int(Int64(seed)), "x-zimage.steps": .int(Int64(steps)),
        ]
        if guidance > 0 { values["x-zimage.guidance"] = .double(guidance) }
        if let negative { values["negative_prompt"] = .string(negative) }
        return values
    }
}

/// MES image.generate: one engine call per image, each with seed + i.
func generate(_ tier: Tier) -> EngineOperation {
    EngineOperation("image.generate", outputNames: ["image": "images"]) { job in
        guard let prompt = try job.text("prompt"), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GPPError(.invalidRequest, "image.generate needs a prompt.")
        }
        let count = job.param("count")?.intValue ?? 1
        guard (1...8).contains(count) else { throw GPPError(.invalidRequest, "count is 1–8.") }
        let size = try snapped(try requestedSize(job, fallback: (1024, 1024)))
        var shared = try Shared(job, tier: tier)
        if let warning = size.warning { shared.warnings.insert(warning, at: 0) }
        let effective = shared.effective(width: size.width, height: size.height, count: count)
        return (0..<count).map { i in
            EngineCall(T2IRequest(prompt: prompt, negativePrompt: shared.negative, width: size.width, height: size.height,
                                  steps: shared.steps, guidanceScale: shared.guidance, seed: shared.seed + UInt64(i)),
                       effective: effective, warnings: shared.warnings)
        }
    }
}

/// MES image.edit as image-to-image: the first image, re-generated at `strength` (0–1, default 0.75)
/// toward the instruction. The first image sets the size (Image profile §3).
func edit(_ tier: Tier) -> EngineOperation {
    EngineOperation("image.edit", outputNames: ["image": "image"]) { job in
        guard let instruction = try job.text("instruction"), !instruction.isEmpty else {
            throw GPPError(.invalidRequest, "image.edit needs an instruction.")
        }
        guard let url = job.input("images"), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let inputWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let inputHeight = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw GPPError(.invalidRequest, "image.edit needs one readable PNG or JPEG in images.")
        }
        let strength = job.param("strength")?.doubleValue ?? 0.75
        guard (0...1).contains(strength) else { throw GPPError(.invalidRequest, "strength is 0–1.") }
        let size = try snapped(try requestedSize(job, fallback: (inputWidth, inputHeight)))
        var shared = try Shared(job, tier: tier)
        if let warning = size.warning { shared.warnings.insert(warning, at: 0) }
        if (job.inputs["images"]?.count ?? 0) > 1 {
            shared.warnings.append(Warning(code: "inputs_ignored", message: "Z-Image re-generates from the first image only.",
                                           param: "images"))
        }
        var effective = shared.effective(width: size.width, height: size.height, count: 1)
        effective["strength"] = .double(strength)
        return [EngineCall(IEditRequest(images: [try job.image("images")], prompt: instruction, negativePrompt: shared.negative,
                                        width: size.width, height: size.height, steps: shared.steps,
                                        guidanceScale: shared.guidance, seed: shared.seed,
                                        metaData: ["strength": .double(strength)]),
                           effective: effective, warnings: shared.warnings)]
    }
}

func lanes(_ tier: Tier) -> [LaneDefinition] {
    [Quant.int4, .int8, .bf16].map { quant in
        LaneDefinition(id: quant.rawValue, default: quant == .int4,
                       configuration: tier == .turbo ? ZImageConfiguration.turbo(quant: quant) : ZImageConfiguration.base(quant: quant))
    }
}

let apache: JSONValue = ["spdx": "Apache-2.0", "commercial_use": true, "terms_url": "https://www.apache.org/licenses/LICENSE-2.0"]
let limits = PluginManifest.Limits(maxPixels: maxPixels, minSide: minSide, maxSide: maxSide, sizeMultiple: grid)
let editLimits = PluginManifest.Limits(maxPixels: maxPixels, minSide: minSide, maxSide: maxSide, sizeMultiple: grid, maxImages: 1)

func stepsParam(_ tier: Tier) -> JSONValue {
    ["type": "integer", "minimum": 1, "maximum": 100, "default": .int(Int64(tier.defaultSteps)),
     "description": .string(tier == .turbo ? "Denoising steps. Turbo is distilled for 8." : "Denoising steps; more is slower and finer."),
     "x-mes-ui": ["widget": "slider", "label": "Steps", "advanced": true]]
}

let guidanceParam: JSONValue = [
    "type": "number", "minimum": 0, "maximum": 20, "default": 4,
    "description": "Classifier-free guidance: how strongly the prompt (and against the negative prompt) steers.",
    "x-mes-ui": ["widget": "slider", "label": "Guidance", "advanced": true],
]

func params(_ tier: Tier) -> JSONValue {
    var properties: [String: JSONValue] = ["x-zimage.steps": stepsParam(tier)]
    if tier == .base { properties["x-zimage.guidance"] = guidanceParam }
    return ["type": "object", "properties": .object(properties), "additionalProperties": false]
}

let plugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.z-image",
    version: "0.1.0",
    minGaea: "0.2.0",
    team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize-code/gaea-plugin-z-image",
    title: "Z-Image",
    summary: "Tongyi-MAI Z-Image 6B (Apache-2.0): Turbo, distilled to 8 steps, and the base model with CFG and negative prompts. "
        + "Photoreal, with English and Chinese text rendering.",
    license: "Apache-2.0",
    executable: "gaea-z-image-worker",
    models: [
        .engine(ZImageTurboT2IPackage.self, id: "z-image-turbo", title: "Z-Image Turbo", lanes: lanes(.turbo),
                operations: [generate(.turbo), edit(.turbo)]),
        .engine(ZImageT2IPackage.self, id: "z-image", title: "Z-Image", lanes: lanes(.base),
                operations: [generate(.base), edit(.base)]),
    ],
    offers: [
        PluginManifest.Offer(
            operation: "image.generate", profile: "image",
            model: ["id": "z-image-turbo", "title": "Z-Image Turbo", "license": apache, "memory_class": "large",
                    "speed_class": "fast", "quality_tiers": ["draft", "standard"], "default": true,
                    "notes": "Distilled 8 steps without CFG: negative prompts do nothing. Seeds vary less than in most models; that's the model."],
            params: params(.turbo), defaults: ["count": 1], limits: limits),
        PluginManifest.Offer(
            operation: "image.generate", profile: "image",
            model: ["id": "z-image", "title": "Z-Image", "license": apache, "memory_class": "large", "speed_class": "slow",
                    "quality_tiers": ["best"],
                    "notes": "The base model: about 28 steps with CFG, honours negative prompts. Slower than Turbo; finer detail."],
            params: params(.base), defaults: ["count": 1], limits: limits),
        PluginManifest.Offer(
            operation: "image.edit", profile: "image",
            model: ["id": "z-image-turbo", "title": "Z-Image Turbo (image to image)", "license": apache, "memory_class": "large",
                    "speed_class": "fast", "quality_tiers": ["draft", "standard"], "named_only": true,
                    "notes": "Re-generates the first image toward the instruction; strength 0–1 (default 0.75). Not an instruction editor."],
            params: params(.turbo), limits: editLimits),
        PluginManifest.Offer(
            operation: "image.edit", profile: "image",
            model: ["id": "z-image", "title": "Z-Image (image to image)", "license": apache, "memory_class": "large",
                    "speed_class": "slow", "quality_tiers": ["best"], "named_only": true,
                    "notes": "Re-generates the first image toward the instruction, with CFG; strength 0–1 (default 0.75). Not an instruction editor."],
            params: params(.base), limits: editLimits),
    ])

await GaeaPluginMain.run(plugin)
