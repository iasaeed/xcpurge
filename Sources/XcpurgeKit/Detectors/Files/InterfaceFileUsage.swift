// LANE: C
/// Storyboards and xibs nothing loads. A file is used when an Info.plist key or `INFOPLIST_KEY_*` setting names it
/// (`UIMainStoryboardFile`, `UILaunchStoryboardName`, scene storyboards), another IB file references it
/// (`storyboardName=`), a loading API names it (`UIStoryboard(name:)`, `UINib(nibName:)`, `loadNibNamed`,
/// `NSNib`, `initWithNibName:`), a generated accessor names it, or a type shares its name (nib-by-class-name
/// loading, `String(describing: Cell.self)`), or a `<stem>Controller` / `<stem>ViewController` type is used
/// (UIKit's default nib lookup: `MyViewController()` loads `MyView.xib`). A bare string literal elsewhere leaves
/// it reported at medium.
enum InterfaceFileUsage {
    static let loaderCallees: Set<String> = ["UIStoryboard", "NSStoryboard", "UINib", "NSNib", "loadNibNamed"]
    static let loaderLabels: Set<String> = [
        "name", "nibName", "nibNamed", "loadNibNamed", "storyboardWithName", "nibWithNibName", "initWithNibName",
        "withNibName", "storyboardName", "initWithNibNamed",
    ]

    static func find(_ ctx: ScanContext, skipping orphans: Set<String>) -> [Finding] {
        let isUser = FilesDetector.userFilter(ctx, orphans: orphans)
        var out: [Finding] = []
        for (i, file) in ctx.inventory.files.enumerated() where file.kind == .storyboard || file.kind == .xib {
            guard !file.modules.isEmpty, !orphans.contains(file.path), !FilesDetector.isInsideOpaqueFolder(file.path)
            else { continue }
            var stem = RelPath.stem(file.path)
            for device in ["~iphone", "~ipad"] where stem.hasSuffix(device) { stem.removeLast(device.count) }
            let visible = FilesDetector.visibility(of: file, in: ctx)
            let canSee = { (source: Int32) in source != Int32(i) && isUser(source) && ctx.refs.isVisible(source, visible) }
            let ext = file.kind == .storyboard ? "storyboard" : "xib"
            let controllers = ["\(stem)Controller", "\(stem)ViewController"].flatMap { ctx.refs.sites($0, kinds: .symbols) }
            let sites = ([stem, "\(stem).\(ext)", "\(stem).storyboardc", "\(stem).nib"].flatMap { ctx.refs.sites($0) } + controllers)
                .filter { !ResourceFileUsage.isUserText($0) && canSee($0.file) }
            if sites.contains(where: isLoad) { continue }

            var reasons = ["no Info.plist key, IB reference or loading call names '\(stem)'"]
            let confidence: Confidence
            if let literal = sites.first {
                confidence = .medium
                reasons.append("'\(stem)' appears as a string at \(ctx.refs.path(of: literal.file)):\(literal.line)")
            } else if let site = ResourceFileUsage.dynamicMatch(stem, domains: [.any, .resource], ctx, canSee: canSee) {
                confidence = .low
                reasons.append("may be built dynamically at \(site)")
            } else {
                confidence = .high
            }
            out.append(Finding(kind: .unusedInterfaceFile, category: .files, path: file.path,
                               module: ctx.moduleName(for: file.path), confidence: confidence, reasons: reasons,
                               sizeBytes: file.size))
        }
        return out
    }

    /// True for a reference that loads the interface file rather than merely spelling its name.
    static func isLoad(_ r: Reference) -> Bool {
        switch r.kind {
        case .plistValue, .buildSetting, .accessorUse, .identifier, .memberSymbol: return true
        case .ibAttribute(let attribute): return attribute == "storyboardName"
        case .stringLiteral:
            return loaderCallees.contains(r.context?.callee ?? "") || loaderLabels.contains(r.context?.label ?? "")
        }
    }
}
