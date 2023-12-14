import ArgumentParser
import Foundation

@main struct Root: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dscify", subcommands: [Download.self, Extract.self, ExtractIPSW.self])
}

struct StringError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) {
        self.description = description
    }
}
