import Foundation
import LocalCutCore

@MainActor
enum PaddedBackgroundBundleResolver {
    struct BundlePlan {
        var assets: [ProjectBundle.BundledMedia] = []
        var accessedURLs: [URL] = []
    }

    static func bundledAssetPlan(model: EditorModel) -> BundlePlan {
        var plan = BundlePlan()
        guard var background = model.project.paddedBackground,
              background.source == .image,
              let sourceURL = resolveURL(background, model: model) else { return plan }
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        if didAccess { plan.accessedURLs.append(sourceURL) }
        let relative = bundleRelativePath(for: background, sourceURL: sourceURL)
        background.imageBundleRelativePath = relative
        model.project.paddedBackground = background
        plan.assets.append(ProjectBundle.BundledMedia(
            mediaID: UUID(),
            sourceURL: sourceURL,
            bundleRelativePath: relative))
        return plan
    }

    static func resolve(_ preset: PaddedBackgroundPreset?,
                        bundleURL: URL?) -> PaddedBackgroundPreset? {
        guard var preset else { return nil }
        guard preset.source == .image,
              preset.imageBookmark == nil,
              let relative = preset.imageBundleRelativePath else { return preset }
        guard ProjectBundleLayout.isSafeAssetRelativePath(relative),
              let bundleURL else {
            preset.imageBundleRelativePath = nil
            return preset
        }
        let sourceURL = bundleURL.appendingPathComponent(relative)
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else { return preset }
        preset.imageBookmark = try? sourceURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        return preset
    }

    static func singleFileBookmark(for preset: PaddedBackgroundPreset,
                                   model: EditorModel) -> Data? {
        guard let relativePath = preset.imageBundleRelativePath,
              ProjectBundleLayout.isSafeAssetRelativePath(relativePath),
              case .saved(let bundleURL, .bundle) = model.projectSessionLocation else {
            return nil
        }
        let didAccess = bundleURL.startAccessingSecurityScopedResource()
        defer { if didAccess { bundleURL.stopAccessingSecurityScopedResource() } }
        let sourceURL = bundleURL.appendingPathComponent(relativePath)
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else { return nil }
        return try? sourceURL.bookmarkData(options: .withSecurityScope,
                                           includingResourceValuesForKeys: nil,
                                           relativeTo: nil)
    }

    static func adoptSingleFileBookmark(from background: PaddedBackgroundPreset?,
                                         model: EditorModel) {
        guard var current = model.project.paddedBackground,
              current.source == .image,
              let bookmark = background?.imageBookmark else { return }
        current.imageBookmark = bookmark
        current.imageBundleRelativePath = nil
        model.project.paddedBackground = current
    }

    private static func resolveURL(_ preset: PaddedBackgroundPreset,
                                   model: EditorModel) -> URL? {
        if let bookmark = preset.imageBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark,
                                  options: [.withSecurityScope],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                return url
            }
        }
        guard let relative = preset.imageBundleRelativePath,
              ProjectBundleLayout.isSafeAssetRelativePath(relative),
              case .saved(let bundleURL, .bundle) = model.projectSessionLocation else { return nil }
        let sourceURL = bundleURL.appendingPathComponent(relative)
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else { return nil }
        return sourceURL
    }

    private static func bundleRelativePath(for preset: PaddedBackgroundPreset,
                                           sourceURL: URL) -> String {
        if let existing = preset.imageBundleRelativePath,
           ProjectBundleLayout.isSafeAssetRelativePath(existing) {
            return existing
        }
        return ProjectBundleLayout.assetRelativePath(mediaID: UUID(),
                                                     sourceExtension: sourceURL.pathExtension)
    }
}
