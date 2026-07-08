import Foundation

/// Single source of truth for product identity. To rebrand, change `productName`
/// and `bundleIdentifier` here and `PRODUCT_BUNDLE_IDENTIFIER` in app/project.yml.
enum Config {
    static let productName = "MicioStudio"
    static let bundleIdentifier = "dev.miciodev.MicioStudio"

    /// Folder under ~/Movies where each recording session is written.
    static let recordingsFolderName = "MicioStudio"
}
