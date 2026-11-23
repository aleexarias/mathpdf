import Foundation

extension AnnotationStore {
    /// Every image an annotation refers to, in every document's current state
    /// and every snapshot, damaged and set-aside files included. The files are
    /// read as text, not decoded, so one this version can't read, damaged or
    /// from a newer version, still counts. Throws if any file can't be read,
    /// as nothing can safely be deleted then.
    public func referencedImages() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: documentsURL.path) else {
            return []
        }
        var failure: Error?
        guard
            let files = FileManager.default.enumerator(
                at: documentsURL, includingPropertiesForKeys: nil,
                errorHandler: { _, error in
                    failure = error
                    return false
                })
        else { throw CocoaError(.fileReadUnknown) }
        // how an image annotation names its image in a store file
        let imageHash = #/"hash"\s*:\s*"([0-9a-f]{64})"/#
        var hashes = Set<String>()
        while let url = files.nextObject() as? URL {
            guard url.pathExtension == "json",
                !url.lastPathComponent.contains(AtomicFile.tempMarker)
            else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in text.matches(of: imageHash) {
                hashes.insert(String(match.output.1))
            }
        }
        if let failure { throw failure }
        return hashes
    }
}
