import SwiftUI

// MARK: - Tema warna status

enum Severity {
    case normal, warning, critical

    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    static func from(percent: Double, severity: String = "normal") -> Severity {
        if severity == "critical" { return .critical }
        if percent >= 85 { return .critical }
        if percent >= 60 { return .warning }
        return .normal
    }
}

// MARK: - Baris progress kuota

struct QuotaRow: View {
    let label: String
    let percent: Double
    let resetText: String
    var severity: Severity = .normal

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(String(format: "%.0f%%", percent))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(severity.color)
                if !resetText.isEmpty {
                    Text(resetText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(severity.color)
                        .frame(width: max(0, min(1, percent / 100)) * geo.size.width)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Kartu agent

struct AgentCard: View {
    let title: String
    let symbol: String
    let usage: AgentUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(Format.cost(usage.total.costUSD))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            HStack(spacing: 14) {
                stat("token", Format.tokens(usage.total.totalTokens))
                stat("in", Format.tokens(usage.total.input))
                stat("out", Format.tokens(usage.total.output))
                stat("cache", Format.tokens(usage.total.cacheTotal))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 11, weight: .medium, design: .rounded))
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Seksi limit

struct LimitsSection: View {
    let claudeLimits: ClaudeLimits?
    let codexRateLimit: CodexRateLimit?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let claudeLimits {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.system(size: 10))
                        Text("Limit Claude").font(.system(size: 11, weight: .semibold))
                    }
                    if let error = claudeLimits.error {
                        Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                        Text("Jalankan `claude` sekali untuk refresh token.")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    } else if let limits = claudeLimits.limits, !limits.isEmpty {
                        ForEach(Array(limits.enumerated()), id: \.offset) { _, lim in
                            QuotaRow(
                                label: lim.label,
                                percent: lim.percent,
                                resetText: Format.reset(iso: lim.resetsAt),
                                severity: Severity.from(percent: lim.percent, severity: lim.severity)
                            )
                        }
                    }
                }
            }

            if let rl = codexRateLimit {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal").font(.system(size: 10))
                        Text("Limit Codex").font(.system(size: 11, weight: .semibold))
                        if let plan = rl.planType {
                            Text(plan).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                    if let p = rl.primary, let pct = p.usedPercent {
                        QuotaRow(label: "5 jam", percent: pct,
                                 resetText: Format.reset(epoch: p.resetsAt),
                                 severity: Severity.from(percent: pct))
                    }
                    if let s = rl.secondary, let pct = s.usedPercent {
                        QuotaRow(label: "mingguan", percent: pct,
                                 resetText: Format.reset(epoch: s.resetsAt),
                                 severity: Severity.from(percent: pct))
                    }
                }
            }
        }
    }
}

// MARK: - Seluruh isi popup

struct PopoverView: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Usage Monitor")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Picker("", selection: $model.days) {
                    Text("7h").tag(7)
                    Text("30h").tag(30)
                }
                .pickerStyle(.segmented)
                .frame(width: 90)
                .onChange(of: model.days) { _ in model.refresh() }
            }

            if let error = model.errorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            }

            if let report = model.report {
                LimitsSection(claudeLimits: report.claudeLimits,
                              codexRateLimit: report.codex.rateLimit)

                Divider()

                AgentCard(title: "Claude", symbol: "sparkles", usage: report.claude)
                AgentCard(title: "Codex", symbol: "terminal", usage: report.codex)

                let total = report.claude.total.costUSD + report.codex.total.costUSD
                HStack {
                    Text("Total \(report.days) hari")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text(Format.cost(total))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
            } else if model.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Memuat...").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
            }

            Divider()

            HStack {
                if let t = model.lastUpdated {
                    Text("Update \(Format.time(t))")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Keluar", systemImage: "power")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

// MARK: - Format helper

enum Format {
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    static func cost(_ c: Double) -> String {
        String(format: "$%.2f", c)
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    static func reset(iso: String?) -> String {
        guard let iso, let date = ISO8601DateFormatter.flexible.date(from: iso) else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return "reset " + f.string(from: date)
    }

    static func reset(epoch: Double?) -> String {
        guard let epoch else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return "reset " + f.string(from: Date(timeIntervalSince1970: epoch))
    }
}

extension ISO8601DateFormatter {
    static let flexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
