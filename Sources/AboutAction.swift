import AppKit

/// Supplies the metadata the standard macOS About panel displays.
protocol AboutMetadataProviding {
    var applicationName: String { get }
    var applicationVersion: String { get }
}

/// Retrieves values from an application's Info.plist without exposing bundle-global state to tests.
protocol BundleInfoReading {
    func object(forInfoDictionaryKey key: String) -> Any?
}

extension Bundle: BundleInfoReading {}

/// Reads About-panel metadata from the application's bundle.
struct BundleAboutMetadata: AboutMetadataProviding {
    private let bundle: BundleInfoReading

    init(bundle: BundleInfoReading = Bundle.main) {
        self.bundle = bundle
    }

    var applicationName: String {
        bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
    }

    var applicationVersion: String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? ""
    }
}

/// Presents About information without coupling the Settings view to AppKit's global application.
protocol AboutPanelPresenting {
    func showAbout(applicationName: String, applicationVersion: String)
}

/// Opens macOS's standard About panel with application bundle metadata.
struct StandardAboutPanelPresenter: AboutPanelPresenting {
    private let licenseURL: URL?

    init(bundle: Bundle = .main) {
        licenseURL = bundle.url(forResource: "LICENSE", withExtension: nil)
    }

    func showAbout(applicationName: String, applicationVersion: String) {
        // NSApplication is main-isolated; callers present from the main queue, so run there
        // synchronously and keep the same-thread behavior the panel had before this hop existed.
        let present: @MainActor @Sendable () -> Void = {
            NSApplication.shared.orderFrontStandardAboutPanel(
                options: self.aboutPanelOptions(applicationName: applicationName, applicationVersion: applicationVersion)
            )
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(present)
        } else {
            DispatchQueue.main.async(execute: present)
        }
    }

    /// Returns the standard panel options, including a navigable link to the bundled license.
    func aboutPanelOptions(applicationName: String,
                           applicationVersion: String) -> [NSApplication.AboutPanelOptionKey: Any] {
        let credits = NSMutableAttributedString(
            string: "Licensed under the GNU Affero General Public License v3. See the included LICENSE file."
        )
        let licenseRange = (credits.string as NSString).range(of: "LICENSE")
        if let licenseURL {
            credits.addAttribute(.link, value: licenseURL, range: licenseRange)
        }
        return [
            .applicationName: applicationName,
            .applicationVersion: applicationVersion,
            .credits: credits
        ]
    }
}

/// Routes the Settings About command through bundle metadata to a panel presenter.
struct AboutAction {
    private let metadata: AboutMetadataProviding
    private let presenter: AboutPanelPresenting

    init(metadata: AboutMetadataProviding = BundleAboutMetadata(),
         presenter: AboutPanelPresenting = StandardAboutPanelPresenter()) {
        self.metadata = metadata
        self.presenter = presenter
    }

    func showAbout() {
        presenter.showAbout(
            applicationName: metadata.applicationName,
            applicationVersion: metadata.applicationVersion
        )
    }
}
