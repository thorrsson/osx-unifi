import Combine
import Foundation
import Sparkle

@MainActor
final class UpdaterModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?
    @Published var automaticallyChecks: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    @Published var automaticallyDownloads: Bool {
        didSet { controller?.updater.automaticallyDownloadsUpdates = automaticallyDownloads }
    }
    let isConfigured: Bool
    private let controller: SPUStandardUpdaterController?
    private var subscriptions = Set<AnyCancellable>()

    init() {
        let bundle = Bundle.main
        isConfigured = Self.validConfiguration(
            feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        )
        if isConfigured {
            controller = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
            )
        } else {
            controller = nil
        }
        automaticallyChecks = controller?.updater.automaticallyChecksForUpdates ?? false
        automaticallyDownloads = controller?.updater.automaticallyDownloadsUpdates ?? false
        guard let updater = controller?.updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &subscriptions)
        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastUpdateCheckDate = $0 }
            .store(in: &subscriptions)
    }

    static func validConfiguration(feed: String?, publicKey: String?) -> Bool {
        guard let feed, let url = URLComponents(string: feed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              let publicKey, Data(base64Encoded: publicKey)?.count == 32 else { return false }
        return true
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }
}
