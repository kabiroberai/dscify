import ArgumentParser
import AsyncAlgorithms
import ZIPFoundation
import Foundation

struct Extract: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Extract symbols from an ipsw file.")

    @Argument var path: String
    @Argument var destPath: String

    func run() async throws {
        let extractor = try await DSCExtractor()

        let url = URL(filePath: path)
        let destURL = URL(filePath: destPath)

        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)

        // TODO: partialzip?
        let archive = try Archive(url: url, accessMode: .read)
        guard let manifestEntry = archive.first(where: { $0.path == "BuildManifest.plist" })
              else { throw StringError("Invalid IPSW: could not locate BuildManifest.plist") }
        var manifestData = Data()
        guard try archive.extract(manifestEntry, consumer: { manifestData += $0 }) == manifestEntry.checksum
              else { throw StringError("Invalid IPSW: bad manifest checksum") }
        let manifest = try PropertyListDecoder().decode(Manifest.self, from: manifestData)

        // TODO: Improve SystemOS search
        guard let path = manifest.buildIdentities.first?.manifest["Cryptex1,SystemOS"]?.info.path
              else { throw StringError("Could not find SystemOS image path.") }
        guard let imageEntry = archive.first(where: { $0.path == path })
              else { throw StringError("SystemOS image was not found in archive") }

        print("Unarchiving SystemOS...")

        let systemOSURL = destURL.appending(component: "SystemOS.dmg")
        guard try archive.extract(imageEntry, to: systemOSURL) == imageEntry.checksum
              else { throw StringError("Invalid IPSW: bad SystemOS checksum") }

        print("Mounting...")

        let mountPoint = destURL.appending(component: "SystemOS")

        let attach = Process()
        attach.executableURL = hdiutil
        attach.arguments = ["attach", systemOSURL.path, "-mountpoint", mountPoint.path, "-nobrowse"]
        try attach.run()
        attach.waitUntilExit()

        print("Expanding cache...")

        // TODO: Support other architectures
        let dsc = mountPoint.appending(path: "System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e")
        extractor.extract(cache: dsc, output: destURL)

        print("Unmounting SystemOS...")
        let detach = Process()
        detach.executableURL = hdiutil
        detach.arguments = ["detach", mountPoint.path]
        try? detach.run()
        detach.waitUntilExit()

        try FileManager.default.removeItem(at: systemOSURL)
    }
}

let hdiutil = URL(filePath: "/usr/bin/hdiutil")

struct DSCExtractor {
    private typealias Extract = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, @convention(block) (CUnsignedInt, CUnsignedInt) -> Void) -> Void

    private let extract: Extract

    init() async throws {
        let developerDirPipe = Pipe()
        let developerDirProc = Process()
        developerDirProc.executableURL = URL(filePath: "/usr/bin/xcode-select")
        developerDirProc.arguments = ["-p"]
        developerDirProc.standardOutput = developerDirPipe
        async let bytesAsync = Data(developerDirPipe.fileHandleForReading.bytes)
        try developerDirProc.run()
        let developerDir = URL(filePath: String(decoding: try await bytesAsync, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        developerDirProc.waitUntilExit()

        let extractor = developerDir.appending(path: "Platforms/iPhoneOS.platform/usr/lib/dsc_extractor.bundle")
        let handle = dlopen(extractor.path, RTLD_LAZY)
        guard let fun = dlsym(handle, "dyld_shared_cache_extract_dylibs_progress")
              else { throw StringError("Could not find dyld_shared_cache_extract_dylibs_progress")}
        self.extract = unsafeBitCast(fun, to: Extract.self)
    }

    func extract(cache: URL, output: URL, progress: (_ current: UInt, _ total: UInt) -> Void = { _, _ in }) {
        extract(cache.path, output.path) { progress(UInt($0), UInt($1)) }
    }
}

struct Manifest: Decodable {
    struct BuildIdentity: Decodable {
        struct ManifestItem: Decodable {
            struct Info: Decodable {
                let path: String?

                private enum CodingKeys: String, CodingKey {
                    case path = "Path"
                }
            }

            let info: Info

            private enum CodingKeys: String, CodingKey {
                case info = "Info"
            }
        }

        let manifest: [String: ManifestItem]

        private enum CodingKeys: String, CodingKey {
            case manifest = "Manifest"
        }
    }

    let buildIdentities: [BuildIdentity]

    private enum CodingKeys: String, CodingKey {
        case buildIdentities = "BuildIdentities"
    }
}
