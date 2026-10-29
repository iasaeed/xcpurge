/// The detectors xcpurge ships, selectable by category.
public enum DetectorRegistry {
    public static let all: [any Detector] = [AssetsDetector(), DuplicatesDetector(), StringsDetector(), FilesDetector()]

    public static func detectors(for categories: Set<Category>) -> [any Detector] {
        all.filter { categories.contains($0.category) }
    }
}
