import ArgumentParser
import AsyncAlgorithms
import ZIPFoundation
import Foundation

struct ExtractIPSW: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Extract symbols from an ipsw file.")

    @Option var extractor: String?

    @Argument var path: String
    @Argument var destPath: String

    func run() async throws {
        let extractor = try await DSCExtractor(path: extractor.map { URL(filePath: $0) })

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

protocol SeekableFile {
    func seek(toOffset: UInt64) throws

    @discardableResult
    func seekToEnd() throws -> UInt64

    associatedtype Bytes: AsyncSequence where Bytes.Element == UInt8

    var bytes: Bytes { get async throws }
}

extension FileHandle: SeekableFile {}

final class MemoryFile: SeekableFile, Incrementing {
    let data: Data
    var offset: Int = 0

    func incrementOffset() {
        offset += 1
    }

    init(data: Data) {
        self.data = data
    }

    func seek(toOffset offset: UInt64) {
        self.offset = Int(offset)
    }

    func seekToEnd() -> UInt64 {
        offset = data.count
        return UInt64(offset)
    }

    var bytes: AsyncIncrementingSequence<AsyncSyncSequence<Data>, MemoryFile> {
        .init(base: data.dropFirst(offset).async, root: self)
    }
}

final class RemoteFile: SeekableFile, Incrementing {
    let request: URLRequest
    let session: URLSession

    let contentLength: UInt64

    var offset: UInt64 = 0

    init(request: URLRequest, session: URLSession = .shared) async throws {
        self.request = request
        self.session = session

        var head = request
        head.httpMethod = "HEAD"
        let (_, response) = try await session.bytes(for: head)
        guard response.expectedContentLength != -1 else { throw StringError("Unknown Content-Length") }
        self.contentLength = UInt64(response.expectedContentLength)
    }

    func incrementOffset() {
        offset += 1
    }

    func seek(toOffset offset: UInt64) throws {
        self.offset = offset
    }

    func seekToEnd() throws -> UInt64 {
        self.offset = contentLength
        return offset
    }

    var bytes: AsyncIncrementingSequence<URLSession.AsyncBytes, RemoteFile> {
        get async throws {
            var request = request
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "range")
            return AsyncIncrementingSequence(base: try await session.bytes(for: request).0, root: self)
        }
    }
}

struct AsyncIncrementingSequence<Base: AsyncSequence, Root: Incrementing>: AsyncSequence {
    typealias Element = Base.Element

    let base: Base
    let root: Incrementing

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), root: root)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        let root: Incrementing

        mutating func next() async throws -> Base.Element? {
            guard let next = try await base.next() else { return nil }
            root.incrementOffset()
            return next
        }
    }
}

protocol Incrementing {
    func incrementOffset()
}
