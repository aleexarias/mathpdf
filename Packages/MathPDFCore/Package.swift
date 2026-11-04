// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MathPDFCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MathPDFCore", targets: ["MathPDFCore"]),
        .library(name: "MathPDFLaTeX", targets: ["MathPDFLaTeX"]),
        .library(name: "MathPDFRendering", targets: ["MathPDFRendering"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/mgriebling/SwiftMath", exact: "1.7.3")
    ],
    targets: [
        /// Annotations, how they change, and how they're saved. No UI.
        .target(name: "MathPDFCore"),
        /// Typesetting LaTeX formulas and drawing them on PDF pages.
        .target(
            name: "MathPDFLaTeX",
            dependencies: [.product(name: "SwiftMath", package: "SwiftMath")]),
        /// Annotations as PDFKit annotations: on screen, and exported into a
        /// copy of the PDF.
        .target(
            name: "MathPDFRendering",
            dependencies: ["MathPDFCore", "MathPDFLaTeX"]),
        .testTarget(
            name: "MathPDFCoreTests",
            dependencies: ["MathPDFCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "MathPDFLaTeXTests", dependencies: ["MathPDFLaTeX"]),
        .testTarget(
            name: "MathPDFRenderingTests", dependencies: ["MathPDFRendering"]),
    ]
)
