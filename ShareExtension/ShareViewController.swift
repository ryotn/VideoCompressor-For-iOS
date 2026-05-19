import UIKit
import Social
import MobileCoreServices
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()

        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let itemProvider = extensionItem.attachments?.first else {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        let movieType = UTType.movie.identifier

        if itemProvider.hasItemConformingToTypeIdentifier(movieType) {
            itemProvider.loadItem(forTypeIdentifier: movieType, options: nil) { [weak self] (item, error) in
                guard let self = self else { return }
                if let url = item as? URL {
                    self.openMainApp(with: url)
                } else {
                    DispatchQueue.main.async {
                        self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                    }
                }
            }
        } else {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    private func setupUI() {
        view.backgroundColor = UIColor(white: 0, alpha: 0.7)

        let container = UIView()
        container.backgroundColor = UIColor.systemBackground
        container.layer.cornerRadius = 10
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        let activityIndicator = UIActivityIndicatorView(style: .large)
        activityIndicator.startAnimating()
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(activityIndicator)

        let label = UILabel()
        label.text = "準備中..."
        label.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        label.textColor = UIColor.label
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            container.widthAnchor.constraint(equalToConstant: 150),
            container.heightAnchor.constraint(equalToConstant: 120),

            activityIndicator.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -10),

            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.topAnchor.constraint(equalTo: activityIndicator.bottomAnchor, constant: 16)
        ])
    }

    private func openMainApp(with url: URL) {
        // App Groups are required to share files between an extension and the main app reliably,
        // but for simplicity in this sandbox we will copy the file to a shared container.
        let groupIdentifier = "group.com.ryotn.VideoCompressor"
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else { return }

        let sharedDir = groupURL.appendingPathComponent("SharedVideo")
        try? FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true, attributes: nil)
        cleanupSharedDirectory(sharedDir)

        let destinationURL = sharedDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destinationURL)
        try? FileManager.default.copyItem(at: url, to: destinationURL)

        // Open the app via custom URL scheme
        var components = URLComponents()
        components.scheme = "videocompressor"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "file", value: destinationURL.lastPathComponent)]

        if let appURL = components.url {
            DispatchQueue.main.async {
                self.openURL(appURL)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                }
            }
        } else {
            DispatchQueue.main.async {
                self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            }
        }
    }

    @objc func openURL(_ url: URL) {
        var responder: UIResponder? = self
        while responder != nil {
            if let application = responder as? UIApplication {
                if #available(iOS 18.0, *) {
                    application.open(url, options: [:], completionHandler: nil)
                } else {
                    application.perform(#selector(openURL(_:)), with: url)
                }
                break
            }
            responder = responder?.next
        }
    }

    private func cleanupSharedDirectory(_ directoryURL: URL) {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            return
        }

        for fileURL in fileURLs {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
