import Foundation

// MARK: - Model yang cocok dengan output `usage-mon --json`

struct UsageReport: Codable {
    let days: Int
    let claude: AgentUsage
    let codex: AgentUsage
    let claudeLimits: ClaudeLimits?

    enum CodingKeys: String, CodingKey {
        case days, claude, codex
        case claudeLimits = "claude_limits"
    }
}

struct AgentUsage: Codable {
    let source: String
    let total: Totals
    let models: [String: ModelUsage]?
    let rateLimit: CodexRateLimit?

    enum CodingKeys: String, CodingKey {
        case source, total, models
        case rateLimit = "rate_limit"
    }
}

struct Totals: Codable {
    let input: Int
    let output: Int
    let cacheWrite: Int
    let cacheRead: Int
    let totalTokens: Int
    let costUSD: Double

    enum CodingKeys: String, CodingKey {
        case input, output
        case cacheWrite = "cache_write"
        case cacheRead = "cache_read"
        case totalTokens = "total_tokens"
        case costUSD = "cost_usd"
    }

    var cacheTotal: Int { cacheWrite + cacheRead }
}

struct ModelUsage: Codable {
    let totalTokens: Int
    let costUSD: Double

    enum CodingKeys: String, CodingKey {
        case totalTokens = "total_tokens"
        case costUSD = "cost_usd"
    }
}

// MARK: - Limit Claude (dari API OAuth)

struct ClaudeLimits: Codable {
    let limits: [ClaudeLimit]?
    let extraUsage: ExtraUsage?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case limits, error
        case extraUsage = "extra_usage"
    }
}

struct ClaudeLimit: Codable {
    let label: String
    let percent: Double
    let severity: String
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case label, percent, severity
        case resetsAt = "resets_at"
    }
}

struct ExtraUsage: Codable {
    let isEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
    }
}

// MARK: - Limit Codex (dari file session)

struct CodexRateLimit: Codable {
    let primary: CodexWindow?
    let secondary: CodexWindow?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case primary, secondary
        case planType = "plan_type"
    }
}

struct CodexWindow: Codable {
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }
}
