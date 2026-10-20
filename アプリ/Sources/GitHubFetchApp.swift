// GitHub 取得（メニューバーのアプリ）
//
// - 状態は、取ったデータのフォルダ（ホームの直下の GitHub取得データ/）の 状態.json と 取得の記録.jsonl を読んで出す
//   （github.py が書く。形は 設計書.md の 3.4・3.5）。データのフォルダは、取得の仕組みのフォルダ（github.py のある場所。
//   GitHub から取ってきて入れ替えたり公開したりする）の外に置く。決まりは台本と同じ（GITHUB_FETCH_DATA があればそこ）
// - 取得の仕組みのフォルダは build.sh が組み立てるときにアプリに書き込む。設定で変えられる
// - 「今すぐ取る」と毎朝の自動実行は、このアプリが github.py fetch を動かす（GitHub は読むだけ。AI は使わない）。
//   Mac は「書類」「ダウンロード」「デスクトップ」のフォルダを守っていて、予約の仕組み（launchd）から動いた台本は
//   中のファイルに触れない。このアプリに許可をもらえば、アプリから動かした台本は触れる。そのためアプリが受け持つ
// - 取得の仕組みのフォルダは、場所の文字と、フォルダそのもの（Mac のブックマーク）の両方で覚える（Slack 取得と同じ）
// - はじめの準備（GitHub にログイン → リポジトリを選ぶ → 取得を始める）は Setup.swift。
//   メニューの「GitHub とリポジトリ…」と設定から開き、取るリポジトリを足す・外す。GitHub取得データ/リポジトリ.json が
//   無いときは開いたときに出す。準備の窓を開いている間と、最初の取得の前は、毎朝の自動取得を動かさない
// - GitHub の回数の上限で待っているとき（状態.json の run.wait_until）は、その時刻を過ぎたら続きを取る
// - Mac のスリープ: Slack 取得と同じ（眠っている間も時刻が来たら始める。眠っていて取れなかったら、黄色で知らせる）
// - 確認用: GitHubFetch --snapshot <フォルダ> で、各状態のメニューと状況ページを画像に書き出して終わる
//   （-baseDir <取得の仕組みのフォルダ> -dataDir <データのフォルダ> を付けると、そのデータで書き出す）
// - 確認用: GitHubFetch --test-base で、フォルダを追いかける仕組みを一時フォルダで試して終わる（本物の設定は触らない）
// - 確認用: GitHubFetch --test-setup で、リポジトリを外す・保存・付け直すを一時フォルダで試して終わる（本物のデータは触らない）
// - 確認用: GitHubFetch --test-chart で、グラフのマウスの位置を聞く所を、日が無いグラフと日のあるグラフで試して終わる
// - 兄弟: Slack 取得（slack-fetch）。区切り（MARK）の順はそろえてある。片方を直したら、もう片方にも要るかを見る

import AppKit
import Charts
import ServiceManagement
import SwiftUI

// MARK: - 色（デジタル庁デザインシステムの値）

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
    static let ink = Color(hex: 0x1A1A1A)        // solid-gray-900
    static let ink2 = Color(hex: 0x4D4D4D)       // solid-gray-700
    static let ink3 = Color(hex: 0x767676)       // solid-gray-536
    static let line = Color(hex: 0xE6E6E6)       // solid-gray-100
    static let line2 = Color(hex: 0xCCCCCC)      // solid-gray-200
    static let surface2 = Color(hex: 0xF2F2F2)   // solid-gray-50
    static let key = Color(hex: 0x0031D8)        // blue-800
    static let keyHover = Color(hex: 0x0017C1)   // blue-900
    static let keyWash = Color(hex: 0xE8F1FE)    // blue-50
    static let bar = Color(hex: 0x3460FB)        // blue-600
    static let okInk = Color(hex: 0x197A4B)      // green-800
    static let okWash = Color(hex: 0xE6F5EC)     // green-50
    static let ngInk = Color(hex: 0xA90000)      // red-1000
    static let ngWash = Color(hex: 0xFDEEEE)     // red-50
    static let ngLine = Color(hex: 0xFFDADA)     // red-100
    static let warnIcon = Color(hex: 0xEBB700)   // yellow-500
    static let warnWash = Color(hex: 0xFBF5E0)   // yellow-50
    static let warnInk = Color(hex: 0x927200)    // yellow-900（注意の文字）
    // 入ったものの2色（下の段が PR 経由、上の段が直接）。見分けの検査（色覚の違い・白地とのコントラスト）を通した（2026-10-18）
    static let barPR = Color(hex: 0x0031D8)          // blue-800
    static let barDirect = Color(hex: 0x4979F5)      // blue-500
    static let barPRHover = Color(hex: 0x00118F)     // blue-1000（マウスを乗せた日）
    static let barDirectHover = Color(hex: 0x264AF4) // blue-700
}

// MARK: - 置き場所

/// 置き場所を覚えておく先。ふだんは Mac の設定、確かめ用のモードではメモリの中だけ（ファイルを作らない）
protocol KeyStore: AnyObject {
    func string(forKey: String) -> String?
    func data(forKey: String) -> Data?
    func set(_ value: Any?, forKey: String)
}
extension UserDefaults: KeyStore {}
final class MemoryStore: KeyStore {
    private var values: [String: Any] = [:]
    func string(forKey k: String) -> String? { values[k] as? String }
    func data(forKey k: String) -> Data? { values[k] as? Data }
    func set(_ value: Any?, forKey k: String) { values[k] = value }
}

enum Paths {
    static let required = ["github.py"]
    /// いま使っている場所（起動したとき・取得の前に resolve で決め直す）
    static var current: URL?
    /// 確かめ用のモードでは、本物の設定を触らないようメモリの中だけのものに差し替える
    static var defaults: KeyStore = UserDefaults.standard
    /// 組み立てたときの場所（build.sh が Info.plist に書く）
    static var builtDir: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "GitHubFetchBaseDir") as? String, !s.isEmpty else { return nil }
        return URL(fileURLWithPath: s)
    }
    /// 組み立てた場所（アプリ/build/GitHub取得.app）から3つ上
    static var nearApp: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// 取得の仕組みのフォルダ
    static var base: URL { current ?? builtDir ?? nearApp }
    /// そのフォルダに github.py があるか（無ければ、アラートか設定でフォルダを選んでもらう）
    static var baseIsReady: Bool { looksRight(base) }
    static var repos: URL { data.appendingPathComponent("リポジトリ.json") }
    /// はじめの準備で使う、見えるリポジトリの一覧とログインの確かめの結果（github.py setup が書く）
    static var candidates: URL { data.appendingPathComponent("リポジトリ候補.json") }
    /// 一覧から外したリポジトリ（呼び名・基準のブランチ・取り始める日を覚えておき、付け直したときに戻す。取ったデータは消さない）
    static var shelved: URL { data.appendingPathComponent("外したリポジトリ.json") }
    /// 既知の例外（GitHub 側の食い違いで直しようがないもの。照合で NG にせず、毎回「既知の例外」として出す）
    static var exceptions: URL { data.appendingPathComponent("例外.json") }

    static func looksRight(_ url: URL) -> Bool {
        if url.path.contains("/.Trash/") { return false }   // ゴミ箱に入ったものは使わない
        return required.allSatisfy { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    enum Outcome: Equatable {
        case same(URL), moved(from: String, to: URL), missing(last: String)
        var url: URL? {
            switch self {
            case .same(let u), .moved(_, let u): return u
            case .missing: return nil
            }
        }
    }

    /// フォルダを探す。データはフォルダの外にあるので、探すのは台本（github.py）の場所だけ。
    /// 1. 組み立て直した場所（前と違う場所で組み立て直したら、新しい版としてそちらを使う）
    /// 2. 覚えている場所の文字（古いフォルダの名前を変えて残し、新しい版を同じ場所に置いたときも、新しい版を使う）
    /// 3. 覚えておいたフォルダそのもの（ブックマーク。元の場所が空のときだけ。同じディスクの中なら、動かしても名前を変えても追いかける）
    /// 4. 組み立てたときの場所 5. アプリの置き場所から3つ上
    static func resolve(save: Bool = true, builtIn: Bool = true, built: URL? = builtDir) -> Outcome {
        let last = defaults.string(forKey: "baseDir")
        var found: URL?
        var rebuilt = false
        if builtIn, let u = built, looksRight(u), defaults.string(forKey: "builtDirSeen") != u.path {
            found = u
            rebuilt = true
        }
        if found == nil, let last, !last.isEmpty, looksRight(URL(fileURLWithPath: last)) { found = URL(fileURLWithPath: last) }
        if found == nil, let data = defaults.data(forKey: "baseBookmark") {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                relativeTo: nil, bookmarkDataIsStale: &stale), looksRight(u) {
                found = u
            }
        }
        if found == nil, builtIn, let u = built, looksRight(u) { found = u }
        if found == nil, builtIn, looksRight(nearApp) { found = nearApp }
        guard let u = found else { return .missing(last: last ?? built?.path ?? nearApp.path) }
        let changed = last.map { !$0.isEmpty && !samePath(URL(fileURLWithPath: $0), u) } ?? false
        if save {
            if builtIn, let b = built { defaults.set(b.path, forKey: "builtDirSeen") }
            remember(u)
        }
        // 組み立て直して新しい版に移ったときは知らせない（自分で組み立てたので）
        if changed, !rebuilt, let last { return .moved(from: last, to: u) }
        return .same(u)
    }

    /// 同じ場所か（日本語の名前は、濁点の持ち方〈NFC・NFD〉が違っても同じとみなす）
    static func samePath(_ a: URL, _ b: URL) -> Bool {
        let n = { (u: URL) in u.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping }
        return n(a) == n(b)
    }

    /// 場所を覚える（場所の文字と、フォルダそのもの〈ブックマーク〉の両方）
    static func remember(_ url: URL) {
        defaults.set(url.path, forKey: "baseDir")
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: "baseBookmark")
        }
    }

    /// 選ばれたフォルダの中から探す（1つ上のフォルダを選んだときなど。3段下まで）
    static func findInside(_ url: URL) -> URL? {
        if looksRight(url) { return url }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let u as URL in e {
            if e.level > 3 { e.skipDescendants(); continue }
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, looksRight(u) { return u }
        }
        return nil
    }

    /// 確認用の画像で、この場所をホーム（~）として出す（一時フォルダの長い名前を、手順書などの画像に出さないため）
    static var displayHome: String?
    /// 確認用の画像で、作り物のフォルダを、本物の置き場所の名前で出す（[(本当の場所, 出す名前)]。作業用の長い名前を写さない）
    static var displayAliases: [(String, String)] = []
    static func short(_ p: String) -> String {
        for (real, shown) in displayAliases where p == real || p.hasPrefix(real + "/") { return shown + p.dropFirst(real.count) }
        if let h = displayHome, p == h || p.hasPrefix(h + "/") { return "~" + p.dropFirst(h.count) }
        return (p as NSString).abbreviatingWithTildeInPath
    }

    /// 取ったもの・設定・状態の置き場所。取得の仕組みのフォルダの外（入れ替えても消えず、公開リポジトリにも入らない）。
    /// 決まりは github.py と同じ: GITHUB_FETCH_DATA があればそこ、無ければホームの直下の GitHub取得データ
    static let dataFolderName = "GitHub取得データ"
    /// 確かめ用（自己試験と、確認用の画像の -dataDir）。本物の設定とデータに触らないため
    static var dataOverride: URL?
    private static let argumentDataDir = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["dataDir"] as? String
    static var data: URL {
        if let dataOverride { return dataOverride }
        for s in [argumentDataDir, ProcessInfo.processInfo.environment["GITHUB_FETCH_DATA"]] {
            if let s, !s.isEmpty { return URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(dataFolderName)
    }
    static var state: URL { data.appendingPathComponent("状態.json") }
    static var history: URL { data.appendingPathComponent("取得の記録.jsonl") }
    static var script: URL { base.appendingPathComponent("github.py") }
    static var lock: URL { data.appendingPathComponent(".取得中") }
    static var logs: URL { data.appendingPathComponent("取得ログ") }   // 中は月ごとのフォルダ
}

// MARK: - データ（状態.json・取得の記録.jsonl。形は 設計書.md の 3.4・3.5）

/// 最後の取得（共通の部分は Slack 取得と同じ名前。calls 以下は GitHub だけ）
struct RunInfo: Codable {
    var start: String?
    var end: String?
    var result: String?
    var note: String?
    var new: Int?
    var since: String?
    var sleep: SleepInfo?
    var delayed_from: String?   // 予定の時刻（9:00 など）に Mac がスリープしていたので、起きてから始めた
    var sleep_missed: Bool?     // 途中で Mac が眠っていて、うまく終わらなかった（もう一度取るよう促す）
    var calls: Int?             // 回数を使った問い合わせ
    var calls_free: Int?        // 回数を使わなかった問い合わせ（変わっていない 304）
    var calls_cap: Int?         // 1回の上限
    var rate: RateInfo?
    var wait_until: String?     // 回数の上限で待っているとき、戻る時刻
    var progress: ProgressInfo?
    var repos_failed: [String]?
    var first_partial: Bool?    // 最初の取得（または古い分を足している途中）で上限に届いた（黄の「最初の取得の途中です」）
}

/// 取得の途中で Mac が眠っていた間（Slack 取得と同じ形）
struct SleepInfo: Codable {
    var count: Int
    var seconds: Int
    var spans: [[String]]?   // [[眠った, 起きた]]（ISO の時刻）
}

/// GitHub の1時間の枠（最後の問い合わせの時点）
struct RateInfo: Codable {
    var limit: Int?
    var remaining: Int?
    var reset: String?
}

/// 取得中: 何個目のリポジトリを取っているか
struct ProgressInfo: Codable {
    var done: Int?
    var total: Int?
    var tag: String?
}

/// ログイン（gh にログインしているアカウント）
struct AuthInfo: Codable {
    var login: String?
    var ok: Bool?
    var checked: String?
}

/// 最後のリリース（版の名札）と、そのあとに入った数
struct ReleaseInfo: Codable {
    var tag: String
    var date: String?
    var after: Int?
}

/// 確認環境・本番のブランチ（設定したとき）。behind は、基準のブランチにあってそこに無い数
struct StageInfo: Codable, Identifiable {
    var name: String
    var branch: String
    var behind: Int?
    var updated: String?
    var id: String { name }
}

/// 1日に入った数（PR 経由・直接）
struct DayLanded: Codable, Identifiable {
    var date: String
    var pr: Int
    var direct: Int
    var id: String { date }
    var total: Int { pr + direct }
}

/// 14日以内に動いた PR・issue（題名は他人が書いた文字列。1行に畳んで出す）
struct ActiveItem: Codable, Identifiable {
    var kind: String     // "pr" か "issue"
    var number: Int
    var title: String
    var updated: String?
    var flags: [String]?
    var id: String { kind + "\(number)" }
}

/// 14日以内に動いた PR の印の数
struct PRFlags: Codable {
    var draft: Int?
    var changes_requested: Int?
    var approved: Int?
    var ci_failed: Int?
}

/// 取り始めた日からの数
struct RepoCounts: Codable {
    var prs: Int?
    var issues: Int?
    var comments: Int?
    var reviews: Int?
}

/// リポジトリ1つ（Slack 取得の ChannelInfo に当たる）
struct RepoInfo: Codable, Identifiable {
    var id: Int
    var tag: String
    var name: String
    var base: String
    var visibility: String?
    var archived: Bool?
    var from: String?
    var fetched: String?
    var error: String?
    var error_kind: String?
    var total: Int
    var total_pr: Int?
    var delta: Int?
    var last7: Int?
    var last7_pr: Int?
    var prev7: Int?
    var week: [DayLanded]?
    var last_landed: String?
    var release: ReleaseInfo?
    var stages: [StageInfo]?
    var open_prs: Int?
    var open_prs_active: Int?
    var open_issues: Int?
    var open_issues_active: Int?
    var pr_flags: PRFlags?
    var active: [ActiveItem]?
    var counts: RepoCounts?
    var complete: Bool?         // 一度でも最後まで読み切ったか（無ければ読み切った扱い。前の版の状態.json）
    var pending: String?        // 読み切っていない理由（「最初の取得の途中（PR 1,061 / 1,527 件まで）」など）

    /// 取れなかった（この回の取得で）
    var failed: Bool { error != nil }
    /// まだ最後まで取れていない（最初の取得の途中・古い分を足している途中）。画面で「取れています」と出さない
    var incomplete: Bool { complete == false }
    /// この14日に動いた（入った・PR や issue が動いた）か。動いていなければ、状況ページでは表にまとめる
    func moved(now: Date) -> Bool {
        if (open_prs_active ?? 0) > 0 || (open_issues_active ?? 0) > 0 { return true }
        guard let d = Fmt.parseISO(last_landed) else { return false }
        return now.timeIntervalSince(d) < 14 * 86400
    }
}

struct CheckItem: Codable, Identifiable {
    var name: String
    var ok: Bool
    var detail: String
    var state: String?          // ok・ng・unverified（確かめていない。このとき ok は偽）。前の版の状態.json には無い
    var id: String { name }
    var unverified: Bool { state == "unverified" }
}

/// 確かめていないリポジトリと理由（最初の取得の途中・今回は途中で止まった・取れなかった など。設計書 5 章）
struct UnverifiedRepo: Codable, Hashable {
    var repo: String
    var reason: String
}

struct CheckInfo: Codable {
    var ng: [String]
    var notes: [String]?
    var exceptions: [String]?
    var items: [CheckItem]?
    var unverified: [UnverifiedRepo]?
    var checked_at: String?     // 照合の材料を取った回の時刻（数え直しのとき、いつの取得で確かめたか）
}

/// 日ごとに入った数（呼び名ごと）。pr はそのうち PR 経由の数（直接は counts − pr）
struct DailyEntry: Codable, Identifiable {
    var date: String
    var counts: [String: Int]
    var pr: [String: Int]?
    var id: String { date }
    var total: Int { counts.values.reduce(0, +) }
    var prTotal: Int { pr?.values.reduce(0, +) ?? 0 }
    var directTotal: Int { total - prTotal }
}

struct StateFile: Codable {
    var source: String?
    var updated: String?
    var state: String?
    var run: RunInfo?
    var repos: [RepoInfo]?
    var check: CheckInfo?
    var last_success: String?
    var last_read: String?      // 最後まで読み切った回（ok・ng・partial）の時刻。「古い」はこれで見る
    var daily: [DailyEntry]?
    var auth: AuthInfo?
}

struct HistoryEntry: Codable, Identifiable {
    var start: String?
    var end: String?
    var result: String?
    var note: String?
    var new: Int?
    var ng: Int?
    var sleep: SleepInfo?
    var delayed_from: String?
    var sleep_missed: Bool?
    var calls: Int?
    var calls_free: Int?
    var failed: [String]?
    var id: String { (start ?? "") + "|" + (end ?? "") }
}

// MARK: - 日付の書き方

enum Fmt {
    static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func parseISO(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }
    static func parseJST(_ s: String) -> Date? {  // "2026-10-08 16:12:34"（日本時間）
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)
    }
    static func string(_ d: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = format
        return f.string(from: d)
    }
    /// 「今日 9:00」「昨日 23:11」「10/6（火）9:00」
    static func relative(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "—" }
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "今日 " + string(d, "H:mm") }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) {
            return "昨日 " + string(d, "H:mm")
        }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) {
            return "明日 " + string(d, "M/d（E）H:mm")
        }
        return string(d, "M/d（E）H:mm")
    }
    /// 日だけ（「今日」「昨日」「10/6」「2025/8/9」）。古いものの「最後に入った」に使う
    static func relativeDay(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "—" }
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "今日" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "昨日" }
        return cal.isDate(d, equalTo: now, toGranularity: .year) ? string(d, "M/d") : string(d, "yyyy/M/d")
    }
    static func number(_ n: Int) -> String { n.formatted(.number.grouping(.automatic)) }
}

// MARK: - 状態と操作

/// 画面に出す状態。fresh: まだ一度も取っていない。login・waiting・partial は GitHub だけ（設計書.md の 6・7.2）
enum DisplayState { case ok, running, ng, failed, filling, stale, fresh, login, waiting, partial }

@MainActor
final class Store: ObservableObject {
    @Published var file = StateFile()
    @Published var history: [HistoryEntry] = []
    @Published var running = false
    @Published var now = Date()
    @Published var message: String?
    @Published var autoEnabled: Bool { didSet { UserDefaults.standard.set(autoEnabled, forKey: "autoEnabled") } }
    @Published var hour: Int { didSet { UserDefaults.standard.set(hour, forKey: "hour") } }
    @Published var minute: Int { didSet { UserDefaults.standard.set(minute, forKey: "minute") } }
    /// 1回の取得で使ってよい回数（0 は上限なし。台本に CALL_CAP として渡す）
    @Published var callCap: Int { didSet { UserDefaults.standard.set(callCap, forKey: "callCap") } }
    @Published var notify: Bool { didSet { UserDefaults.standard.set(notify, forKey: "notify") } }
    @Published var loginItem = false
    @Published var showInDock: Bool {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "showInDock")
            AppDelegate.shared?.applyDockSetting()
        }
    }

    @Published var showSettings = false
    @Published var configured = false   // GitHub取得データ/リポジトリ.json に取るリポジトリがあるか（はじめの準備が済んだか）
    let setup = Setup()
    /// 状況ページの数え直し（github.py status refresh）をしている間
    @Published var refreshing = false
    @Published var baseMissing = false
    @Published var basePath = ""
    private var lastMissingAlert: String?
    var forced: DisplayState?   // 確認用の画像を作るときだけ使う
    var previewTip: String?
    var previewBar: String?
    var previewExpanded = false
    var previewWeekBar: String?
    private var process: Process?
    private var refreshProcess: Process?
    private var refreshAgain = false   // 数え直しの途中で、もう一度保存された
    private var timer: Timer?
    /// 回数の上限で待っていて、続きを動かした「戻る時刻」（同じ待ちで二度動かさない）
    private var resumedWait: String?

    // ---- Mac のスリープ（Slack 取得と同じ。2026-10-13） ----
    // 眠っている Mac は、点検のために数十秒だけ起きる（DarkWake）ことがあり、このアプリの時計もそのとき動く。
    // それでも取得は始める（本人の希望）。眠っている中で始めたことは記録に残し、取れなかったら知らせて、もう一度取るよう促す
    /// 眠りに入った時刻（本当に起きたら nil）
    private var asleepSince: Date?
    /// いちばん新しく眠っていた間（予定の時刻に眠っていたかを見る）
    private var lastSleep: DateInterval?
    /// 本当に起きた時刻（起きてすぐは通信がつながっていないことがあるので、20秒待ってから取る）
    private var wokeAt: Date?
    /// いまの取得の途中で眠っていた間（取得中の表示に使う。終わったあとは github.py が 状態.json に書いたものを出す）
    @Published var runSleeps: [DateInterval] = []
    /// いまの取得は、予定の時刻に眠っていたので起きてから始めたもの（予定の時刻）
    @Published var runDelayedFrom: String?

    init(live: Bool = true) {
        let d = UserDefaults.standard
        autoEnabled = d.object(forKey: "autoEnabled") as? Bool ?? true
        hour = d.object(forKey: "hour") as? Int ?? 9
        minute = d.object(forKey: "minute") as? Int ?? 0
        callCap = d.object(forKey: "callCap") as? Int ?? 1500
        notify = d.object(forKey: "notify") as? Bool ?? true
        showInDock = d.object(forKey: "showInDock") as? Bool ?? true
        loginItem = SMAppService.mainApp.status == .enabled
        if live {
            checkBase()
        } else if let s = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["baseDir"] as? String,
                  !s.isEmpty {
            Paths.current = URL(fileURLWithPath: s)   // 確認用の画像: -baseDir で渡されたフォルダで書き出す
        } else {
            Paths.current = Paths.resolve(save: false).url
        }
        basePath = Paths.base.path
        load()
        guard live else { return }
        // リポジトリを足した・外したら、次の取得を待たずに状況ページを数え直す
        setup.onSaved = { [weak self] in self?.refreshStatus() }
        if !baseMissing && !configured { setup.open() }   // 取るリポジトリが無いときは、はじめの準備から
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // 起動したとき・Mac が起きたときにも確かめる（9時に寝ていた日も、起きたら取る）
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.tick() }
        let nc = NSWorkspace.shared.notificationCenter
        // 知らせは main の上で届くので、その場で（眠りに入る前に）書き留める
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000_000)  // 起きてすぐは通信がつながっていないことがある
                self?.tick()
            }
        }
        // 念のため: 画面が点いたなら、Mac は起きている（起きた知らせを取りこぼしても、取得が止まったままにならないように）
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
    }

    private func willSleep() {
        asleepSince = Date()
        if process?.isRunning == true {
            Store.appLogLine("Mac がスリープに入りました。スリープの間、取得は止まります")
        }
    }

    private func didWake() {
        guard let since = asleepSince else { return }
        let woke = Date()
        asleepSince = nil
        lastSleep = DateInterval(start: since, end: max(since, woke))
        wokeAt = woke
        if running {
            runSleeps.append(DateInterval(start: since, end: max(since, woke)))
        }
        if process?.isRunning == true {
            Store.appLogLine("Mac がスリープから戻りました。取得の続きを動かします")
        }
    }

    func tick() {
        now = Date()
        if baseMissing || !Paths.looksRight(Paths.base) { checkBase() }
        load()
        checkSchedule()
        checkWait()
    }

    static let noPermissionMessage = "取得の仕組みのフォルダを読む許可がありません。システム設定 → プライバシーとセキュリティ → "
        + "ファイルとフォルダ で「GitHub 取得」をオンにしてください。"
    static let noScriptMessage = "取得の仕組みのフォルダに github.py が見つかりません。設定（歯車）でフォルダを選んでください。"
    /// まだ一度も取っていないときの案内（はじめの準備が済んだかで変わる）
    var freshText: String {
        configured
            ? "準備ができました。「今すぐ取る」を押すと、取り始める日からの分をまとめて取ります（多いときは何回かに分けて）"
            : "はじめの準備（GitHub にログイン・取るリポジトリを選ぶ）をしてください。終わったら、取り始める日からの分をまとめて取ります"
    }

    func load() {
        do {
            let data = try Data(contentsOf: Paths.state)
            if let f = try? JSONDecoder().decode(StateFile.self, from: data) { file = f }
            if message == Store.noPermissionMessage { message = nil }
        } catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoPermissionError {
            message = Store.noPermissionMessage
        } catch {
            file = StateFile()  // まだ一度も取っていない（または、フォルダを選び直した）
        }
        if let text = try? String(contentsOf: Paths.history, encoding: .utf8) {
            history = text.split(separator: "\n")
                .compactMap { try? JSONDecoder().decode(HistoryEntry.self, from: Data($0.utf8)) }
                .reversed()
        } else {
            history = []
        }
        running = (process?.isRunning ?? false) || lockIsAlive()
        configured = !Setup.savedRepos().isEmpty
        if !running && forced == nil {
            // 取得が終わったら、眠っていた間は github.py が 状態.json に書いたもの（file.run.sleep）を出す
            if !runSleeps.isEmpty { runSleeps = [] }
            if runDelayedFrom != nil { runDelayedFrom = nil }
        }
    }

    // ---- 取得の仕組みのフォルダ ----

    enum BaseAlert { case moved(from: String, to: String), missing(last: String) }

    /// フォルダを確かめる。動いていたら追いかけて知らせ、見つからなければアラートで選び直してもらう
    func checkBase() {
        switch Paths.resolve() {
        case .same(let u):
            Paths.current = u
            baseMissing = false
        case .moved(let from, let to):
            Paths.current = to
            baseMissing = false
            present(.moved(from: from, to: to.path))
        case .missing(let last):
            baseMissing = true
            message = Store.noScriptMessage
            if lastMissingAlert != last {
                lastMissingAlert = last
                present(.missing(last: last))
            }
        }
        if !baseMissing {
            lastMissingAlert = nil
            if message == Store.noScriptMessage { message = nil }
        }
        basePath = Paths.base.path
    }

    private func present(_ a: BaseAlert) {
        // 起動の途中でも出せるよう、少し待ってから出す
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.runAlert(a) }
    }

    private func runAlert(_ a: BaseAlert) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        switch a {
        case .moved(let from, let to):
            alert.messageText = "取得の仕組みのフォルダが移動していました"
            alert.informativeText = "新しい場所に切り替えました。\n前: \(Paths.short(from))\n今: \(Paths.short(to))"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .missing(let last):
            alert.alertStyle = .warning
            alert.messageText = "取得の仕組みのフォルダが見つかりません"
            alert.informativeText = "github.py があるフォルダが、前の場所にありません。\n前の場所: \(Paths.short(last))\n\n"
                + "フォルダを動かした場合は「場所を選ぶ」で選び直してください。見つかるまで、取得はしません。"
            alert.addButton(withTitle: "場所を選ぶ")
            alert.addButton(withTitle: "あとで")
            if alert.runModal() == .alertFirstButtonReturn { chooseBase() }
        }
    }

    /// 取得の仕組みのフォルダを選び直す（設定の「変更…」と、見つからないときのアラートから）
    func chooseBase() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Paths.baseIsReady ? Paths.base : FileManager.default.homeDirectoryForCurrentUser
        panel.message = "github.py のあるフォルダを選んでください（1つ上のフォルダを選んでもかまいません）"
        panel.prompt = "このフォルダにする"
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        guard let u = Paths.findInside(picked) else {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "このフォルダではありません"
            a.informativeText = "選んだフォルダ（\(Paths.short(picked.path))）の中に、github.py が見つかりませんでした。"
            a.addButton(withTitle: "もう一度選ぶ")
            a.addButton(withTitle: "あとで")
            if a.runModal() == .alertFirstButtonReturn { chooseBase() }
            return
        }
        Paths.remember(u)
        Paths.current = u
        baseMissing = false
        lastMissingAlert = nil
        if message == Store.noScriptMessage { message = nil }
        basePath = u.path
        load()
    }

    private func lockIsAlive() -> Bool {
        guard let s = try? String(contentsOf: Paths.lock.appendingPathComponent("pid"), encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0
    }

    // ---- 表示に使う値 ----

    var lastSuccess: Date? { Fmt.parseISO(file.last_success) }
    /// 最後まで読み切った回の時刻（無ければ最後にうまく取れた時刻）。「古い」はこれで見る（設計書 6 章。
    /// 1 つのリポジトリが取れないだけ・NG を例外に入れただけで「古い」にしない）
    var lastRead: Date? { Fmt.parseISO(file.last_read) ?? lastSuccess }
    var lastRunEnd: Date? { Fmt.parseISO(file.run?.end) }
    var lastRunStart: Date? { Fmt.parseISO(file.run?.start) ?? history.first.flatMap { Fmt.parseISO($0.start) } }

    var display: DisplayState {
        if let forced { return forced }
        if running { return .running }
        if file.state == nil && file.run == nil && history.isEmpty { return .fresh }
        switch file.state {
        case "ng": return .ng
        case "stopped" where file.run?.first_partial == true: return .filling   // 最初の取得の途中（黄。大きいリポジトリのふつうの流れ）
        case "error", "stopped": return .failed
        case "login": return .login
        case "waiting": return .waiting
        default: break
        }
        if autoEnabled, let ls = lastRead, now.timeIntervalSince(ls) > 26 * 3600 { return .stale }
        if file.state == "partial" { return .partial }
        return .ok
    }

    var timeText: String { String(format: "%d:%02d", hour, minute) }
    var staleDays: Int { max(1, Int(now.timeIntervalSince(lastRead ?? now) / 86400)) }
    /// 「前回の取得から入った」の前回（いま出している数は、この取得からのもの）
    var prevRunEnd: Date? {
        Fmt.parseISO(file.run?.since) ?? (history.count >= 2 ? Fmt.parseISO(history[1].end) : nil)
    }
    var monthRuns: [HistoryEntry] {
        history.filter { e in
            guard let d = Fmt.parseISO(e.start) else { return false }
            return Calendar.current.isDate(d, equalTo: now, toGranularity: .month)
        }
    }
    var last30Runs: [HistoryEntry] {
        history.filter { e in (Fmt.parseISO(e.start) ?? .distantPast) >= now.addingTimeInterval(-30 * 86400) }
    }
    var todaySchedule: Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
    }
    var nextRunText: String {
        if !configured || history.isEmpty { return "最初の取得のあとから" }   // checkSchedule と同じ決まり
        let t = todaySchedule
        if now < t { return Fmt.relative(t, now: now) }
        if let s = lastRunStart, s >= t {
            return Fmt.relative(Calendar.current.date(byAdding: .day, value: 1, to: t), now: now)
        }
        return "このあとすぐ"
    }
    var repos: [RepoInfo] { file.repos ?? [] }
    var totalLanded: Int { repos.reduce(0) { $0 + $1.total } }
    var totalLandedPR: Int { repos.reduce(0) { $0 + ($1.total_pr ?? 0) } }
    var last7: Int { repos.reduce(0) { $0 + ($1.last7 ?? 0) } }
    var last7PR: Int { repos.reduce(0) { $0 + ($1.last7_pr ?? 0) } }
    var openPRs: Int { repos.reduce(0) { $0 + ($1.open_prs ?? 0) } }
    var openPRsActive: Int { repos.reduce(0) { $0 + ($1.open_prs_active ?? 0) } }
    var openIssues: Int { repos.reduce(0) { $0 + ($1.open_issues ?? 0) } }
    var openIssuesActive: Int { repos.reduce(0) { $0 + ($1.open_issues_active ?? 0) } }
    var newSinceLast: Int { file.run?.new ?? 0 }
    var ngLines: [String] { file.check?.ng ?? [] }
    var exceptionLines: [String] { file.check?.exceptions ?? [] }
    var failedRepos: [RepoInfo] { repos.filter(\.failed) }
    var monthCalls: Int { monthRuns.reduce(0) { $0 + ($1.calls ?? 0) } }
    var callCapText: String { callCap == 0 ? "上限なし" : "\(Fmt.number(callCap)) 回" }
    /// 回数の上限で待っているとき、戻る時刻
    var waitUntil: Date? { Fmt.parseISO(file.run?.wait_until) }
    /// 照合で確かめていないリポジトリ（最初の取得の途中・今回は途中で止まった など）。あれば照合のタイルを緑にしない
    var unverified: [UnverifiedRepo] { file.check?.unverified ?? [] }
    /// まだ最後まで取れていないリポジトリの説明（「whisper.cpp（最初の取得の途中（PR 1,061 / 1,527 件まで））」）
    var pendingText: String {
        let p = repos.filter(\.incomplete).map { r in r.tag + (r.pending.map { ": \($0)" } ?? "") }
        return p.isEmpty ? "" : p.prefix(3).joined(separator: "／") + (p.count > 3 ? "／ほか \(p.count - 3)" : "")
    }

    /// NG の行を読みやすくする（github.py が呼び名で書くので、頭の「NG 」を外すだけ）
    func readable(_ line: String) -> String {
        if line.hasPrefix("NG: ") { return String(line.dropFirst(4)) }   // 前の版の状態.json
        return line.hasPrefix("NG ") ? String(line.dropFirst(3)) : line
    }

    // ---- Mac のスリープ（表示の言葉。Slack 取得と同じ） ----

    /// 「39分」「13時間7分」「1分未満」
    static func spanText(_ seconds: Int) -> String {
        let m = seconds / 60
        if m < 1 { return "1分未満" }
        return m >= 60 ? "\(m / 60)時間\(m % 60)分" : "\(m)分"
    }

    /// 「9:01〜9:40」（日をまたぐときは終わりに日付も）
    static func rangeText(_ a: Date, _ b: Date) -> String {
        let end = Calendar.current.isDate(a, inSameDayAs: b) ? Fmt.string(b, "H:mm") : Fmt.string(b, "M/d H:mm")
        return "\(Fmt.string(a, "H:mm"))〜\(end)"
    }

    /// 眠っていた間。1回なら「9:01〜9:40・39分」、2回以上なら「2回・合わせて 52分」
    static func sleepWhen(_ s: SleepInfo) -> String {
        if s.count == 1, let p = s.spans?.first, p.count == 2, let a = Fmt.parseISO(p[0]), let b = Fmt.parseISO(p[1]) {
            return "\(rangeText(a, b))・\(spanText(s.seconds))"
        }
        return "\(s.count)回・合わせて \(spanText(s.seconds))"
    }

    /// 眠っていた間を短く。1回なら「9:02〜12:05」、2回以上なら「2回・合わせて 52分」
    static func sleepRange(_ s: SleepInfo) -> String {
        if s.count == 1, let p = s.spans?.first, p.count == 2, let a = Fmt.parseISO(p[0]), let b = Fmt.parseISO(p[1]) {
            return rangeText(a, b)
        }
        return "\(s.count)回・合わせて \(spanText(s.seconds))"
    }

    /// スリープで取れなかった（途中で眠っていて、うまく終わらなかった）。黄色で出し、もう一度取るよう促す
    var sleepMissed: Bool {
        (display == .ng || display == .failed || display == .partial) && file.run?.sleep_missed == true && file.run?.sleep != nil
    }

    /// スリープで取れなかったときの説明（小窓のカードと、状況ページの見出しの下）
    var sleepMissedText: String? {
        guard sleepMissed, let s = file.run?.sleep else { return nil }
        return "\(Fmt.relative(Fmt.parseISO(file.run?.start), now: now)) に始めた取得の途中で Mac がスリープしていて"
            + "（\(Store.sleepRange(s))）、取れなかった分があります。Mac が起きているときに、もう一度取ってください"
    }

    /// 予定の時刻に眠っていたので、起きてから取った（小窓・状況ページの1行）
    var delayedText: String? {
        guard let d = file.run?.delayed_from else { return nil }
        let start = Fmt.parseISO(file.run?.start).map { Fmt.string($0, "H:mm") } ?? "あと"
        return "予定の \(d) は Mac がスリープしていたので、起きた \(start) に取りました"
    }

    /// 取得中に、アプリが見ていた眠り（取得中の小窓・状況ページ）
    var runningSleepText: String? {
        if let last = runSleeps.last {
            let r = Store.rangeText(last.start, last.end)
            return runSleeps.count == 1
                ? "\(r) は Mac がスリープしていて、取得が止まっていました。いま続きを取っています"
                : "途中で Mac が \(runSleeps.count)回スリープしていて、取得が止まっていました（最後は \(r)）。いま続きを取っています"
        }
        if let d = runDelayedFrom {
            return "予定の \(d) は Mac がスリープしていたので、起きてから取っています"
        }
        return nil
    }

    /// 小窓の状態のカードに出す行（取得中は取得中の眠り、終わったあとは最後の取得の眠りと遅れ）
    var sleepNotes: [String] {
        if display == .running { return runningSleepText.map { [$0] } ?? [] }
        if sleepMissed { return delayedText.map { [$0] } ?? [] }   // 眠りのことは、カードそのものに書いてある
        var out: [String] = []
        if let s = file.run?.sleep {
            out.append("取得の途中で Mac がスリープしていました（\(Store.sleepWhen(s))）。"
                       + (display == .ok ? "その間は止まっていましたが、全部取れています" : "その間は取得が止まっていました"))
        }
        if let d = delayedText { out.append(d) }
        return out
    }

    /// 状況ページの見出しの下に出す行
    var sleepNotesPage: [String] {
        if display == .running { return runningSleepText.map { [$0] } ?? [] }
        if sleepMissed { return delayedText.map { [$0] } ?? [] }   // 眠りのことは、見出しの下の知らせに書いてある
        var out: [String] = []
        if let s = file.run?.sleep {
            let start = Fmt.parseISO(file.run?.start)
            let day = start.map { d -> String in
                let cal = Calendar.current
                if cal.isDate(d, inSameDayAs: now) { return "今日" }
                if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "昨日" }
                return Fmt.string(d, "M/d（E）")
            } ?? "前回"
            var t = "\(day)の取得の途中で Mac がスリープしていました（\(Store.sleepWhen(s))）。スリープの間は取得が止まっていました"
            if display == .ok { t += "が、抜けはありません" }
            out.append(t)
        }
        if let d = delayedText { out.append(d) }
        return out
    }

    /// 取得の記録の「メモ」（前からのメモに、眠っていたことを足す）
    static func historyMemo(_ e: HistoryEntry) -> String {
        var parts: [String] = []
        let missed = e.sleep_missed == true
        if missed, let s = e.sleep { parts.append("スリープで取れなかった分あり（\(sleepWhen(s))）") }   // いちばん大事なので先に
        if let n = e.note, !n.isEmpty { parts.append(n) }
        if let d = e.delayed_from { parts.append("予定の \(d) は Mac がスリープ中。起きてから取った") }
        if !missed, let s = e.sleep { parts.append("途中で Mac がスリープ（\(sleepWhen(s))）") }
        return parts.joined(separator: "／")
    }

    // ---- 毎朝の自動実行 ----

    func checkSchedule() {
        // はじめの準備が済み、最初の取得を自分で始めてから動く。準備の窓を開いている間も待つ（リポジトリを選び直している途中に始めない）
        guard autoEnabled, !running, !baseMissing, forced == nil, configured, !history.isEmpty, !setup.show else { return }
        let t = todaySchedule
        guard now >= t else { return }
        if let s = lastRunStart, s >= t { return }
        if let w = wokeAt, now.timeIntervalSince(w) < 20 { return }   // 起きてすぐは通信がつながっていないことがある
        let asleep = asleepSince != nil
        let slept = !asleep && (lastSleep.map { $0.start <= t && t <= $0.end } ?? false)
        runNow(delayedFrom: slept ? timeText : nil, asleep: asleep)
    }

    /// GitHub の回数の上限で待っているとき、戻る時刻を過ぎたら続きを取る（30秒ゆとりを見る）
    func checkWait() {
        guard file.state == "waiting", !running, !baseMissing, forced == nil, configured,
              let raw = file.run?.wait_until, let w = Fmt.parseISO(raw), now >= w.addingTimeInterval(30),
              resumedWait != raw else { return }
        resumedWait = raw
        Store.appLogLine("GitHub の回数が戻る時刻（\(Fmt.string(w, "H:mm"))）を過ぎたので、続きを取ります")
        runNow()
    }

    // ---- 操作 ----

    /// 台本（github.py）に渡す環境。gh は入れ方によって置き場所が違う（Homebrew は /opt/homebrew/bin か /usr/local/bin）
    static func scriptEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["GITHUB_FETCH_DATA"] = Paths.data.path   // 台本にも、アプリと同じデータの場所を使わせる
        env["PYTHONDONTWRITEBYTECODE"] = "1"         // 取得の仕組みのフォルダに __pycache__ を作らない
        return env
    }

    /// 台本の出力を書き足す 取得ログ/アプリから動かした記録.log（見出しを1行書いてから渡す）。
    /// 「必ず後ろに足す」形（O_APPEND）で開く。2つが同時に書いても、相手を上書きしない（Slack 取得で 2026-10-09 に起きた）
    static func appLog(_ title: String) -> FileHandle? {
        guard let h = openAppLog() else { return nil }
        h.write(Data("\n==== \(Fmt.string(Date(), "yyyy-MM-dd HH:mm:ss")) に開始（\(title)） ====\n".utf8))
        return h
    }

    /// アプリから動かした記録.log に、見出しを付けずに1行足す（取得の途中のスリープ・待ち明けなど）
    static func appLogLine(_ text: String) {
        openAppLog()?.write(Data("（\(Fmt.string(Date(), "yyyy-MM-dd HH:mm:ss"))）\(text)\n".utf8))
    }

    private static func openAppLog() -> FileHandle? {
        let logURL = Paths.logs.appendingPathComponent("アプリから動かした記録.log")
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        let fd = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// delayedFrom: 予定の時刻（9:00 など）に Mac が眠っていたので、起きてから始めるとき（台本に SLEEP_DELAYED として渡す）
    /// asleep: Mac が眠っている中（点検のために一瞬起きたところ）で始めるとき（記録に1行残す）
    func runNow(delayedFrom: String? = nil, asleep: Bool = false) {
        guard !running else { return }
        checkBase()
        guard !baseMissing else {
            message = Store.noScriptMessage
            return
        }
        configured = !Setup.savedRepos().isEmpty   // はじめの準備で保存した直後でも、ここで読み直す
        guard configured else {   // 取るリポジトリが無ければ、はじめの準備を開く
            AppDelegate.shared?.openSetup()
            return
        }
        // 状況ページの数え直しの途中なら止める。取得の終わりに必ず数え直すので要らない
        if let r = refreshProcess, r.isRunning {
            refreshAgain = false
            r.terminate()
        }
        try? FileManager.default.removeItem(at: Paths.lock.appendingPathComponent("stop"))   // 前に押した「止める」の印を残さない
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-i", "/usr/bin/python3", Paths.script.path, "fetch"]
        p.currentDirectoryURL = Paths.base
        var env = Store.scriptEnvironment()
        env["CALL_CAP"] = String(callCap)
        env["NOTIFY"] = notify ? "1" : "0"
        if let d = delayedFrom { env["SLEEP_DELAYED"] = d }
        p.environment = env
        runSleeps = []
        runDelayedFrom = delayedFrom
        if asleep {
            Store.appLogLine("Mac がスリープ中（点検のために一瞬起きたところ）ですが、予定の \(timeText) の取得を始めます。眠っている間は止まります")
        }
        if let h = Store.appLog("取得") {
            p.standardOutput = h
            p.standardError = h
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.process = nil
                self?.load()
            }
        }
        do {
            try p.run()
            process = p
            running = true
            message = nil
        } catch {
            message = "取得を動かせませんでした: \(error.localizedDescription)"
        }
    }

    /// 状況ページの数字を数え直す（github.py status refresh。GitHub には問い合わせない・取得の記録は増えない）。
    /// 数えるのは一覧（リポジトリ.json）にあるリポジトリだけ。取得中は数え直さない
    func refreshStatus() {
        guard !running, !baseMissing else { return }
        if refreshProcess != nil {   // 数え直しの途中なら、終わってからもう一度
            refreshAgain = true
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [Paths.script.path, "status", "refresh"]
        p.currentDirectoryURL = Paths.base
        p.environment = Store.scriptEnvironment()
        if let h = Store.appLog("状況の数え直し") {
            p.standardOutput = h
            p.standardError = h
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshProcess = nil
                self.refreshing = false
                self.load()
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.refreshStatus()
                }
            }
        }
        do {
            try p.run()
            refreshProcess = p
            refreshing = true
        } catch {
            message = "状況ページを数え直せませんでした: \(error.localizedDescription)"
        }
    }

    /// 止める: 台本は問い合わせの合間に「止める」の印を見て、しおりを書いてから終わる（次は続きから取れる）。
    /// 20秒たっても終わらなければ、台本を止める
    func stop() {
        try? FileManager.default.createDirectory(at: Paths.lock, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Paths.lock.appendingPathComponent("stop").path, contents: nil)
        Store.appLogLine("「止める」が押されました。問い合わせの合間で止めます")
        let script = Paths.script.path
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.running else { return }
            let k = Process()
            k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            k.arguments = ["-TERM", "-f", script + " fetch"]
            try? k.run()
        }
    }

    /// GitHub にログインする（ターミナルの窓を開いて、gh auth login を始める。本人は画面の案内どおりに進めるだけ）
    func openLoginTerminal() {
        let cmd = FileManager.default.temporaryDirectory.appendingPathComponent("GitHub取得_ログイン.command")
        let text = """
            #!/bin/zsh
            export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
            echo "GitHub にログインします（gh auth login）。"
            echo "ブラウザが開いたら、この窓に出る8文字のコードを入れて「Authorize」を押してください。"
            echo
            gh auth login --hostname github.com --git-protocol https --web
            echo
            echo "終わったら、この窓を閉じて「GitHub 取得」に戻り、「ログインを確かめる」を押してください。"
            """
        do {
            try text.write(to: cmd, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cmd.path)
            NSWorkspace.shared.open(cmd)
        } catch {
            message = "ターミナルを開けませんでした: \(error.localizedDescription)"
        }
    }

    func openLatestLog() {
        let fm = FileManager.default
        // 取得ログは月ごとのフォルダに分かれているので、中まで見る
        let files = (fm.enumerator(at: Paths.logs, includingPropertiesForKeys: [.contentModificationDateKey])?
            .compactMap { $0 as? URL }) ?? []
        let latest = files.filter { $0.pathExtension == "log" && $0.lastPathComponent != "アプリから動かした記録.log" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
        NSWorkspace.shared.open(latest ?? Paths.logs)
    }

    func openFolder() { NSWorkspace.shared.open(FileManager.default.fileExists(atPath: Paths.data.path) ? Paths.data : Paths.base) }

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            message = nil
        } catch {
            message = "Mac の起動時に開く設定ができませんでした（\(error.localizedDescription)）。"
                + "システム設定 → 一般 → ログイン項目 で、このアプリを足してください。"
        }
        loginItem = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - 部品

struct SwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Color.okInk : Color(hex: 0xB3B3B3))
                Circle().fill(.white).shadow(color: .black.opacity(0.3), radius: 1, y: 1).padding(3)
            }
            .frame(width: 42, height: 24)
            .animation(.easeOut(duration: 0.15), value: configuration.isOn)
        }
        .buttonStyle(.plain)
    }
}

struct DadsButton: View {
    enum Kind { case primary, secondary, quiet }
    let title: String
    var kind: Kind = .primary
    var small = false
    var enabled = true
    var shortcut: KeyboardShortcut? = nil   // 例: .cancelAction（Esc で押したことにする）
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: small ? 12 : 13, weight: .bold))
                .foregroundStyle(fg)
                .padding(.vertical, small ? 6 : 9)
                .padding(.horizontal, small ? 10 : 14)
                .frame(maxWidth: small ? nil : .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(bg))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .disabled(!enabled)
        .onHover { hover = $0 }
    }
    private var fg: Color {
        if !enabled { return Color(hex: 0x949494) }
        switch kind { case .primary: return .white; case .secondary: return .key; case .quiet: return .ink }
    }
    private var bg: Color {
        if !enabled { return .line }
        switch kind {
        case .primary: return hover ? .keyHover : .key
        case .secondary: return hover ? .keyWash : .white
        case .quiet: return hover ? .surface2 : .white
        }
    }
    private var border: Color {
        if !enabled { return .clear }
        switch kind { case .primary: return .clear; case .secondary: return .key; case .quiet: return .line2 }
    }
}

struct MenuRow: View {
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack { Text(title).font(.system(size: 13)); Spacer() }
                .foregroundStyle(hover ? .white : .ink)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.key : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// 取得の記録の「結果」
struct Pill: View {
    let result: String?
    let ng: Int?
    var body: some View {
        let (text, fg, bg): (String, Color, Color) = {
            switch result {
            case "ok": return ("照合 OK", .okInk, .okWash)
            case "ng": return ("照合 NG \(ng ?? 0)件", .ngInk, .ngWash)
            case "stopped": return ("途中で止めた", .warnInk, .warnWash)
            case "interrupted": return ("途中で終わった", .warnInk, .warnWash)   // 取得中にアプリや Mac が止まった（Slack 版と同じ）
            case "partial": return ("一部取れず", .warnInk, .warnWash)
            case "waiting": return ("回数の待ち", .warnInk, .warnWash)
            case "login": return ("ログインが必要", .ngInk, .ngWash)
            default: return ("失敗", .ngInk, .ngWash)
            }
        }()
        Text(text).font(.system(size: 11, weight: .bold)).foregroundStyle(fg)
            .padding(.horizontal, 8).padding(.vertical, 1)
            .background(Capsule().fill(bg))
    }
}

/// 取得の記録の「スリープ」の印（取得の途中で Mac が眠っていた・予定の時刻に眠っていた）。問題ではないので灰色
struct SleepBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "moon").font(.system(size: 9, weight: .bold))
            Text("スリープ").font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(Color.ink2)
        .padding(.horizontal, 8).padding(.vertical, 1)
        .background(Capsule().fill(Color.surface2))
    }
}

/// Mac のスリープの知らせ（月の印と文）。小窓の状態のカードと状況ページで使う。問題ではないので灰色
struct SleepNote: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "moon").font(.system(size: 11)).foregroundStyle(Color.ink2)
            Text(text).font(.system(size: 12)).foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 呼び名（2〜4文字）の札。小窓の一覧・状況ページ・はじめの準備で使う
struct TagChip: View {
    let tag: String
    var width: CGFloat? = 40
    var body: some View {
        Text(tag).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ink2)
            .lineLimit(1)
            .frame(width: width).padding(.vertical, 2).padding(.horizontal, width == nil ? 8 : 0)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.surface2))
    }
}

/// 他人が書いた文字列（題名など）を、画面の1行に畳む（改行・タブを空白にし、長いものは切る）
func oneLine(_ s: String, max: Int = 80) -> String {
    let flat = s.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "\t", with: " ")
    return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
}

/// 取れなかった理由を短く（小窓の一覧・カードの1行に使う）
func failShort(_ kind: String?) -> String {
    switch kind {
    case "not_found": return "見えません"
    case "forbidden": return "権限が足りません"
    case "sso": return "組織の許可（SSO）が要ります"
    case "login": return "ログインが必要です"
    case "rate": return "回数の上限"
    case "network": return "GitHub につながりませんでした"
    case "server": return "GitHub の側の不調"
    default: return "くわしくは取得ログ"
    }
}

// MARK: - メニュー（メニューバーのアイコンを押すと出る）

struct MenuIcon: View {
    let state: DisplayState
    var body: some View {
        switch state {
        case .ok: Image(systemName: "checkmark.circle")
        case .running: Image(systemName: "arrow.triangle.2.circlepath")
        case .ng: Image(systemName: "exclamationmark.triangle.fill")
        case .failed: Image(systemName: "exclamationmark.circle.fill")
        case .filling: Image(systemName: "hourglass")
        case .stale: Image(systemName: "clock.badge.exclamationmark")
        case .fresh: Image(systemName: "tray")
        case .login: Image(systemName: "key.fill")
        case .waiting: Image(systemName: "hourglass")
        case .partial: Image(systemName: "exclamationmark.circle")
        }
    }
}

struct StatusCard: View {
    @EnvironmentObject var store: Store
    var openStatus: () -> Void

    var body: some View {
        let s = store.display
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(iconBG(s))
                Image(systemName: iconName(s)).font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(yellow(s) ? Color.ink : .white)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title(s)).font(.system(size: 15, weight: .bold)).foregroundStyle(Color.ink)
                Text(desc(s)).font(.system(size: 12)).foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                extras(s)
                ForEach(store.sleepNotes, id: \.self) { SleepNote(text: $0).padding(.top, 2) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(wash(s)))
    }

    /// 黄色のカード（待てば戻る・一部だけ・古い・スリープで取れなかった）は、印を黒で描く
    private func yellow(_ s: DisplayState) -> Bool { store.sleepMissed || s == .stale || s == .waiting || s == .partial }

    // スリープで取れなかったときは、照合 NG・失敗の代わりに、黄色に月の印で「もう一度取る」を促す（Slack 取得と同じ）
    private func iconName(_ s: DisplayState) -> String {
        if store.sleepMissed { return "moon.fill" }
        switch s {
        case .ok: return "checkmark"
        case .running: return "arrow.clockwise"
        case .ng, .failed, .partial: return "exclamationmark"
        case .filling: return "hourglass"
        case .stale: return "clock"
        case .fresh: return "arrow.down"
        case .login: return "key.fill"
        case .waiting: return "hourglass"
        }
    }
    private func iconBG(_ s: DisplayState) -> Color {
        if store.sleepMissed { return .warnIcon }
        switch s {
        case .ok: return .okInk
        case .running, .fresh: return .key
        case .ng, .failed, .login: return .ngInk
        case .stale, .waiting, .partial, .filling: return .warnIcon
        }
    }
    private func wash(_ s: DisplayState) -> Color {
        if store.sleepMissed { return .warnWash }
        switch s {
        case .ok: return .okWash
        case .running, .fresh: return .keyWash
        case .ng, .failed, .login: return .ngWash
        case .stale, .waiting, .partial, .filling: return .warnWash
        }
    }
    private func title(_ s: DisplayState) -> String {
        if store.sleepMissed { return "スリープで取れなかった分があります" }
        switch s {
        case .ok: return "最新です"
        case .running: return "取得中…"
        case .ng: return "照合で合わないものが \(store.ngLines.count)件あります"
        case .failed: return store.file.state == "stopped" ? "途中で止まりました" : "取れませんでした"
        case .filling: return "最初の取得の途中です"
        case .stale: return "\(store.staleDays)日間 取れていません"
        case .fresh: return "まだ一度も取っていません"
        case .login: return "ログインが必要です"
        case .waiting: return "回数の上限で待っています"
        case .partial: return "一部のリポジトリが取れませんでした"
        }
    }
    private func desc(_ s: DisplayState) -> String {
        if let t = store.sleepMissedText { return t }
        let last = Fmt.relative(store.lastRunEnd, now: store.now)
        switch s {
        case .ok:
            return "\(last) に取得・照合 OK（\(store.repos.count) リポジトリすべて取れています）"
        case .running:
            return StatusCard.progressText(store)
        case .ng:
            return "\(last) の取得。ほかは全部 OK です"
        case .failed:
            return "\(last)・\(store.file.run?.note ?? "くわしくは取得ログを見てください")。取れた分は残っています。もう一度動かせば、続きから取ります"
        case .filling:
            return "\(store.callCapText)ずつ分けて取ります" + (store.pendingText.isEmpty ? "" : "。いま \(store.pendingText)")
                + "。\(last) までに取れた分は残っています。続きは次の取得（今すぐ取る・毎朝）で取ります"
        case .stale:
            return "最後に取れたのは \(Fmt.relative(store.lastRead, now: store.now))。Mac が止まっていたか、このアプリが閉じていたかもしれません。次に取れば、その間の分もまとめて取ります（抜けません）"
        case .fresh:
            return store.freshText
        case .login:
            return "\(last)、GitHub のログインが切れていました。ターミナルで gh にログインしてから、もう一度取ってください。前のデータは残っています"
        case .waiting:
            let back = store.waitUntil.map { Fmt.string($0, "H:mm") } ?? "1時間以内"
            return "GitHub の1時間あたりの回数を使い切りました。\(back) に戻ります。そのあと自動で続きを取ります（抜けません）"
        case .partial:
            return StatusCard.partialText(store)
        }
    }

    /// 取得中の1行（何個目のリポジトリか）
    static func progressText(_ store: Store) -> String {
        if let p = store.file.run?.progress, let total = p.total, total > 0 {
            let n = min(total, (p.done ?? 0) + 1)
            return "\(total) のうち \(n) つ目" + (p.tag.map { "（\($0)）" } ?? "") + "を取っています"
        }
        return "取得を始めています"
    }

    /// 一部だけ取れなかったときの説明（理由がそろっていれば、理由まで言う）
    static func partialText(_ store: Store) -> String {
        let bad = store.failedRepos
        let tags = bad.map(\.tag).joined(separator: "・")
        let kinds = Set(bad.map { $0.error_kind ?? "" })
        let why: String
        switch kinds.count == 1 ? kinds.first : nil {
        case "not_found": why = "が見えませんでした。権限が無いか、名前が変わったのかもしれません"
        case "forbidden": why = "が読めませんでした（権限が足りません）"
        case "sso": why = "は、組織の許可（SSO）が要ります。ブラウザで許可してから、もう一度取ってください"
        default: why = "が取れませんでした（くわしくは状況ページ）"
        }
        let okCount = store.repos.count - bad.count
        return "\(store.repos.count) のうち \(bad.count) つ（\(tags)）\(why)。ほかの \(okCount) は取れています"
    }

    @ViewBuilder private func extras(_ s: DisplayState) -> some View {
        if store.sleepMissed {
            HStack(spacing: 8) {
                DadsButton(title: "もう一度取る", small: true) { store.runNow() }
                DadsButton(title: "取得ログを開く", kind: .quiet, small: true) { store.openLatestLog() }
            }
            .padding(.top, 6)
        } else {
            stateExtras(s)
        }
    }
    @ViewBuilder private func stateExtras(_ s: DisplayState) -> some View {
        switch s {
        case .running:
            if let p = store.file.run?.progress, let total = p.total, total > 0 {
                ProgressLine(value: Double(p.done ?? 0) / Double(total), track: .white).padding(.vertical, 5)
            } else {
                ProgressView().progressViewStyle(.linear).tint(.key).padding(.top, 4)
            }
            if let st = Fmt.parseISO(store.file.run?.start), store.file.state == "running" {
                let secs = Int(store.now.timeIntervalSince(st))
                Text("\(Fmt.relative(st, now: store.now)) に開始・経過 \(secs / 60)分\(secs % 60)秒・使った回数 \(Fmt.number(store.file.run?.calls ?? 0))")
                    .font(.system(size: 11)).foregroundStyle(Color.ink2)
            }
        case .ng:
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(store.ngLines.prefix(2).enumerated()), id: \.offset) { _, line in
                    Text(store.readable(line)).font(.system(size: 12)).foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.ngLines.count > 2 {
                    Text("ほか \(store.ngLines.count - 2)件").font(.system(size: 11)).foregroundStyle(Color.ink3)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.ngLine, lineWidth: 1))
            .padding(.top, 4)
            HStack(spacing: 8) {
                DadsButton(title: "もう一度取る", small: true) { store.runNow() }
                DadsButton(title: "詳しく見る", kind: .quiet, small: true, action: openStatus)
            }
            .padding(.top, 6)
        case .failed, .filling:
            HStack(spacing: 8) {
                DadsButton(title: "今すぐ取る", small: true) { store.runNow() }
                DadsButton(title: "取得ログを開く", kind: .quiet, small: true) { store.openLatestLog() }
            }
            .padding(.top, 6)
        case .login:
            HStack(spacing: 8) {
                DadsButton(title: "ターミナルでログイン", small: true) { store.openLoginTerminal() }
                DadsButton(title: "もう一度取る", kind: .quiet, small: true) { store.runNow() }
            }
            .padding(.top, 6)
        case .waiting:
            DadsButton(title: "取得ログを開く", kind: .quiet, small: true) { store.openLatestLog() }.padding(.top, 6)
        case .partial:
            HStack(spacing: 8) {
                DadsButton(title: "リポジトリを見直す", small: true) { AppDelegate.shared?.openSetup() }
                DadsButton(title: "もう一度取る", kind: .quiet, small: true) { store.runNow() }
            }
            .padding(.top, 6)
        case .fresh where !store.configured:
            DadsButton(title: "はじめの準備を開く", small: true) { AppDelegate.shared?.openSetup() }.padding(.top, 6)
        case .stale, .fresh:
            DadsButton(title: "今すぐ取る", small: true) { store.runNow() }.padding(.top, 6)
        case .ok:
            EmptyView()
        }
    }
}

extension Store {
    /// 小窓に出すリポジトリ。取れなかったものは必ず先に出す（5つの枠の外）。ほかは最後に入った時刻が新しい順に、
    /// 6つまでなら全部、7つ以上なら5つ。残りは1行にまとめる（取れなかったものに押し出されて、動いているものが隠れないように）
    var menuRepos: [RepoInfo] {
        let newer = { (a: RepoInfo, b: RepoInfo) in
            (Fmt.parseISO(a.last_landed) ?? .distantPast) > (Fmt.parseISO(b.last_landed) ?? .distantPast)
        }
        let failed = repos.filter(\.failed).sorted(by: newer)
        let others = repos.filter { !$0.failed }.sorted(by: newer)
        return failed + (others.count <= 6 ? others : Array(others.prefix(5)))
    }
    var menuRest: [RepoInfo] {
        let shown = Set(menuRepos.map(\.id))
        return repos.filter { !shown.contains($0.id) }
    }
    /// 「最後に入った」の言い方（7日以内は時刻まで、それより前は日だけ）
    func landedText(_ r: RepoInfo) -> String {
        guard let d = Fmt.parseISO(r.last_landed) else { return "まだ入ったものがありません" }
        return now.timeIntervalSince(d) < 7 * 86400 ? Fmt.relative(d, now: now) : Fmt.relativeDay(d, now: now)
    }
}

struct RepoList: View {
    @EnvironmentObject var store: Store
    var openStatus: () -> Void

    var body: some View {
        let rows = store.menuRepos
        let rest = store.menuRest
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                if i > 0 { Divider().overlay(Color.line) }
                HStack(spacing: 10) {
                    TagChip(tag: r.tag)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.name).font(.system(size: 12)).foregroundStyle(Color.ink)
                            .lineLimit(1).truncationMode(.middle)
                        if r.failed {
                            Text("取れませんでした（\(failShort(r.error_kind))）").font(.system(size: 11)).foregroundStyle(Color.ngInk)
                        } else {
                            Text("最後に入った " + store.landedText(r)).font(.system(size: 11)).foregroundStyle(Color.ink3)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Fmt.number(r.total)).font(.system(size: 13, weight: .bold)).monospacedDigit()
                            .foregroundStyle(Color.ink)
                        if r.failed {
                            Text("—").font(.system(size: 11)).foregroundStyle(Color.ink3)
                        } else {
                            Text("+\(Fmt.number(r.delta ?? 0))").font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.okInk)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            }
            if !rest.isEmpty {
                Divider().overlay(Color.line)
                Button(action: openStatus) {
                    HStack(spacing: 10) {
                        TagChip(tag: "ほか")
                        VStack(alignment: .leading, spacing: 1) {
                            Text("ほか \(rest.count) リポジトリ").font(.system(size: 12)).foregroundStyle(Color.ink)
                            Text(restNote(rest)).font(.system(size: 11)).foregroundStyle(Color.ink3)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(Fmt.number(rest.reduce(0) { $0 + $1.total })).font(.system(size: 13, weight: .bold))
                                .monospacedDigit().foregroundStyle(Color.ink)
                            Text("+\(Fmt.number(rest.reduce(0) { $0 + ($1.delta ?? 0) }))").font(.system(size: 11))
                                .monospacedDigit().foregroundStyle(Color.okInk)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("状況ページで、全部のリポジトリを見る")
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line, lineWidth: 1))
    }

    /// まとめた行の説明（動きがあるものが混じっていれば、そう言う。取れなかったものは、まとめずに上に出している）
    private func restNote(_ rest: [RepoInfo]) -> String {
        let moving = rest.filter { ($0.last7 ?? 0) > 0 }.count
        let pending = rest.filter(\.incomplete).count
        return (moving == 0 ? "この7日は動きなし" : "うち \(moving) つに動きあり")
            + (pending == 0 ? "・すべて取れています" : "・\(pending) つはまだ最後まで取れていません")
    }
}

/// 進みの線（何個目のリポジトリを取っているか）。ProgressView は確認用の画像で黄色い四角になるので、自分で描く
struct ProgressLine: View {
    let value: Double        // 0〜1
    var track: Color = .line
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(Color.key).frame(width: max(6, g.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 6)
    }
}

struct PopoverView: View {
    @EnvironmentObject var store: Store

    private func openStatus() { AppDelegate.shared?.showStatus() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("GitHub 取得").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.ink)
                    Text("\(store.repos.count) リポジトリ").font(.system(size: 11)).foregroundStyle(Color.ink3)
                }
                Spacer()
                Button(action: openStatus) {
                    Image(systemName: "gearshape").font(.system(size: 15)).foregroundStyle(Color.ink2)
                }
                .buttonStyle(.plain)
                .help("状況ページと設定を開く")
            }

            StatusCard(openStatus: openStatus)

            if !store.repos.isEmpty {   // まだ一度も取っていなければ、見出しの下が空になるので出さない
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.display == .stale
                         ? "リポジトリ（\(Fmt.relative(store.lastSuccess, now: store.now)) に取った時点）"
                         : "リポジトリ（前回の取得から入ったもの）")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ink3)
                    RepoList(openStatus: openStatus)
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("毎朝 \(store.timeText) に自動で取る").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.ink)
                    Text(store.autoEnabled ? "次は \(store.nextRunText)・土日も動く" : "自動の取得は止まっています")
                        .font(.system(size: 11)).foregroundStyle(Color.ink3)
                }
                Spacer()
                Toggle("", isOn: $store.autoEnabled).toggleStyle(SwitchStyle())
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line, lineWidth: 1))

            HStack(spacing: 8) {
                switch store.display {
                case .running:
                    DadsButton(title: "今すぐ取る", enabled: false) {}
                    DadsButton(title: "止める", kind: .quiet) { store.stop() }
                case .ok:
                    DadsButton(title: "今すぐ取る") { store.runNow() }
                    DadsButton(title: "状況ページを開く", kind: .secondary, action: openStatus)
                case .fresh where !store.configured:
                    DadsButton(title: "はじめの準備を開く", kind: .quiet) { AppDelegate.shared?.openSetup() }
                    DadsButton(title: "状況ページを開く", kind: .secondary, action: openStatus)
                default:
                    DadsButton(title: "今すぐ取る", kind: .quiet) { store.runNow() }
                    DadsButton(title: "状況ページを開く", kind: .secondary, action: openStatus)
                }
            }

            if let m = store.message {
                Text(m).font(.system(size: 11)).foregroundStyle(Color.ngInk).fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(Color.line)
            VStack(spacing: 0) {
                MenuRow(title: "GitHub とリポジトリ…") { AppDelegate.shared?.openSetup() }
                MenuRow(title: "取得ログを開く") { store.openLatestLog() }
                MenuRow(title: "記録のフォルダを開く") { store.openFolder() }
                MenuRow(title: "設定…") { openStatus(); store.showSettings = true }
                MenuRow(title: "終了") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}

// MARK: - 状況ページ（ウィンドウ）

/// マウスを乗せると、下に説明の札を出す（まわりの大きさは変えない）
struct HoverTip<Tip: View>: ViewModifier {
    var alignTrailing = false
    var forced = false
    @ViewBuilder var tip: () -> Tip
    @State private var hovering = false
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .background(GeometryReader { g in
                Color.clear.onAppear { height = g.size.height }.onChange(of: g.size.height) { _, h in height = h }
            })
            // 札は枠のすぐ下に重ねる（offset なので、まわりの並びは動かない）
            .overlay(alignment: alignTrailing ? .topTrailing : .topLeading) {
                if hovering || forced {
                    tip()
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ink)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.line2, lineWidth: 1))
                        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
                        .fixedSize()
                        .offset(y: (height > 0 ? height : 92) + 8)
                        .allowsHitTesting(false)
                }
            }
            .zIndex(hovering || forced ? 10 : 0)
    }
}

extension View {
    func hoverTip<Tip: View>(alignTrailing: Bool = false, forced: Bool = false,
                             @ViewBuilder _ tip: @escaping () -> Tip) -> some View {
        modifier(HoverTip(alignTrailing: alignTrailing, forced: forced, tip: tip))
    }
}

struct Card<Content: View>: View {
    let title: String
    let note: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(Color.ink)
            Text(note).font(.system(size: 11)).foregroundStyle(Color.ink3).padding(.bottom, 10)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line, lineWidth: 1))
    }
}

struct Tile: View {
    let label: String
    let value: String
    let note: String
    var valueColor: Color = .ink
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 11)).foregroundStyle(Color.ink3)
                Spacer(minLength: 4)
                Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Color(hex: 0xB3B3B3))
            }
            Text(value).font(.system(size: 22, weight: .bold)).monospacedDigit().foregroundStyle(valueColor)
            Text(note).font(.system(size: 11)).foregroundStyle(Color.ink2).lineLimit(2)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

/// 説明の札の中の見出し
struct TipTitle: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.ink) }
}

/// くるくる回るアイコン（取得中の印）
struct SpinningIcon: View {
    let name: String
    @State private var spin = false
    var body: some View {
        Image(systemName: name)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

struct StatePill: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let s = spec
        HStack(spacing: 5) {
            if store.display == .running {
                SpinningIcon(name: s.0).font(.system(size: 12, weight: .bold))
            } else {
                Image(systemName: s.0).font(.system(size: 12, weight: .bold))
            }
            Text(s.1).font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(s.2)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(s.3))
    }
    private var spec: (String, String, Color, Color) {
        if store.sleepMissed { return ("moon", "スリープで取れなかった", .warnInk, .warnWash) }
        switch store.display {
        case .ok: return ("checkmark.circle.fill", "最新・照合 OK", .okInk, .okWash)
        case .running:
            let p = store.file.state == "running" ? store.file.run?.progress : nil
            let step = p.flatMap { p in p.total.map { "\(min($0, (p.done ?? 0) + 1))/\($0)" } }
            return ("arrow.triangle.2.circlepath", step.map { "取得中・\($0)" } ?? "取得中", .key, .keyWash)
        case .ng: return ("exclamationmark.triangle.fill", "照合 NG \(store.ngLines.count)件", .ngInk, .ngWash)
        case .failed:
            return ("exclamationmark.circle.fill", store.file.state == "stopped" ? "途中で止まった" : "取れなかった", .ngInk, .ngWash)
        case .filling: return ("hourglass", "最初の取得の途中", .warnInk, .warnWash)
        case .stale: return ("clock.badge.exclamationmark", "\(store.staleDays)日間 取れていない", .warnInk, .warnWash)
        case .fresh: return ("tray", "まだ取っていない", .key, .keyWash)
        case .login: return ("key.fill", "ログインが必要", .ngInk, .ngWash)
        case .waiting: return ("hourglass", "回数の上限で待っている", .warnInk, .warnWash)
        case .partial: return ("exclamationmark.circle", "一部取れなかった", .warnInk, .warnWash)
        }
    }
}

/// グラフの凡例（2色。系列が2つなので、いつも出す）
struct LandedLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            item(.barPR, "PR 経由（PR 1 件で 1）")
            item(.barDirect, "直接（コミット 1 つで 1）")
        }
        .font(.system(size: 11)).foregroundStyle(Color.ink2)
    }
    private func item(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10)
            Text(t)
        }
    }
}

/// 日の並び（グラフの下の「10/5」と曜日）
private func dayLabel(_ date: String) -> String {
    guard let d = Fmt.parseJST(date + " 12:00:00") else { return date }
    return Fmt.string(d, "M/d")
}
/// マウスの位置の日（棒の吹き出しに使う）。日が 1 つも無いグラフでは聞かずに nil。
/// Swift Charts は、日の並びが空のグラフで位置を聞くと落ちる（まだ一度も数えていないとき。2026-10-20 に別の PC で落ちた）
func hoveredDay(_ proxy: ChartProxy, x: CGFloat, days: Int) -> String? {
    days > 0 ? proxy.value(atX: x, as: String.self) : nil
}
private func dayWeekday(_ date: String) -> String {
    guard let d = Fmt.parseJST(date + " 12:00:00") else { return "" }
    return Fmt.string(d, "E")
}

/// 2段の積み上げの棒（下が PR 経由、上が直接）。段のあいだは白いすき間、上の端だけ角を丸める
@ChartContentBuilder
func landedBars(x: String, pr: Int, direct: Int, hot: Bool, width: MarkDimension, gap: Double, radius: CGFloat,
                label: Text?) -> some ChartContent {
    let p = Double(pr), all = Double(pr + direct)
    if pr > 0 {
        BarMark(x: .value("日", x), yStart: .value("数", 0), yEnd: .value("数", direct > 0 ? max(0, p - gap / 2) : p), width: width)
            .foregroundStyle(hot ? Color.barPRHover : Color.barPR)
            .clipShape(direct > 0 ? AnyShape(Rectangle())
                                  : AnyShape(UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius)))
            .annotation(position: .top, spacing: 3) { if direct == 0, let label { label } }
    }
    if direct > 0 {
        BarMark(x: .value("日", x), yStart: .value("数", pr > 0 ? p + gap / 2 : 0), yEnd: .value("数", all), width: width)
            .foregroundStyle(hot ? Color.barDirectHover : Color.barDirect)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius))
            .annotation(position: .top, spacing: 3) { if let label { label } }
    }
}

struct DailyChart: View {
    @EnvironmentObject var store: Store
    @State private var hovered: String?

    private func niceTop(_ m: Int) -> Int {
        let raw = max(10.0, Double(m) * 1.2)
        let step: Double = raw > 400 ? 100 : raw > 200 ? 50 : raw > 100 ? 25 : 10
        return Int((raw / step).rounded(.up) * step)
    }

    var body: some View {
        let data = store.file.daily ?? []
        let maxTotal = data.map(\.total).max() ?? 0
        let top = niceTop(maxTotal)
        let gap = Double(top) * 2 / 190   // 段のあいだの約 2px（棒の描ける高さは約 190px）
        let sel = store.previewBar ?? hovered
        Chart {
            ForEach(data) { e in
                let x = dayLabel(e.date)
                landedBars(x: x, pr: e.prTotal, direct: e.directTotal, hot: sel == x, width: .fixed(28), gap: gap, radius: 4,
                           label: e.total == maxTotal && maxTotal > 0 && sel != x
                               ? Text("\(e.total)").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ink) : nil)
            }
        }
        .chartXScale(domain: data.map { dayLabel($0.date) })   // 0件の日も並べる
        .chartYScale(domain: 0...top)
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Color.line)
                AxisValueLabel().foregroundStyle(Color.ink3)
            }
        }
        .chartXAxis {
            AxisMarks { v in
                AxisValueLabel {
                    if let s = v.as(String.self) {
                        VStack(spacing: 0) {
                            Text(s).font(.system(size: 11)).foregroundStyle(Color.ink3)
                            Text(data.first { dayLabel($0.date) == s }.map { dayWeekday($0.date) } ?? "").font(.system(size: 10))
                                .foregroundStyle(Color(hex: 0x949494))
                        }
                    }
                }
            }
        }
        // 吹き出しはグラフの上に重ねる（グラフの大きさは変えない）。半透明で、下の棒が透けて見える
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hovered = hoveredDay(proxy, x: p.x - plot.minX, days: data.count)
                        case .ended: hovered = nil
                        }
                    }
                if let sel, let e = data.first(where: { dayLabel($0.date) == sel }),
                   let x = proxy.position(forX: sel), let y = proxy.position(forY: e.total) {
                    let w: CGFloat = 250
                    let parts = store.repos.compactMap { r -> String? in
                        let n = e.counts[r.tag] ?? 0
                        return n > 0 ? "\(r.tag) \(n)" : nil
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(sel)（\(dayWeekday(e.date))） \(e.total)件").font(.system(size: 12, weight: .bold))
                        Text("PR 経由 \(e.prTotal)・直接 \(e.directTotal)").font(.system(size: 11))
                        Text(parts.isEmpty ? "入ったものはありません" : parts.joined(separator: "・"))
                            .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(width: w, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.62)))
                    .position(x: min(max(plot.minX + x, w / 2), geo.size.width - w / 2),
                              y: max(plot.minY + y - 44, 34))
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 230)
    }
}

struct HistoryCard: View {
    @EnvironmentObject var store: Store
    @State private var expanded = false

    var body: some View {
        let recent = store.last30Runs
        let open = expanded || store.previewExpanded
        let rows = open ? recent : Array(store.history.prefix(5))
        Card(title: "取得の記録",
             note: "毎回の取得の結果（新しい順）。使った回数は、GitHub の1時間の枠から使った数（変わっていないものの問い合わせは数えません）") {
            HStack(spacing: 18) {
                summary("今月", store.monthRuns)
                summary("過去30日", recent)
                Spacer()
            }
            .padding(.bottom, 10)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    ForEach(["日時", "結果", "新しく入った", "使った回数", "メモ"], id: \.self) {
                        Text($0).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ink3)
                    }
                }
                Divider().overlay(Color.line)
                ForEach(rows) { e in
                    GridRow {
                        Text(Fmt.relative(Fmt.parseISO(e.start), now: store.now)).font(.system(size: 12))
                        HStack(spacing: 6) {
                            Pill(result: e.result, ng: e.ng)
                            if e.sleep != nil || e.delayed_from != nil { SleepBadge() }
                        }
                        Text("+\(Fmt.number(e.new ?? 0))").font(.system(size: 12)).monospacedDigit()
                            .gridColumnAlignment(.trailing)
                        Text("\(Fmt.number(e.calls ?? 0)) 回").font(.system(size: 12)).monospacedDigit()
                            .gridColumnAlignment(.trailing)
                        Text(Store.historyMemo(e)).font(.system(size: 11)).foregroundStyle(Color.ink3).lineLimit(1)
                            .frame(maxWidth: 420, alignment: .leading)
                    }
                }
            }
            .foregroundStyle(Color.ink)
            if recent.count > 5 || open {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .bold))
                        Text(open ? "閉じる" : "過去30日をすべて見る（\(recent.count)回）").font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(Color.key)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }
        }
    }

    private func summary(_ label: String, _ runs: [HistoryEntry]) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ink3)
            Text("\(runs.count)回").font(.system(size: 12)).foregroundStyle(Color.ink)
            Text("使った回数 \(Fmt.number(runs.reduce(0) { $0 + ($1.calls ?? 0) })) 回")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.ink)
        }
    }
}

struct WeekChart: View {
    let days: [DayLanded]
    var forcedLabel: String?
    @State private var hovered: String?

    var body: some View {
        let sel = forcedLabel ?? hovered
        let maxV = days.map(\.total).max() ?? 0
        let top = max(1, Double(maxV) * 1.25)
        let gap = top * 2 / 90   // 段のあいだの約 2px（棒の描ける高さは約 90px）
        Chart {
            ForEach(days) { d in
                let x = dayLabel(d.date)
                landedBars(x: x, pr: d.pr, direct: d.direct, hot: sel == x, width: .ratio(0.6), gap: gap, radius: 3,
                           label: d.total > 0 && sel != x
                               ? Text("\(d.total)").font(.system(size: 10)).foregroundStyle(Color.ink3) : nil)
            }
        }
        .chartXScale(domain: days.map { dayLabel($0.date) })
        .chartYScale(domain: 0...top)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { v in
                AxisValueLabel {
                    if let s = v.as(String.self) {
                        VStack(spacing: 0) {
                            Text(s).font(.system(size: 10)).foregroundStyle(Color.ink3)
                            Text(days.first { dayLabel($0.date) == s }.map { dayWeekday($0.date) } ?? "").font(.system(size: 9))
                                .foregroundStyle(Color(hex: 0x949494))
                        }
                    }
                }
            }
        }
        // 吹き出しはグラフの上に重ねる（大きさは変えない）。半透明で、下の棒が透けて見える
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hovered = hoveredDay(proxy, x: p.x - plot.minX, days: days.count)
                        case .ended: hovered = nil
                        }
                    }
                if let sel, let d = days.first(where: { dayLabel($0.date) == sel }),
                   let x = proxy.position(forX: sel), let y = proxy.position(forY: d.total) {
                    let w: CGFloat = 170
                    let room = max(plot.minY + y - 6, 30)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(sel)（\(dayWeekday(d.date))） \(d.total)件").font(.system(size: 12, weight: .bold))
                            Text(d.total == 0 ? "入ったものはありません" : "PR 経由 \(d.pr)・直接 \(d.direct)").font(.system(size: 11))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(width: w, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.68)))
                    }
                    .frame(width: w, height: room, alignment: .bottom)
                    .position(x: min(max(plot.minX + x, w / 2), geo.size.width - w / 2), y: room / 2)
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

/// 小さな札（非公開・アーカイブ済み・PR の印）
struct MiniBadge: View {
    let text: String
    var icon: String? = nil
    var fg: Color = .ink2
    var bg: Color = .surface2
    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(Capsule().fill(bg))
    }
}

/// PR の印の色（承認済み＝緑・CI 失敗と変更の依頼＝赤・下書き＝灰）。どれも文字と一緒に出す（色だけで伝えない）
func flagBadge(_ f: String, count: Int? = nil) -> MiniBadge {
    let text = count.map { "\(f) \($0)" } ?? f
    switch f {
    case "承認済み": return MiniBadge(text: text, fg: .okInk, bg: .okWash)
    case "CI 失敗", "変更の依頼": return MiniBadge(text: text, fg: .ngInk, bg: .ngWash)
    default: return MiniBadge(text: text)
    }
}

/// リポジトリ1つのカード（状況ページ。この14日に動いたもの・取れなかったもの）
struct RepoPanel: View {
    let r: RepoInfo
    let now: Date
    var forcedLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(r.tag).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.ink2)
                    .padding(.horizontal, 10).padding(.vertical, 2)
                    .background(Capsule().fill(Color.surface2))
                if r.visibility == "private" { MiniBadge(text: "非公開", icon: "lock.fill") }
                if r.archived == true { MiniBadge(text: "アーカイブ済み") }
                Spacer()
                if r.failed {
                    Text("取れませんでした").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ngInk)
                } else {
                    Text("前回から +\(Fmt.number(r.delta ?? 0))").font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.okInk)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(r.name).font(.system(size: 12)).foregroundStyle(Color.ink2).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("基準 \(r.base)").font(.system(size: 11)).foregroundStyle(Color.ink3).lineLimit(1)
            }
            if r.failed {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(Color.ngInk)
                    Text("\(r.error ?? failShort(r.error_kind))。数字は、最後に取れた \(Fmt.relative(Fmt.parseISO(r.fetched), now: now)) の時点です")
                        .font(.system(size: 11)).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.ngWash))
            }

            // 主役: この7日に入ったもの
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("この7日に入った").font(.system(size: 11)).foregroundStyle(Color.ink3)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(Fmt.number(r.last7 ?? 0)).font(.system(size: 26, weight: .bold)).monospacedDigit()
                            .foregroundStyle(Color.ink)
                        Text("件").font(.system(size: 12)).foregroundStyle(Color.ink3)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(trend).font(.system(size: 11)).foregroundStyle(Color.ink2)
                    Text("PR 経由 \(r.last7_pr ?? 0)・直接 \((r.last7 ?? 0) - (r.last7_pr ?? 0))")
                        .font(.system(size: 11)).foregroundStyle(Color.ink3)
                }
            }
            WeekChart(days: r.week ?? [], forcedLabel: forcedLabel).frame(height: 120)
            Text("棒にマウスを乗せると、その日の内訳が出ます")
                .font(.system(size: 10)).foregroundStyle(Color.ink3)

            reach
            upcoming

            Rectangle().fill(Color.line).frame(height: 1)
            Text("合計（\(fromText) から）").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.ink3)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 9) {
                stat("入ったもの", Fmt.number(r.total) + "件")
                stat("PR 経由・直接", "\(Fmt.number(r.total_pr ?? 0))・\(Fmt.number(r.total - (r.total_pr ?? 0)))")
                stat("PR・issue", "\(Fmt.number(r.counts?.prs ?? 0))・\(Fmt.number(r.counts?.issues ?? 0))")
                stat("コメント・レビュー", "\(Fmt.number(r.counts?.comments ?? 0))・\(Fmt.number(r.counts?.reviews ?? 0))")
                stat("最後に入った", lastLanded)
                stat("最後に取れた", r.incomplete ? "まだ最後まで取れていません" : Fmt.relative(Fmt.parseISO(r.fetched), now: now))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(r.failed ? Color.ngLine : Color.line, lineWidth: 1))
    }

    /// 届き具合（確認環境・本番のブランチを設定していれば、そこまで。無ければ最後のリリースのあと）
    @ViewBuilder private var reach: some View {
        let stages = r.stages ?? []
        if !stages.isEmpty || r.release != nil {
            Rectangle().fill(Color.line).frame(height: 1)
            Text(stages.isEmpty ? "届き具合（リリース）" : "届き具合（設定したブランチ）")
                .font(.system(size: 10, weight: .bold)).foregroundStyle(Color.ink3)
            if !stages.isEmpty {
                ForEach(stages) { s in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(s.name).font(.system(size: 12)).foregroundStyle(Color.ink)
                            Spacer(minLength: 4)
                            Text((s.behind ?? 0) == 0 ? "すべて届いています" : "まだ届いていない \(Fmt.number(s.behind ?? 0))件")
                                .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.ink)
                        }
                        Text("\(s.branch) ブランチ・最終更新 " + Fmt.relativeDay(Fmt.parseISO(s.updated), now: now))
                            .font(.system(size: 10)).foregroundStyle(Color.ink3)
                    }
                }
            } else if let rel = r.release {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(rel.tag)（\(Fmt.relativeDay(Fmt.parseISO(rel.date), now: now))）のあとに入った")
                        .font(.system(size: 12)).foregroundStyle(Color.ink)
                    Spacer(minLength: 4)
                    Text("\(Fmt.number(rel.after ?? 0))件").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.ink)
                }
            }
        }
    }

    /// これから入るもの（開いている PR・issue）。14日以内に動いたものだけを見せ、残りは数にまとめる
    @ViewBuilder private var upcoming: some View {
        let prs = r.open_prs ?? 0, issues = r.open_issues ?? 0
        if prs > 0 || issues > 0 {
            Rectangle().fill(Color.line).frame(height: 1)
            Text("これから（開いている PR・issue）").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.ink3)
            VStack(alignment: .leading, spacing: 3) {
                count("PR", prs, r.open_prs_active ?? 0)
                count("issue", issues, r.open_issues_active ?? 0)
            }
            if let f = r.pr_flags {
                let parts = [("承認済み", f.approved), ("変更の依頼", f.changes_requested), ("CI 失敗", f.ci_failed), ("下書き", f.draft)]
                    .compactMap { p in (p.1 ?? 0) > 0 ? (p.0, p.1 ?? 0) : nil }
                if !parts.isEmpty {
                    // 印は語の途中で折り返さないよう、札にして2列に並べる
                    VStack(alignment: .leading, spacing: 4) {
                        Text("動いた PR のうち").font(.system(size: 10)).foregroundStyle(Color.ink3)
                        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                                  alignment: .leading, spacing: 4) {
                            ForEach(parts.indices, id: \.self) { i in flagBadge(parts[i].0, count: parts[i].1) }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach((r.active ?? []).prefix(3)) { a in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "#\(a.number)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.ink3)
                        Image(systemName: a.kind == "pr" ? "arrow.triangle.pull" : "smallcircle.filled.circle")
                            .font(.system(size: 9)).foregroundStyle(Color.ink3)
                        Text(oneLine(a.title)).font(.system(size: 11)).foregroundStyle(Color.ink).lineLimit(1)
                        Spacer(minLength: 4)
                        ForEach(a.flags ?? [], id: \.self) { flagBadge($0) }
                    }
                }
            }
        } else if r.counts?.prs ?? 0 == 0 && r.counts?.issues ?? 0 == 0 {
            Rectangle().fill(Color.line).frame(height: 1)
            Text("PR と issue は使われていません（入ったものは、すべて直接の push です）")
                .font(.system(size: 11)).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func count(_ label: String, _ n: Int, _ active: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundStyle(Color.ink3).frame(width: 34, alignment: .leading)
            Text(Fmt.number(n)).font(.system(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(Color.ink)
            Text("開いている").font(.system(size: 11)).foregroundStyle(Color.ink3)
            Spacer(minLength: 4)
            Text("うち 14日で動いた \(Fmt.number(active))").font(.system(size: 11)).foregroundStyle(Color.ink2)
        }
    }

    /// 前の7日と比べて（Slack 取得と同じ言い方）
    private var trend: String {
        let now7 = r.last7 ?? 0, before = r.prev7 ?? 0
        guard before > 0 else { return "前の7日 \(Fmt.number(before))件" }
        if now7 >= before * 2 {
            return String(format: "前の7日 %@件の 約%.1f倍", Fmt.number(before), Double(now7) / Double(before))
        }
        let pct = Int((Double(now7 - before) / Double(before) * 100).rounded())
        let word = pct > 0 ? "\(pct)% 多い" : pct < 0 ? "\(-pct)% 少ない" : "同じ"
        return "前の7日 \(Fmt.number(before))件より \(word)"
    }

    private var fromText: String {
        guard let s = r.from, let d = Fmt.parseJST(s + " 12:00:00") else { return "取り始めた日" }
        return Fmt.string(d, "yyyy/M/d")
    }

    private var lastLanded: String {
        guard let d = Fmt.parseISO(r.last_landed) else { return "—" }
        return now.timeIntervalSince(d) < 7 * 86400 ? Fmt.relative(d, now: now) : Fmt.relativeDay(d, now: now)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(Color.ink3)
            Text(value).font(.system(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(Color.ink)
        }
    }
}

/// 14日動きのないリポジトリの表（消さずにまとめる。「動きなし」と「取れなかった」は言葉を分ける）
struct QuietTable: View {
    let repos: [RepoInfo]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("この14日に動きのないリポジトリ（\(repos.count)）").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.ink)
                Text("動きがないだけで、どれも取れています").font(.system(size: 11)).foregroundStyle(Color.ink3)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                GridRow {
                    ForEach(["呼び名", "リポジトリ", "最後に入った", "入ったもの（合計）", "取り始めた日", "取れたか"], id: \.self) {
                        Text($0).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ink3)
                    }
                }
                Divider().overlay(Color.line)
                ForEach(repos) { r in
                    GridRow {
                        TagChip(tag: r.tag)
                        Text(r.name).font(.system(size: 12)).foregroundStyle(Color.ink).lineLimit(1)
                        Text(Fmt.relativeDay(Fmt.parseISO(r.last_landed), now: now)).font(.system(size: 12)).monospacedDigit()
                        Text("\(Fmt.number(r.total))件").font(.system(size: 12)).monospacedDigit().gridColumnAlignment(.trailing)
                        Text(r.from.flatMap { Fmt.parseJST($0 + " 12:00:00") }.map { Fmt.string($0, "yyyy/M/d") } ?? "—")
                            .font(.system(size: 12)).monospacedDigit()
                        HStack(spacing: 4) {
                            Image(systemName: r.incomplete ? "hourglass" : "checkmark.circle.fill").font(.system(size: 11))
                                .foregroundStyle(r.incomplete ? Color.warnInk : Color.okInk)
                            Text(r.incomplete ? "まだ最後まで取れていません" + (r.pending.map { "（\($0)）" } ?? "")
                                 : "取れています（\(Fmt.relative(Fmt.parseISO(r.fetched), now: now))）")
                                .font(.system(size: 11)).foregroundStyle(Color.ink2)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.line, lineWidth: 1))
        }
    }
}

/// 設定の行の上下の余白（設定の窓では詰める）
private struct SettingRowPadKey: EnvironmentKey { static let defaultValue: CGFloat = 11 }
extension EnvironmentValues {
    var settingRowPad: CGFloat {
        get { self[SettingRowPadKey.self] }
        set { self[SettingRowPadKey.self] = newValue }
    }
}

struct SettingRow<C: View>: View {
    let title: String
    let sub: String
    var last = false
    @ViewBuilder var control: C
    @Environment(\.settingRowPad) private var pad
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(Color.ink)
                Text(sub).font(.system(size: 11)).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            control
        }
        .padding(.vertical, pad)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Color.line).frame(height: 1) } }
    }
}

/// 設定の窓の区切り（囲みごとに、見出し・何が決められるか・行）
enum SettingsGroup: String, CaseIterable, Identifiable {
    case fetch, github, app, base
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fetch: return "取得"
        case .github: return "GitHub とリポジトリ"
        case .app: return "このアプリ"
        case .base: return "保存先"
        }
    }
    /// その区切りで何が決められるか（見出しの下に出す。見出しがあるわけが、その場で分かるように）
    var note: String {
        switch self {
        case .fetch: return "いつ取るか・1回にどこまで問い合わせるか"
        case .github: return "どのリポジトリを取るか・GitHub のログイン"
        case .app: return "終わったときの知らせと、アプリの開き方・出し方"
        case .base: return "取ったデータと、取得の仕組みを置くフォルダ"
        }
    }
    var icon: String {
        switch self {
        case .fetch: return "arrow.down.circle"
        case .github: return "arrow.triangle.branch"
        case .app: return "macwindow"
        case .base: return "folder"
        }
    }
}

/// 中身が画面に収まらないときだけ、スクロールにする（画面の小さい Mac で、窓の下が切れないように）
struct ScrollIfTaller<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        if height > maxHeight {
            ScrollView { content }.frame(height: maxHeight)
        } else {
            content.background(GeometryReader { g in Color.clear.preference(key: ContentHeightKey.self, value: g.size.height) })
                .onPreferenceChange(ContentHeightKey.self) { height = $0 }
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct SettingsSheet: View {
    /// 囲みを並べた部分の高さの上限（画面の使える高さから、窓の題・設定の見出し・余白を引いたもの）。確認用の画像では使わない
    static var maxGroupsHeight: CGFloat? = (NSScreen.main?.visibleFrame.height).map { $0 - 150 }
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("設定").font(.system(size: 18, weight: .bold)).foregroundStyle(Color.ink)
                    Text("変えるとすぐに反映されます（保存ボタンはありません）").font(.system(size: 11)).foregroundStyle(Color.ink3)
                }
                Spacer()
                DadsButton(title: "閉じる", kind: .quiet, small: true, shortcut: .cancelAction) { dismiss(); store.showSettings = false }
            }
            .padding(.bottom, 2)
            if let maxH = SettingsSheet.maxGroupsHeight {
                ScrollIfTaller(maxHeight: maxH) { groups }
            } else {
                groups
            }
            if let m = store.message {
                Text(m).font(.system(size: 11)).foregroundStyle(Color.ngInk).padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 620)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .environment(\.settingRowPad, 8)
        .onAppear {
            // 開いたときに、どの欄にもキーボードの的を当てない（誤って数字を触っても変わらないように）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SettingsGroup.allCases) { g in group(g) }
        }
    }

    /// 区切りごとに囲む（状況ページのカードと同じ見せ方）。見出しは囲みの中に太字で、何が決められるかを1行そえる
    private func group(_ g: SettingsGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: g.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.key)
                Text(g.title).font(.system(size: 14, weight: .bold)).foregroundStyle(Color.ink)
            }
            Text(g.note).font(.system(size: 11)).foregroundStyle(Color.ink2).padding(.top, 3)
            rows(g)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 2)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.line, lineWidth: 1))
        .padding(.top, 10)
    }

    @ViewBuilder private func rows(_ g: SettingsGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch g {
            case .fetch:
                SettingRow(title: "毎朝 自動で取る", sub: "このアプリが開いている間、毎日この時刻に動きます（土日も）。Mac が寝ていた日は、起きたときに動きます") {
                    Picker("", selection: $store.hour) {
                        ForEach(0..<24, id: \.self) { Text("\($0)時").tag($0) }
                    }
                    .labelsHidden().frame(width: 78)
                    Picker("", selection: $store.minute) {
                        ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text(String(format: "%02d分", $0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 78)
                    Toggle("", isOn: $store.autoEnabled).toggleStyle(SwitchStyle())
                }
                SettingRow(title: "1回の取得で使ってよい回数",
                           sub: "1回の取得で GitHub に問い合わせる回数がこれを超えたら、その回を止めます（次は続きから）。"
                               + "変わっていないものは数えません。GitHub の枠（1時間 5,000 回）は、ほかの gh と分け合います",
                           last: true) {
                    Picker("", selection: $store.callCap) {
                        Text("500 回").tag(500); Text("1,000 回").tag(1000); Text("1,500 回（既定）").tag(1500)
                        Text("2,500 回").tag(2500); Text("上限なし").tag(0)
                    }
                    .labelsHidden().frame(width: 150)
                }
            case .github:
                SettingRow(title: "取るリポジトリ",
                           sub: "\(store.repos.count) リポジトリ。足す・外す、呼び名・基準のブランチ・取り始める日を変えるときに（閉じると設定に戻ります）") {
                    DadsButton(title: "開く…", kind: .quiet, small: true) {
                        dismiss()
                        store.showSettings = false
                        // 設定の窓が閉じてから開く（窓の上に窓は重ねられない）
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { AppDelegate.shared?.openSetup(backToSettings: true) }
                    }
                }
                SettingRow(title: "GitHub のログイン",
                           sub: (store.file.auth?.login.map { "\($0) でログインしています（gh）。" } ?? "gh にログインしているアカウントで取ります。")
                               + "最後にうまく取れたのは \(Fmt.relative(store.lastSuccess, now: store.now))。"
                               + "ログインが切れると取得が失敗し、状況ページに出ます。このアプリは読むだけで、GitHub に書き込みません",
                           last: true) {
                    DadsButton(title: "ログインし直す…", kind: .quiet, small: true) { store.openLoginTerminal() }
                }
            case .app:
                SettingRow(title: "終わったら通知する", sub: "NG や失敗のときも通知します") {
                    Toggle("", isOn: $store.notify).toggleStyle(SwitchStyle())
                }
                SettingRow(title: "Mac の起動時にこのアプリを開く", sub: "自動の取得には、このアプリが開いている必要があります") {
                    Toggle("", isOn: Binding(get: { store.loginItem }, set: { store.setLoginItem($0) })).toggleStyle(SwitchStyle())
                }
                SettingRow(title: "Dock にアイコンを出す", sub: "メニューバーがいっぱいでアイコンが見えないとき用。Dock のアイコンを押すと、状況ページが開きます", last: true) {
                    Toggle("", isOn: $store.showInDock).toggleStyle(SwitchStyle())
                }
            case .base:
                SettingRow(title: "取ったデータのフォルダ",
                           sub: Paths.short(Paths.data.path) + "。取得の仕組みのフォルダの外にあるので、仕組みを新しい版に入れ替えても消えません") {
                    DadsButton(title: "開く", kind: .quiet, small: true) { store.openFolder() }
                }
                SettingRow(title: "取得の仕組みのフォルダ",
                           sub: Paths.short(store.basePath) + (store.baseMissing ? "（github.py が見つかりません）" : "")
                               + "。新しい版を別の場所で組み立て直したら、そちらを使います。フォルダを動かしても、同じ Mac の中なら追いかけます",
                           last: true) {
                    DadsButton(title: "変更…", kind: .quiet, small: true) { store.chooseBase() }
                }
            }
        }
    }
}

struct StatusContent: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if store.display == .running {
                if let p = store.file.run?.progress, let total = p.total, total > 0 {
                    ProgressLine(value: Double(p.done ?? 0) / Double(total))
                } else {
                    ProgressView().progressViewStyle(.linear).tint(.key)
                }
            }
            notice
            sleepLine
            exceptionsLine
            tiles.zIndex(2)
            Card(title: "日ごとに入ったもの（\(store.repos.count) リポジトリ合計・直近14日）",
                 note: "基準のブランチに入った時刻で数えています（コミットに書かれた日付ではありません）。棒にマウスを乗せると、リポジトリごとの内訳が出ます") {
                LandedLegend().padding(.bottom, 8)
                DailyChart()
            }
            .zIndex(1)
            Card(title: "リポジトリごとの内訳",
                 note: "主役はこの7日に入ったもの。下に、届き具合・これから入るもの・取り始めた日からの合計。数字は最後の取得の時点") {
                let shown = panelRepos
                let quiet = store.repos.filter { r in !shown.contains { $0.id == r.id } }
                if !shown.isEmpty {
                    // 横に3つまで。4つ以上は折り返す
                    let cols = max(1, min(3, shown.count))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: cols),
                              alignment: .leading, spacing: 14) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, r in
                            RepoPanel(r: r, now: store.now, forcedLabel: i == 0 ? store.previewWeekBar : nil)
                        }
                    }
                }
                if !quiet.isEmpty {
                    QuietTable(repos: quiet, now: store.now).padding(.top, shown.isEmpty ? 0 : 14)
                }
            }
            HistoryCard()
            if let m = store.message {
                Text(m).font(.system(size: 12)).foregroundStyle(Color.ngInk)
            }
            Text("入ったものと日ごとの数は リポジトリ/ の記録から、取得の記録は 取得の記録.jsonl から出しています（データのフォルダ: "
                 + Paths.short(Paths.data.path) + "）。GitHub には読むだけで、書き込みません。")
                .font(.system(size: 11)).foregroundStyle(Color.ink3)
        }
        .padding(24)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .sheet(isPresented: $store.showSettings) { SettingsSheet().environmentObject(store) }
    }

    /// カードで見せるリポジトリ（取れなかったもの、次にこの14日に動いたもの。最後に入った時刻が新しい順）
    private var panelRepos: [RepoInfo] {
        store.repos.filter { $0.failed || $0.moved(now: store.now) }.sorted { a, b in
            if a.failed != b.failed { return a.failed }
            return (Fmt.parseISO(a.last_landed) ?? .distantPast) > (Fmt.parseISO(b.last_landed) ?? .distantPast)
        }
    }

    // ---- 見出し: 「状況」と、いまの状態・最後の取得・次の自動取得を1か所にまとめる ----
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text("状況").font(.system(size: 22, weight: .bold)).foregroundStyle(Color.ink)
                    StatePill()
                }
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Color.ink3)
            }
            Spacer()
            DadsButton(title: "取得ログを開く", kind: .quiet, small: true) { store.openLatestLog() }
            if store.running {
                DadsButton(title: "止める", kind: .quiet, small: true) { store.stop() }
            }
            if !store.configured && !store.running {   // 取るリポジトリが無いうちは、はじめの準備から
                DadsButton(title: "はじめの準備を開く", small: true) { AppDelegate.shared?.openSetup() }
            } else {
                DadsButton(title: store.running ? "取得中…" : "今すぐ取る", small: true, enabled: !store.running) { store.runNow() }
            }
            Button { store.showSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 16)).foregroundStyle(Color.ink2)
                    .frame(width: 32, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(Color.line2, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("設定")
        }
    }

    private var subtitle: String {
        let r = store.file.run
        let next = store.autoEnabled ? "次の自動取得 \(store.nextRunText)" : "自動の取得は止まっています"
        if store.display == .running {
            if let st = Fmt.parseISO(r?.start), store.file.state == "running" {
                let secs = Int(store.now.timeIntervalSince(st))
                return "\(Fmt.relative(st, now: store.now)) に開始・経過 \(secs / 60)分\(secs % 60)秒・"
                    + StatusCard.progressText(store) + "・使った回数 \(Fmt.number(r?.calls ?? 0))"
            }
            return "取得を始めています"
        }
        var parts = ["最後の取得 " + Fmt.relative(store.lastRunEnd, now: store.now)]
        if let calls = r?.calls { parts.append("（使った回数 \(Fmt.number(calls)) 回）") }
        return parts.joined() + "　" + next
    }

    // ---- 問題があるときだけ、見出しの下に1行で理由と次の一手 ----
    @ViewBuilder private var notice: some View {
        if let t = store.sleepMissedText {
            // スリープで取れなかった: 照合 NG・失敗の1行の代わりに、理由ともう一度取るボタン（Slack 取得と同じ）
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "moon").foregroundStyle(Color.warnInk)
                Text(t).font(.system(size: 12)).foregroundStyle(Color.ink2).lineLimit(2)
                Spacer()
                DadsButton(title: "もう一度取る", small: true) { store.runNow() }
            }
        } else {
            displayNotice
        }
    }

    @ViewBuilder private var displayNotice: some View {
        switch store.display {
        case .ng:
            noticeLine("exclamationmark.triangle.fill", .ngInk,
                       store.ngLines.prefix(2).map(store.readable).joined(separator: "／")
                           + (store.ngLines.count > 2 ? "（ほか \(store.ngLines.count - 2)件）" : "")) {
                DadsButton(title: "もう一度取る", small: true) { store.runNow() }
            }
        case .failed:
            noticeLine("exclamationmark.circle.fill", .ngInk,
                       "\(store.file.run?.note ?? "くわしくは取得ログを見てください")。取れた分は残っています。もう一度動かせば、続きから取ります") {
                EmptyView()
            }
        case .filling:
            noticeLine("hourglass", .warnInk,
                       "最初の取得の途中です。\(store.callCapText)ずつ分けて取ります" + (store.pendingText.isEmpty ? "" : "。いま \(store.pendingText)")
                           + "。取れた分は残っていて、続きは次の取得（今すぐ取る・毎朝）で取ります") {
                DadsButton(title: "今すぐ取る", small: true) { store.runNow() }
            }
        case .login:
            noticeLine("key.fill", .ngInk,
                       "GitHub のログインが切れていました。ターミナルで gh にログインしてから、もう一度取ってください。前のデータは残っています") {
                DadsButton(title: "ターミナルでログイン", small: true) { store.openLoginTerminal() }
            }
        case .waiting:
            noticeLine("hourglass", .warnInk,
                       "GitHub の1時間あたりの回数を使い切りました。\(store.waitUntil.map { Fmt.string($0, "H:mm") } ?? "1時間以内") に戻ります。"
                           + "そのあと自動で続きを取ります（抜けません）") {
                EmptyView()
            }
        case .partial:
            noticeLine("exclamationmark.circle", .warnInk, StatusCard.partialText(store)) {
                DadsButton(title: "リポジトリを見直す", small: true) { AppDelegate.shared?.openSetup() }
            }
        case .stale:
            noticeLine("clock.badge.exclamationmark", .warnInk,
                       "最後に取れたのは \(Fmt.relative(store.lastRead, now: store.now))。Mac が止まっていたか、このアプリが閉じていたかもしれません。次に取れば、その間の分もまとめて取ります（抜けません）") {
                EmptyView()
            }
        default:
            EmptyView()
        }
    }

    private func noticeLine<B: View>(_ icon: String, _ color: Color, _ text: String, @ViewBuilder button: () -> B) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(size: 12)).foregroundStyle(Color.ink2).lineLimit(2)
            Spacer()
            button()
        }
    }

    // ---- Mac のスリープ（あるときだけ。問題ではないので灰色で） ----
    @ViewBuilder private var sleepLine: some View {
        let notes = store.sleepNotesPage
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(notes, id: \.self) { t in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "moon").foregroundStyle(Color.ink2)
                        Text(t).font(.system(size: 12)).foregroundStyle(Color.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // ---- 既知の例外（あるときだけ。問題ではないので灰色で） ----
    @ViewBuilder private var exceptionsLine: some View {
        if let first = store.exceptionLines.first {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(Color.ink3)
                Text("既知の例外 \(store.exceptionLines.count)件（GitHub 側の食い違いで直しようがないもの。照合では NG にしない）: "
                     + store.readable(first.replacingOccurrences(of: "既知の例外: ", with: ""))
                     + (store.exceptionLines.count > 1 ? "（ほか \(store.exceptionLines.count - 1)件）" : ""))
                    .font(.system(size: 11)).foregroundStyle(Color.ink3).lineLimit(2)
                Spacer()
            }
        }
    }

    // ---- 4つの数字（マウスを乗せると説明） ----
    private var tiles: some View {
        HStack(spacing: 12) {
            Tile(label: "この7日に入ったもの", value: Fmt.number(store.last7),
                 note: "PR 経由 \(Fmt.number(store.last7PR))・直接 \(Fmt.number(store.last7 - store.last7PR))・前回から +\(Fmt.number(store.newSinceLast))")
                .hoverTip(forced: store.previewTip == "landed") { landedTip }
            Tile(label: "これから（開いている PR）", value: Fmt.number(store.openPRs),
                 note: "14日で動いた \(Fmt.number(store.openPRsActive))・issue \(Fmt.number(store.openIssues))（動いた \(Fmt.number(store.openIssuesActive))）")
                .hoverTip(forced: store.previewTip == "open") { openTip }
            // 確かめていないリポジトリがあれば、緑の「OK・抜けなし」にしない（設計書 5 章）
            Tile(label: "照合",
                 value: !store.ngLines.isEmpty ? "NG \(store.ngLines.count)件" : (store.unverified.isEmpty ? "OK" : "確かめていない"),
                 note: !store.ngLines.isEmpty ? "見出しの下に理由"
                     : (store.unverified.isEmpty ? "\((store.file.check?.items ?? []).count)項目すべて OK・抜けなし"
                        : "確かめていない所があります（\(store.unverified.count) リポジトリ）"),
                 valueColor: !store.ngLines.isEmpty ? .ngInk : (store.unverified.isEmpty ? .okInk : .warnInk))
                .hoverTip(alignTrailing: true, forced: store.previewTip == "check") { checkTip }
            Tile(label: "使った回数（今回）", value: "\(Fmt.number(store.file.run?.calls ?? 0)) 回",
                 note: "上限 \(store.callCap == 0 ? "なし" : Fmt.number(store.callCap))・枠の残り \(Fmt.number(store.file.run?.rate?.remaining ?? 0))")
                .hoverTip(alignTrailing: true, forced: store.previewTip == "calls") { callsTip }
        }
    }

    private var landedTip: some View {
        VStack(alignment: .leading, spacing: 8) {
            TipTitle(text: "リポジトリごとの、この7日に入ったもの")
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(["この7日", "PR 経由", "直接", "合計"], id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(Color.ink3) }
                }
                ForEach(store.repos.sorted { ($0.last7 ?? 0) > ($1.last7 ?? 0) }) { r in
                    GridRow {
                        Text("\(r.tag)  \(r.name)").lineLimit(1).frame(maxWidth: 280, alignment: .leading)
                        Text(Fmt.number(r.last7 ?? 0)).bold().monospacedDigit()
                        Text(Fmt.number(r.last7_pr ?? 0)).monospacedDigit()
                        Text(Fmt.number((r.last7 ?? 0) - (r.last7_pr ?? 0))).monospacedDigit()
                        Text(Fmt.number(r.total)).monospacedDigit().foregroundStyle(Color.ink2)
                    }
                }
                Divider().overlay(Color.line)
                GridRow {
                    Text("合計").bold()
                    Text(Fmt.number(store.last7)).bold().monospacedDigit()
                    Text(Fmt.number(store.last7PR)).monospacedDigit()
                    Text(Fmt.number(store.last7 - store.last7PR)).monospacedDigit()
                    Text(Fmt.number(store.totalLanded)).monospacedDigit().foregroundStyle(Color.ink2)
                }
            }
            Text("基準のブランチに入った時刻（日本時間の日）で数えています。PR 経由は PR の数（中のコミットの数ではありません）。直接はコミットの数（マージのコミットは数えません）。「合計」は取り始めた日から")
                .font(.system(size: 11)).foregroundStyle(Color.ink3).frame(width: 440, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var openTip: some View {
        let rows = store.repos.filter { ($0.open_prs ?? 0) + ($0.open_issues ?? 0) > 0 }
        return VStack(alignment: .leading, spacing: 8) {
            TipTitle(text: "開いている PR・issue（最後の取得の時点）")
            if rows.isEmpty {
                Text("開いている PR・issue はありません").foregroundStyle(Color.ink3)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        ForEach(["PR", "動いた", "issue", "動いた"], id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(Color.ink3) }
                    }
                    ForEach(rows) { r in
                        GridRow {
                            Text("\(r.tag)  \(r.name)").lineLimit(1).frame(maxWidth: 280, alignment: .leading)
                            Text(Fmt.number(r.open_prs ?? 0)).bold().monospacedDigit()
                            Text(Fmt.number(r.open_prs_active ?? 0)).monospacedDigit()
                            Text(Fmt.number(r.open_issues ?? 0)).bold().monospacedDigit()
                            Text(Fmt.number(r.open_issues_active ?? 0)).monospacedDigit()
                        }
                    }
                }
            }
            Text("「動いた」は、14日以内に更新があったもの。それより前から止まっているものは、数にだけ入れています（並べると、止まっているものに埋もれるため）")
                .font(.system(size: 11)).foregroundStyle(Color.ink3).frame(width: 400, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var checkTip: some View {
        VStack(alignment: .leading, spacing: 8) {
            TipTitle(text: "照合で確かめていること（\(Fmt.relative(store.lastRunEnd, now: store.now)) の取得のあと）")
            VStack(alignment: .leading, spacing: 7) {
                ForEach(store.file.check?.items ?? []) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: i.unverified ? "questionmark.circle.fill" : (i.ok ? "checkmark.circle.fill" : "xmark.circle.fill"))
                            .foregroundStyle(i.unverified ? Color.warnInk : (i.ok ? Color.okInk : Color.ngInk))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(i.name).bold()
                            Text(i.detail).font(.system(size: 11)).foregroundStyle(Color.ink2)
                                .frame(width: 380, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if (store.file.check?.items ?? []).isEmpty {
                    Text("次の取得のあとに、項目ごとの結果が出ます").foregroundStyle(Color.ink3)
                }
            }
            ForEach(store.file.check?.notes ?? [], id: \.self) {
                Text($0).font(.system(size: 11)).foregroundStyle(Color.ink3).frame(width: 400, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var callsTip: some View {
        let runs = store.monthRuns
        let byDay = Dictionary(grouping: runs) { e -> String in
            Fmt.parseISO(e.start).map { Fmt.string($0, "M/d（E）") } ?? "—"
        }
        let days = byDay.keys.sorted { a, b in
            (byDay[a]?.first.flatMap { Fmt.parseISO($0.start) } ?? .distantPast)
                > (byDay[b]?.first.flatMap { Fmt.parseISO($0.start) } ?? .distantPast)
        }
        return VStack(alignment: .leading, spacing: 8) {
            TipTitle(text: "今月の取得 \(runs.count)回・使った回数 \(Fmt.number(store.monthCalls)) 回")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                ForEach(days.prefix(10), id: \.self) { d in
                    GridRow {
                        Text(d)
                        Text("\(byDay[d]?.count ?? 0)回").foregroundStyle(Color.ink3).gridColumnAlignment(.trailing)
                        Text("\(Fmt.number(byDay[d]?.reduce(0) { $0 + ($1.calls ?? 0) } ?? 0)) 回")
                            .monospacedDigit().gridColumnAlignment(.trailing)
                    }
                }
            }
            Text("1回の取得で使ってよい回数: \(store.callCapText)（設定で変えられます）。GitHub の枠は1時間 5,000 回で、ほかの gh（Claude Code など）と分け合います。"
                 + "変わっていないものの問い合わせ（今回 \(Fmt.number(store.file.run?.calls_free ?? 0)) 回）は、回数を使わないので数えていません")
                .font(.system(size: 11)).foregroundStyle(Color.ink3).frame(width: 360, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StatusWindowView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var setup: Setup

    var body: some View {
        ScrollView { StatusContent() }
            .frame(minWidth: 980, minHeight: 640)
            .background(Color.white)
            .sheet(isPresented: $setup.show, onDismiss: {
                // 設定の窓から開いたときは、閉じたら設定の窓に戻す
                if setup.backToSettings {
                    setup.backToSettings = false
                    DispatchQueue.main.async { store.showSettings = true }
                }
            }) { SetupSheet().environmentObject(store).environmentObject(setup) }
            .onAppear {
                // 初めて開いたときは、窓が出る前に「準備の窓を出す」と決まっている。窓が出てから出し直す
                if setup.show {
                    setup.show = false
                    DispatchQueue.main.async { setup.show = true }
                }
            }
            // 窓ごと閉じたときに「準備の窓が開いたまま」と残ると、毎朝の自動取得が止まったままになる
            .onDisappear { setup.show = false }
    }
}

// MARK: - 確認用の画像

enum Snapshot {
    @MainActor
    static func run(dir: String) {
        SettingsSheet.maxGroupsHeight = nil   // 確認用の画像では、設定の窓を画面の高さで切らない
        // 本物の設定と、本物の取ったデータは読まない（-dataDir を渡されたときだけ、そのデータで描く）
        Paths.defaults = MemoryStore()
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("github-fetch-snapshot-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? fm.removeItem(at: work) }
        let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if args["dataDir"] == nil {
            Paths.dataOverride = work.appendingPathComponent(Paths.dataFolderName)
            Paths.displayHome = work.path   // 画像の中の場所は ~/GitHub取得データ・~/github-fetch のように出す
        }
        // -dataDir・-baseDir で渡した作り物のフォルダも、画像の中では本物の置き場所の名前で出す（作業用の長い名前を写さない）
        Paths.displayAliases = [(Paths.data.path, "~/" + Paths.dataFolderName)]
        if let b = args["baseDir"] as? String, !b.isEmpty { Paths.displayAliases.append((b, "~/github-fetch")) }
        defer { Paths.displayHome = nil; Paths.displayAliases = [] }
        let states: [(String, DisplayState)] = [("ok", .ok), ("running", .running), ("ng", .ng), ("failed", .failed), ("filling", .filling),
                                                ("stale", .stale), ("fresh", .fresh), ("login", .login),
                                                ("waiting", .waiting), ("partial", .partial)]
        for (name, st) in states {
            let store = Store(live: false)
            prepare(store, st)
            render(PopoverView().environmentObject(store), to: "\(dir)/menu_\(name).png", width: 380)
            if st != .ok {
                render(StatusContent().environmentObject(store), to: "\(dir)/window_\(name).png", width: 1000)
            }
        }
        render(StatusContent().environmentObject(Store(live: false)), to: "\(dir)/window.png", width: 1000)
        // まだ準備もしていないとき（取るリポジトリが無い。はじめの準備へ案内する）
        let unset = Store(live: false)
        prepare(unset, .fresh)
        unset.configured = false
        render(PopoverView().environmentObject(unset), to: "\(dir)/menu_fresh_unset.png", width: 380)
        render(StatusContent().environmentObject(unset), to: "\(dir)/window_fresh_unset.png", width: 1000)
        // 取れなかった（ネットワーク）。途中で止まった（1回の上限）とは見出しが違う
        let net = Store(live: false)
        prepare(net, .failed)
        net.file.state = "error"
        net.file.run?.note = "GitHub につながりませんでした。ネットにつながっているかを確かめてください"
        net.file.run?.calls = 12
        render(PopoverView().environmentObject(net), to: "\(dir)/menu_failed_network.png", width: 380)
        render(StatusContent().environmentObject(net), to: "\(dir)/window_failed_network.png", width: 1000)
        // Mac のスリープ（Slack 取得と同じ場面）
        let cal = Calendar.current
        let at = { (h: Int, m: Int) in cal.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date() }
        let slept = Store(live: false)
        prepare(slept, .ok)
        slept.file.run?.start = Fmt.iso.string(from: at(9, 0))
        slept.file.run?.end = Fmt.iso.string(from: at(9, 41))
        slept.file.run?.sleep = SleepInfo(count: 1, seconds: 2340, spans: [[Fmt.iso.string(from: at(9, 1)), Fmt.iso.string(from: at(9, 40))]])
        render(PopoverView().environmentObject(slept), to: "\(dir)/menu_ok_sleep.png", width: 380)
        let missed = Store(live: false)
        prepare(missed, .failed)
        missed.file.state = "error"
        missed.file.run?.start = Fmt.iso.string(from: at(9, 1))
        missed.file.run?.end = Fmt.iso.string(from: at(12, 5))
        missed.file.run?.note = "GitHub につながりませんでした（Mac がスリープしていた）"
        missed.file.run?.sleep = SleepInfo(count: 1, seconds: 10980, spans: [[Fmt.iso.string(from: at(9, 2)), Fmt.iso.string(from: at(12, 5))]])
        missed.file.run?.sleep_missed = true
        render(PopoverView().environmentObject(missed), to: "\(dir)/menu_sleep_missed.png", width: 380)
        render(StatusContent().environmentObject(missed), to: "\(dir)/window_sleep_missed.png", width: 1000)
        // 説明の札（タイルにマウスを乗せたとき）
        for tip in ["landed", "open", "check", "calls"] {
            let s = Store(live: false)
            s.previewTip = tip
            render(StatusContent().environmentObject(s), to: "\(dir)/window_tip_\(tip).png", width: 1000)
        }
        // 照合の札（最初の取得の途中で、確かめていない所があるとき）
        let unv = Store(live: false)
        prepare(unv, .filling)
        unv.previewTip = "check"
        render(StatusContent().environmentObject(unv), to: "\(dir)/window_tip_check_unverified.png", width: 1000)
        // 棒にマウスを乗せたとき・取得の記録を全部開いたとき
        let s = Store(live: false)
        s.previewBar = (s.file.daily ?? []).dropLast(2).last.flatMap { Fmt.parseJST($0.date + " 12:00:00") }.map { Fmt.string($0, "M/d") }
        s.previewExpanded = true
        s.previewWeekBar = (s.repos.first?.week ?? []).dropLast(1).last.flatMap { Fmt.parseJST($0.date + " 12:00:00") }
            .map { Fmt.string($0, "M/d") }
        render(StatusContent().environmentObject(s), to: "\(dir)/window_hover_chart_history.png", width: 1000)
        render(SettingsSheet().environmentObject(Store(live: false)), to: "\(dir)/settings.png", width: 580)
        // 設定の窓は、選択の欄（時刻・回数の上限）も写るように本物の窓として描く
        renderWindow(SettingsSheet().environmentObject(Store(live: false)), to: "\(dir)/settings_window.png")
        SetupSnapshot.run(dir: dir)
    }

    @MainActor
    static func prepare(_ store: Store, _ st: DisplayState) {
        store.forced = st
        switch st {
        case .running:
            store.running = true   // 見出しのボタンも、取得中の形（「取得中…」と「止める」）で写す
            store.file.state = "running"
            let seventh = store.repos.dropFirst(6).first?.tag
            store.file.run = RunInfo(start: Fmt.iso.string(from: Date().addingTimeInterval(-72)), calls: 85,
                                     progress: ProgressInfo(done: 6, total: max(store.repos.count, 1), tag: seventh))
        case .ng:
            let r = store.repos.first
            store.file.state = "ng"
            store.file.check?.ng = ["NG 件数が合わない: \(r?.tag ?? "音声")の PR が GitHub 118 / 取れた 117"]
            if let i = store.file.check?.items?.firstIndex(where: { $0.name == "件数の突き合わせ" }) {
                store.file.check?.items?[i].ok = false
                store.file.check?.items?[i].detail = "PR の数が合わない（\(r?.tag ?? "音声")）: GitHub 118 / 取れた 117。次の取得で、そのリポジトリの PR を全部取り直します"
            }
        case .failed:
            store.file.state = "stopped"
            store.file.run?.result = "stopped"
            store.file.run?.note = "1回の上限（1,500 回）に届きました"
            store.file.run?.calls = 1500
        case .filling:
            store.file.state = "stopped"
            store.file.run?.result = "stopped"
            store.file.run?.note = "1回の上限（1,500 回）に届いた"
            store.file.run?.calls = 1500
            store.file.run?.first_partial = true
            if let i = store.file.repos?.firstIndex(where: { _ in true }) {
                let tag = store.file.repos?[i].tag ?? "音声"
                let why = "最初の取得の途中・PR 1,061 / 1,527 件まで"
                store.file.repos?[i].complete = false
                store.file.repos?[i].pending = why
                store.file.check?.unverified = [UnverifiedRepo(repo: tag, reason: why)]
                for j in (store.file.check?.items ?? []).indices {
                    store.file.check?.items?[j].ok = false
                    store.file.check?.items?[j].state = "unverified"
                    store.file.check?.items?[j].detail = "確かめていない: \(tag)（\(why)）"
                }
            }
        case .stale:
            store.file.last_read = Fmt.iso.string(from: Date().addingTimeInterval(-2 * 86400 - 3600))
            store.file.last_success = Fmt.iso.string(from: Date().addingTimeInterval(-2 * 86400 - 3600))
        case .fresh:
            store.file = StateFile()
            store.history = []
        case .login:
            store.file.state = "login"
            store.file.run?.result = "login"
            store.file.run?.note = "GitHub のログインが切れていた"
            store.file.run?.calls = 1
            store.file.auth?.ok = false
        case .waiting:
            store.file.state = "waiting"
            store.file.run?.result = "waiting"
            store.file.run?.calls = 820
            store.file.run?.rate = RateInfo(limit: 5000, remaining: 0, reset: nil)
            let back = Date().addingTimeInterval(38 * 60)
            store.file.run?.wait_until = Fmt.iso.string(from: back)
            store.file.run?.rate?.reset = Fmt.iso.string(from: back)
        case .partial:
            store.file.state = "partial"
            store.file.run?.result = "partial"
            if let i = store.file.repos?.lastIndex(where: { _ in true }) {
                store.file.repos?[i].error = "見えません（権限が無いか、名前が変わったのかもしれません）"
                store.file.repos?[i].error_kind = "not_found"
                store.file.repos?[i].fetched = Fmt.iso.string(from: Date().addingTimeInterval(-2 * 86400 - 3 * 3600))
                store.file.run?.repos_failed = [store.file.repos?[i].tag ?? ""]
            }
        case .ok:
            break
        }
    }

    @MainActor
    static func render<V: View>(_ view: V, to path: String, width: CGFloat, scale: CGFloat = 2) {
        let r = ImageRenderer(content: view.frame(width: width))
        r.scale = scale
        r.proposedSize = ProposedViewSize(width: width, height: nil)
        guard let image = r.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("画像にできませんでした: \(path)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("書き出し: \(path)")
    }

    /// 本物の窓として描く（render では黄色い四角になる、選択の欄や入力欄も写る）
    @MainActor
    static func renderWindow<V: View>(_ view: V, to path: String) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        // 描いたあとに大きさが変わるもの（画面に収まらないときのスクロールなど）は、測り直して描き直す
        let size2 = host.fittingSize
        if size2 != size {
            window.setContentSize(size2)
            host.frame = NSRect(origin: .zero, size: size2)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("画像にできませんでした: \(path)")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("画像にできませんでした: \(path)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("書き出し: \(path)")
    }
}

// MARK: - 確かめ用: フォルダを追いかける仕組み

enum BaseTest {
    /// 一時フォルダで「覚える → 動かす・名前を変える → 追いかける」「ゴミ箱 → 見つからない」などを試す。本物の設定は触らない
    @MainActor
    static func run() -> Int32 {
        Paths.defaults = MemoryStore()   // 本物の設定（と設定のファイル）は触らない
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("github-fetch-test-\(ProcessInfo.processInfo.processIdentifier)")
        Paths.dataOverride = root.appendingPathComponent(Paths.dataFolderName)   // 本物の取ったデータも触らない
        defer { try? fm.removeItem(at: root) }
        var ng = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "OK  " : "NG  ") + name); if !ok { ng += 1 } }
        func same(_ a: URL?, _ b: URL) -> Bool { a?.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path }
        func make(_ u: URL, _ files: [String] = Paths.required) throws {
            try fm.createDirectory(at: u, withIntermediateDirectories: true)
            for f in files { fm.createFile(atPath: u.appendingPathComponent(f).path, contents: Data()) }
        }
        let find = { Paths.resolve(builtIn: false) }
        do {
            let a = root.appendingPathComponent("A/github-fetch")
            try make(a)
            Paths.remember(a)
            if case .same(let u) = find() { check("覚えた場所で見つかる", same(u, a)) } else { check("覚えた場所で見つかる", false) }

            let b = root.appendingPathComponent("B")
            try fm.createDirectory(at: b, withIntermediateDirectories: true)
            try fm.moveItem(at: a, to: b.appendingPathComponent("github-fetch"))
            let a2 = b.appendingPathComponent("github-fetch")
            if case .moved(_, let u) = find() { check("フォルダを動かしても追いかけて、知らせる", same(u, a2)) }
            else { check("フォルダを動かしても追いかけて、知らせる", false) }
            if case .same(let u) = find() { check("追いかけたあとは、新しい場所を覚えている", same(u, a2)) }
            else { check("追いかけたあとは、新しい場所を覚えている", false) }

            let a3 = b.appendingPathComponent("github-fetch-名前を変えた")
            try fm.moveItem(at: a2, to: a3)
            if case .moved(_, let u) = find() { check("フォルダの名前を変えても追いかける", same(u, a3)) }
            else { check("フォルダの名前を変えても追いかける", false) }

            let trash = root.appendingPathComponent(".Trash")
            try fm.createDirectory(at: trash, withIntermediateDirectories: true)
            try fm.moveItem(at: a3, to: trash.appendingPathComponent("github-fetch"))
            if case .missing = find() { check("ゴミ箱に入れたら「見つからない」になる", true) }
            else { check("ゴミ箱に入れたら「見つからない」になる", false) }

            let c = root.appendingPathComponent("C/github-fetch")
            try make(c, ["README.md"])
            check("github.py の無いフォルダは選べない", Paths.findInside(root.appendingPathComponent("C")) == nil)

            let e = root.appendingPathComponent("E/作業/github-fetch")
            try make(e)
            check("1つ上のフォルダを選んでも、中から見つける", same(Paths.findInside(root.appendingPathComponent("E")), e))

            Paths.remember(e)
            try fm.removeItem(at: root.appendingPathComponent("E"))
            if case .missing(let last) = find() { check("消したら「見つからない」になり、前の場所を言える", last == e.path) }
            else { check("消したら「見つからない」になり、前の場所を言える", false) }

            // 新しい版に入れ替えたとき（データはフォルダの外なので、探すのは台本の場所だけ。古い台本は動かさない）
            let f = root.appendingPathComponent("F/github-fetch")
            try make(f)
            Paths.remember(f)
            try fm.moveItem(at: f, to: root.appendingPathComponent("F/github-fetch-古い版"))
            try make(f)
            let sameNew = "同じ場所に新しい版を置けば、古いほうの名前を変えて残していても、新しい版を使う"
            if case .same(let u) = find() { check(sameNew, same(u, f)) } else { check(sameNew, false) }

            let g1 = root.appendingPathComponent("G/前の版/github-fetch"), g2 = root.appendingPathComponent("G/新しい版/github-fetch")
            try make(g1)
            try make(g2)
            Paths.defaults.set(g1.path, forKey: "builtDirSeen")   // 前の版は g1 で組み立てて使っていた
            Paths.remember(g1)
            let rebuilt = "別の場所で組み立て直したら、そちら（新しい版）を使う（知らせは出さない）"
            if case .same(let u) = Paths.resolve(built: g2) { check(rebuilt, same(u, g2)) } else { check(rebuilt, false) }
            Paths.remember(g1)   // 設定の「変更…」で前の場所を選び直した
            let picked = "同じ組み立てのまま、設定で選び直した場所はそのまま使う"
            if case .same(let u) = Paths.resolve(built: g2) { check(picked, same(u, g1)) } else { check(picked, false) }
            Paths.current = nil
        } catch {
            print("NG  準備で失敗: \(error)")
            ng += 1
        }
        print(ng == 0 ? "すべて期待どおりです" : "\(ng) 件おかしい")
        return ng == 0 ? 0 : 1
    }
}

// MARK: - 確かめ用: グラフのマウスの位置

enum ChartTest {
    /// 日が 1 つも無いグラフと、日のあるグラフで、マウスの位置を聞く所（hoveredDay）を試す。画面の外の窓で描くので、何も出ない。
    /// 日が無いときに Swift Charts へ聞いてしまうと、この試しごと落ちる（2026-10-20 に別の PC で落ちた形）
    @MainActor
    static func run() -> Int32 {
        _ = NSApplication.shared
        var ng = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "OK  " : "NG  ") + name); if !ok { ng += 1 } }
        // 状況ページのグラフと同じ形（横軸は日の文字で、並びを決めて渡す）。目盛りを隠して、1 日を幅 100 にする
        func ask(_ days: [String], at xs: [CGFloat]) -> [String?]? {
            var got: [String?]?
            let chart = Chart {
                ForEach(days, id: \.self) { d in BarMark(x: .value("日", d), y: .value("数", 1)) }
            }
            .chartXScale(domain: days)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartOverlay { proxy in
                Color.clear.onAppear { got = xs.map { hoveredDay(proxy, x: $0, days: days.count) } }
            }
            .frame(width: 300, height: 120)
            let host = NSHostingView(rootView: chart)
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 300, height: 120), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            return got
        }
        let none = ask([], at: [-10, 0, 150, 400])
        check("日が 1 つも無いグラフ: 落ちずに、どこにマウスを乗せても「無し」", none.map { $0.allSatisfy { $0 == nil } } ?? false)
        let three = ask(["10/1", "10/2", "10/3"], at: [50, 150, 250, -1000, 10000])
        check("日が 3 つのグラフ: マウスの下の日を返す", three.map { Array($0.prefix(3)) == ["10/1", "10/2", "10/3"] } ?? false)
        check("日が 3 つのグラフ: グラフの外は「無し」", three.map { $0.suffix(2).allSatisfy { $0 == nil } } ?? false)
        print(ng == 0 ? "すべて期待どおりです" : "\(ng) 件おかしい")
        return ng == 0 ? 0 : 1
    }
}

// MARK: - アイコン（Dock と Finder 用）

/// Apple の記号（SF Symbols）はアプリのアイコンに使えない決まりなので、図形だけで描く。
/// Slack 取得と同じ組み立て（白い札の中に、下向きの矢印と受け皿＝手元にためる）。見分けやすいよう緑にし、札の下に
/// コミットの点と線を付ける
struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x259D63), Color(hex: 0x115A36)], startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
            RoundedRectangle(cornerRadius: 96, style: .continuous).fill(.white)
                .frame(width: 560, height: 430).offset(y: -50)
            IconArrow().fill(Color.okInk).frame(width: 240, height: 230).offset(y: -90)
            Capsule().fill(Color.okInk).frame(width: 260, height: 40).offset(y: 62)
            // コミットの点と線（札から離して、札の下に）
            Path { p in
                p.move(to: CGPoint(x: 352, y: 776))
                p.addLine(to: CGPoint(x: 672, y: 776))
            }
            .stroke(.white, style: StrokeStyle(lineWidth: 24, lineCap: .round))
            Circle().fill(.white).frame(width: 84, height: 84).position(x: 352, y: 776)
            Circle().fill(.white).frame(width: 84, height: 84).position(x: 512, y: 776)
            Circle().fill(.white).frame(width: 84, height: 84).position(x: 672, y: 776)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// 下向きの矢印（軸と矢じりを1つの多角形で）
struct IconArrow: Shape {
    func path(in r: CGRect) -> Path {
        let stem = r.width * 0.36
        let headTop = r.minY + r.height * 0.45
        var p = Path()
        p.move(to: CGPoint(x: r.midX - stem / 2, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX + stem / 2, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX + stem / 2, y: headTop))
        p.addLine(to: CGPoint(x: r.maxX, y: headTop))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: headTop))
        p.addLine(to: CGPoint(x: r.midX - stem / 2, y: headTop))
        p.closeSubpath()
        return p
    }
}

// MARK: - アプリ

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?
    let store: Store
    private var statusWindow: NSWindow?
    private var launchedAtLogin = false

    override init() {
        store = Store(live: !CommandLine.arguments.contains("--snapshot") && !CommandLine.arguments.contains("--icon")
                      && !CommandLine.arguments.contains("--test-base") && !CommandLine.arguments.contains("--test-setup")
                      && !CommandLine.arguments.contains("--test-chart"))
        super.init()
        AppDelegate.shared = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Mac の起動時に自動で開かれたのか、自分で開いたのか（自分で開いたときだけ状況ページを出す）
        if let ev = NSAppleEventManager.shared().currentAppleEvent,
           ev.eventID == AEEventID(kAEOpenApplication),
           ev.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            launchedAtLogin = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        applyDockSetting()
        // はじめの準備が済んでいなければ、Mac の起動時に開かれたときも出す
        if !launchedAtLogin || store.setup.show { showStatus() }
    }

    // Dock のアイコンを押したとき・Finder でもう一度開いたとき
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStatus()
        return true
    }

    func applyDockSetting() {
        NSApp.setActivationPolicy(store.showInDock ? .regular : .accessory)
    }

    /// はじめの準備（GitHub とリポジトリ）の窓を、状況ページの上に開く。設定から開いたときは、閉じたら設定に戻す
    func openSetup(backToSettings: Bool = false) {
        showStatus()
        store.setup.backToSettings = backToSettings
        store.setup.open()
    }

    func showStatus() {
        if statusWindow == nil {
            let host = NSHostingController(rootView: StatusWindowView().environmentObject(store).environmentObject(store.setup))
            host.sizingOptions = [.minSize]
            let w = NSWindow(contentViewController: host)
            w.title = "GitHub 取得 — 状況"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 980, height: 880))
            w.center()
            statusWindow = w
        }
        statusWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuIconLabel: View {
    @ObservedObject var store: Store
    var body: some View {
        if #available(macOS 15.0, *), store.display == .running {
            Image(systemName: "arrow.triangle.2.circlepath").symbolEffect(.rotate, options: .repeating)
        } else {
            MenuIcon(state: store.display)
        }
    }
}

@main
struct GitHubFetchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.run(dir: args[i + 1])
            exit(0)
        }
        if args.contains("--test-base") {
            exit(BaseTest.run())
        }
        if args.contains("--test-setup") {
            exit(SetupTest.run())
        }
        if args.contains("--test-chart") {
            exit(ChartTest.run())
        }
        if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
            Snapshot.render(AppIconView(), to: args[i + 1], width: 1024, scale: 1)
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(delegate.store)
        } label: {
            MenuIconLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}
