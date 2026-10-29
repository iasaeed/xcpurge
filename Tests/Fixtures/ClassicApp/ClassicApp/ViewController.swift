import CoreData
import UIKit

/// Instantiated by Main.storyboard (customClass); Main.storyboard is the Info.plist main storyboard.
final class ViewController: UIViewController {
    private let container = NSPersistentContainer(name: "Model")

    override func viewDidLoad() {
        super.viewDidLoad()
        Legacy().greet()
        let icon = UIImage(named: "icon")
        _ = icon
        if let url = Bundle.main.url(forResource: "config", withExtension: "json") {
            _ = try? Data(contentsOf: url)
        }
        title = NSLocalizedString("greeting", comment: "")
    }
}
