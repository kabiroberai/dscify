import ArgumentParser
import AsyncAlgorithms
import Foundation

struct Extract: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Extract symbols from a dyld_shared_cache.")

    @Option var extractor: String?

    @Argument var path: String
    @Argument var destPath: String

    func run() async throws {
        let extractor = try await DSCExtractor(path: extractor.map { URL(filePath: $0) })

        let url = URL(filePath: path)
        let destURL = URL(filePath: destPath)

        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)

        let progress = Progress()
        try log("Preparing...\n")
        let cancellable = progress.publisher(for: \.completedUnitCount, options: .new).sink { completed in
            try? log("""
            \rExtracting: \
            \(progress.fractionCompleted.formatted(.percent.precision(.fractionLength(2)))) \
            [\(progress.completedUnitCount)/\(progress.totalUnitCount)]
            """)
        }
        extractor.extract(cache: url, output: destURL, progress: progress)
        cancellable.cancel()
        try log("\n")
    }

    private func log(_ string: String) throws {
        try FileHandle.standardError.write(contentsOf: Data(string.utf8))
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
            developerDirProc.executableURL = URL(filePath: "/usr/bin/xcode-select")
            developerDirProc.arguments = ["-p"]
            developerDirProc.standardOutput = developerDirPipe
            async let bytesAsync = Data(developerDirPipe.fileHandleForReading.bytes)
            try developerDirProc.run()
            let developerDir = URL(filePath: String(decoding: try await bytesAsync, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            developerDirProc.waitUntilExit()
            extractor = developerDir.appending(path: "Platforms/iPhoneOS.platform/usr/lib/dsc_extractor.bundle")
        }

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
