import Foundation
@testable import Readling

extension BookImporter {
    /// Imports into a throwaway folder, for tests that only look at the text.
    static func load(url: URL) throws -> ImportedBook {
        try load(url: url, staging: FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadlingTests-staging-\(UUID().uuidString)", isDirectory: true))
    }
}
