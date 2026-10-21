// はじめの準備（① GitHub にログイン → ② 取るリポジトリを選ぶ → ③ 取得を始める）
//
// - Slack 取得の Setup.swift を手本に、GitHub 向けに書き直したもの。部品（チェック・リンク・知らせの箱・番号つきの行）は同じ
// - 初めて開いたとき（GitHub取得データ/リポジトリ.json が無いとき）に、状況ページの上に出す。設定とメニューからも開ける。
//   準備が済んでいれば、題は「GitHub とリポジトリ」で、リポジトリの画面から始まる
// - 「ログインを確かめる」「owner/name で探す」「見込みを調べる」は、このアプリが github.py setup を動かす（gh の読み取りだけ）。
//   結果は GitHub取得データ/リポジトリ候補.json に書かれ、ここで読む
// - ログインそのもの（gh auth login）は、ターミナルの窓を開いて本人に渡す（Store.openLoginTerminal）
// - リンクは、build.sh がアプリに入れた links.json（もとは アプリ/リンク.json）から読む。変わったら直して組み立て直す

import AppKit
import SwiftUI

// MARK: - リンク

struct Links {
    var ghInstall: URL
    var ghLogin: URL
    var sso: URL
    var authorized: URL
    var rateLimit: URL
    var checked: String

    /// アプリに入っている links.json。読めなければ、どれも gh のページにする
    static let shared: Links = {
        let fallback = URL(string: "https://cli.github.com/")!
        var d: [String: Any] = [:]
        if let url = Bundle.main.url(forResource: "links", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            d = obj
        }
        func u(_ key: String) -> URL { (d[key] as? String).flatMap(URL.init(string:)) ?? fallback }
        return Links(ghInstall: u("gh_install"), ghLogin: u("gh_login"), sso: u("sso"), authorized: u("authorized_apps"),
                     rateLimit: u("rate_limit"), checked: d["checked"] as? String ?? "")
    }()
}

// MARK: - データ（GitHub取得データ/リポジトリ候補.json・リポジトリ.json）

/// gh のログインを確かめた結果
struct LoginInfo: Codable {
    var ok: Bool?
    var login: String?
    var gh: String?        // gh の版
    var error: String?     // 平易な1行（gh が無い・ログインしていない・切れている）
    var at: String?
}

/// 基準のブランチの提案（既定のブランチが止まっていて、別のブランチで動いているとき）
struct BaseHint: Codable {
    var suggested: String?          // 提案するブランチ
    var default_quiet_since: String? // 既定のブランチに最後に入った日（yyyy-MM-dd）
    var pushes30: Int?              // 提案するブランチに、この30日に入った回数
}

/// 最初の取得の見込みの回数（全部・90日前から）
struct Estimate: Codable {
    var all: Int?
    var days90: Int?
}

struct RepoCandidate: Codable, Identifiable {
    var id: Int
    var name: String               // owner/name
    var isPrivate: Bool?
    var archived: Bool?
    var fork: Bool?
    var default_branch: String?
    var branches: [String]?
    var created: String?           // 作った日（yyyy-MM-dd）
    var pushed: String?            // 最後に push された時刻（ISO）
    var description: String?       // 他人が書いた文字列（1行に畳んで出す）
    var prs: Int?
    var issues: Int?
    var commits: Int?
    var hint: BaseHint?
    var estimate: Estimate?
    enum CodingKeys: String, CodingKey {
        case id, name, archived, fork, default_branch, branches, created, pushed, description, prs, issues, commits, hint, estimate
        case isPrivate = "private"
    }
}

/// github.py setup の最後の結果
struct SetupStatus: Codable {
    var mode: String?
    var query: String?
    var at: String?
    var ok: Bool?
    var found: Int?
    var error: String?
}

struct CandidateFile: Codable {
    var updated: String?
    var login: LoginInfo?
    var last: SetupStatus?
    var repos: [RepoCandidate]?
}

/// リポジトリ.json の1行（設計書.md の 3.6）
struct StageConfig: Codable {
    var name: String
    var branch: String
}

struct RepoConfig: Codable {
    var id: Int
    var name: String
    var tag: String
    var base: String
    var stages: [StageConfig]?
    var from: String
    var added: String?
}

/// GitHub取得データ/外したリポジトリ.json の1行。一覧から外したリポジトリの呼び名・基準・取り始める日を覚えておき、付け直したときに戻す
struct ShelvedRepo: Codable {
    var id: Int
    var name: String
    var tag: String
    var base: String
    var from: String
    var removed_at: String?
}

/// 選んだリポジトリ（保存する前）
struct PickedRepo: Identifiable {
    enum From: Hashable { case created, days90, manual, saved, previous }
    var id: Int
    var name: String
    var isPrivate: Bool
    var tag: String
    var base: String
    var branches: [String]
    var created: Date?
    var from: Date?
    var fromKind: From
    var estimate: Estimate?
    var hint: BaseHint?
    var stages: [StageConfig] = []

    /// いまの取り始める日での、最初の取得の見込みの回数
    var estimateNow: Int? {
        switch fromKind {
        case .created: return estimate?.all
        case .days90: return estimate?.days90
        default: return nil
        }
    }
    /// 既定のブランチが止まっていて、別のブランチを勧めている（まだそのブランチにしていない）
    var baseWarning: Bool {
        guard let s = hint?.suggested else { return false }
        return s != base
    }
}

// MARK: - 状態と操作

@MainActor
final class Setup: ObservableObject {
    enum Conn: Equatable { case unknown, checking, ok, failed(String) }

    @Published var show = false
    @Published var step = 1
    @Published var conn: Conn = .unknown
    @Published var openedTerminal = false   // 「ターミナルでログインを始める」を押したか（押したら「確かめる」を目立たせる）
    /// 初めての準備か（開いたときに、保存してあるリポジトリが無かった）。準備済みなら「GitHub とリポジトリ」の窓として出す
    @Published var firstTime = true
    @Published var confirmClose = false   // 保存していない変更があるのに閉じようとした（聞く）
    @Published var helpOpen = false       // ①の「うまくいかないとき」を開いているか
    /// 設定の窓から開いたか（閉じたら設定の窓に戻す）
    var backToSettings = false
    @Published var query = ""
    @Published var listOpen = true
    @Published var searchingFor: String?
    @Published var inspecting: Set<Int> = []   // 見込みを調べているリポジトリ
    @Published var note: String?
    @Published var noteIsError = false
    @Published var candidates: [RepoCandidate] = []
    @Published var picked: [PickedRepo] = []
    @Published var problem: String?
    @Published var login: LoginInfo?
    /// 保存したときに、前の一覧から足した・外した・付け直したリポジトリ（③で伝える）
    @Published var added: [String] = []
    @Published var removed: [String] = []
    @Published var reattached: [String] = []
    /// 窓を開いたときに保存してあった一覧（✗ で外したものを戻す・変更を捨てるのに使う）
    @Published var savedAtOpen: [RepoConfig] = []
    /// 前に取っていたリポジトリ（外したリポジトリ.json）
    @Published var shelved: [ShelvedRepo] = []
    /// 保存したあとに呼ぶ（状況ページを数え直す。Store が決める）
    var onSaved: (() -> Void)?
    private var lastStatus: SetupStatus?
    private var process: Process?
    /// 動いている準備の処理のあとに、順番を待っているもの。準備の処理（--login・--find・--inspect）は 1 つずつ動かす。
    /// どれも候補のファイルを最初に読んで最後に書くので、2 つ同時に動くと後から書いた方が残り、先の結果が消える（設計書 4.9・10/21）
    private var waiting: [(args: [String], done: (Outcome) -> Void)] = []
    /// 一度調べたリポジトリ（調べても見込みが届かなかったものを、続けて調べ直し続けないため）
    private var inspectTried: Set<Int> = []
    /// 準備の処理が動いているか（自己試験が、全部終わるまで待つのに使う）
    var helperRunning: Bool { process != nil || !waiting.isEmpty }
    /// 選んだリポジトリの見込みの言葉。見込みを調べたが届かなかったものは、そう言う（1 度調べたものは自分からは
    /// 調べ直さず、保存しても調べない。チェックを付け直すと調べ直す。設計書 4.9・Y-7。前は「見込みは保存のあとに」）
    func estimateLabel(_ p: PickedRepo) -> String {
        if inspecting.contains(p.id) { return "見込みを調べています…" }
        if p.estimateNow == nil && inspectTried.contains(p.id) {
            return "見込みを調べられませんでした（チェックを付け直すと、もう一度調べます）"
        }
        return Setup.estimateText(p.estimateNow)
    }

    var busy: Bool { conn == .checking || searchingFor != nil }

    /// 入れた言葉（前後の空白を除く）
    var queryText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// owner/name の形か（GitHub で探せるのは、この形のときだけ）
    var queryIsFullName: Bool {
        let p = queryText.split(separator: "/")
        return p.count == 2 && !p[0].isEmpty && !p[1].isEmpty && !queryText.contains(" ")
    }

    /// 候補を、入れた言葉で絞り込む（名前か説明に含むもの）。アーカイブ済みとフォークは後ろへ、ほかは最後の push が新しい順
    var filtered: [RepoCandidate] {
        let q = queryText
        return candidates
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || ($0.description ?? "").localizedCaseInsensitiveContains(q) }
            .sorted { a, b in
                let ra = (a.archived == true || a.fork == true) ? 1 : 0, rb = (b.archived == true || b.fork == true) ? 1 : 0
                if ra != rb { return ra < rb }
                return (Fmt.parseISO(a.pushed) ?? .distantPast) > (Fmt.parseISO(b.pushed) ?? .distantPast)
            }
    }

    /// 開く。すでに保存してあるリポジトリは、選んだ状態から始める
    func open() {
        loadCandidates()
        shelved = Setup.shelvedRepos()
        let saved = Setup.savedRepos()
        // 開くたびに、保存してある一覧から始める（保存していない変更は持ち越さない）。
        // まだ何も保存していない（はじめの準備の途中）ときだけ、選びかけの一覧を残す
        if !show && (!saved.isEmpty || picked.isEmpty) {
            savedAtOpen = saved
            picked = saved.map(asPicked)
        }
        if conn == .unknown && login?.ok == true { conn = .ok }
        if !show {
            firstTime = saved.isEmpty
            step = saved.isEmpty && conn != .ok ? 1 : 2
            confirmClose = false
        }
        problem = nil
        show = true
    }

    func go(_ n: Int) {
        guard !busy, n == 1 || n == 2 else { return }   // ③ へは「保存して次へ」からだけ進む
        step = n
    }

    func loadCandidates() {
        guard let data = try? Data(contentsOf: Paths.candidates),
              let f = try? JSONDecoder().decode(CandidateFile.self, from: data) else { return }
        candidates = f.repos ?? []
        lastStatus = f.last
        login = f.login
        // 調べ終えた見込みを、選んだ一覧にも入れる
        for i in picked.indices {
            if let c = candidates.first(where: { $0.id == picked[i].id }) {
                let arrived = picked[i].estimate == nil && c.estimate != nil
                picked[i].estimate = picked[i].estimate ?? c.estimate
                // 見込みはチェックのあとで届く。届いたときに、人がまだ取り始める日を変えていなければ、
                // 大きいリポジトリは「90日前から」に選び直す（設計書 4.9。前は、届く前にしか選ばなかった）
                if arrived, picked[i].fromKind == .created, let all = c.estimate?.all, all > Setup.callCap {
                    picked[i].fromKind = .days90
                    picked[i].from = Calendar.current.date(byAdding: .day, value: -90, to: Date())
                }
                picked[i].hint = picked[i].hint ?? c.hint
                if picked[i].branches.count <= 1, let b = c.branches, !b.isEmpty { picked[i].branches = b }
            }
        }
    }

    static func savedRepos() -> [RepoConfig] {
        guard let data = try? Data(contentsOf: Paths.repos) else { return [] }
        return (try? JSONDecoder().decode([RepoConfig].self, from: data)) ?? []
    }

    static func shelvedRepos() -> [ShelvedRepo] {
        guard let data = try? Data(contentsOf: Paths.shelved) else { return [] }
        return (try? JSONDecoder().decode([ShelvedRepo].self, from: data)) ?? []
    }

    // ---- github.py setup を動かす ----

    private enum Outcome { case finished(SetupStatus?), cannotRun(String) }

    /// 終わったら done を呼ぶ。finished には、今回書かれた結果だけを渡す（前の回の結果は渡さない）。
    /// ほかの準備の処理が動いていれば、順番を待つ（1 つずつ動かす）
    private func runHelper(_ args: [String], done: @escaping (Outcome) -> Void) {
        guard process == nil else {
            waiting.append((args, done))
            return
        }
        startHelper(args, done: done)
    }

    private func startHelper(_ args: [String], done: @escaping (Outcome) -> Void) {
        guard FileManager.default.fileExists(atPath: Paths.script.path) else {
            done(.cannotRun("取得の仕組みのフォルダに github.py が見つかりません。設定（歯車）でフォルダを選び直してください。"))
            nextHelper()
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [Paths.script.path, "setup"] + args
        p.currentDirectoryURL = Paths.base
        p.environment = Store.scriptEnvironment()
        if let h = Store.appLog("はじめの準備 " + args.joined(separator: " ")) {
            p.standardOutput = h
            p.standardError = h
        }
        let started = Date().addingTimeInterval(-1)   // 書かれる時刻は秒までなので、1秒ゆとりを見る
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                self.loadCandidates()
                let fresh = (Fmt.parseISO(self.lastStatus?.at) ?? .distantPast) >= started
                done(.finished(fresh ? self.lastStatus : nil))
                self.nextHelper()
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            done(.cannotRun("準備の台本を動かせませんでした: \(error.localizedDescription)"))
            nextHelper()
        }
    }

    /// 順番を待っている処理を動かす。無ければ、見込みがまだ無い選んだリポジトリを調べる
    /// （調べている数秒の間に付けた 2 つ目も調べる。前は調べず、大きいリポジトリでも「作った日から」のまま残った。W-1）
    private func nextHelper() {
        guard process == nil else { return }
        if !waiting.isEmpty {
            let w = waiting.removeFirst()
            startHelper(w.args, done: w.done)
            return
        }
        let need = picked.first { p in
            p.fromKind != .saved && !inspecting.contains(p.id) && !inspectTried.contains(p.id)
                && candidates.contains { $0.id == p.id && ($0.estimate == nil || $0.hint == nil) }
        }
        if let p = need { inspect(p.id) }
    }

    /// 「ログインを確かめる」: gh が入っているか・ログインしているか・本当に読めるかを確かめ、見えるリポジトリの一覧を読む
    func checkLogin() {
        guard !busy else { return }
        conn = .checking
        note = nil
        runHelper(["--login"]) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .cannotRun(let why):
                self.conn = .failed(why)
                self.helpOpen = true
            case .finished(nil):
                self.conn = .failed("うまく確かめられませんでした。取得ログの「アプリから動かした記録」を見てください。")
                self.helpOpen = true
            case .finished(let st?):
                guard st.ok == true, self.login?.ok == true else {
                    self.conn = .failed(self.login?.error ?? st.error ?? "うまく確かめられませんでした。")
                    self.helpOpen = true
                    return
                }
                self.conn = .ok
                let n = st.found ?? self.candidates.count
                self.setNote("\(self.login?.login ?? "") でログインしています。見えるリポジトリを \(n)件 読みました。", error: false)
                if self.firstTime { self.step = 2 }
            }
        }
    }

    /// 「GitHub で探す」（Enter）: owner/name のリポジトリを1つ調べて、候補に足す（ほかの人の公開リポジトリなど）
    func search() {
        let q = queryText
        guard queryIsFullName, !busy else {
            if !queryText.isEmpty && !queryIsFullName {
                setNote("GitHub で探すときは owner/name の形で入れてください（例: ggml-org/whisper.cpp）。名前の一部なら、下の一覧をその場で絞り込みます。", error: false)
            }
            return
        }
        searchingFor = q
        note = nil
        listOpen = true
        runHelper(["--find", q]) { [weak self] outcome in
            guard let self else { return }
            self.searchingFor = nil
            switch outcome {
            case .cannotRun(let why):
                self.setNote(why, error: true)
            case .finished(nil):
                self.setNote("うまく探せませんでした。取得ログの「アプリから動かした記録」を見てください。", error: true)
            case .finished(let st?):
                if let e = st.error {
                    self.setNote(e, error: true)
                } else if (st.found ?? 0) == 0 {
                    self.setNote("「\(q)」は見えませんでした。名前の書き間違いか、見る権限が無いのかもしれません（非公開のリポジトリは、権限が無いと「無い」と同じに見えます）。", error: false)
                } else {
                    self.setNote("「\(q)」を見つけました。チェックを付けると、取るリポジトリに入ります。", error: false)
                }
            }
        }
    }

    /// 選んだリポジトリの、基準のブランチの提案と、最初の取得の見込みを調べる（まだ無いときだけ。数回の問い合わせ）。
    /// ほかの処理が動いていれば順番を待つ。待っている間も「見込みを調べています…」と出す
    func inspect(_ id: Int) {
        guard let c = candidates.first(where: { $0.id == id }), c.estimate == nil || c.hint == nil,
              !inspecting.contains(id) else { return }
        inspecting.insert(id)
        inspectTried.insert(id)
        runHelper(["--inspect", c.name]) { [weak self] _ in
            self?.inspecting.remove(id)
        }
    }

    private func setNote(_ text: String, error: Bool) {
        note = text
        noteIsError = error
    }

    // ---- 選ぶ ----

    func isPicked(_ id: Int) -> Bool { picked.contains { $0.id == id } }

    func toggle(_ c: RepoCandidate) {
        if let i = picked.firstIndex(where: { $0.id == c.id }) {
            picked.remove(at: i)
            return
        }
        // 前に取っていたリポジトリなら、前の呼び名・基準・取り始める日に戻す
        if let s = shelved.first(where: { $0.id == c.id }) {
            picked.append(fromShelf(s))
            problem = nil
            return
        }
        let base = c.hint?.suggested ?? c.default_branch ?? "main"
        var p = PickedRepo(id: c.id, name: c.name, isPrivate: c.isPrivate ?? false,
                           tag: Setup.suggestTag(c.name, taken: Set(picked.map(\.tag))),
                           base: c.default_branch ?? base, branches: c.branches ?? [base],
                           created: Setup.day(c.created), from: Setup.day(c.created), fromKind: .created,
                           estimate: c.estimate, hint: c.hint)
        // 見込みが1回の上限を超える大きいリポジトリは、90日前からを勧める（はじめの準備で、両方の見込みを並べて見せる）
        if let all = c.estimate?.all, all > Setup.callCap {
            p.fromKind = .days90
            p.from = Calendar.current.date(byAdding: .day, value: -90, to: Date())
        }
        picked.append(p)
        problem = nil
        inspect(c.id)
    }

    func remove(_ id: Int) { picked.removeAll { $0.id == id } }

    /// 勧めているブランチを基準にする（「develop を基準にする」）
    func useSuggested(_ id: Int) {
        guard let i = picked.firstIndex(where: { $0.id == id }), let s = picked[i].hint?.suggested else { return }
        picked[i].base = s
    }

    /// 取り始める日の選び方を変える
    func setFrom(_ id: Int, _ kind: PickedRepo.From) {
        guard let i = picked.firstIndex(where: { $0.id == id }) else { return }
        picked[i].fromKind = kind
        switch kind {
        case .created: picked[i].from = picked[i].created
        case .days90: picked[i].from = Calendar.current.date(byAdding: .day, value: -90, to: Date())
        default: if picked[i].from == nil { picked[i].from = Calendar.current.date(byAdding: .day, value: -30, to: Date()) }
        }
    }

    /// 前に取っていたリポジトリのうち、いま選んでいないもの（「付け直す」の欄に出す）
    var shelvedNow: [ShelvedRepo] { shelved.filter { s in !isPicked(s.id) } }

    /// 前に取っていたリポジトリを付け直す。前の呼び名・基準・取り始める日に戻す（取ったデータは使い回し、取っていない期間だけを取る）
    func reattach(_ id: Int) {
        guard let s = shelved.first(where: { $0.id == id }), !isPicked(id) else { return }
        picked.append(fromShelf(s))
        problem = nil
    }

    private func fromShelf(_ s: ShelvedRepo) -> PickedRepo {
        let taken = Set(picked.map { $0.tag.trimmingCharacters(in: .whitespaces) })
        let c = candidates.first { $0.id == s.id }
        return PickedRepo(id: s.id, name: s.name, isPrivate: c?.isPrivate ?? false,
                          tag: taken.contains(s.tag) ? Setup.suggestTag(s.name, taken: taken) : s.tag,   // 呼び名が重なるときだけ変える
                          base: s.base, branches: c?.branches ?? [s.base], created: Setup.day(c?.created),
                          from: Setup.day(s.from), fromKind: .previous, estimate: c?.estimate, hint: c?.hint)
    }

    /// 保存してある1行を、選んだ一覧の形にする
    func asPicked(_ s: RepoConfig) -> PickedRepo {
        let c = candidates.first { $0.id == s.id }
        return PickedRepo(id: s.id, name: s.name, isPrivate: c?.isPrivate ?? false, tag: s.tag, base: s.base,
                          branches: c?.branches ?? [s.base], created: Setup.day(c?.created), from: Setup.day(s.from),
                          fromKind: .saved, estimate: c?.estimate, hint: c?.hint, stages: s.stages ?? [])
    }

    /// 保存してあるのに、いま外している（保存すると外れる）リポジトリ
    var removedSaved: [RepoConfig] { savedAtOpen.filter { s in !picked.contains { $0.id == s.id } } }

    /// ✗ で外した、保存してあるリポジトリを戻す（保存してある一覧での順番に戻す）
    func restore(_ id: Int) {
        guard let s = savedAtOpen.first(where: { $0.id == id }), !isPicked(id) else { return }
        let order = savedAtOpen.map(\.id)
        let at = picked.firstIndex { p in (order.firstIndex(of: p.id) ?? Int.max) > (order.firstIndex(of: id) ?? 0) } ?? picked.count
        picked.insert(asPicked(s), at: at)
    }

    /// 保存してある一覧から変えたか（足した・外した・呼び名・基準・取り始める日）
    var changed: Bool {
        picked.map { "\($0.id)|\($0.tag.trimmingCharacters(in: .whitespaces))|\($0.base)|\($0.from.map(Setup.dayString) ?? "")" }
            != savedAtOpen.map { "\($0.id)|\($0.tag)|\($0.base)|\($0.from)" }
    }

    /// 保存していない変更があるか（準備済みなら保存してある一覧から変えたか、初めてなら何か選んだか）
    var hasUnsaved: Bool { savedAtOpen.isEmpty ? !picked.isEmpty : changed }

    /// 右上の「閉じる」と Esc。保存していない変更があれば、捨ててよいかを聞く
    func close() {
        if hasUnsaved { confirmClose = true } else { closeNow() }
    }

    /// 閉じる（選び直した分は捨てる。次に開くと、保存してある一覧から始まる）
    func closeNow() {
        picked = savedAtOpen.map(asPicked)
        problem = nil
        confirmClose = false
        show = false
    }

    /// 呼び名の案: リポジトリの名前（owner/ の後ろ）を - _ . で切り、よくある語を除いた最初のまとまりの頭から、
    /// 英数字なら4文字・日本語なら3文字（メニューの呼び名の枠に収まる長さ）
    static func suggestTag(_ fullName: String, taken: Set<String>) -> String {
        let name = fullName.split(separator: "/").last.map(String.init) ?? fullName
        let generic: Set<String> = ["the", "my", "app", "web", "api", "lib", "cli", "tool", "tools", "project", "sample", "test", "x"]
        let parts = name.split(whereSeparator: { "-_. ".contains($0) }).map(String.init)
        let core = parts.first(where: { !generic.contains($0.lowercased()) }) ?? parts.first ?? name
        let base = String(core.prefix(core.unicodeScalars.allSatisfy(\.isASCII) ? 4 : 3))
        var tag = base
        var i = 2
        while taken.contains(tag) {
            tag = String(base.prefix(3)) + "\(i)"
            i += 1
        }
        return tag
    }

    /// 1回の取得で使ってよい回数（設定。0 は上限なし）
    static var callCap: Int {
        if let t = testCallCap { return t }
        let v = UserDefaults.standard.object(forKey: "callCap") as? Int ?? 1500
        return v == 0 ? Int.max : v
    }
    /// 自己試験だけが使う（本物の設定の上限を読まない。10/21）
    static var testCallCap: Int?

    // ---- 次へ ----

    var invalidReason: String? {
        if picked.isEmpty { return "リポジトリを1つ以上選んでください。" }
        if let p = picked.first(where: { $0.tag.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "\(p.name) の呼び名を入れてください。"
        }
        let tags = picked.map { $0.tag.trimmingCharacters(in: .whitespaces) }
        if Set(tags).count < tags.count { return "呼び名が重なっています。リポジトリごとに違う呼び名にしてください。" }
        if let p = picked.first(where: { $0.from == nil }) { return "\(p.name) の取り始める日を決めてください。" }
        return nil
    }

    func next() {
        guard !busy else { return }
        save()
    }

    func save() {
        if let why = invalidReason {
            problem = why
            return
        }
        let before = Setup.savedRepos()
        let shelf = Setup.shelvedRepos()
        do {
            try Setup.write(picked)
            let new = picked.filter { p in !before.contains { $0.id == p.id } }
            added = new.filter { p in !shelf.contains { $0.id == p.id } }.map(\.name)
            reattached = new.filter { p in shelf.contains { $0.id == p.id } }.map(\.name)
            let gone = before.filter { s in !picked.contains { $0.id == s.id } }
            removed = gone.map(\.name)
            // 外したリポジトリを覚える（付け直したものは消す）。書けなくても、取るリポジトリの一覧は保存できている
            let now = Fmt.iso.string(from: Date())
            let next = shelf.filter { s in !picked.contains { $0.id == s.id } && !gone.contains { $0.id == s.id } }
                + gone.map { ShelvedRepo(id: $0.id, name: $0.name, tag: $0.tag, base: $0.base, from: $0.from, removed_at: now) }
            try? Setup.writeShelved(next)
            shelved = next
            savedAtOpen = Setup.savedRepos()
            problem = nil
            step = 3
            onSaved?()
        } catch {
            problem = "リポジトリ.json に書けませんでした: \(error.localizedDescription)"
        }
    }

    /// 文字を JSON の文字列にする（日本語はそのまま）
    static func js(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            ?? Data("\"\"".utf8)
        return String(decoding: d, as: UTF8.self)
    }

    /// GitHub取得データ/外したリポジトリ.json に、1リポジトリ1行で書く
    static func writeShelved(_ list: [ShelvedRepo]) throws {
        let rows = list.map { s in
            "{\"id\": \(s.id), \"name\": \(js(s.name)), \"tag\": \(js(s.tag)), \"base\": \(js(s.base)), "
                + "\"from\": \(js(s.from)), \"removed_at\": \(js(s.removed_at ?? ""))}"
        }
        let text = rows.isEmpty ? "[]\n" : "[\n " + rows.joined(separator: ",\n ") + "\n]\n"
        try FileManager.default.createDirectory(at: Paths.data, withIntermediateDirectories: true)
        try text.write(to: Paths.shelved, atomically: true, encoding: .utf8)
    }

    /// GitHub取得データ/リポジトリ.json に、1リポジトリ1行で書く（設計書.md の 3.6 の形）
    static func write(_ list: [PickedRepo]) throws {
        let today = dayString(Date())
        let saved = savedRepos()
        let rows = list.map { p -> String in
            let stages = p.stages.map { "{\"name\": \(js($0.name)), \"branch\": \(js($0.branch))}" }.joined(separator: ", ")
            let added = saved.first { $0.id == p.id }?.added ?? today
            return "{\"id\": \(p.id), \"name\": \(js(p.name)), \"tag\": \(js(p.tag.trimmingCharacters(in: .whitespaces))), "
                + "\"base\": \(js(p.base)), \"stages\": [\(stages)], \"from\": \(js(dayString(p.from ?? Date()))), "
                + "\"added\": \(js(added))}"
        }
        try FileManager.default.createDirectory(at: Paths.data, withIntermediateDirectories: true)
        try ("[\n " + rows.joined(separator: ",\n ") + "\n]\n").write(to: Paths.repos, atomically: true, encoding: .utf8)
    }

    // ---- 日付（日本時間の日で扱う） ----

    static let jst = TimeZone(identifier: "Asia/Tokyo")!

    /// "2025-01-15" → その日の正午（日本時間）
    static func day(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return Fmt.parseJST(s + " 12:00:00")
    }

    static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = jst
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// 見込みの回数を言葉に（上限を超えるなら、何回に分けるかも）
    static func estimateText(_ n: Int?) -> String {
        guard let n else { return "見込みは保存のあとに" }
        let cap = callCap
        if n <= cap { return "見込み 約 \(Fmt.number(n)) 回" }
        return "見込み 約 \(Fmt.number(n)) 回（\((n + cap - 1) / cap) 回に分けて取る）"
    }
}

// MARK: - 部品

struct CheckBox: View {
    let on: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(on ? Color.key : Color.white)
            RoundedRectangle(cornerRadius: 4).stroke(on ? Color.key : Color.ink3, lineWidth: 1.5)
            if on {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// 外のページを開くボタン（ブラウザで開く印つき）
struct LinkButton: View {
    let title: String
    let url: URL
    var primary = false
    var action: () -> Void = {}
    @State private var hover = false

    var body: some View {
        Button {
            action()
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .bold))
                Image(systemName: "arrow.up.right.square").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(primary ? Color.white : Color.key)
            .padding(.vertical, 9).padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(primary ? (hover ? Color.keyHover : Color.key) : (hover ? Color.keyWash : Color.white)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(primary ? Color.clear : Color.key, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(url.absoluteString)
    }
}

/// 文の中の小さなリンク
struct LinkLine: View {
    let lead: String
    let title: String
    let url: URL
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(lead + "：").font(.system(size: 12)).foregroundStyle(Color.ink2)
            Button { NSWorkspace.shared.open(url) } label: {
                HStack(spacing: 3) {
                    Text(title).underline()
                    Image(systemName: "arrow.up.right.square").font(.system(size: 10))
                }
                .font(.system(size: 12)).foregroundStyle(Color.key)
            }
            .buttonStyle(.plain)
            .help(url.absoluteString)
        }
    }
}

struct Notice<Content: View>: View {
    enum Kind { case info, ok, error, warn }
    let kind: Kind
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) { content }
                .font(.system(size: 12)).foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(wash))
    }
    private var icon: String {
        switch kind {
        case .ok: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
    private var color: Color {
        switch kind { case .ok: return .okInk; case .error: return .ngInk; case .warn: return .warnInk; case .info: return .key }
    }
    private var wash: Color {
        switch kind { case .ok: return .okWash; case .error: return .ngWash; case .warn: return .warnWash; case .info: return .keyWash }
    }
}

/// 番号つきの手順の1行
struct NumberedLine<Extra: View>: View {
    let n: Int
    let title: String
    var sub: String?
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.key)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.keyWash))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.ink)
                if let sub {
                    Text(sub).font(.system(size: 12)).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
                }
                extra
            }
            Spacer(minLength: 0)
        }
    }
}

extension NumberedLine where Extra == EmptyView {
    init(n: Int, title: String, sub: String? = nil) {
        self.init(n: n, title: title, sub: sub, extra: { EmptyView() })
    }
}

/// 初めての準備の手順（見るだけ。画面は下の「戻る」「次へ」で移る）
struct StepBar: View {
    let step: Int
    let connected: Bool   // ①は、確かめてログインできていたときだけチェックを付ける
    private let titles = ["GitHub にログイン", "リポジトリを選ぶ", "取得を始める"]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, title in
                let n = i + 1
                let done = n < step && (n != 1 || connected)
                if i > 0 { Rectangle().fill(Color.line2).frame(width: 24, height: 1) }
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(n == step ? Color.key : done ? Color.okInk : Color.surface2)
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                        } else {
                            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(n == step ? Color.white : Color.ink2)
                        }
                    }
                    .frame(width: 22, height: 22)
                    Text(title).font(.system(size: 12, weight: n == step ? .bold : .regular))
                        .foregroundStyle(n == step ? Color.ink : Color.ink2)
                }
            }
        }
    }
}

/// 準備済みのときに、リポジトリの画面の上に出す GitHub のログイン（1行）
struct ConnectionLine: View {
    @EnvironmentObject var setup: Setup

    var body: some View {
        HStack(spacing: 8) {
            switch setup.conn {
            case .checking:
                ProgressView().controlSize(.small)
                Text("GitHub を読めるか確かめています（数秒）…").foregroundStyle(Color.ink2)
            case .failed(let why):
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.ngInk)
                Text("GitHub: まだ読めません。\(why)").foregroundStyle(Color.ngInk).lineLimit(2)
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.okInk)
                Text("GitHub: \(setup.login?.login ?? "") でログインしています" + (checkedText.map { "（\($0) に確かめた）" } ?? ""))
                    .foregroundStyle(Color.ink2)
            case .unknown:
                Image(systemName: "questionmark.circle").foregroundStyle(Color.ink3)
                Text("GitHub: まだ確かめていません").foregroundStyle(Color.ink2)
            }
            Spacer(minLength: 8)
            Button("確かめる") { setup.checkLogin() }
                .buttonStyle(.link).disabled(setup.busy)
            Button("ログインのしかたを見る") { setup.go(1) }
                .buttonStyle(.link).disabled(setup.busy)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.surface2))
    }

    private var checkedText: String? {
        Fmt.parseISO(setup.login?.at).map { Fmt.string($0, "M/d H:mm") }
    }
}

// MARK: - ① GitHub にログイン

struct LoginStep: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var setup: Setup

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if setup.firstTime {
                // 先に知らせること: 読むだけ・書き込まない（ログインの広さとの違い）
                Notice(kind: .info) {
                    Text("このアプリは、GitHub を読むだけです").bold()
                    Text("コメント・ラベル・マージ・push など、GitHub に書き込むことはしません。gh のログインは書き込みもできる広さですが、"
                         + "このアプリは問い合わせを「読む」だけに縛っています。ソースコードの中身も取りません。")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(setup.firstTime ? "GitHub にログインする" : "GitHub へのログインのしかた").font(.system(size: 16, weight: .bold)).foregroundStyle(Color.ink)
                Text(setup.firstTime
                     ? "このアプリは、Mac に入っている gh（GitHub の公式の道具）を通して GitHub を読みます。はじめに1回だけ、ターミナルで gh にログインしてください。"
                     : "このアプリは、Mac に入っている gh（GitHub の公式の道具）を通して GitHub を読みます。ログインが切れたときは、ここからログインし直してください。")
                    .font(.system(size: 13)).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 14) {
                NumberedLine(n: 1, title: "gh を入れる（入っていれば飛ばす）",
                             sub: "ターミナルで brew install gh と打つと入ります。入っているかは、4 でアプリが確かめます") {
                    LinkButton(title: "gh の入れ方を開く", url: Links.shared.ghInstall)
                        .padding(.top, 6)
                }
                NumberedLine(n: 2, title: "下のボタンでターミナルを開き、表示に沿って進める",
                             sub: "ログインの準備をした窓が開きます。聞かれたら、そのまま Enter で進めます") {
                    DadsButton(title: "ターミナルでログインを始める", small: true) {
                        setup.openedTerminal = true
                        store.openLoginTerminal()
                    }
                    .padding(.top, 6)
                }
                NumberedLine(n: 3, title: "ブラウザで、ターミナルに出た8文字のコードを入れて「Authorize」を押す",
                             sub: "GitHub にログインしていなければ、先にログインします。終わると、ターミナルに「Logged in as …」と出ます")
                NumberedLine(n: 4, title: "このアプリに戻って「ログインを確かめる」を押す",
                             sub: "アプリが、本当に GitHub を読めるかを確かめて、見えるリポジトリの一覧を読みます（数秒）")
            }
            status
            // うまくいかないときのリンク（ふだんは閉じておく。確かめて失敗したら開く）
            VStack(alignment: .leading, spacing: 7) {
                Button { setup.helpOpen.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: setup.helpOpen ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                        Text("うまくいかないとき").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(Color.ink2).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if setup.helpOpen {
                    LinkLine(lead: "gh が入っていないとき", title: "GitHub CLI（gh）の入れ方", url: Links.shared.ghInstall)
                    LinkLine(lead: "ログインのしかた", title: "gh auth login の説明", url: Links.shared.ghLogin)
                    LinkLine(lead: "組織のリポジトリが見えないとき", title: "シングルサインオン（SSO）の許可", url: Links.shared.sso)
                    LinkLine(lead: "許可したアプリを見る", title: "GitHub の設定 → アプリ", url: Links.shared.authorized)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.surface2))
        }
    }

    @ViewBuilder private var status: some View {
        switch setup.conn {
        case .checking:
            Notice(kind: .info) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("GitHub を読めるか確かめています（数秒）…")
                }
            }
        case .failed(let why):
            Notice(kind: .error) {
                Text("まだ GitHub を読めません").bold()
                Text(why)
            }
        case .ok:
            Notice(kind: .ok) {
                Text("\(setup.login?.login ?? "") でログインしています" + (setup.firstTime ? "。「次へ」でリポジトリを選びます。" : "。")).bold()
                Text("読める範囲: 公開リポジトリと、あなたに権限のある非公開リポジトリ" + (setup.login?.gh.map { "（gh \($0)）" } ?? ""))
                    .foregroundStyle(Color.ink2)
            }
        case .unknown:
            EmptyView()
        }
    }
}

// MARK: - ② リポジトリを選ぶ

struct PickStep: View {
    @EnvironmentObject var setup: Setup

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !setup.firstTime { ConnectionLine() }
            VStack(alignment: .leading, spacing: 6) {
                Text(setup.firstTime ? "取るリポジトリを選ぶ" : "リポジトリを探して足す").font(.system(size: 16, weight: .bold)).foregroundStyle(Color.ink)
                Text("あなたが見られるリポジトリの一覧です。名前の一部を入れると絞り込みます。ほかの人の公開リポジトリは、"
                     + "owner/name（例: ggml-org/whisper.cpp）を入れて Enter で探します。")
                    .font(.system(size: 13)).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                RepoCombo()
                Text("一覧は、ログインを確かめたときに GitHub から読んだもの（自分のリポジトリと、入っている組織のもの）です。"
                     + "GitHub で探すたびに、回数を1〜3回使います")
                    .font(.system(size: 11)).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
            }
            if let note = setup.note {
                Text(note).font(.system(size: 12)).foregroundStyle(setup.noteIsError ? Color.ngInk : Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PickedList()
            if !setup.shelvedNow.isEmpty { ShelvedList() }
            if let p = setup.problem {
                Notice(kind: .error) { Text(p) }
            }
        }
    }
}

/// 検索できるコンボボックス（打つと候補をその場で絞り込み、owner/name なら Enter で GitHub を探す。チェックで複数選べる）
struct RepoCombo: View {
    @EnvironmentObject var setup: Setup
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Color.ink3)
                TextField("名前の一部、または owner/name（例: ggml-org/whisper.cpp）", text: $setup.query)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { setup.search() }
                    .onChange(of: setup.query) { _, _ in setup.listOpen = true }
                if setup.searchingFor != nil {
                    ProgressView().controlSize(.small)
                } else if !setup.query.isEmpty {
                    Button { setup.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color(hex: 0xB3B3B3))
                    }
                    .buttonStyle(.plain).help("消す")
                }
                Button { setup.search() } label: {
                    Text("GitHub で探す").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(!setup.queryIsFullName || setup.busy ? Color(hex: 0x949494) : Color.key)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!setup.queryIsFullName || setup.busy)
                .help("owner/name の形で入れると、GitHub で探せます")
                Rectangle().fill(Color.line2).frame(width: 1, height: 18)
                Button { setup.listOpen.toggle() } label: {
                    Image(systemName: setup.listOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ink2)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(setup.listOpen ? "候補を閉じる" : "候補を開く")
            }
            .padding(.horizontal, 12).frame(height: 42)
            if setup.listOpen {
                Rectangle().fill(Color.line).frame(height: 1)
                list
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? Color.key : Color.line2, lineWidth: focused ? 2 : 1))
    }

    private var list: some View {
        let rows = setup.filtered
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let q = setup.searchingFor {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("GitHub で「\(q)」を探しています（数秒）…").font(.system(size: 12)).foregroundStyle(Color.ink2)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
                ForEach(rows) { c in
                    CandidateRow(c: c, on: setup.isPicked(c.id)) { setup.toggle(c) }
                    Rectangle().fill(Color.line).frame(height: 1).padding(.leading, 40)
                }
                if rows.isEmpty && setup.searchingFor == nil {
                    Text(setup.candidates.isEmpty
                         ? "まだ一覧がありません。①の「ログインを確かめる」で、見えるリポジトリを読みます。"
                         : setup.queryIsFullName
                         ? "「\(setup.queryText)」は一覧にありません。Enter を押すと、GitHub で探します。"
                         : "「\(setup.queryText)」に合うリポジトリは、一覧にありません。ほかの人のリポジトリは owner/name で探せます。")
                        .font(.system(size: 12)).foregroundStyle(Color.ink3)
                        .padding(12)
                }
            }
        }
        .frame(height: 200)
    }
}

struct CandidateRow: View {
    let c: RepoCandidate
    let on: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 10) {
                CheckBox(on: on).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(c.name).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.ink).lineLimit(1)
                        if c.isPrivate == true {
                            Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Color.ink3).help("非公開のリポジトリ")
                        }
                        if c.archived == true { MiniBadge(text: "アーカイブ済み") }
                        if c.fork == true { MiniBadge(text: "フォーク") }
                        Spacer(minLength: 8)
                        Text(meta).font(.system(size: 11)).foregroundStyle(Color.ink3).monospacedDigit()
                    }
                    if let p = c.description, !p.isEmpty {
                        Text(oneLine(p)).font(.system(size: 11)).foregroundStyle(Color.ink2).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(hover ? Color.surface2 : on ? Color.keyWash.opacity(0.6) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var meta: String {
        var parts: [String] = []
        if let d = Fmt.parseISO(c.pushed) { parts.append("最後の push " + Fmt.relativeDay(d)) }
        if let n = c.prs { parts.append("PR \(Fmt.number(n))") }
        if let n = c.issues { parts.append("issue \(Fmt.number(n))") }
        return parts.joined(separator: "・")
    }
}

struct PickedList: View {
    @EnvironmentObject var setup: Setup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text((setup.firstTime ? "選んだリポジトリ" : "取るリポジトリ") + "（\(setup.picked.count)）")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.ink)
                Spacer()
                Text("呼び名は、アプリの表示に使う短い名前（2〜4文字）")
                    .font(.system(size: 11)).foregroundStyle(Color.ink3)
            }
            if setup.picked.isEmpty {
                Text("まだ選んでいません。上の一覧にチェックを付けてください。")
                    .font(.system(size: 12)).foregroundStyle(Color.ink3)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.line2, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                // 4つを超えたら、この中でスクロールする（窓が画面からはみ出さないように）
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach($setup.picked) { $p in
                            PickedRow(p: $p)
                            if p.id != setup.picked.last?.id { Rectangle().fill(Color.line).frame(height: 1) }
                        }
                    }
                }
                .frame(height: setup.picked.prefix(4).reduce(0) { $0 + PickedRow.height($1) })
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.line, lineWidth: 1))
                if setup.picked.count > 4 {
                    Text("ほか \(setup.picked.count - 4) つは、一覧の中を下へスクロールすると見られます")
                        .font(.system(size: 11)).foregroundStyle(Color.ink2)
                }
            }
            // ✗ で外した、保存してあるリポジトリ。保存するまでは外れないので、ここから戻せる
            if !setup.removedSaved.isEmpty {
                VStack(spacing: 0) {
                    ForEach(setup.removedSaved, id: \.id) { c in
                        HStack(spacing: 10) {
                            Text(c.name).strikethrough().font(.system(size: 13, weight: .bold)).foregroundStyle(Color.ink3)
                                .lineLimit(1).truncationMode(.middle)
                            Text("保存すると外れます（取ったデータは残り、あとで付け直せます）").font(.system(size: 11)).foregroundStyle(Color.warnInk)
                            Spacer(minLength: 8)
                            Button("戻す") { setup.restore(c.id) }
                                .buttonStyle(.link).font(.system(size: 12, weight: .bold))
                                .disabled(setup.busy)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.warnWash))
            }
            if !setup.picked.isEmpty {
                Text(setup.firstTime
                     ? "取り始める日から今日までの分を、最初の取得でまとめて取ります。大きいリポジトリ（見込みが1回の上限を超えるもの）は、90日前からを選んであります。"
                     : "取り始める日を前にずらすと、その前の分だけを足して取ります（取ってあるところは取り直しません）。後ろにずらしても、取ったデータは消えません。")
                    .font(.system(size: 11)).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 前に取っていたリポジトリ（今は取っていない）。付け直すと、前の呼び名・基準・取り始める日に戻し、続きから取る
struct ShelvedList: View {
    @EnvironmentObject var setup: Setup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("前に取っていたリポジトリ（今は取っていない・取ったデータは残っています）")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.ink)
            VStack(spacing: 0) {
                ForEach(setup.shelvedNow, id: \.id) { c in
                    HStack(spacing: 10) {
                        Text(c.name).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.ink2)
                            .lineLimit(1).truncationMode(.middle)
                        Text(detail(c)).font(.system(size: 11)).foregroundStyle(Color.ink3).lineLimit(1)
                        Spacer(minLength: 8)
                        Button("付け直す") { setup.reattach(c.id) }
                            .buttonStyle(.link).font(.system(size: 12, weight: .bold))
                            .disabled(setup.busy)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    if c.id != setup.shelvedNow.last?.id { Rectangle().fill(Color.line).frame(height: 1) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.surface2))
            Text("付け直すと、前の呼び名・基準のブランチ・取り始める日に戻します。前に取った分は使い回して、取っていない期間（外していた間）と最近の分だけを取ります。")
                .font(.system(size: 11)).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func detail(_ c: ShelvedRepo) -> String {
        let from = Setup.day(c.from).map { Fmt.string($0, "yyyy/M/d") } ?? c.from
        let gone = Fmt.parseISO(c.removed_at).map { "・" + Fmt.string($0, "M/d") + " に外した" } ?? ""
        return "呼び名 \(c.tag)・基準 \(c.base)・\(from) から" + gone
    }
}

struct PickedRow: View {
    @Binding var p: PickedRepo
    @EnvironmentObject var setup: Setup

    /// 1行の高さ（区切りの線を含む）。注意の行・見込みの行があると高くなる
    static func height(_ p: PickedRepo) -> CGFloat {
        var h: CGFloat = 75
        if p.baseWarning { h += 40 }
        return h
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(p.name).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.ink)
                    .lineLimit(1).truncationMode(.middle)
                if p.isPrivate {
                    Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Color.ink3)
                }
                Spacer(minLength: 8)
                // 保存してある（もう取っている）リポジトリには、最初の取得の見込みは出さない
                if p.fromKind != .saved {
                    Text(setup.estimateLabel(p))
                        .font(.system(size: 11)).foregroundStyle(Color.ink3).monospacedDigit()
                        .lineLimit(2).multilineTextAlignment(.trailing)
                }
                Button { setup.remove(p.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ink3)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("外す")
            }
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Text("呼び名").font(.system(size: 11)).foregroundStyle(Color.ink3)
                    TextField("", text: $p.tag).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(width: 60)
                }
                HStack(spacing: 6) {
                    Text("基準").font(.system(size: 11)).foregroundStyle(Color.ink3).help("基準のブランチ（入ったものを数えるブランチ）")
                    Picker("", selection: $p.base) {
                        ForEach(Array(Set(p.branches + [p.base])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 110)
                }
                HStack(spacing: 6) {
                    Text("取り始める日").font(.system(size: 11)).foregroundStyle(Color.ink3)
                    fromControl
                }
                Spacer(minLength: 0)
            }
            if p.baseWarning, let s = p.hint?.suggested {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Color.warnInk)
                    Text(warningText(s)).font(.system(size: 11)).foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("\(s) を基準にする") { setup.useSuggested(p.id) }
                        .buttonStyle(.link).font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.warnWash))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(height: PickedRow.height(p) - 1, alignment: .top)
    }

    /// 取り始める日（作った日から・90日前から・日付を入れる）
    @ViewBuilder private var fromControl: some View {
        let kinds: [(PickedRepo.From, String)] = {
            var k: [(PickedRepo.From, String)] = []
            if let c = p.created { k.append((.created, "作った日から（\(Fmt.string(c, "yyyy/M/d"))）")) }
            k.append((.days90, "90日前から（\(Fmt.string(Date().addingTimeInterval(-90 * 86400), "yyyy/M/d"))）"))
            k.append((.manual, "日付を入れる"))
            if p.fromKind == .saved { k.append((.saved, "今の設定")) }
            if p.fromKind == .previous { k.append((.previous, "前に取っていた日")) }
            return k
        }()
        Picker("", selection: Binding(get: { p.fromKind }, set: { setup.setFrom(p.id, $0) })) {
            ForEach(kinds.indices, id: \.self) { i in Text(kinds[i].1).tag(kinds[i].0) }
        }
        // 日付の欄も出すときは、1行に収まるよう選択の欄を細くする
        .labelsHidden().frame(width: p.fromKind == .created || p.fromKind == .days90 ? 196 : 132)
        if p.fromKind != .created, p.fromKind != .days90, let d = p.from {
            DatePicker("", selection: Binding(get: { d }, set: { p.from = $0; p.fromKind = .manual }), displayedComponents: .date)
                .labelsHidden().datePickerStyle(.field).frame(width: 100)
                .environment(\.locale, Locale(identifier: "ja_JP"))
                .environment(\.timeZone, Setup.jst)
        }
    }

    private func warningText(_ suggested: String) -> String {
        let quiet = Setup.day(p.hint?.default_quiet_since).map { Fmt.string($0, "M/d") }
        let n = p.hint?.pushes30.map { " \($0) 回" } ?? ""
        return "既定の \(p.base) は\(quiet.map { " \($0) から" } ?? "")止まっています。この30日の変更は \(suggested) に\(n)入っています"
    }
}

// MARK: - ③ 取得を始める

struct StartStep: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var setup: Setup

    /// まだ一度も取っていないか（取ったことがあれば、リポジトリの変更として伝える）
    private var first: Bool { store.history.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(first ? "取得を始める" : "保存しました").font(.system(size: 16, weight: .bold)).foregroundStyle(Color.ink)
                Text("\(setup.picked.count) リポジトリを \(Paths.short(Paths.repos.path)) に保存しました。")
                    .font(.system(size: 13)).foregroundStyle(Color.ink2)
            }
            VStack(spacing: 0) {
                ForEach(setup.picked) { p in
                    HStack(spacing: 10) {
                        TagChip(tag: p.tag, width: 48)
                        Text(p.name).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.ink).lineLimit(1)
                        Spacer()
                        Text("基準 \(p.base)・\(fromText(p))").font(.system(size: 12)).foregroundStyle(Color.ink2)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    if p.id != setup.picked.last?.id { Rectangle().fill(Color.line).frame(height: 1) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.line, lineWidth: 1))
            Notice(kind: .info) {
                if first {
                    Text("最初の取得では、取り始める日からの分をまとめて取ります。\(totalText)")
                } else {
                    if !setup.added.isEmpty {
                        Text("足したリポジトリ（\(setup.added.joined(separator: "・"))）は、\(nextFetch)で、取り始める日からの分をまとめて取ります。\(resumeText)")
                    }
                    if !setup.reattached.isEmpty {
                        Text("付け直したリポジトリ（\(setup.reattached.joined(separator: "・"))）は、前に取った分を使い回して、\(nextFetch)で、外していた間と最近の分だけを取ります。")
                    }
                    if !setup.removed.isEmpty {
                        Text("外したリポジトリ（\(setup.removed.joined(separator: "・"))）の取ったデータは消えずに、\(Paths.short(Paths.data.path))/リポジトリ/ に残ります。これからは取らず、状況ページの数にも入れません。あとで付け直せます。")
                    }
                    if setup.added.isEmpty && setup.reattached.isEmpty && setup.removed.isEmpty {
                        Text("取るリポジトリは変わっていません。呼び名・基準のブランチ・取り始める日を変えたときは、次の取得から効きます。")
                    }
                    Text(store.running ? "取得中なので、状況ページとメニューは、この取得が終わったときに新しくなります。"
                         : store.refreshing ? "状況ページとメニューを数え直しています…"
                         : "状況ページとメニューにも反映しました。")
                }
                Text("このアプリは GitHub を読むだけで、書き込みません。").foregroundStyle(Color.ink2)
            }
            if setup.firstTime {
                VStack(spacing: 0) {
                    SettingRow(title: "毎朝 \(store.timeText) に自動で取る",
                               sub: (first ? "最初の取得のあと、" : "") + "このアプリが開いている間、毎日この時刻に動きます（土日も）") {
                        Toggle("", isOn: $store.autoEnabled).toggleStyle(SwitchStyle())
                    }
                    SettingRow(title: "Mac の起動時にこのアプリを開く", sub: "自動の取得には、このアプリが開いている必要があります", last: true) {
                        Toggle("", isOn: Binding(get: { store.loginItem }, set: { store.setLoginItem($0) })).toggleStyle(SwitchStyle())
                    }
                }
            }
            if let m = store.message {
                Text(m).font(.system(size: 11)).foregroundStyle(Color.ngInk).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 次の取得（毎朝の自動取得が入っていれば、それも）
    private var nextFetch: String {
        store.autoEnabled ? "次の取得（「今すぐ取る」か、毎朝 \(store.timeText) の自動取得）" : "次に「今すぐ取る」を押したとき"
    }

    private var resumeText: String {
        "1回の上限（\(store.callCapText)）で止まったら、もう一度「今すぐ取る」を押すか、次の自動取得で続きから取ります（抜けません）。"
    }

    /// 最初の取得の見込みの合計と、何回に分かれるか
    private var totalText: String {
        let known = setup.picked.compactMap(\.estimateNow)
        guard !known.isEmpty else { return resumeText }
        let total = known.reduce(0, +)
        let cap = Setup.callCap
        if total <= cap {
            return "見込みは合わせて 約 \(Fmt.number(total)) 回で、1回で取り終えます（数分）。"
        }
        return "見込みは合わせて 約 \(Fmt.number(total)) 回です。1回の上限（\(store.callCapText)）を超えるので、\((total + cap - 1) / cap) 回に分けて取ります。"
            + "2回目からは「今すぐ取る」か毎朝の自動取得で、続きから取ります（抜けません）。"
            + "GitHub の1時間の枠（5,000 回）が残り少なくなったら、戻るまで待ってから続きを取ります。"
    }

    private func fromText(_ p: PickedRepo) -> String {
        guard let d = p.from else { return "—" }
        let day = Fmt.string(d, "yyyy/M/d") + " から"
        switch p.fromKind {
        case .created: return day + "（作った日・全部）"
        case .days90: return day + "（90日前）"
        default: return day
        }
    }
}

// MARK: - 窓

struct SetupSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var setup: Setup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(setup.firstTime ? "はじめの準備" : "GitHub とリポジトリ")
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(Color.ink)
                    if setup.firstTime { StepBar(step: setup.step, connected: setup.conn == .ok) }
                }
                Spacer()
                // 閉じるのは、どの画面でもここ（Esc でも）。保存していない変更があれば聞く
                DadsButton(title: "閉じる", kind: .quiet, small: true, shortcut: .cancelAction) { setup.close() }
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
            Rectangle().fill(Color.line).frame(height: 1)
            Group {
                switch setup.step {
                case 1: LoginStep()
                case 2: PickStep()
                default: StartStep()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            Rectangle().fill(Color.line).frame(height: 1)
            footer.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 720)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .alert("保存せずに閉じますか？", isPresented: $setup.confirmClose) {
            Button("保存せずに閉じる", role: .destructive) { setup.closeNow() }
            Button("続ける", role: .cancel) {}
        } message: {
            Text(setup.savedAtOpen.isEmpty
                 ? "選んだリポジトリは保存されません。"
                 : "選び直した分は捨てて、保存してある一覧（\(setup.savedAtOpen.count) リポジトリ）のままにします。")
        }
    }

    /// 下のボタン。左は「前の画面へ」だけ、右はその画面でいちばん大事な1つだけ（閉じるのは右上）
    @ViewBuilder private var footer: some View {
        HStack(spacing: 10) {
            switch setup.step {
            case 1:
                if !setup.firstTime {
                    DadsButton(title: "リポジトリの画面に戻る", kind: .quiet, small: true, enabled: !setup.busy) { setup.go(2) }
                }
                Spacer()
                if setup.conn == .ok {
                    DadsButton(title: "もう一度確かめる", kind: setup.firstTime ? .quiet : .secondary, enabled: !setup.busy) {
                        setup.checkLogin()
                    }
                    .frame(width: 180)
                    if setup.firstTime { DadsButton(title: "次へ") { setup.step = 2 }.frame(width: 180) }
                } else {
                    DadsButton(title: checkTitle,
                               kind: setup.openedTerminal || setup.conn != .unknown || !setup.firstTime ? .primary : .secondary,
                               enabled: !setup.busy) { setup.checkLogin() }
                        .frame(width: 240)
                }
            case 2:
                if setup.firstTime {
                    DadsButton(title: "戻る", kind: .quiet, small: true, enabled: !setup.busy) { setup.go(1) }
                } else {
                    Text(setup.changed ? "変えた分は、保存するまで反映されません" : "直したいところを変えると、保存できるようになります")
                        .font(.system(size: 12)).foregroundStyle(setup.changed ? Color.warnInk : Color.ink3)
                }
                Spacer()
                DadsButton(title: setup.firstTime ? "保存して次へ" : "保存する",
                           enabled: !setup.busy && !setup.picked.isEmpty && (setup.firstTime || setup.changed)) {
                    setup.next()
                }
                .frame(width: 220)
            default:
                DadsButton(title: "リポジトリを選び直す", kind: .quiet, small: true, enabled: !store.running) { setup.go(2) }
                Spacer()
                if setup.firstTime || !setup.added.isEmpty || !setup.reattached.isEmpty {
                    // 初めて・リポジトリを足したときは、取るのがいちばん大事
                    DadsButton(title: store.running ? "取得中です" : store.history.isEmpty ? "最初の取得を始める" : "今すぐ取る",
                               enabled: !store.running) {
                        setup.backToSettings = false
                        setup.closeNow()
                        store.runNow()
                    }
                    .frame(width: 220)
                } else {
                    // 呼び名や取り始める日を変えた・外しただけなら、取らずに閉じるのがふつう（今すぐ取るは状況ページから）
                    DadsButton(title: "閉じる") { setup.closeNow() }.frame(width: 220)
                }
            }
        }
    }

    private var checkTitle: String {
        switch setup.conn {
        case .checking: return "確かめています…"
        case .failed: return "もう一度確かめる"
        default: return "ログインを確かめる"
        }
    }
}

// MARK: - 確認用の画像（本物の窓として描く。入力欄や選択の欄も写る）

enum SetupSnapshot {
    @MainActor
    static func run(dir: String) {
        let ago = { (days: Int) in Fmt.iso.string(from: Date().addingTimeInterval(Double(-days) * 86400)) }
        let dayAgo = { (days: Int) in Setup.dayString(Date().addingTimeInterval(Double(-days) * 86400)) }
        // 作り物の候補（名前も数字も作り物）
        let samples = [
            RepoCandidate(id: 600000000, name: "open-voice/speech-engine", isPrivate: false, archived: false, fork: false,
                          default_branch: "master", branches: ["master", "release-1.9"], created: "2022-09-26", pushed: ago(1),
                          description: "Speech recognition engine in plain C/C++", prs: 1527, issues: 1994, commits: 5456,
                          hint: BaseHint(), estimate: Estimate(all: 3600, days90: 400)),
            RepoCandidate(id: 600001111, name: "sample-org/web-app", isPrivate: true, archived: false, fork: false,
                          default_branch: "main", branches: ["main", "develop", "staging", "production"], created: "2025-11-04",
                          pushed: ago(2), description: "会員向けのウェブアプリ", prs: 58, issues: 0, commits: 1210,
                          hint: BaseHint(suggested: "develop", default_quiet_since: dayAgo(81), pushes30: 41),
                          estimate: Estimate(all: 820, days90: 260)),
            RepoCandidate(id: 600002222, name: "sample-user/menu-bar-app", isPrivate: false, archived: false, fork: false,
                          default_branch: "main", branches: ["main"], created: dayAgo(1), pushed: ago(1),
                          description: "メニューバーから画面の配置を戻すアプリ", prs: 0, issues: 0, commits: 25,
                          hint: BaseHint(), estimate: Estimate(all: 8, days90: 8)),
            RepoCandidate(id: 600003333, name: "sample-user/transcriber", isPrivate: false, archived: false, fork: false,
                          default_branch: "main", branches: ["main"], created: dayAgo(19), pushed: ago(3),
                          description: "話者付きの文字起こし", prs: 0, issues: 0, commits: 13,
                          hint: BaseHint(), estimate: Estimate(all: 6, days90: 6)),
            RepoCandidate(id: 600004444, name: "sample-user/chat-fetch", isPrivate: false, archived: false, fork: false,
                          default_branch: "main", branches: ["main"], created: dayAgo(9), pushed: ago(2),
                          description: "チャットの取得アプリ", prs: 0, issues: 0, commits: 6,
                          hint: BaseHint(), estimate: Estimate(all: 5, days90: 5)),
            RepoCandidate(id: 600005555, name: "sample-user/comment-layer", isPrivate: false, archived: false, fork: false,
                          default_branch: "main", branches: ["main"], created: dayAgo(72), pushed: ago(70),
                          description: "HTML 資料にコメントを付ける", prs: 0, issues: 0, commits: 34,
                          hint: BaseHint(), estimate: Estimate(all: 10, days90: 10)),
            RepoCandidate(id: 600006666, name: "sample-user/old-notes", isPrivate: false, archived: true, fork: false,
                          default_branch: "main", branches: ["main"], created: "2024-02-01", pushed: ago(400),
                          description: nil, prs: 0, issues: 0, commits: 3, hint: BaseHint(), estimate: Estimate(all: 3, days90: 0)),
            RepoCandidate(id: 600007777, name: "sample-user/some-library", isPrivate: false, archived: false, fork: true,
                          default_branch: "main", branches: ["main"], created: "2025-06-12", pushed: ago(130),
                          description: "（フォーク）", prs: 0, issues: 0, commits: 210, hint: BaseHint(), estimate: Estimate(all: 9, days90: 1)),
        ]
        let login = LoginInfo(ok: true, login: "sample-user", gh: "2.94.0", error: nil, at: ago(0))
        let store = Store(live: false)   // 取ったことがある人の見え方（-dataDir のデータ）
        let fresh = Store(live: false)   // まだ一度も取っていない人の見え方
        fresh.history = []
        func shot(_ name: String, store: Store = fresh, _ prepare: (Setup) -> Void) {
            let s = Setup()
            s.candidates = samples
            prepare(s)
            Snapshot.renderWindow(SetupSheet().environmentObject(store).environmentObject(s), to: "\(dir)/setup_\(name).png")
        }
        shot("1") { _ in }
        shot("1_checking") { s in
            s.openedTerminal = true
            s.conn = .checking
        }
        shot("1_failed") { s in
            s.openedTerminal = true
            s.helpOpen = true
            s.conn = .failed("gh にログインしていません。2 の「ターミナルでログインを始める」から進めてください（gh は入っています: 2.94.0）")
        }
        shot("1_ok") { s in
            s.openedTerminal = true
            s.login = login
            s.conn = .ok
        }
        shot("2") { s in
            s.step = 2
            s.login = login
            s.conn = .ok
            s.toggle(samples[0])
            s.toggle(samples[1])
            s.toggle(samples[2])
            s.inspecting = []
        }
        shot("2_find") { s in   // ほかの人のリポジトリを owner/name で探しているところ
            s.step = 2
            s.login = login
            s.conn = .ok
            s.query = "ggml-org/whisper.cpp"
            s.searchingFor = "ggml-org/whisper.cpp"
        }
        shot("2_filter") { s in   // 名前の一部で絞り込んだところ（一覧に無いときの案内）
            s.step = 2
            s.login = login
            s.conn = .ok
            s.query = "notes"
            s.toggle(samples[2])
            s.inspecting = []
        }
        shot("3") { s in
            s.login = login
            s.conn = .ok
            s.toggle(samples[0])
            s.toggle(samples[1])
            s.toggle(samples[2])
            s.useSuggested(samples[1].id)
            s.inspecting = []
            s.step = 3
        }
        // 準備済みの見え方（「GitHub とリポジトリ」の窓）
        shot("c2", store: store) { s in
            s.firstTime = false
            s.login = login
            s.conn = .ok
            s.savedAtOpen = [
                RepoConfig(id: 600000000, name: "open-voice/speech-engine", tag: "音声", base: "master", stages: [], from: dayAgo(90), added: dayAgo(20)),
                RepoConfig(id: 600001111, name: "sample-org/web-app", tag: "web", base: "develop", stages: [], from: "2025-11-04", added: dayAgo(20)),
                RepoConfig(id: 600002222, name: "sample-user/menu-bar-app", tag: "窓", base: "main", stages: [], from: dayAgo(1), added: dayAgo(1)),
            ]
            s.picked = s.savedAtOpen.map(s.asPicked)
            s.step = 2
            s.listOpen = false
        }
    }
}

// MARK: - 確かめ用: リポジトリを外す・保存・付け直す（--test-setup）

enum SetupTest {
    /// 一時フォルダの中だけで「外す → 戻す → 外して保存 → 開き直す → 付け直して保存」などを試す。本物のデータと設定は触らない
    @MainActor
    static func run() -> Int32 {
        Paths.defaults = MemoryStore()
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("github-fetch-setup-test-\(ProcessInfo.processInfo.processIdentifier)")
        Paths.dataOverride = root.appendingPathComponent(Paths.dataFolderName)   // 取ったデータの場所も一時フォルダの中
        defer { try? fm.removeItem(at: root) }
        Setup.testCallCap = 1500   // 1 回の上限も、本物の設定を読まない（10/21）
        defer { Setup.testCallCap = nil }
        var ng = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "OK  " : "NG  ") + name); if !ok { ng += 1 } }
        func text(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            for f in Paths.required { fm.createFile(atPath: root.appendingPathComponent(f).path, contents: Data()) }
            Paths.current = root
            check("一時フォルダを使っている（本物のデータではない）", Paths.repos.path.hasPrefix(root.path))
            try fm.createDirectory(at: Paths.data, withIntermediateDirectories: true)
            // リポジトリ.json と同じ形の、架空の3リポジトリ
            let original = "[\n {\"id\": 1001, \"name\": \"test-owner/one\", \"tag\": \"一\", \"base\": \"main\", \"stages\": [], \"from\": \"2024-12-27\", \"added\": \"2026-10-01\"},\n"
                + " {\"id\": 1002, \"name\": \"test-owner/two\", \"tag\": \"二\", \"base\": \"develop\", \"stages\": [], \"from\": \"2025-02-20\", \"added\": \"2026-10-01\"},\n"
                + " {\"id\": 1003, \"name\": \"test-owner/three\", \"tag\": \"三\", \"base\": \"main\", \"stages\": [], \"from\": \"2025-10-28\", \"added\": \"2026-10-01\"}\n]\n"
            try original.write(to: Paths.repos, atomically: true, encoding: .utf8)
            var savedCount = 0
            let s = Setup()
            s.onSaved = { savedCount += 1 }

            s.open()
            check("開くと、保存してある3リポジトリが選ばれている（準備済みの窓・リポジトリの画面）",
                  s.picked.count == 3 && !s.firstTime && s.step == 2 && !s.changed)
            s.remove(1002)
            check("✗ で外すと「変えた」になり、戻せる欄に出る", s.changed && s.removedSaved.map(\.id) == [1002])
            s.restore(1002)
            check("「戻す」で元の順番に戻り、「変えた」でなくなる", !s.changed && s.picked.map(\.id) == [1001, 1002, 1003])
            s.remove(1002)
            s.close()
            check("保存せずに閉じようとすると聞く（窓は開いたまま）", s.confirmClose && s.show)
            s.closeNow()
            check("「保存せずに閉じる」ならファイルは変わらない", text(Paths.repos) == original && !s.show)

            s.open()
            check("開き直すと、保存してある一覧から始まる", s.picked.count == 3 && !s.changed)
            s.remove(1002)
            s.next()
            let after1 = Setup.savedRepos().map(\.id)
            let shelf1 = Setup.shelvedRepos()
            check("外して保存すると、取るリポジトリから消える", after1 == [1001, 1003] && s.step == 3)
            check("外したリポジトリは、呼び名・基準・取り始める日を覚えておく",
                  shelf1.count == 1 && shelf1[0].id == 1002 && shelf1[0].tag == "二" && shelf1[0].base == "develop"
                  && shelf1[0].from == "2025-02-20" && shelf1[0].removed_at != nil)
            check("保存したら、状況ページの数え直しを呼ぶ", savedCount == 1)
            check("③で「外した」と伝える", s.removed == ["test-owner/two"] && s.added.isEmpty && s.reattached.isEmpty)

            s.closeNow()
            s.open()
            check("開き直すと、前に取っていたリポジトリの欄に出る", s.shelvedNow.map(\.id) == [1002] && s.picked.count == 2)
            s.reattach(1002)
            let p = s.picked.first { $0.id == 1002 }
            check("付け直すと、前の呼び名・基準・取り始める日に戻る",
                  p?.tag == "二" && p?.base == "develop" && p.flatMap { $0.from }.map(Setup.dayString) == "2025-02-20"
                  && p?.fromKind == .previous)
            check("付け直したものは、前に取っていたリポジトリの欄から消える", s.shelvedNow.isEmpty && s.changed)
            s.next()
            let after2 = Setup.savedRepos()
            check("付け直して保存すると、取るリポジトリに戻る（呼び名・基準・取り始める日も同じ）",
                  Set(after2.map(\.id)) == [1001, 1002, 1003]
                  && after2.first { $0.id == 1002 }.map { $0.tag == "二" && $0.base == "develop" && $0.from == "2025-02-20" } == true)
            check("外したリポジトリの記録から消える", Setup.shelvedRepos().isEmpty && text(Paths.shelved) == "[]\n")
            check("③で「付け直した」と伝える（足した、ではない）", s.reattached == ["test-owner/two"] && s.added.isEmpty)

            // 最後のリポジトリを外して付け直すと、ファイルは元とまったく同じになる（足した日も覚えている）
            s.closeNow(); s.open()
            s.remove(1003); s.next()
            s.closeNow(); s.open()
            s.remove(1002); s.reattach(1003)
            s.restore(1002)
            s.next()
            let order = Setup.savedRepos().map(\.id)
            check("付け直したリポジトリは一覧の最後に入る（\(order.map(String.init).joined(separator: ","))）", order == [1001, 1002, 1003])

            // 候補からチェックを付けたときも、前の呼び名・基準・取り始める日に戻す
            s.closeNow(); s.open()
            s.remove(1001); s.next()
            s.closeNow(); s.open()
            s.candidates = [RepoCandidate(id: 1001, name: "test-owner/one", default_branch: "main", branches: ["main"], created: "2020-01-01")]
            s.toggle(s.candidates[0])
            let q = s.picked.first { $0.id == 1001 }
            check("候補からチェックしても、前の呼び名と取り始める日に戻る（作った日ではなく）",
                  q?.tag == "一" && q.flatMap { $0.from }.map(Setup.dayString) == "2024-12-27" && q?.fromKind == .previous)

            // 大きいリポジトリは、90日前からを勧める
            s.candidates.append(RepoCandidate(id: 1009, name: "test-owner/big", default_branch: "main", branches: ["main"],
                                              created: "2020-01-01", estimate: Estimate(all: 9000, days90: 300)))
            s.toggle(s.candidates[1])
            check("見込みが1回の上限を超えるリポジトリは、90日前からになる",
                  s.picked.first { $0.id == 1009 }?.fromKind == .days90)
            // 見込みがチェックのあとで届いても、大きいリポジトリは「90日前から」に選び直す（レビュー 4 回目 P-4）
            s.candidates.append(RepoCandidate(id: 1011, name: "test-owner/big-later", default_branch: "main", branches: ["main"],
                                              created: "2020-01-01"))
            s.toggle(s.candidates[s.candidates.count - 1])
            let beforeKind = s.picked.first { $0.id == 1011 }?.fromKind
            try "{\"repos\": [{\"id\": 1011, \"name\": \"test-owner/big-later\", \"created\": \"2020-01-01\", \"estimate\": {\"all\": 9000, \"days90\": 300}}]}"
                .write(to: Paths.candidates, atomically: true, encoding: .utf8)
            s.loadCandidates()
            check("見込みがあとで届いても、大きいリポジトリは90日前からに選び直す（届く前は作った日から）",
                  beforeKind == .created && s.picked.first { $0.id == 1011 }?.fromKind == .days90)
            s.candidates = [RepoCandidate(id: 1001, name: "test-owner/one", default_branch: "main", branches: ["main"], created: "2020-01-01"),
                            RepoCandidate(id: 1009, name: "test-owner/big", default_branch: "main", branches: ["main"],
                                          created: "2020-01-01", estimate: Estimate(all: 9000, days90: 300))]
            // 既定のブランチが止まっていれば、注意を出し、押すと勧めるブランチになる
            s.candidates.append(RepoCandidate(id: 1010, name: "test-owner/quiet-main", default_branch: "main",
                                              branches: ["main", "develop"], created: "2024-01-01",
                                              hint: BaseHint(suggested: "develop", default_quiet_since: "2026-07-29", pushes30: 41)))
            s.toggle(s.candidates[2])
            check("既定の main が止まっていれば、注意が出る（基準はまだ main）",
                  s.picked.first { $0.id == 1010 }.map { $0.baseWarning && $0.base == "main" } == true)
            s.useSuggested(1010)
            check("「develop を基準にする」で develop になり、注意が消える",
                  s.picked.first { $0.id == 1010 }.map { !$0.baseWarning && $0.base == "develop" } == true)

            // 続けて 2 つにチェックを付けても、2 つとも見込みを調べる（準備の処理は 1 つずつ動き、順番を待ったものも調べる。W-1・10/21）。
            // 見込みを調べる処理を本当に動かす: --inspect で呼ばれた名前に見込みを書いて返す小さな台本（GitHub には問い合わせない）
            let stub = """
            import datetime, json, os, sys, time
            d = os.environ["GITHUB_FETCH_DATA"]
            p = os.path.join(d, "リポジトリ候補.json")
            f = json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {}
            name = sys.argv[3] if len(sys.argv) > 3 and sys.argv[2] == "--inspect" else ""
            time.sleep(0.3)
            for r in f.get("repos") or []:
                if r.get("name") == name:
                    r["estimate"] = {"all": 9000, "days90": 300}
                    r["hint"] = {}
            f["last"] = {"mode": "inspect", "at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"), "ok": True, "found": 1}
            json.dump(f, open(p, "w", encoding="utf-8"), ensure_ascii=False)
            open(os.path.join(d, "調べた.log"), "a", encoding="utf-8").write(name + "\\n")
            """
            try stub.write(to: Paths.script, atomically: true, encoding: .utf8)
            func waitHelpers() {   // 準備の処理が全部終わるまで待つ（終わりの知らせは、メインの流れで受け取る）
                let deadline = Date().addingTimeInterval(20)
                while s.helperRunning && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            }
            waitHelpers()   // 上の試しで付けたものの見込み調べ（順番を待っていた分）を、先に流し切る
            try? fm.removeItem(at: Paths.data.appendingPathComponent("調べた.log"))
            try "{\"repos\": [{\"id\": 1021, \"name\": \"test-owner/first\", \"created\": \"2020-01-01\"}, {\"id\": 1022, \"name\": \"test-owner/second\", \"created\": \"2020-01-01\"}]}"
                .write(to: Paths.candidates, atomically: true, encoding: .utf8)
            s.closeNow(); s.open()
            if let c1 = s.candidates.first(where: { $0.id == 1021 }), let c2 = s.candidates.first(where: { $0.id == 1022 }) {
                s.toggle(c1); s.toggle(c2)   // 1 つ目を調べている間に、2 つ目にチェック
            }
            let queuedBoth = s.inspecting == [1021, 1022]
            waitHelpers()
            let asked = text(Paths.data.appendingPathComponent("調べた.log")).split(separator: "\n").map(String.init)
            check("続けて 2 つにチェックを付けても、2 つとも見込みを調べる（1 つずつ順に: \(asked.joined(separator: " → "))）",
                  queuedBoth && asked == ["test-owner/first", "test-owner/second"] && s.inspecting.isEmpty)
            check("順番を待った 2 つ目も見込みが届き、大きいので「90日前から」に選び直す",
                  s.picked.first { $0.id == 1022 }?.estimate?.all == 9000 && s.picked.first { $0.id == 1022 }?.fromKind == .days90)

            // 見込みを調べたが届かなかった（GitHub につながらない形の台本）→「見込みを調べられませんでした」。チェックを付け直すと調べ直す（Y-7・10/21）
            let failStub = """
            import datetime, json, os, sys
            d = os.environ["GITHUB_FETCH_DATA"]
            p = os.path.join(d, "リポジトリ候補.json")
            f = json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {}
            f["last"] = {"mode": "inspect", "at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"), "ok": False,
                         "error": "GitHub につながりませんでした"}
            json.dump(f, open(p, "w", encoding="utf-8"), ensure_ascii=False)
            sys.exit(1)
            """
            try failStub.write(to: Paths.script, atomically: true, encoding: .utf8)
            try "{\"repos\": [{\"id\": 1031, \"name\": \"test-owner/offline\", \"created\": \"2020-01-01\"}]}"
                .write(to: Paths.candidates, atomically: true, encoding: .utf8)
            s.closeNow(); s.open()
            if let c = s.candidates.first(where: { $0.id == 1031 }) { s.toggle(c) }
            waitHelpers()
            let failedLabel = s.picked.first { $0.id == 1031 }.map { s.estimateLabel($0) } ?? ""
            check("見込みが届かなかったリポジトリは「見込みを調べられませんでした」（「保存のあとに」と言わない）: \(failedLabel)",
                  failedLabel.hasPrefix("見込みを調べられませんでした"))
            try stub.write(to: Paths.script, atomically: true, encoding: .utf8)
            if let c = s.candidates.first(where: { $0.id == 1031 }) { s.toggle(c); s.toggle(c) }   // チェックを付け直す
            waitHelpers()
            let retried = s.picked.first { $0.id == 1031 }.map { s.estimateLabel($0) } ?? ""
            check("チェックを付け直すと、もう一度調べて見込みが届く: \(retried)", retried.hasPrefix("見込み 約"))

            // 記録のファイル: 2つが同時に書いても上書きしない（Slack 取得で 2026-10-09 に起きた順番を再現）
            guard let first = Store.appLog("状況の数え直し"), let second = Store.appLog("取得") else {
                check("記録のファイルを開ける", false)
                throw CocoaError(.fileWriteUnknown)
            }
            func child(_ text: String, _ h: FileHandle) {   // 台本（別のプログラム）として書く
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/echo")
                p.arguments = [text]
                p.standardOutput = h
                try? p.run()
                p.waitUntilExit()
            }
            child("取得を始めます", second)
            child("数え直しました", first)
            child("取り残しはありません", second)
            let log = text(Paths.logs.appendingPathComponent("アプリから動かした記録.log"))
            let positions = ["に開始（状況の数え直し）", "に開始（取得）", "取得を始めます", "数え直しました", "取り残しはありません"]
                .map { log.range(of: $0)?.lowerBound }
            check("記録のファイルは、2つが同時に書いても上書きせず、書いた順に後ろへ足す",
                  !positions.contains { $0 == nil } && positions.compactMap { $0 } == positions.compactMap { $0 }.sorted())
        } catch {
            print("NG  準備で失敗: \(error)")
            ng += 1
        }
        print(ng == 0 ? "すべて期待どおりです" : "\(ng) 件おかしい")
        return ng == 0 ? 0 : 1
    }
}
