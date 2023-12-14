import ArgumentParser
import Foundation

struct Extract: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Extract symbols from a dyld_shared_cache.")

    @Option(name: .shortAndLong, help: "Path to dsc_extractor.bundle. Computed with xcrun by default.")
    var extractor: String?

    @Argument(help: ArgumentHelp("Path to dyld_shared_cache", discussion: "On newer OSes, this file should have sub-caches as siblings.")) var input: String
    @Argument var output: String

    func run() async throws {
        let extractor = try await DSCExtractor(path: extractor.map { URL(filePath: $0) })

        let url = URL(filePath: input)
        let destURL = URL(filePath: output)

        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)

        let progress = Progress()
        log("Extracting...", newline: false)
        let cancellable = progress.publisher(for: \.completedUnitCount, options: .new).sink { _ in
            log(
                """
                \rExtracting: \
                \(progress.fractionCompleted.formatted(.percent.precision(.fractionLength(2)))) \
                [\(progress.completedUnitCount)/\(progress.totalUnitCount)]
                """,
                newline: false
            )
        }
        extractor.extract(cache: url, output: destURL, progress: progress)
        cancellable.cancel()
        log("")
    }
}

struct DSCExtractor {
    private typealias Extract = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, @convention(block) (CUnsignedInt, CUnsignedInt) -> Void) -> Void

    private let extract: Extract

    init(path: URL? = nil) async throws {
        let extractor: URL
        if let path {
            extractor = path
        } else {
            let developerDirPipe = Pipe()
            let developerDirProc = Process()
            developerDirProc.executableURL = URL(filePath: "/usr/bin/xcrun")
            developerDirProc.arguments = ["--show-sdk-platform-path", "--sdk", "iphoneos"]
            developerDirProc.standardOutput = developerDirPipe
            async let bytesAsync = Data(developerDirPipe.fileHandleForReading.bytes)
            try developerDirProc.run()
            let developerDir = URL(filePath: String(decoding: try await bytesAsync, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            developerDirProc.waitUntilExit()
            extractor = developerDir.appending(path: "usr/lib/dsc_extractor.bundle")
        }
        log("Loading \(extractor.path)...")

        guard let handle = dlopen(extractor.path, RTLD_LAZY) else {
            let error = String(cString: dlerror())
            throw StringError("Could not load extractor: \(error)")
        }

        guard let fun = dlsym(handle, "dyld_shared_cache_extract_dylibs_progress") else {
            let error = String(cString: dlerror())
            throw StringError("Could not find dyld_shared_cache_extract_dylibs_progress: \(error)")
        }

        self.extract = unsafeBitCast(fun, to: Extract.self)
    }

    func extract(cache: URL, output: URL, progress: Progress? = nil) {
        extract(cache.path, output.path) { completed, total in
            guard let progress else { return }
            let total = Int64(total)
            if progress.totalUnitCount != total {
                progress.totalUnitCount = total
            }
            progress.completedUnitCount = Int64(completed)
        }
        if let progress {
            progress.completedUnitCount = progress.totalUnitCount
        }
    }
}

private func log(_ string: some CustomStringConvertible, newline: Bool = true) {
    try? FileHandle.standardError.write(contentsOf: Data("\(string)\(newline ? "\n" : "")".utf8))
}
