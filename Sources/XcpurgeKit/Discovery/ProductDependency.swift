/// A dependency on a Swift package product (`XCSwiftPackageProductDependency`, `.product(name:package:)`).
public struct ProductDependency: Sendable, Hashable {
    /// Root-relative directory of a local package, or nil for remote / unknown packages.
    public var packageDir: String?
    /// Package identity or name as written (`package:` argument, or the remote URL's last component).
    public var package: String?
    public var product: String

    public init(packageDir: String? = nil, package: String? = nil, product: String) {
        self.packageDir = packageDir
        self.package = package
        self.product = product
    }
}
