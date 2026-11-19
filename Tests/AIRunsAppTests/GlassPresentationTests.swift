import XCTest
@testable import AIRunsApp

final class GlassPresentationTests: XCTestCase {
    func testReduceTransparencyAlwaysUsesOpaqueMaterial() {
        for supported in [false, true] {
            for contrast in [false, true] {
                let presentation = GlassPresentation.resolve(
                    supportsLiquidGlass: supported, reduceTransparency: true,
                    increasedContrast: contrast)
                XCTAssertEqual(presentation.material, .opaque)
            }
        }
    }

    func testOlderSystemsUseFrostedMaterial() {
        let presentation = GlassPresentation.resolve(
            supportsLiquidGlass: false, reduceTransparency: false,
            increasedContrast: false)
        XCTAssertEqual(presentation.material, .frosted)
    }

    func testSupportedSystemsUseNativeGlass() {
        let presentation = GlassPresentation.resolve(
            supportsLiquidGlass: true, reduceTransparency: false,
            increasedContrast: false)
        XCTAssertEqual(presentation.material, .liquid)
        XCTAssertFalse(presentation.needsContrastBorder)
    }

    func testIncreasedContrastKeepsAnExplicitEdgeInEveryMaterial() {
        for supported in [false, true] {
            for reduced in [false, true] {
                let presentation = GlassPresentation.resolve(
                    supportsLiquidGlass: supported, reduceTransparency: reduced,
                    increasedContrast: true)
                XCTAssertTrue(presentation.needsContrastBorder)
            }
        }
    }
}
