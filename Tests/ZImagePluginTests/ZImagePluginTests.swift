import Foundation
@testable import GaeaPluginKit
import GaeaProtocol
import MLXToolKit
import Testing
@testable import ZImagePlugin

@Suite struct ZImagePluginTests {
    func job(_ params: [String: JSONValue], model: String = "z-image-nitrofusion2") -> Job {
        Job(requestID: "r", job: "job_1", operation: "image.generate", model: model, lane: "int4", inputs: [:],
            params: params, modelParams: [:], adapters: [], seed: 7, outputDir: URL(fileURLWithPath: "/tmp"))
    }

    @Test func nitroFusion2RunsOneToFourStepsWithoutCFG() throws {
        #expect(try Shared(job([:]), tier: .nitro).steps == 2)
        #expect(try Shared(job(["x-zimage.steps": 1]), tier: .nitro).steps == 1)
        #expect(try Shared(job(["x-zimage.steps": 4]), tier: .nitro).steps == 4)
        #expect(throws: GPPError.self) { try Shared(job(["x-zimage.steps": 5]), tier: .nitro) }
        #expect(throws: GPPError.self) { try Shared(job(["x-zimage.steps": 0]), tier: .nitro) }
        let shared = try Shared(job(["negative_prompt": "blurry", "x-zimage.guidance": 6]), tier: .nitro)
        #expect(shared.guidance == 0 && shared.negative == nil)
        #expect(shared.warnings.map(\.code) == ["negative_prompt_ignored"])
        #expect(shared.warnings[0].message.hasPrefix("NitroFusion2 runs without CFG"))
    }

    @Test func turboAndBaseKeepTheirSettings() throws {
        #expect(try Shared(job([:]), tier: .turbo).steps == 8)
        #expect(try Shared(job(["x-zimage.steps": 40]), tier: .turbo).steps == 40)
        let base = try Shared(job(["negative_prompt": "blurry"]), tier: .base)
        #expect(base.steps == 28 && base.guidance == 4 && base.negative == "blurry" && base.warnings.isEmpty)
    }

    @Test func theManifestAddsNitroFusion2AsADraftModelByNameOnly() throws {
        let manifest = try zImagePlugin.manifest()
        #expect(manifest.models.map(\.id) == ["z-image-turbo", "z-image", "z-image-nitrofusion2"])
        let offers = manifest.offers.filter { $0.modelID == "z-image-nitrofusion2" }
        #expect(offers.map(\.operation) == ["image.generate"], "text-to-image only")
        let model = offers[0].model
        #expect(model["named_only"] == true && model["default"] == nil)
        #expect(model["quality_tiers"]?.arrayValue?.compactMap(\.stringValue) == ["draft"])
        let steps = offers[0].params?["properties"]?["x-zimage.steps"]
        #expect(steps?["minimum"] == 1 && steps?["maximum"] == 4 && steps?["default"] == 2)
        // Its lanes fetch the transformer and LoRA from NitroFusion2's repo, and the rest from Turbo's snapshot.
        let nitro = try #require(manifest.models.last)
        #expect(nitro.lanes.map(\.id) == ["int4", "int8", "bf16"] && nitro.lanes[0].default)
        #expect(Set(nitro.lanes[0].resolved.weightSources.map(\.repo)) == ["mlx-community/Z-Image-Turbo-bf16", "ChenDY/NitroFusion2"])
        // Turbo stays the default for draft and standard.
        let turbo = try #require(manifest.offers.first { $0.modelID == "z-image-turbo" && $0.operation == "image.generate" })
        #expect(turbo.model["default"] == true)
        #expect(turbo.params?["properties"]?["x-zimage.steps"]?["maximum"] == 100)
    }
}
