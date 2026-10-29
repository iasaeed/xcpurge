import SwiftUI
import Core

public struct DSButton: View {
    let title: String

    public init(title: String) {
        self.title = title
    }

    public var body: some View {
        Button(action: {}) {
            HStack {
                Image("ds_internal", bundle: .module)
                Text(title)
            }
        }
    }
}
