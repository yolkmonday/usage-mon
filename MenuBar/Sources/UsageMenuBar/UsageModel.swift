import Foundation
import SwiftUI

/// State untuk popup: menyimpan hasil report terakhir, status loading, dan error.
@MainActor
final class UsageModel: ObservableObject {
    @Published var report: UsageReport?
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var lastUpdated: Date?
    @Published var days: Int = 7

    private var runner: UsageRunner { UsageRunner(days: days) }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        let currentDays = days
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<UsageReport, Error>
            do {
                let r = try UsageRunner(days: currentDays).fetch()
                result = .success(r)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let r):
                    self.report = r
                    self.lastUpdated = Date()
                    self.errorMessage = nil
                case .failure(let e):
                    self.errorMessage = e.localizedDescription
                }
            }
        }
    }

    /// Nilai persentase tertinggi dari semua limit, untuk label menu bar.
    var peakPercent: (Double, Severity)? {
        var list: [(Double, Severity)] = []
        if let limits = report?.claudeLimits?.limits {
            for l in limits {
                list.append((l.percent, Severity.from(percent: l.percent, severity: l.severity)))
            }
        }
        if let rl = report?.codex.rateLimit {
            if let p = rl.primary?.usedPercent { list.append((p, Severity.from(percent: p))) }
            if let s = rl.secondary?.usedPercent { list.append((s, Severity.from(percent: s))) }
        }
        guard let maxItem = list.max(by: { $0.0 < $1.0 }) else { return nil }
        // severity dari item dengan persentase tertinggi; jika persen sama, ambil yang terparah
        let tied = list.filter { $0.0 == maxItem.0 }
        let sev = tied.contains { $0.1 == .critical } ? Severity.critical
                : tied.contains { $0.1 == .warning } ? .warning : .normal
        return (maxItem.0, sev)
    }
}
