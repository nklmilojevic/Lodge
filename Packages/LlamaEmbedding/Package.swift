// swift-tools-version: 5.9
import PackageDescription

// EmbeddingGemma 2 on llama.cpp. scripts/build-llama.sh builds Vendor/CLlama.xcframework.
let package = Package(
  name: "LlamaEmbedding",
  platforms: [.macOS(.v14)],
  products: [.library(name: "LlamaEmbedding", targets: ["LlamaEmbedding"])],
  targets: [
    .binaryTarget(name: "CLlama", path: "Vendor/CLlama.xcframework"),
    .target(name: "LlamaEmbedding", dependencies: ["CLlama"]),
    .testTarget(name: "LlamaEmbeddingTests", dependencies: ["LlamaEmbedding"])
  ]
)
