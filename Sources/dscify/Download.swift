import Foundation
import ArgumentParser
import AsyncAlgorithms

struct Download: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Download ipsw list from ipsw.me.")

    func run() async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let devicesURL = URL(string: "https://api.ipsw.me/v4/devices")!
        let deviceURL = URL(string: "https://api.ipsw.me/v4/device")!
        let devicesResponse = try await Data(devicesURL.resourceBytes)
        let devices = try decoder.decode([DeviceData].self, from: devicesResponse)
        let ipswData = try await withThrowingTaskGroup(of: IPSWData.self) { group in
            for device in devices {
                group.addTask {
                    let url = deviceURL.appending(component: device.identifier)
                    let response = try await Data(url.resourceBytes)
                    return try decoder.decode(IPSWData.self, from: response)
                }
            }
            return try await [IPSWData](group)
        }
        let encoded = try encoder.encode(ipswData)
        try FileHandle.standardOutput.write(contentsOf: encoded)
        print() // newline
    }
}

struct IPSWData: Codable {
    struct Firmware: Codable {
        let version: String
        let buildid: String
        let sha1sum: String
        let filesize: UInt64
        let url: String
        let uploaddate: Date
        let releasedate: Date?
    }

    let name: String
    let identifier: String
    let firmwares: [Firmware]
}

struct DeviceData: Decodable {
    let name: String
    let identifier: String
}
