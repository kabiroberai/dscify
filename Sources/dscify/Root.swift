import ArgumentParser
import Foundation

@main struct Root: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dscify", subcommands: [Download.self, Extract.self])
}

struct StringError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) {
        self.description = description
    }
}

func log(_ string: some CustomStringConvertible, newline: Bool = true) {
    try? FileHandle.standardError.write(contentsOf: Data("\(string)\(newline ? "\n" : "")".utf8))
}
