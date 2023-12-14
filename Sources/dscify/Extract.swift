import ArgumentParser
import Foundation

struct Extract: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Extract symbols from a dyld_shared_cache.")

    @Option(
        name: .shortAndLong,
        help: "Path to dsc_extractor.bundle. Computed with xcrun by default.",
        completion: .file(extensions: ["bundle"]),
        transform: { URL(filePath: $0) }
    ) var extractor: URL?

    @Argument(
        help: ArgumentHelp(
            "Path to dyld_shared_cache.",
            discussion: "On newer OSes, this file should have sub-caches as siblings."
        ),
        completion: .file(),
        transform: { URL(filePath: $0) }
    ) var input: URL

    @Argument(
        help: "Path to output directory.",
        completion: .directory,
        transform: { URL(filePath: $0) }
    )
    var output: URL

    func run() async throws {
        let extractor = try await DSCExtractor(path: extractor)

        let progress = Progress()
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
        extractor.extract(cache: input, output: output, progress: progress)
        cancellable.cancel()
        log("")
    }
}

struct DSCExtractor {
    private typealias ExtractFunc = @convention(c) (
        UnsafePointer<CChar>,
        UnsafePointer<CChar>,
        @convention(block) (CUnsignedInt, CUnsignedInt) -> Void
    ) -> Void

    private let extract: ExtractFunc

    init(path: URL? = nil) async throws {
        let extractor: URL
        if let path {
            extractor = path
        } else {
            let xcrunPipe = Pipe()
            let xcrun = Process()
            xcrun.executableURL = URL(filePath: "/usr/bin/xcrun")
            xcrun.arguments = ["--show-sdk-platform-path", "--sdk", "iphoneos"]
            xcrun.standardOutput = xcrunPipe
            async let platformRaw = Data(xcrunPipe.fileHandleForReading.bytes)
            try xcrun.run()
            let platform = URL(filePath: String(decoding: try await platformRaw.dropLast(), as: UTF8.self))
            xcrun.waitUntilExit()
            extractor = platform.appending(path: "usr/lib/dsc_extractor.bundle")
        }
        log("Loading \(extractor.path)...")

        guard let handle = dlopen(extractor.path, RTLD_LAZY) else {
            let error = String(cString: dlerror())
            throw StringError("Could not load extractor: \(error)")
        }

        guard let extract = dlsym(handle, "dyld_shared_cache_extract_dylibs_progress") else {
            let error = String(cString: dlerror())
            throw StringError("Could not find dyld_shared_cache_extract_dylibs_progress: \(error)")
        }

        self.extract = unsafeBitCast(extract, to: ExtractFunc.self)
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
