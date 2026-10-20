#!/usr/bin/env python3
"""GitHub 取得の取る係。gh api の GET だけで GitHub を読み、原本・記録・照合・状態を作る（設計書.md）。

使い方（アプリが動かす。手で動かすときも同じ）:
  python3 github.py fetch                      取る → 記録を作る → 照合する → 状態.json と取得の記録を書く
  python3 github.py build                      原本から記録を作り直す（GitHub には問い合わせない）
  python3 github.py status refresh             状況ページの数字と照合を数え直す（GitHub には問い合わせない）
  python3 github.py setup --login              gh のログインを確かめ、見えるリポジトリの一覧を読む（リポジトリ候補.json）
  python3 github.py setup --find owner/name    リポジトリを 1 つ調べて、候補に足す
  python3 github.py setup --inspect owner/name 基準のブランチの提案と、最初の取得の見込みの回数を調べる
環境:
  GITHUB_FETCH_DATA  データの場所（無ければ ~/GitHub取得データ）。試しは必ず一時フォルダにする
  CALL_CAP           1 回の取得で使ってよい回数（既定 1500。0 は上限なし）
  NOTIFY             1 なら終わったときに通知する（既定 1）
  SLEEP_DELAYED      予定の時刻（9:00 など）に Mac が眠っていたので、起きてから始めたとき（アプリが渡す）
  GITHUB_FETCH_WAIT_SCALE  待つ秒数に掛ける値（試しの道具だけが使う。既定 1。0 にすると、GitHub の「待って」を守らなくなる）
約束: GitHub には書き込まない。GitHub への問い合わせは gh_argv_allowed を通ったものだけ
（gh api --method GET -i [-H If-None-Match: …] <許可した場所> と gh --version）。許可の外は止めて、取得ログに全文を残す。
手元のコマンドとして、pmset（Mac の電源の記録）と osascript（通知）も動かす（どちらも GitHub には問い合わせない）。
"""
import datetime
import glob
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.parse

# ---- 場所と決まった数 ----

BASE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.abspath(os.path.expanduser(os.environ.get("GITHUB_FETCH_DATA") or "~/GitHub取得データ"))
REPOS_PATH = os.path.join(DATA, "リポジトリ.json")
SHELVED_PATH = os.path.join(DATA, "外したリポジトリ.json")
CANDIDATES_PATH = os.path.join(DATA, "リポジトリ候補.json")
EXCEPTIONS_PATH = os.path.join(DATA, "例外.json")
STATE_PATH = os.path.join(DATA, "状態.json")
HISTORY_PATH = os.path.join(DATA, "取得の記録.jsonl")
LOG_ROOT = os.path.join(DATA, "取得ログ")
LOCK = os.path.join(DATA, ".取得中")
GLOBAL_RAW = os.path.join(DATA, "原本")      # リポジトリに属さない返事（user・user/repos・rate_limit）

GH = "gh"
UTC = datetime.timezone.utc
JST = datetime.timezone(datetime.timedelta(hours=9))   # 日の区切り（Slack 版と同じ。設計書 4.6）
DEFAULT_CAP = 1500
RATE_RESERVE = 300          # GitHub の枠に残しておく回数（設計書 4.7）
OVERLAP_DAYS = 14           # 取り直しの窓（設計書 4.5）
ACTIVE_DAYS = 14            # 「動いた」とみなす日数
CI_KEEP_DAYS = 400          # CI の結果が GitHub に残っている目安（約 13 か月）。最初の取得はこの間に動いた PR の CI を聞く（設計書 2.1）
GHOST_ID = 10137            # 消されたアカウント（ghost）の番号。作者がこれの PR は、検索に出ない（設計書 5 章）
WAIT_SCALE = float(os.environ.get("GITHUB_FETCH_WAIT_SCALE") or 1)   # 試しのときだけ 0（待たない）
RETRY_WAITS = (2, 5, 10)    # 取り直しの間（3 回まで）
RECHECK_WAIT = 20           # 照合で合わないとき、取り直す前に待つ秒数
RETRY_AFTER_LIMIT = 600     # retry-after で待つのは、1 回の取得で合わせて 10 分まで
EVENT_SKIP = {"subscribed", "unsubscribed", "mentioned"}   # 通知の設定にあたる種類は、記録に入れない（設計書 3.3）
ZERO_SHA = "0" * 40


# ---- 時刻 ----

def utcnow():
    return datetime.datetime.now(UTC)


def iso_z(dt):
    """記録と原本の時刻（UTC・末尾 Z。GitHub の返事と同じ書き方）"""
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def now_iso():
    """状態.json と取得の記録の時刻（Slack 版と同じ +09:00 付き）"""
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def parse_time(s):
    """ISO の時刻（Z でも +09:00 でも）。読めなければ None"""
    if not s:
        return None
    try:
        return datetime.datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except ValueError:
        return None


def jst_day(s):
    """日本時間の暦日（yyyy-MM-dd）。日ごとの数はこれで分ける"""
    t = parse_time(s)
    return t.astimezone(JST).date().isoformat() if t else None


def week_start(dt):
    """その週の月曜 0:00（UTC）。一覧の since をここに丸めて、問い合わせの場所を 1 週間同じにする（設計書 4.4）"""
    d = dt.astimezone(UTC)
    d = d - datetime.timedelta(days=d.weekday())
    return d.replace(hour=0, minute=0, second=0, microsecond=0)


def local_iso(s):
    t = parse_time(s)
    return t.astimezone().isoformat(timespec="seconds") if t else None


# ---- ファイル ----

def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
        f.write("\n")
    os.replace(tmp, path)


def write_jsonl(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


def read_jsonl(path):
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        rows.append(json.loads(line))
                    except ValueError:
                        pass
    except OSError:
        pass
    return rows


def append_jsonl(path, row):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def repo_dir(repo):
    owner, name = repo["name"].split("/", 1)
    return os.path.join(DATA, "リポジトリ", "%s__%s__%s" % (owner, name, repo["id"]))


def listed_repos():
    return [r for r in (read_json(REPOS_PATH, []) or []) if r.get("id") and r.get("name")]


def data_inside_code():
    """データの場所が、取得の仕組みのフォルダの中なら True（公開リポジトリに入らないよう、外に置く決まり）"""
    d, b = os.path.realpath(DATA), os.path.realpath(BASE)
    return d == b or d.startswith(b + os.sep)


# ---- 取得ログ ----

class Log:
    """取得ログ/<年-月>/<日時>.log（全文）と、問い合わせ 1 回ごとの 1 行（<日時>_問い合わせ.jsonl）"""

    def __init__(self, stamp):
        month = stamp[:4] + "-" + stamp[4:6]
        self.dir = os.path.join(LOG_ROOT, month)
        os.makedirs(self.dir, exist_ok=True)
        self.path = os.path.join(self.dir, stamp + ".log")
        self.calls_path = os.path.join(self.dir, stamp + "_問い合わせ.jsonl")

    def line(self, text, show=True):
        if show:
            print(text, flush=True)
        with open(self.path, "a", encoding="utf-8") as f:
            f.write("[%s] %s\n" % (datetime.datetime.now().strftime("%H:%M:%S"), text))

    def call(self, row):
        append_jsonl(self.calls_path, row)


# ---- gh の許可リスト（読むだけを、道具の側で縛る。設計書 4.2） ----

_NAME = r"[A-Za-z0-9_.-]+"
_REPO = r"(?:repos/%s/%s|repositories/[0-9]+)" % (_NAME, _NAME)
_SHA = r"[0-9a-f]{7,40}"
PAGE = {"per_page", "page", "after", "before"}   # ページ送り（番号と、GitHub が返すしるし）
ALLOWED_PATHS = [
    (r"user", set()),
    (r"user/repos", PAGE | {"affiliation", "sort", "direction", "visibility"}),
    (r"rate_limit", set()),
    (r"search/issues", {"q", "per_page"}),
    (_REPO, set()),
    (_REPO + r"/git/ref/heads/(?!.*\.\.)[A-Za-z0-9_./-]+", set()),
    (_REPO + r"/activity", {"ref", "per_page", "after", "before", "direction"}),
    (_REPO + r"/commits", PAGE | {"sha", "since", "until"}),
    (_REPO + r"/commits/" + _SHA + r"/check-runs", PAGE | {"filter"}),
    (_REPO + r"/commits/" + _SHA + r"/status", PAGE),
    (_REPO + r"/compare/" + _SHA + r"\.\.\." + _SHA, PAGE),
    (_REPO + r"/issues", PAGE | {"state", "since", "sort", "direction"}),
    (_REPO + r"/issues/events", PAGE),
    (_REPO + r"/issues/comments", PAGE | {"since", "sort", "direction"}),
    (_REPO + r"/issues/[0-9]+/comments", PAGE),   # コメントの数が合わないときに、その issue・PR の分を全部取り直す
    (_REPO + r"/pulls", PAGE | {"state", "sort", "direction"}),
    (_REPO + r"/pulls/[0-9]+", set()),
    (_REPO + r"/pulls/[0-9]+/reviews", PAGE),
    (_REPO + r"/pulls/comments", PAGE | {"since", "sort", "direction"}),
    (_REPO + r"/releases", PAGE),
    (_REPO + r"/tags", PAGE),
    (_REPO + r"/branches", PAGE),
]


def path_allowed(where):
    """問い合わせの場所が、決めた形と決めた引数だけでできているか"""
    if not where or where.startswith("/") or "://" in where or "graphql" in where.lower():
        return False
    path, _, query = where.partition("?")
    if any(seg in (".", "..") for seg in path.split("/")):   # gh がたどって、決めた形の外の場所に届く（設計書 4.2）
        return False
    if not any(re.fullmatch(p, path) for p, _ in ALLOWED_PATHS):
        return False
    names = {k for k, _ in urllib.parse.parse_qsl(query, keep_blank_values=True)}
    allowed = next(a for p, a in ALLOWED_PATHS if re.fullmatch(p, path))
    return names <= allowed


def gh_argv_allowed(argv):
    """外のコマンドを確かめる。通すのは次の 2 つの形だけ:
      gh --version
      gh api --method GET -i [-H "If-None-Match: <ETag>"] <許可した場所>
    -f・-F・--field・--raw-field・--input・--method の GET 以外・graphql・表に無い場所は、すべて止める"""
    if list(argv) == [GH, "--version"]:
        return True
    if list(argv[:5]) != [GH, "api", "--method", "GET", "-i"]:
        return False
    rest = list(argv[5:])
    if len(rest) == 3 and rest[0] == "-H" and rest[1].startswith("If-None-Match: ") and "\n" not in rest[1]:
        rest = rest[2:]
    return len(rest) == 1 and not rest[0].startswith("-") and path_allowed(rest[0])


class Refused(Exception):
    """許可リストの外のコマンドを動かそうとした（作りのまちがい。その回の取得を止める）"""


def run_command(argv, timeout=120):
    if not gh_argv_allowed(argv):
        raise Refused(" ".join(argv))
    return subprocess.run(argv, capture_output=True, timeout=timeout)


# ---- 返事 ----

class Resp:
    def __init__(self, status, headers, body, data, raw_path=None, where=None):
        self.status, self.headers, self.body, self.data = status, headers, body, data
        self.raw_path, self.where = raw_path, where

    @property
    def next(self):
        return link_next(self.headers.get("link", ""))


def link_next(link):
    """返事の Link の next（https://api.github.com/ を除いた場所）"""
    for part in (link or "").split(","):
        m = re.search(r'<https://api\.github\.com/([^>]+)>;\s*rel="next"', part)
        if m:
            return m.group(1)
    return None


def parse_gh_output(out):
    """gh api -i の出力を、状態の番号・見出し・本文に分ける。HTTP の行が無ければ None"""
    text = out.decode("utf-8", "replace")
    m = re.match(r"HTTP/[0-9.]+ ([0-9]{3})", text)
    if not m:
        return None
    head, sep, body = text.partition("\r\n\r\n")
    if not sep:
        head, sep, body = text.partition("\n\n")
    headers = {}
    for line in head.splitlines()[1:]:
        k, _, v = line.partition(":")
        if k.strip():
            headers[k.strip().lower()] = v.strip()
    return int(m.group(1)), headers, body


class Stop(Exception):
    """その回の取得を止める（しおりは書いてあるので、次は続きから取れる）。
    kind: stop（止めるボタン）・cap（1 回の上限）・rate（GitHub の枠）・login・network・gh_missing・refused"""

    def __init__(self, kind, message, wait_until=None):
        Exception.__init__(self, message)
        self.kind, self.message, self.wait_until = kind, message, wait_until


class RepoError(Exception):
    """そのリポジトリだけ取れない（次のリポジトリへ進む）。kind: not_found・forbidden・sso・server"""

    def __init__(self, kind, message):
        Exception.__init__(self, message)
        self.kind, self.message = kind, message


# ---- 原本の保存（設計書 2.2・3.2） ----

def trim_body(kind, data):
    """保存する前に捨てる欄（ソースコードの中身・出来事に付く issue の写し）。捨てた欄の名前を返す"""
    removed = set()
    if kind == "compare" and isinstance(data, dict) and "files" in data:
        data.pop("files")
        removed.add("files")
    if kind == "code_comments" and isinstance(data, list):
        for c in data:
            if isinstance(c, dict) and "diff_hunk" in c:
                c.pop("diff_hunk")
                removed.add("diff_hunk")
    if kind == "check_runs" and isinstance(data, dict):
        for c in data.get("check_runs") or []:
            out = c.get("output") or {}
            for k in ("text", "summary"):
                if k in out:
                    out.pop(k)
                    removed.add("output." + k)
    if kind == "events" and isinstance(data, list):
        for e in data:
            iss = e.get("issue") if isinstance(e, dict) else None
            if isinstance(iss, dict):
                e["issue"] = {"number": iss.get("number"), "pull_request": bool(iss.get("pull_request"))}
                removed.add("issue（番号と PR かどうか以外）")
    return sorted(removed)


class Run:
    """1 回の取得。問い合わせの回数・枠・上限・止める印を見張り、返事を原本に書く"""

    def __init__(self, cap, log, stamp):
        self.cap, self.log, self.stamp = cap, log, stamp
        self.calls = 0          # 回数を使った問い合わせ
        self.free = 0           # 使わなかった問い合わせ（変わっていない 304）
        self.seq = 0
        self.rate = {}          # core の枠（最後の問い合わせの時点）
        self.waited = 0         # retry-after で待った秒数の合計
        self.incomplete = []    # 取り直しても取れなかった一覧（照合の「ページの取りこぼし」）
        self.empty_pages = []   # 次のページをたどったのに、取り直しても空だったページ（同じ）
        self.started = utcnow()

    # ---- 見張り ----

    def check_stop(self):
        if os.path.exists(os.path.join(LOCK, "stop")):
            raise Stop("stop", "止めるボタンで止めた")

    def check_cap(self):
        if self.cap and self.calls >= self.cap:
            raise Stop("cap", "1回の上限（%s 回）に届いた" % format(self.cap, ","))

    def note_rate(self, headers):
        res = headers.get("x-ratelimit-resource", "core")
        try:
            info = {"limit": int(headers["x-ratelimit-limit"]), "remaining": int(headers["x-ratelimit-remaining"]),
                    "reset": iso_z(datetime.datetime.fromtimestamp(int(headers["x-ratelimit-reset"]), UTC))}
        except (KeyError, ValueError):
            return None
        if res == "core":
            self.rate = info
        return res, info

    # ---- 1 回の問い合わせ ----

    def get(self, where, kind, rdir=None, etag=None, quiet_404=False, save=True):
        """GET を 1 回（取り直しは 3 回まで）。200 は原本に書く（save=False のときは書かない）。304 は数えずに返す（本文は無い）"""
        last = None
        for attempt in range(len(RETRY_WAITS) + 1):
            self.check_stop()
            self.check_cap()
            argv = [GH, "api", "--method", "GET", "-i"] + (["-H", "If-None-Match: " + etag] if etag else []) + [where]
            t0 = time.time()
            try:
                p = run_command(argv)
            except FileNotFoundError:
                raise Stop("gh_missing", "gh（GitHub の公式の道具）が見つからない")
            except subprocess.TimeoutExpired:
                p = None
            elapsed = round(time.time() - t0, 2)
            parsed = parse_gh_output(p.stdout) if p is not None else None
            if parsed is None:
                err = p.stderr.decode("utf-8", "replace").strip() if p is not None else "2 分たっても返事が無かった"
                self.log.line("問い合わせに返事が無い（%d 回目）: %s → %s" % (attempt + 1, where, err))
                self.log.call({"at": iso_z(utcnow()), "where": where, "status": None, "error": err, "elapsed": elapsed})
                if re.search(r"gh auth login|not logged in|authentication", err, re.I):
                    raise Stop("login", "GitHub のログインが切れていた（gh にログインしていない）")
                last = ("network", err)
                if attempt < len(RETRY_WAITS):
                    time.sleep(RETRY_WAITS[attempt] * WAIT_SCALE)
                continue
            status, headers, body = parsed
            rate = self.note_rate(headers)
            row = {"at": iso_z(utcnow()), "where": where, "status": status, "elapsed": elapsed,
                   "etag_sent": bool(etag), "remaining": rate[1]["remaining"] if rate else None,
                   "resource": rate[0] if rate else None}
            if status == 304:
                self.free += 1
                self.log.call(dict(row, counted=False))
                return Resp(304, headers, "", None, where=where)
            self.calls += 1
            self.log.call(dict(row, counted=True))
            if rate and rate[0] == "core" and rate[1]["remaining"] < RATE_RESERVE and status < 400:
                # この返事は使ってから止める（原本に書く）。次の問い合わせの前に止まる
                self._rate_low = rate[1]
            if status == 401:
                self.log.line("401 の全文: %s" % body[:2000])
                raise Stop("login", "GitHub のログインが切れていた（401）")
            if status in (403, 429) and rate and rate[0] == "search" and rate[1]["remaining"] == 0 \
                    and self.waited < RETRY_AFTER_LIMIT:
                # 検索の枠（1 分 30 回）を使い切った。1 分以内に戻るので、待ってから続ける
                reset = parse_time(rate[1]["reset"])
                wait = int(min(65, max(1, (reset - utcnow()).total_seconds() + 1))) if reset else 60
                self.log.line("検索の枠（1 分あたり）を使い切った。%d 秒待ってから続ける" % wait)
                self.waited += wait
                time.sleep(wait * WAIT_SCALE)
                continue
            if status in (403, 429):
                low = headers.get("x-ratelimit-remaining") == "0"
                if headers.get("retry-after") and self.waited < RETRY_AFTER_LIMIT:
                    wait = min(int(headers.get("retry-after", "60") or 60), RETRY_AFTER_LIMIT - self.waited)
                    self.log.line("短い時間に多すぎる、と言われた（retry-after %s 秒）。待ってから続ける" % wait)
                    self.waited += wait
                    time.sleep(wait * WAIT_SCALE)
                    continue
                if low:
                    reset = rate[1]["reset"] if rate else None
                    # 戻る時刻が分からないとき（見出しが無い返事）も、アプリが自動で続けられるよう 1 時間後にする
                    raise Stop("rate", "GitHub の 1 時間あたりの回数を使い切った",
                               wait_until=reset or iso_z(utcnow() + datetime.timedelta(hours=1)))
                if "rate limit" in body.lower():
                    # 二つ目の制限（短い時間に多すぎる）。retry-after が無いときは 1 分待つ（設計書 6 章）
                    if self.waited < RETRY_AFTER_LIMIT:
                        wait = min(60, RETRY_AFTER_LIMIT - self.waited)
                        self.log.line("短い時間に問い合わせが多すぎる、と言われた（retry-after なし）。%d 秒待ってから続ける" % wait)
                        self.waited += wait
                        time.sleep(wait * WAIT_SCALE)
                        continue
                    raise Stop("rate", "短い時間に問い合わせが多すぎると言われた（少し待ってから続きを取る）",
                               wait_until=iso_z(utcnow() + datetime.timedelta(minutes=15)))
                self.log.line("%d の全文: %s → %s" % (status, where, body[:2000]))
                # SSO は見出しの X-GitHub-SSO と本文の saml で見分ける（本文の「sso」の並びは associated などに当たる）
                if headers.get("x-github-sso") or "saml" in body.lower():
                    raise RepoError("sso", "組織の許可（SSO）が要る")
                raise RepoError("forbidden", "見る権限が無い（403）")
            if status == 404:
                if not quiet_404:
                    self.log.line("404: %s" % where)
                return Resp(404, headers, body, None, where=where)
            if status >= 500:
                self.log.line("GitHub の側の不調（%d・%d 回目）: %s" % (status, attempt + 1, where))
                last = ("server", "GitHub の側が不調だった（%d）" % status)
                if attempt < len(RETRY_WAITS):
                    time.sleep(RETRY_WAITS[attempt] * WAIT_SCALE)
                continue
            if status >= 400:
                self.log.line("%d の全文: %s → %s" % (status, where, body[:2000]))
                raise RepoError("forbidden", "GitHub が受け付けなかった（%d）" % status)
            try:
                data = json.loads(body)
            except ValueError:
                self.log.line("返事の形が崩れていた（途中で切れた JSON・%d 回目）: %s" % (attempt + 1, where))
                last = ("server", "返事の形が崩れていた")
                if attempt < len(RETRY_WAITS):
                    time.sleep(RETRY_WAITS[attempt] * WAIT_SCALE)
                continue
            raw_path = self.save_raw(rdir, kind, where, status, headers, data) if save else None
            return Resp(status, headers, body, data, raw_path=raw_path, where=where)
        if last and last[0] == "network":
            raise Stop("network", "GitHub につながらなかった")
        raise RepoError("server", last[1] if last else "取れなかった")

    def after_response(self):
        """枠の残りが少ないときは、ここで止める（返事は原本に書いたあと）"""
        low = getattr(self, "_rate_low", None)
        if low:
            raise Stop("rate", "GitHub の枠の残りが %d 回になった（%d 回は残しておく）" % (low["remaining"], RATE_RESERVE),
                       wait_until=low["reset"])

    def save_raw(self, rdir, kind, where, status, headers, data):
        removed = trim_body(kind, data)
        self.seq += 1
        root = os.path.join(rdir, "原本") if rdir else GLOBAL_RAW
        month = self.stamp[:4] + "-" + self.stamp[4:6]
        path = os.path.join(root, kind, month, "%s_%04d.json" % (self.stamp, self.seq))
        meta = {"where": where, "kind": kind, "fetched_at": iso_z(utcnow()), "status": status,
                "etag": headers.get("etag"), "link_next": link_next(headers.get("link", "")),
                "rate": {k: headers.get("x-ratelimit-" + k) for k in ("resource", "limit", "remaining", "used", "reset")},
                "run": self.stamp, "removed": removed}
        write_json(path, {"meta": meta, "body": data})
        return path

    # ---- ページ送り（Link の next をたどる。--paginate は使わない。設計書 4.4） ----

    def pages(self, where, kind, rdir, bm, stop=None, max_pages=None, keep_going_after_304=True):
        """1 ページずつ取る。前に取ったページの場所には ETag を添え、変わっていなければ（304）前の原本を読む。
        stop(items) が True を返したら、そこで止める（そのページは使う）。返すのは [(items, raw_path, 304 か)]"""
        out, n = [], 0
        pages_bm = bm.setdefault("pages", {})
        while where:
            n += 1
            prev = pages_bm.get(where) or {}
            etag = prev.get("etag") if prev.get("raw") and os.path.exists(os.path.join(rdir or DATA, prev["raw"])) else None
            r = self.get(where, kind, rdir, etag=etag)
            if r.status == 304:
                saved = read_json(os.path.join(rdir or DATA, prev["raw"]), {}) or {}
                items, nxt, path, same = saved.get("body"), prev.get("next"), prev["raw"], True
            elif r.status == 200:
                if n > 1 and r.data == [] and not getattr(r, "_retried", False):
                    # 前のページの next をたどったのに空だった（GitHub の一時的な不調のことがある）。1 回だけ取り直す
                    self.log.line("次のページが空で返った（%d ページ目）。1 回だけ取り直す: %s" % (n, where))
                    time.sleep(RETRY_WAITS[0] * WAIT_SCALE)
                    r2 = self.get(where, kind, rdir)
                    if r2.status == 200:
                        r2._retried = True
                        r = r2
                    if r.data == []:
                        self.empty_pages.append((where, n))
                items, nxt, path, same = r.data, r.next, os.path.relpath(r.raw_path, rdir or DATA), False
                pages_bm[where] = {"etag": r.headers.get("etag"), "raw": path, "next": nxt}
            else:
                return out, r
            self.after_response()
            out.append((items, path, same))
            if stop and stop(items):
                break
            if same and not keep_going_after_304:
                break
            if max_pages and n >= max_pages:
                break
            where = nxt
        return out, None


# ==== 取る（設計書 4.3） ====

def start_of(cfg):
    """取り始める日（日本時間の 0:00）を UTC で"""
    d = cfg.get("from") or "1970-01-01"
    return datetime.datetime.fromisoformat(d + "T00:00:00+09:00").astimezone(UTC)


def bm_path(rdir):
    return os.path.join(rdir, "しおり.json")


def first_items(pages):
    """pages() の結果から、項目を順に（ページの本文が配列のときだけ）"""
    for items, _, _ in pages:
        if isinstance(items, list):
            for x in items:
                yield x


def oldest(items, key):
    ts = [parse_time(i.get(key)) for i in items if isinstance(i, dict) and i.get(key)]
    return min(ts) if ts else None


def fetch_repo(run, cfg, log):
    """リポジトリを 1 つ取る。取れた分は 1 ページごとに原本に書いてある。しおりは最後に書く"""
    rdir = repo_dir(cfg)
    os.makedirs(rdir, exist_ok=True)
    bm = read_json(bm_path(rdir), {}) or {}
    rid, base = int(cfg["id"]), cfg.get("base") or "main"
    P = "repositories/%d" % rid
    start = start_of(cfg)
    before = bm.get("fetch") or {}
    same_run = before.get("started") == iso_z(run.started)
    if not same_run:
        refill_if_moved(bm, cfg, base, log)
    prev = parse_time(bm.get("last_success"))
    if same_run and before.get("line") and before.get("since"):
        # 同じ回の取り直し（照合で合わないとき）は、1 回目と同じ範囲を読む。1 回目で「最後にうまく取れた時刻」が
        # 進んだあとに線を引き直すと、範囲が直近 14 日に縮み、古い範囲の NG が消える（設計書 5 章・レビュー 4 回目 K-2）
        first, line, since = bool(before.get("first")), parse_time(before["line"]), parse_time(before["since"])
    else:
        first = prev is None
        line = max(start, prev - datetime.timedelta(days=OVERLAP_DAYS)) if prev else start   # 取り直しの窓の線
        since = max(start, week_start(line)) if prev else start
    since_q = iso_z(since)
    facts = {"started": iso_z(run.started), "line": iso_z(line), "since": since_q, "first": first, "incomplete": [],
             "notes": []}
    if same_run:   # 同じ回の取り直し。先に見つけた取りこぼしは消さない
        facts["incomplete"] = list(before.get("incomplete") or [])
    try:
        return _fetch_repo(run, cfg, log, rdir, bm, rid, base, P, start, first, line, since, since_q, facts)
    finally:
        # 途中で止まっても、しおり（取ったページの ETag・済んだ PR と CI・前回いちばん新しかった記録と出来事の番号）は書く。
        # 最後にうまく取れた時刻と取った期間は、読み切ったときだけ進める（読み直す範囲は時刻の線で決まるので、すき間はできない）
        write_json(bm_path(rdir), bm)


def refill_if_moved(bm, cfg, base, log):
    """取り始める日を前にずらした・基準のブランチを変えたリポジトリは、次の取得を最初の取得として読む（設計書 4.9。
    Slack 版と同じ考え: 取ってある所は取り直さず、足りない古い分を足す）。GitHub の一覧の多くは期間で区切れないので、
    一覧は新しい日から読み直す。済んだ PR・CI と、取ったページの ETag は使い回す（聞き直さない）。原本は消さない"""
    read_from, read_base = bm.get("read_from"), bm.get("read_base")
    if not bm.get("last_success") or (read_from is None and read_base is None):
        return   # まだ読み切っていない（最初の取得の途中は、そのまま新しい日まで読む）か、比べる元が無い（前の版で読み切った）
    moved_from = (cfg.get("from") or "") < (read_from or "")
    moved_base = bool(read_base) and base != read_base
    if not (moved_from or moved_base):
        return
    why = []
    if moved_from:
        why.append("取り始める日を %s から %s に前へずらした" % (read_from, cfg.get("from")))
    if moved_base:
        why.append("基準のブランチを %s から %s に変えた" % (read_base, base))
    log.line("  %s。足りない古い分を、最初の取得として読み直します（済んだ PR と CI は聞き直しません）" % "・".join(why))
    for k in ("last_success", "spans", "fetch", "activity_newest_id", "events_newest_id", "open_lists_done"):
        bm.pop(k, None)
    bm["filling"] = {"why": "・".join(why), "at": iso_z(utcnow()), "base_changed": moved_base}


def _fetch_repo(run, cfg, log, rdir, bm, rid, base, P, start, first, line, since, since_q, facts):
    q = urllib.parse.urlencode

    def need(pages_bad, what):
        out, bad = pages_bad
        while run.empty_pages:
            where, n = run.empty_pages.pop(0)
            facts["incomplete"].append("%s（%d ページ目が空で返った）" % (what, n))
        if bad is not None:
            if bad.status == 404:
                raise RepoError("not_found", "%s が見えません（権限が無いか、名前が変わったか、消えた）" % what)
            facts["incomplete"].append(what)
        return out

    # 1. リポジトリの情報（名前の変更・アーカイブ・見えるか・開いている数）
    info = need(run.pages(P, "repo", rdir, bm, max_pages=1), "リポジトリ")[0][0]
    facts.update(full_name=info.get("full_name"), default_branch=info.get("default_branch"),
                 open_issues_count=info.get("open_issues_count"), pushed_at=info.get("pushed_at"),
                 created_at=info.get("created_at"), archived=info.get("archived"), visibility=info.get("visibility"))
    if info.get("full_name") and info["full_name"] != cfg["name"]:
        facts["notes"].append("名前が変わっていました（%s → %s）" % (cfg["name"], info["full_name"]))

    # 2. 基準の先頭（「0件」を信じてよいかの確かめに使う）
    head = need(run.pages(P + "/git/ref/heads/" + urllib.parse.quote(base, safe="/"), "base_head", rdir, bm,
                          max_pages=1), "基準のブランチ（%s）" % base)[0][0]
    facts["base_head"] = (head.get("object") or {}).get("sha")

    # 3. 入った記録（新しい順。14 日の線と、前回いちばん新しかった記録の両方を越えたら止める）
    act_prev = int(bm.get("activity_newest_id") or 0)

    def stop_act(items):
        if not items:
            return True
        o = oldest(items, "timestamp")
        return o is not None and o < line and (first or min(i["id"] for i in items) <= act_prev)
    acts = list(first_items(need(run.pages(P + "/activity?" + q({"ref": "refs/heads/" + base, "per_page": 100}),
                                           "activity", rdir, bm, stop=stop_act), "入った記録")))
    bm["activity_newest_id"] = max([act_prev] + [int(a["id"]) for a in acts])

    # 4. コミット（親をたどって、入った記録ごとに新しく入ったコミットを出すため）
    need(run.pages(P + "/commits?" + q({"sha": base, "since": since_q, "per_page": 100}), "commits", rdir, bm),
         "コミット")

    # 5. 手元でたどりきれない入った記録だけ、compare で聞く（作ったとき・つながりの無い書き換えは、後の先頭から全部）。
    #    入った記録の鎖の切れ目（GitHub の側で記録が抜けたもの）も、compare を 1 回聞いて埋める（設計書 4.6）
    resolve_landings(run, cfg, rdir, bm, facts)
    fill_gaps(run, cfg, rdir, bm)

    # 6. PR と issue（一覧で閉じた・マージしたものと出来事を突き合わせるので、出来事より先に取る）
    need(run.pages(P + "/issues?" + q({"state": "all", "since": since_q, "per_page": 100}), "issues", rdir, bm),
         "PR と issue の一覧")

    def stop_pulls(items):
        o = oldest(items, "updated_at")
        return not items or (o is not None and o < line)
    pulls = list(first_items(need(run.pages(P + "/pulls?" + q({"state": "all", "sort": "updated", "direction": "desc",
                                                                 "per_page": 100}), "pulls", rdir, bm,
                                            stop=stop_pulls), "PR の一覧")))
    created = parse_time(info.get("created_at"))
    if first and created and start > created and not bm.get("open_lists_done"):
        # 取り始める日より前に作られ、まだ開いているもの（照合の「開いている数」に要る）
        need(run.pages(P + "/pulls?" + q({"state": "open", "per_page": 100}), "pulls_open", rdir, bm), "開いている PR")
        need(run.pages(P + "/issues?" + q({"state": "open", "per_page": 100}), "issues_open", rdir, bm),
             "開いている PR と issue")
        bm["open_lists_done"] = True
    seen_pr = bm.setdefault("pr_seen", {})
    moved = {}
    for pr in pulls:
        t = parse_time(pr.get("updated_at"))
        if t and t >= line:
            moved.setdefault(pr["number"], pr)
    for n, pr in sorted(moved.items()):
        if seen_pr.get(str(n)) == pr.get("updated_at"):
            continue
        need(run.pages(P + "/pulls/%d" % n, "pull", rdir, bm, max_pages=1), "PR #%d の詳しさ" % n)
        need(run.pages(P + "/pulls/%d/reviews?per_page=100" % n, "reviews", rdir, bm), "PR #%d のレビュー" % n)
        seen_pr[str(n)] = pr.get("updated_at")

    # 7. 出来事（since が効かない。1 ページ目から、14 日の線と前回いちばん新しかった ID の両方を越えるまで）
    ev_prev = int(bm.get("events_newest_id") or 0)

    def stop_ev(items):
        if not items:
            return True
        o = oldest(items, "created_at")
        return o is not None and o < line and (first or min(e["id"] for e in items) <= ev_prev)
    ev_pages = need(run.pages(P + "/issues/events?per_page=100", "events", rdir, bm, stop=stop_ev), "出来事")
    evs = list(first_items(ev_pages))
    ev_ids = [int(e["id"]) for e in evs]
    facts["events"] = {"prev_newest": ev_prev, "found_prev": first or ev_prev in ev_ids or not ev_prev,
                       "first_page_same": bool(ev_pages and ev_pages[0][2]),
                       "oldest_read": iso_z(oldest(evs, "created_at")) if evs else None,
                       "list_end": bool(ev_pages) and not stop_ev(ev_pages[-1][0] or []) and len(ev_pages[-1][0] or []) < 100}
    bm["events_newest_id"] = max([ev_prev] + ev_ids)

    # 8. コメントとコードへのコメント
    need(run.pages(P + "/issues/comments?" + q({"since": since_q, "per_page": 100}), "comments", rdir, bm), "コメント")
    need(run.pages(P + "/pulls/comments?" + q({"since": since_q, "per_page": 100}), "code_comments", rdir, bm),
         "コードへのコメント")

    # 9. CI の結果（開いていて動いた PR・前回から閉じた PR・基準の先頭。結果が出そろったものは、もう聞かない）
    targets = {}
    if facts.get("base_head"):
        targets[facts["base_head"]] = "base"
    # 最初の取得は、CI の結果が残っている約 13 か月の間に動いた PR まで聞く（それより前は結果がもう無い。設計書 2.1）
    ci_line = max(start, utcnow() - datetime.timedelta(days=CI_KEEP_DAYS)) if first else line
    for n, pr in moved.items():
        if (parse_time(pr.get("updated_at")) or ci_line) < ci_line:
            continue
        sha = (pr.get("head") or {}).get("sha")
        if sha:
            targets.setdefault(sha, "pr:%d" % n)
    ci_done = bm.setdefault("ci_done", {})
    for sha, why in targets.items():
        if ci_done.get(sha):
            continue
        runs = need(run.pages(P + "/commits/%s/check-runs?per_page=100" % sha, "check_runs", rdir, bm),
                    "CI の結果（%s）" % sha[:7])
        st = need(run.pages(P + "/commits/%s/status" % sha, "status", rdir, bm, max_pages=1), "CI の状態（%s）" % sha[:7])
        all_runs = [c for body, _, _ in runs if isinstance(body, dict) for c in body.get("check_runs") or []]
        status = (st[0][0] or {}) if st else {}
        settled = all(c.get("status") == "completed" for c in all_runs) and status.get("state") != "pending"
        if settled and why != "base" and (all_runs or status.get("statuses")):
            ci_done[sha] = iso_z(utcnow())

    # 10. リリースとタグ（最初は全部、あとは 1 ページ目だけ。変わっていなければ 304）
    need(run.pages(P + "/releases?per_page=100", "releases", rdir, bm, max_pages=None if first else 1), "リリース")
    need(run.pages(P + "/tags?per_page=100", "tags", rdir, bm, max_pages=None if first else 1), "タグ")

    # 11. PR と issue の数（検索。照合の「件数の突き合わせ」。取り始めた日より後に作られたもの）
    name = info.get("full_name") or cfg["name"]
    for kind in ("pr", "issue"):
        r = run.get("search/issues?" + q({"q": "repo:%s is:%s created:>=%s" % (name, kind, iso_z(start)),
                                           "per_page": 1}), "search", rdir)
        if r.status == 200:
            facts["search_" + kind] = {"total": r.data.get("total_count"), "incomplete": r.data.get("incomplete_results")}
        run.after_response()

    facts["ended"] = iso_z(utcnow())
    bm["fetch"] = facts
    if facts["incomplete"]:
        # 取りこぼしがあった回は、「最後にうまく取れた時刻」と取った期間を進めない。次の回が同じ所から読み直す
        # （前に取ったページは 304 で安い。GitHub が直っていれば、取りこぼした分を取り戻せる）
        log.line("  取りこぼしがあったので、次の回も同じ所から読み直します: %s" % "・".join(facts["incomplete"]))
    else:
        bm["last_success"] = iso_z(run.started)
        spans = bm.setdefault("spans", [])
        spans.append([iso_z(since if not first else start), iso_z(run.started)])
        bm["spans"] = merge_spans(spans)
        # 読み切ったときの取り始める日と基準を覚える（あとで前にずらした・基準を変えたと見分けるため。設計書 4.9）
        bm["read_from"], bm["read_base"] = cfg.get("from"), base
        filling = bm.pop("filling", None)
        if filling:
            facts["notes"].append("%s。足りない古い分を取りました%s" % (
                filling.get("why"), "（入ったものは新しいブランチで数え直しました）" if filling.get("base_changed") else ""))
    write_json(bm_path(rdir), bm)
    return facts


def refetch_comments(run, cfg, numbers, limit=20):
    """コメントの数が合わない issue・PR のコメントを、全部取り直す（設計書 5 章）。取り直した数を、しおりに残す"""
    rdir = repo_dir(cfg)
    bm = read_json(bm_path(rdir), {}) or {}
    P = "repositories/%d" % int(cfg["id"])
    full = bm.setdefault("full_comments", {})
    had = {}   # 取り直す前に記録にあった数（取り直しで増えたら「一覧の取りこぼし」と注記に出す）
    for c in read_jsonl(os.path.join(rdir, "記録", "コメント.jsonl")):
        if c.get("kind") == "comment":
            had[c.get("number")] = had.get(c.get("number"), 0) + 1
    try:
        for n in numbers[:limit]:
            out, bad = run.pages(P + "/issues/%d/comments?per_page=100" % n, "comments", rdir, bm)
            if bad is None:
                full[str(n)] = {"count": sum(len(items) for items, _, _ in out if isinstance(items, list)),
                                "at": iso_z(utcnow()), "before": had.get(n, 0)}
    finally:
        write_json(bm_path(rdir), bm)


def merge_spans(spans):
    """取った期間 [[始め, 終わり], …] を、重なり・つながりで 1 つにまとめる（照合の「期間の抜け」）"""
    out = []
    for a, b in sorted(spans):
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out


def resolve_landings(run, cfg, rdir, bm, facts):
    """手元のコミットの一覧で親をたどれない入った記録だけ、compare で聞く（設計書 4.6）。
    ブランチを作ったとき（前が 0000000）と、compare が 404 を返すつながりの無い書き換えは、後の先頭から辿れるコミット全部を取る"""
    P = "repositories/%d" % int(cfg["id"])
    asked = bm.setdefault("asked", {})
    for _ in range(4):   # compare で足したコミットで、ほかの記録もたどれるようになることがある
        model = landing_model(rdir, cfg)
        todo = [l for l in model["landings"] if l.get("missing")]
        if not todo:
            return
        progress = False
        for l in todo:
            key = "%s...%s" % (l["before"], l["after"])
            if l["before"] == ZERO_SHA or asked.get(key) == "404":
                k2 = "all:" + l["after"]
                if asked.get(k2):
                    continue
                out, bad = run.pages(P + "/commits?" + urllib.parse.urlencode({"sha": l["after"], "per_page": 100}),
                                     "commits_for", rdir, bm)
                asked[k2] = "done" if bad is None else str(bad.status)
                progress = progress or bad is None
                continue
            if asked.get(key):
                continue
            out, bad = run.pages(P + "/compare/%s...%s?per_page=100" % (l["before"], l["after"]), "compare", rdir, bm)
            asked[key] = "404" if (bad is not None and bad.status == 404) else ("done" if bad is None else str(bad.status))
            progress = True
        write_json(bm_path(rdir), bm)
        if not progress:
            break
    model = landing_model(rdir, cfg)
    left = [l for l in model["landings"] if l.get("missing")]
    if left:
        facts["notes"].append("親をたどりきれない入った記録が %d 件あります" % len(left))


def chain_breaks(landings):
    """入った記録の鎖の切れ目（前の記録の後の先頭 ≠ 次の記録の前の先頭）。[(前の後の先頭, 次の記録)]"""
    out, prev_after = [], None
    for L in landings:
        if prev_after and L["before"] not in (prev_after, ZERO_SHA) and L["kind"] not in ("branch_creation", "gap"):
            out.append((prev_after, L))
        if L["kind"] != "branch_deletion" and L.get("after") and L["after"] != ZERO_SHA:
            prev_after = L["after"]
    return out


def fill_gaps(run, cfg, rdir, bm):
    """入った記録の鎖の切れ目は、GitHub の側で記録が抜けたもの（whisper.cpp の 2023-06-25）。取り直しても直らないので、
    compare を 1 回聞いて間のコミットを出す（設計書 4.6）。埋めるのは記録を作るとき（landing_model）"""
    P = "repositories/%d" % int(cfg["id"])
    asked = bm.setdefault("asked", {})
    model = landing_model(rdir, cfg)
    for prev_after, L in chain_breaks(model["landings"]):
        key = "%s...%s" % (prev_after, L["before"])
        if asked.get(key):
            continue
        out, bad = run.pages(P + "/compare/%s...%s?per_page=100" % (prev_after, L["before"]), "compare", rdir, bm)
        asked[key] = "404" if (bad is not None and bad.status == 404) else ("done" if bad is None else str(bad.status))
    write_json(bm_path(rdir), bm)


# ==== 記録（原本から作る。何度でも作り直せる。設計書 3.3） ====

RAW_KINDS_LANDING = {"activity", "commits", "commits_for", "compare", "pulls", "pull", "pulls_open"}


def load_raw(rdir, kinds=None):
    """原本を、取った順に読む。{kind: [(meta, body, 場所)]}。読めない原本は "_broken" に場所だけ"""
    out, broken = {}, []
    for path in glob.glob(os.path.join(rdir, "原本", "*", "*", "*.json")):
        kind = path.split(os.sep)[-3]
        if kinds and kind not in kinds:
            continue
        d = read_json(path)
        if not isinstance(d, dict) or not isinstance(d.get("meta"), dict):
            broken.append(os.path.relpath(path, rdir))
            continue
        out.setdefault(kind, []).append((d["meta"], d.get("body"), os.path.relpath(path, rdir)))
    for v in out.values():
        v.sort(key=lambda x: (x[0].get("fetched_at") or "", x[2]))
    out["_broken"] = broken
    return out


def broken_raws(rdir):
    """読めない原本（形の崩れた JSON・添える情報が無いもの）の場所。照合の「原本の形」"""
    out = []
    for path in glob.glob(os.path.join(rdir, "原本", "*", "*", "*.json")):
        d = read_json(path)
        if not isinstance(d, dict) or not isinstance(d.get("meta"), dict):
            out.append(os.path.relpath(path, rdir))
    return out


def body_items(body, key=None):
    if isinstance(body, list):
        return body
    if isinstance(body, dict) and key:
        return body.get(key) or []
    return [body] if isinstance(body, dict) else []


def first_line(s, limit=300):
    t = (s or "").strip().split("\n", 1)[0].strip()
    return t[:limit]


def who(u):
    """人を、ログイン名と番号（ID）の組で（設計書 2.3）"""
    u = u or {}
    return u.get("login"), u.get("id")


def commit_graph(raws):
    """コミットの親子（sha → 親・題名・作った人・日時・知った時刻）"""
    g = {}
    for kind in ("commits", "commits_for", "compare"):
        for meta, body, _ in raws.get(kind, []):
            for c in body_items(body, "commits"):
                if not isinstance(c, dict) or not c.get("sha"):
                    continue
                if c["sha"] in g:
                    continue
                cm = c.get("commit") or {}
                login, uid = who(c.get("author"))
                g[c["sha"]] = {"p": [x.get("sha") for x in c.get("parents") or []],
                               "title": first_line(cm.get("message")),
                               "author": login, "author_id": uid,
                               "committed_at": (cm.get("committer") or {}).get("date"),
                               "known_at": meta.get("fetched_at")}
    return g


def activity_entries(raws, base):
    """基準のブランチの入った記録（古い順）。同じ記録が 2 回返ることがある（before・after・時刻が同じ）ので 1 つに"""
    by_id = {}
    for meta, body, _ in raws.get("activity", []):
        for a in body_items(body):
            if not isinstance(a, dict) or a.get("ref") not in ("refs/heads/" + base, base):
                continue
            if a["id"] not in by_id:
                by_id[a["id"]] = dict(a, _known=meta.get("fetched_at"))
    uniq = {}
    for a in sorted(by_id.values(), key=lambda a: (a.get("timestamp") or "", a["id"])):
        uniq.setdefault((a.get("before"), a.get("after"), a.get("timestamp"), a.get("activity_type")), a)
    return sorted(uniq.values(), key=lambda a: (a.get("timestamp") or "", a["id"]))


def reach_new(g, after, stop):
    """after から親をたどり、stop に着いたら止める。手元に無いコミットに着いたら missing に入れる"""
    new, missing, stack, seen = [], set(), [after], set()
    while stack:
        c = stack.pop()
        if not c or c in seen or c in stop:
            continue
        seen.add(c)
        node = g.get(c)
        if node is None:
            missing.add(c)
            continue
        new.append(c)
        stack.extend(node["p"])
    return new, missing


def reach_all(g, sha, within=None):
    """sha から辿れるコミット（手元にあるものだけ。within を渡すと、その中だけ）"""
    out, stack = set(), [sha]
    while stack:
        c = stack.pop()
        if not c or c in out or c not in g or (within is not None and c not in within):
            continue
        out.add(c)
        stack.extend(g[c]["p"])
    return out


def pr_latest(raws):
    """PR の番号 → いちばん新しい形（一覧と詳しさから）と、初めて現れた時刻"""
    latest, known = {}, {}
    for kind in ("pulls", "pulls_open", "pull"):
        for meta, body, _ in raws.get(kind, []):
            for p in body_items(body):
                if not isinstance(p, dict) or "number" not in p:
                    continue
                n = p["number"]
                known.setdefault(n, meta.get("fetched_at"))
                cur = latest.get(n)
                if cur is None or (p.get("updated_at") or "") > (cur.get("updated_at") or "") or \
                        ((p.get("updated_at") or "") == (cur.get("updated_at") or "") and kind == "pull"):
                    merged = dict(cur or {})
                    merged.update(p)
                    latest[n] = merged
    return latest, known


def landing_model(rdir, cfg, raws=None):
    """入った記録ごとに、新しく入ったコミットを出す（後の先頭から辿れて、前の先頭から辿れないもの。設計書 4.6）"""
    raws = raws or load_raw(rdir, RAW_KINDS_LANDING)
    base = cfg.get("base") or "main"
    start = start_of(cfg)
    g = commit_graph(raws)
    acts = [a for a in activity_entries(raws, base) if (parse_time(a.get("timestamp")) or start) >= start]
    compares = {}
    for meta, body, _ in raws.get("compare", []):
        m = re.search(r"/compare/([0-9a-f]+)\.\.\.([0-9a-f]+)", meta.get("where") or "")
        if not m or not isinstance(body, dict):
            continue
        c = compares.setdefault((m.group(1), m.group(2)), {"status": body.get("status"), "total": body.get("total_commits"),
                                                           "commits": []})
        for x in body.get("commits") or []:
            if x.get("sha") not in c["commits"]:
                c["commits"].append(x.get("sha"))
    landed, old = set(), set()
    if acts and acts[0].get("before") not in (None, ZERO_SHA):
        old = reach_all(g, acts[0]["before"])   # 取り始める前からブランチにあったもの
    landings, prev_after = [], None
    for a in acts:
        before, after, kind = a.get("before"), a.get("after"), a.get("activity_type")
        actor, actor_id = who(a.get("actor"))
        L = {"id": a["id"], "at": a.get("timestamp"), "kind": kind, "before": before, "after": after,
             "known_at": a.get("_known"), "actor": actor, "actor_id": actor_id}
        if kind == "branch_deletion" or not after or after == ZERO_SHA:
            L["new"] = []
            landings.append(L)
            continue
        gap = compares.get((prev_after, before)) if prev_after and before not in (prev_after, ZERO_SHA) \
            and kind != "branch_creation" else None
        if gap and gap["status"] == "ahead" and gap["total"] == len(gap["commits"]):
            # 鎖の切れ目（GitHub の入った記録の抜け）を compare で埋める。入った時刻は次の記録の時刻・推定の印（設計書 4.6）
            gap_new = [s for s in gap["commits"] if s not in landed]
            landings.append({"id": "gap:%s" % a["id"], "at": a.get("timestamp"), "kind": "gap", "before": prev_after,
                             "after": before, "known_at": a.get("_known"), "actor": None, "actor_id": None,
                             "estimated": True, "new": gap_new})
            landed |= set(gap_new)
        prev_after = after
        new, missing = reach_new(g, after, landed | old | {before})
        comp = compares.get((before, after))
        if missing and comp and comp["status"] in ("ahead", "diverged") and comp["total"] == len(comp["commits"]):
            new, missing = [s for s in comp["commits"] if s not in landed], set()
        L["new"] = new
        if missing:
            L["missing"] = sorted(missing)[:5]
        if kind == "force_push":
            still = reach_all(g, after)
            L["erased"] = sorted(s for s in landed if s not in still)
        landed |= set(new)
        landings.append(L)
    return {"graph": g, "landings": landings, "start": start}


def classify(model, prs):
    """入ったコミットを、PR 経由・直接・数えない（強制の書き換え）に分ける（設計書 4.6 の表）"""
    g = model["graph"]
    merged = {n: p for n, p in prs.items() if p.get("merged_at")}   # マージされずに閉じた PR は使わない
    by_merge = {p.get("merge_commit_sha"): n for n, p in merged.items() if p.get("merge_commit_sha")}
    by_head = {(p.get("head") or {}).get("sha"): n for n, p in merged.items() if (p.get("head") or {}).get("sha")}
    for L in model["landings"]:
        new = L.get("new") or []
        via = {}
        if L["kind"] in ("pr_merge", "merge_queue_merge"):
            n = by_merge.get(L["after"])
            if n is None:   # PR の一覧にまだ出ていないとき。題名の末尾の (#123) で補う（推定の印を付ける）
                m = re.search(r"\(#([0-9]+)\)\s*$", (g.get(L["after"]) or {}).get("title") or "")
                if m:
                    n = int(m.group(1))
                    L["via_guess"] = True
            for s in new:
                via[s] = n            # None は「分からない」（照合の「入り方の見分け」で NG）
        elif L["kind"] in ("push", "branch_creation", "gap"):   # gap（記録の抜けを補ったもの）も push の形と同じ決まり
            newset = set(new)
            cands = sorted({by_merge[s] for s in new if s in by_merge} | {by_head[s] for s in new if s in by_head})
            for n in cands:
                p = merged[n]
                h = (p.get("head") or {}).get("sha")
                h = h if h in newset else p.get("merge_commit_sha")
                for s in reach_all(g, h, within=newset):
                    via.setdefault(s, n)
            for s in new:
                via.setdefault(s, 0)  # 0 は直接
        L["via"] = via
    return model


def build_records(cfg):
    """原本から、記録の 7 つ（入ったもの・PR・issue・コメント・出来事・CI・リリース）を作り直す"""
    rdir = repo_dir(cfg)
    raws = load_raw(rdir)
    prs, pr_known = pr_latest(raws)
    model = classify(landing_model(rdir, cfg, raws), prs)
    g = model["graph"]
    erased_at = {}
    for L in model["landings"]:
        for s in L.get("erased") or []:
            erased_at.setdefault(s, L["at"])
    landed_rows = []
    for L in model["landings"]:
        for s in L.get("new") or []:
            c = g.get(s) or {}
            v = (L.get("via") or {}).get(s)
            row = {"sha": s, "landed_at": L["at"], "landed_by": L["kind"],
                   "via_pr": v if v else None, "title": c.get("title"), "author": c.get("author"),
                   "author_id": c.get("author_id"), "committed_at": c.get("committed_at"),
                   "event": "%s..%s" % ((L["before"] or "")[:7], (L["after"] or "")[:7]),
                   "merge": len(c.get("p") or []) > 1, "estimated": bool(L.get("estimated")), "known_at": L.get("known_at"),
                   "untrusted": ["title"]}
            if L["kind"] in ("pr_merge", "merge_queue_merge") and v is None:
                row["via_unknown"] = True
            if L.get("via_guess"):
                row["via_guess"] = True
            if s in erased_at:
                row["erased_at"] = erased_at[s]
            landed_rows.append(row)
    rec = os.path.join(rdir, "記録")
    write_jsonl(os.path.join(rec, "入ったもの.jsonl"), landed_rows)

    # PR と issue（いちばん新しい形）
    issue_items, issue_known = {}, {}
    for kind in ("issues", "issues_open"):
        for meta, body, _ in raws.get(kind, []):
            for it in body_items(body):
                if not isinstance(it, dict) or "number" not in it:
                    continue
                n = it["number"]
                issue_known.setdefault(n, meta.get("fetched_at"))
                cur = issue_items.get(n)
                if cur is None or (it.get("updated_at") or "") >= (cur.get("updated_at") or ""):
                    issue_items[n] = it
    pr_rows, issue_rows = [], []
    for n in sorted(set(prs) | {n for n, it in issue_items.items() if it.get("pull_request")}):
        p = prs.get(n) or {}
        it = issue_items.get(n) or {}
        if not p and not it:
            continue
        a, aid = who(p.get("user") or it.get("user"))
        ms = it.get("milestone") or p.get("milestone") or {}
        pr_rows.append({
            "number": n, "title": p.get("title") or it.get("title"), "state": p.get("state") or it.get("state"),
            "draft": p.get("draft"), "merged_at": p.get("merged_at"), "merge_commit_sha": p.get("merge_commit_sha") if p.get("merged_at") else None,
            "head_sha": (p.get("head") or {}).get("sha"), "head_ref": (p.get("head") or {}).get("ref"),
            "head_repo": ((p.get("head") or {}).get("repo") or {}).get("full_name"),
            "base": (p.get("base") or {}).get("ref"), "author": a, "author_id": aid,
            "created_at": p.get("created_at") or it.get("created_at"), "updated_at": max(p.get("updated_at") or "", it.get("updated_at") or ""),
            "closed_at": p.get("closed_at") or it.get("closed_at"),
            "labels": [l.get("name") for l in (it.get("labels") or p.get("labels") or []) if isinstance(l, dict)],
            "assignees": [{"login": x.get("login"), "id": x.get("id")} for x in (it.get("assignees") or p.get("assignees") or [])],
            "requested_reviewers": [{"login": x.get("login"), "id": x.get("id")} for x in (p.get("requested_reviewers") or [])],
            "milestone": {"title": ms.get("title"), "due_on": ms.get("due_on")} if ms else None,
            "comments": it.get("comments", p.get("comments")), "review_comments": p.get("review_comments"),
            "commits": p.get("commits"), "additions": p.get("additions"), "deletions": p.get("deletions"),
            "changed_files": p.get("changed_files"), "body": p.get("body") if p.get("body") is not None else it.get("body"),
            "known_at": min(x for x in (pr_known.get(n), issue_known.get(n)) if x) if (pr_known.get(n) or issue_known.get(n)) else None,
            "untrusted": ["title", "body", "labels", "head_ref", "head_repo", "milestone"]})
    for n, it in sorted(issue_items.items()):
        if it.get("pull_request"):
            continue
        a, aid = who(it.get("user"))
        ms = it.get("milestone") or {}
        issue_rows.append({
            "number": n, "title": it.get("title"), "state": it.get("state"), "state_reason": it.get("state_reason"),
            "author": a, "author_id": aid, "created_at": it.get("created_at"), "updated_at": it.get("updated_at"),
            "closed_at": it.get("closed_at"), "labels": [l.get("name") for l in it.get("labels") or [] if isinstance(l, dict)],
            "assignees": [{"login": x.get("login"), "id": x.get("id")} for x in it.get("assignees") or []],
            "milestone": {"title": ms.get("title"), "due_on": ms.get("due_on")} if ms else None,
            "comments": it.get("comments"), "body": it.get("body"), "known_at": issue_known.get(n),
            "untrusted": ["title", "body", "labels", "milestone"]})
    write_jsonl(os.path.join(rec, "PR.jsonl"), pr_rows)
    write_jsonl(os.path.join(rec, "issue.jsonl"), issue_rows)

    # コメント（会話のコメント・コードへのコメント・レビュー）
    comments = {}

    def num_from(url):
        m = re.search(r"/(?:issues|pulls)/([0-9]+)$", url or "")
        return int(m.group(1)) if m else None
    for kind, ckind in (("comments", "comment"), ("code_comments", "code_comment"), ("reviews", "review")):
        for meta, body, _ in raws.get(kind, []):
            for c in body_items(body):
                if not isinstance(c, dict) or "id" not in c:
                    continue
                key = (ckind, c["id"])
                a, aid = who(c.get("user"))
                if ckind == "comment":
                    number = num_from(c.get("issue_url"))
                elif ckind == "code_comment":
                    number = num_from(c.get("pull_request_url"))
                else:
                    m = re.search(r"/pulls/([0-9]+)/reviews", meta.get("where") or "")
                    number = int(m.group(1)) if m else None
                row = {"id": c["id"], "kind": ckind, "number": number, "author": a, "author_id": aid,
                       "created_at": c.get("created_at") or c.get("submitted_at"),
                       "updated_at": c.get("updated_at") or c.get("submitted_at"), "body": c.get("body"),
                       "known_at": (comments.get(key) or {}).get("known_at") or meta.get("fetched_at"),
                       "untrusted": ["body"]}
                if ckind == "review":
                    row.update(state=c.get("state"), commit_id=c.get("commit_id"))
                if ckind == "code_comment":
                    row.update(path=c.get("path"), line=c.get("line"), original_line=c.get("original_line"),
                               commit_id=c.get("commit_id"), in_reply_to_id=c.get("in_reply_to_id"))
                    row["untrusted"] = ["body", "path"]
                cur = comments.get(key)
                if cur is None or (row["updated_at"] or "") >= (cur["updated_at"] or ""):
                    comments[key] = row
    write_jsonl(os.path.join(rec, "コメント.jsonl"),
                sorted(comments.values(), key=lambda r: (r.get("created_at") or "", r["id"])))

    # 出来事（通知の種類は入れない）
    events = {}
    for meta, body, _ in raws.get("events", []):
        for e in body_items(body):
            if not isinstance(e, dict) or "id" not in e or e["id"] in events or e.get("event") in EVENT_SKIP:
                continue
            a, aid = who(e.get("actor"))
            detail, untrusted = {}, []
            if e.get("label"):
                detail["label"] = (e.get("label") or {}).get("name")
                untrusted.append("detail.label")
            if e.get("rename"):
                detail["rename"] = e.get("rename")
                untrusted.append("detail.rename")
            if e.get("commit_id"):
                detail["commit_id"] = e.get("commit_id")
            if e.get("assignee"):
                detail["assignee"] = {"login": e["assignee"].get("login"), "id": e["assignee"].get("id")}
            if e.get("milestone"):
                detail["milestone"] = (e.get("milestone") or {}).get("title")
                untrusted.append("detail.milestone")
            if e.get("requested_reviewer"):
                detail["requested_reviewer"] = {"login": e["requested_reviewer"].get("login"),
                                                "id": e["requested_reviewer"].get("id")}
            if e.get("state_reason"):
                detail["state_reason"] = e.get("state_reason")
            iss = e.get("issue") or {}
            events[e["id"]] = {"id": e["id"], "event": e.get("event"), "at": e.get("created_at"),
                               "number": iss.get("number"), "pr": bool(iss.get("pull_request")),
                               "actor": a, "actor_id": aid, "bot": ((e.get("actor") or {}).get("type") == "Bot"),
                               "detail": detail, "known_at": meta.get("fetched_at"), "untrusted": untrusted}
    write_jsonl(os.path.join(rec, "出来事.jsonl"), sorted(events.values(), key=lambda r: (r["at"] or "", r["id"])))

    # CI の結果（コミットごと。いちばん新しい形）
    ci = {}
    for meta, body, _ in raws.get("check_runs", []):
        m = re.search(r"/commits/([0-9a-f]+)/check-runs", meta.get("where") or "")
        for c in body_items(body, "check_runs"):
            key = ("check_run", c.get("id"))
            ci[key] = {"sha": c.get("head_sha") or (m.group(1) if m else None), "kind": "check_run", "name": c.get("name"),
                       "app": (c.get("app") or {}).get("slug"), "status": c.get("status"), "conclusion": c.get("conclusion"),
                       "started_at": c.get("started_at"), "completed_at": c.get("completed_at"),
                       "known_at": (ci.get(key) or {}).get("known_at") or meta.get("fetched_at"), "untrusted": ["name", "app"]}
    for meta, body, _ in raws.get("status", []):
        if not isinstance(body, dict):
            continue
        for s in body.get("statuses") or []:
            key = ("status", body.get("sha"), s.get("context"))
            ci[key] = {"sha": body.get("sha"), "kind": "status", "name": s.get("context"), "state": s.get("state"),
                       "created_at": s.get("created_at"), "updated_at": s.get("updated_at"),
                       "known_at": (ci.get(key) or {}).get("known_at") or meta.get("fetched_at"), "untrusted": ["name"]}
    write_jsonl(os.path.join(rec, "CI.jsonl"), sorted(ci.values(), key=lambda r: (r.get("sha") or "", r.get("name") or "")))

    # リリースとタグ
    rel = {}
    for meta, body, _ in raws.get("releases", []):
        for r in body_items(body):
            if isinstance(r, dict) and "id" in r:
                a, aid = who(r.get("author"))
                rel[("release", r["id"])] = {"kind": "release", "tag": r.get("tag_name"), "name": r.get("name"),
                                             "draft": r.get("draft"), "prerelease": r.get("prerelease"),
                                             "created_at": r.get("created_at"), "published_at": r.get("published_at"),
                                             "author": a, "author_id": aid,
                                             "known_at": (rel.get(("release", r["id"])) or {}).get("known_at") or meta.get("fetched_at"),
                                             "untrusted": ["name", "tag"]}
    for meta, body, _ in raws.get("tags", []):
        for t in body_items(body):
            if isinstance(t, dict) and t.get("name"):
                rel.setdefault(("tag", t["name"]), {"kind": "tag", "tag": t["name"], "sha": (t.get("commit") or {}).get("sha"),
                                                     "known_at": meta.get("fetched_at"), "untrusted": ["tag"]})
    write_jsonl(os.path.join(rec, "リリース.jsonl"),
                sorted(rel.values(), key=lambda r: (r.get("published_at") or r.get("created_at") or "", r.get("tag") or "")))
    return {"model": model, "raws": raws, "prs": prs, "broken": raws.get("_broken") or []}


# ==== 数える（状況ページの数字。設計書 3.4・4.6） ====

def units_of(rows):
    """入ったものを、数える単位にする（PR 経由は PR 1 件で 1 つ・直接はコミット 1 つずつ・マージのコミットと強制の書き換えは数えない）。
    消えたコミット（強制の書き換え）も、それまでに数えた分は減らさない（10/20 本人 OK）"""
    seen, out = set(), []
    for r in sorted(rows, key=lambda r: (r.get("landed_at") or "", r.get("sha") or "")):
        if r.get("merge") or r.get("landed_by") == "force_push":
            continue
        if r.get("via_pr"):
            key, is_pr = ("pr", r["via_pr"]), True
        elif r.get("via_unknown"):
            key, is_pr = ("landing", r.get("event")), True   # PR のマージの記録で、PR が分からないもの（1 つと数える）
        else:
            key, is_pr = ("c", r.get("sha")), False
        if key in seen:
            continue
        seen.add(key)
        out.append({"at": r.get("landed_at"), "pr": is_pr, "known_at": r.get("known_at"), "key": key})
    return out


def jst_today():
    return datetime.datetime.now(JST).date()


def last_days(n=14):
    t = jst_today()
    return [(t - datetime.timedelta(days=i)).isoformat() for i in range(n - 1, -1, -1)]


def one_line(s, limit=120):
    t = re.sub(r"\s+", " ", s or "").strip()
    return t if len(t) <= limit else t[:limit - 1] + "…"


def repo_stats(cfg, run_start=None, keep_delta=None):
    """記録から、リポジトリ 1 つの数字（状態.json の repos[] の 1 つ）を作る"""
    rdir = repo_dir(cfg)
    rec = os.path.join(rdir, "記録")
    bm = read_json(bm_path(rdir), {}) or {}
    facts = bm.get("fetch") or {}
    rows = read_jsonl(os.path.join(rec, "入ったもの.jsonl"))
    units = units_of(rows)
    days = last_days(14)
    per = {d: [0, 0] for d in days}
    for u in units:
        d = jst_day(u["at"])
        if d in per:
            per[d][0 if u["pr"] else 1] += 1
    week = [{"date": d, "pr": per[d][0], "direct": per[d][1]} for d in days[7:]]
    now = utcnow()
    act_line = now - datetime.timedelta(days=ACTIVE_DAYS)
    prs = read_jsonl(os.path.join(rec, "PR.jsonl"))
    issues = read_jsonl(os.path.join(rec, "issue.jsonl"))
    comments = read_jsonl(os.path.join(rec, "コメント.jsonl"))
    ci = read_jsonl(os.path.join(rec, "CI.jsonl"))
    rels = [r for r in read_jsonl(os.path.join(rec, "リリース.jsonl")) if r.get("kind") == "release" and not r.get("draft")]

    def recent(x):
        t = parse_time(x.get("updated_at"))
        return t is not None and t >= act_line
    open_prs = [p for p in prs if p.get("state") == "open"]
    open_issues = [i for i in issues if i.get("state") == "open"]
    reviews = {}
    for c in comments:
        if c.get("kind") == "review" and c.get("state") in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED") and c.get("author_id"):
            key = (c.get("number"), c["author_id"])
            if (c.get("created_at") or "") >= (reviews.get(key, {}).get("created_at") or ""):
                reviews[key] = c
    failed_sha = {c.get("sha") for c in ci if c.get("conclusion") in ("failure", "timed_out") or c.get("state") in ("failure", "error")}

    def pr_flags(p):
        f = []
        if p.get("draft"):
            f.append("下書き")
        states = {c.get("state") for (n, _), c in reviews.items() if n == p.get("number")}
        if "CHANGES_REQUESTED" in states:
            f.append("変更の依頼")
        elif "APPROVED" in states:
            f.append("承認済み")
        if p.get("head_sha") in failed_sha:
            f.append("CI 失敗")
        return f
    act_prs = [p for p in open_prs if recent(p)]
    flags = {"draft": 0, "changes_requested": 0, "approved": 0, "ci_failed": 0}
    for p in act_prs:
        fl = pr_flags(p)
        flags["draft"] += "下書き" in fl
        flags["changes_requested"] += "変更の依頼" in fl
        flags["approved"] += "承認済み" in fl
        flags["ci_failed"] += "CI 失敗" in fl
    active = [{"kind": "pr", "number": p["number"], "title": one_line(p.get("title")), "updated": local_iso(p.get("updated_at")),
               "flags": pr_flags(p)} for p in act_prs]
    active += [{"kind": "issue", "number": i["number"], "title": one_line(i.get("title")),
                "updated": local_iso(i.get("updated_at")), "flags": []} for i in open_issues if recent(i)]
    active.sort(key=lambda a: a.get("updated") or "", reverse=True)
    release = None
    if rels:
        r = max(rels, key=lambda r: r.get("published_at") or r.get("created_at") or "")
        t = r.get("published_at") or r.get("created_at")
        release = {"tag": r.get("tag") or "", "date": local_iso(t), "after": sum(1 for u in units if (u["at"] or "") > (t or ""))}
    if run_start is not None:
        delta = sum(1 for u in units if (u.get("known_at") or "") >= run_start)
    else:
        delta = keep_delta
    landed_times = [u["at"] for u in units if u.get("at")]
    return {
        "id": int(cfg["id"]), "tag": cfg.get("tag") or cfg["name"], "name": facts.get("full_name") or cfg["name"],
        "base": cfg.get("base") or "main", "visibility": facts.get("visibility"), "archived": facts.get("archived"),
        "from": cfg.get("from"), "fetched": local_iso(bm.get("last_success")), "error": None, "error_kind": None,
        # 一度も最後まで読み切っていないリポジトリを、画面で「取れています」と出さない（設計書 3.4・5 章）
        "complete": bool(bm.get("last_success")), "pending": pending_reason(bm, rdir),
        "total": len(units), "total_pr": sum(1 for u in units if u["pr"]), "delta": delta,
        "last7": sum(per[d][0] + per[d][1] for d in days[7:]), "last7_pr": sum(per[d][0] for d in days[7:]),
        "prev7": sum(per[d][0] + per[d][1] for d in days[:7]), "week": week,
        "last_landed": local_iso(max(landed_times)) if landed_times else None,
        "release": release, "stages": [],
        "open_prs": len(open_prs), "open_prs_active": len(act_prs), "open_issues": len(open_issues),
        "open_issues_active": sum(1 for i in open_issues if recent(i)),
        "pr_flags": flags if act_prs else None, "active": active[:5],
        "counts": {"prs": len(prs), "issues": len(issues),
                   "comments": sum(1 for c in comments if c.get("kind") in ("comment", "code_comment")),
                   "reviews": sum(1 for c in comments if c.get("kind") == "review")},
        "_units": units,
    }


def daily_of(stats):
    days = last_days(14)
    out = []
    for d in days:
        counts, pr = {}, {}
        for s in stats:
            n = sum(1 for u in s["_units"] if jst_day(u["at"]) == d)
            p = sum(1 for u in s["_units"] if u["pr"] and jst_day(u["at"]) == d)
            counts[s["tag"]] = n
            pr[s["tag"]] = p
        out.append({"date": d, "counts": counts, "pr": pr})
    return out


# ==== 照合（設計書 5 章。11 項目） ====

CHECK_NAMES = ["ページの取りこぼし", "件数の突き合わせ", "期間の抜け", "ブランチのつながり", "入り方の見分け",
               "基準の先頭", "開いている数", "出来事のつながり", "出来事と一覧", "原本の形", "既知の例外"]
RECHECK = {"基準の先頭", "開いている数", "出来事と一覧", "件数の突き合わせ"}   # 合わないとき、少し待って 1 回だけ取り直す


def short_t(s):
    """NG と注記の時刻（日本時間）。今年でないときは年を付ける（3 年分の記録で、何年のことか分かるように。設計書 5 章）"""
    t = parse_time(s)
    if not t:
        return "?"
    t = t.astimezone(JST)
    return t.strftime("%-m/%-d %-H:%M") if t.year == jst_today().year else t.strftime("%Y/%-m/%-d %-H:%M")


def pending_reason(bm, rdir):
    """一度も読み切っていないリポジトリの、「確かめていない」の理由（設計書 5 章）。読み切っていれば None"""
    if bm.get("last_success"):
        return None
    if bm.get("filling"):
        return "古い分を足している途中（%s）" % bm["filling"].get("why")
    seen = len(bm.get("pr_seen") or {})
    total = len(read_jsonl(os.path.join(rdir, "記録", "PR.jsonl")))
    if total:
        return "最初の取得の途中（PR %s / %s 件まで）" % (format(min(seen, total), ","), format(total, ","))
    return "最初の取得の途中"


def check_repo(cfg, built=None, run_start=None):
    """1 つのリポジトリの照合。({項目: [NG の理由]}, 注記, 数, 確かめていない理由) を返す。
    確かめるのは、照合の材料（しおりの fetch）が今回の取得のもの（run_start と同じ）のときだけ。ほかは確かめずに理由を返す
    （確かめていないのに OK と言わない。前の回の材料で比べると、逆向きの NG も出る。設計書 5 章・レビュー 4 回目 K-1）。
    run_start が None（状況の数え直し）なら、最後に読み切った回の材料で確かめる"""
    rdir = repo_dir(cfg)
    tag = cfg.get("tag") or cfg["name"]
    rec = os.path.join(rdir, "記録")
    bm = read_json(bm_path(rdir), {}) or {}
    f = bm.get("fetch") or {}
    ng = {n: [] for n in CHECK_NAMES}
    notes = []
    if not f:
        return ng, notes, {}, pending_reason(bm, rdir) or "まだ照合の材料が無い"
    if run_start is not None and f.get("started") != run_start:
        return ng, notes, {}, "今回は途中で止まった（前回の照合は %s の取得）" % short_t(f.get("started"))
    stat = {"checked_at": f.get("started")}
    for n in f.get("notes") or []:   # 取る係の注記（名前が変わっていました・古い分を足しました など）も、照合の注記に出す
        notes.append("%s: %s" % (tag, n))
    # ページの取りこぼし
    for what in f.get("incomplete") or []:
        ng["ページの取りこぼし"].append("%s: %s が取り直しても取れなかった" % (tag, what))
    # 件数の突き合わせ（取り始めた日より後に作られたもの）。作者のアカウントが消された PR・issue は検索に出ないので除く
    start = start_of(cfg)
    prs = read_jsonl(os.path.join(rec, "PR.jsonl"))
    issues = read_jsonl(os.path.join(rec, "issue.jsonl"))
    for kind, rows_, label in (("pr", prs, "PR"), ("issue", issues, "issue")):
        s = f.get("search_" + kind) or {}
        if s.get("total") is None:
            continue
        mine_rows = [r for r in rows_ if (parse_time(r.get("created_at")) or start) >= start]
        # 作者のアカウントが消された PR は、検索に出ない（issue は出る。10/20 に #3456・#3983 で確かめた）
        ghosts = [r for r in mine_rows if kind == "pr" and (r.get("author_id") == GHOST_ID or r.get("author") == "ghost")]
        mine = len(mine_rows) - len(ghosts)
        stat[kind] = (s["total"], mine)
        if ghosts:
            notes.append("%s: 作者のアカウントが消された %s %d 件（%s）は、GitHub の検索に出ないので、数から外して比べました"
                         % (tag, label, len(ghosts), "・".join("#%d" % r["number"] for r in ghosts[:5])))
        if s.get("incomplete"):
            notes.append("%s: GitHub の検索の数が途中までだった（%s）" % (tag, label))
        elif mine != s["total"]:
            ng["件数の突き合わせ"].append("%s: %s が GitHub %s / 取れた %s" % (tag, label, format(s["total"], ","), format(mine, ",")))
    # コメントの数（合わないものは番号の一覧にして、全部の取り直しに使う。設計書 5 章）
    comments = read_jsonl(os.path.join(rec, "コメント.jsonl"))
    per_num = {}
    for c in comments:
        if c.get("kind") == "comment":
            per_num[c.get("number")] = per_num.get(c.get("number"), 0) + 1
    checked, mismatch = 0, []
    covered = parse_time((bm.get("spans") or [[None]])[0][0]) if bm.get("spans") else None
    fulls = bm.get("full_comments") or {}
    for r in sorted(prs + issues, key=lambda r: r["number"]):
        cr = parse_time(r.get("created_at"))
        if r.get("comments") is None or not cr or not covered or cr < covered:
            continue
        checked += 1
        mine = per_num.get(r["number"], 0)
        full = fulls.get(str(r["number"])) or {}
        fresh = (full.get("at") or "") >= (r.get("updated_at") or "")   # 取り直したあと、その issue・PR は動いていない
        if fresh and full.get("before") is not None and full.get("count", 0) > full["before"]:
            notes.append("%s: #%d のコメントを全部取り直したら %d 件増えました（一覧の取りこぼし）"
                         % (tag, r["number"], full["count"] - full["before"]))
        if mine == r["comments"]:
            continue
        # 全部取り直した結果は、取り直したあと動いていないときだけ使う（古い結果で、新しいコメントの取りこぼしを隠さない）
        if fresh and full.get("count") == mine:
            if mine > r["comments"]:
                notes.append("%s: #%d は GitHub の数より %d 多く見えます（GitHub の側の数え違い。全部取り直して確かめた）"
                             % (tag, r["number"], mine - r["comments"]))
            else:
                notes.append("%s: #%d は GitHub の数のうち %d 件が見えません（消された・隠されたコメント。全部取り直して確かめた）"
                             % (tag, r["number"], r["comments"] - mine))
            continue
        mismatch.append(r["number"])
    if mismatch:
        ng["件数の突き合わせ"].append("%s: コメントの数が合わない issue・PR が %d 件（%s%s）" % (
            tag, len(mismatch), "・".join("#%d" % n for n in mismatch[:3]),
            "ほか %d 件" % (len(mismatch) - 3) if len(mismatch) > 3 else ""))
    stat["comments_checked"] = checked
    stat["comment_mismatch"] = mismatch
    # 期間の抜け
    spans = bm.get("spans") or []
    if len(spans) > 1:
        ng["期間の抜け"].append("%s: %s〜%s が取れていない" % (tag, short_t(spans[0][1]), short_t(spans[1][0])))
    elif spans and parse_time(spans[0][0]) and parse_time(spans[0][0]) > start + datetime.timedelta(minutes=1):
        ng["期間の抜け"].append("%s: 取り始めた日（%s）から取れていない" % (tag, cfg.get("from")))
    # ブランチのつながり（記録の抜けを compare で補ったものは注記）・入り方の見分け・基準の先頭（入った記録から）
    model = (built or {}).get("model") or classify(landing_model(rdir, cfg), pr_latest(load_raw(rdir, {"pulls", "pull", "pulls_open"}))[0])
    lands = model["landings"]
    g = model["graph"]
    prev_after = None
    for L in lands:
        if L["kind"] == "force_push":
            notes.append("%s: %s が %s に書き換えられました（強制の書き換え）。前の歴史は原本に残っています" % (tag, cfg.get("base"), short_t(L["at"])))
        if L["kind"] == "gap":
            ts = [x for x in ((g.get(s) or {}).get("committed_at") for s in L.get("new") or []) if x]
            notes.append("%s: GitHub の入った記録が %s ごろ 1 つ抜けていました。間のコミット %d 個を compare で補いました（推定）"
                         % (tag, short_t(max(ts) if ts else L["at"]), len(L.get("new") or [])))
        if L.get("missing"):
            ng["ブランチのつながり"].append("%s: %s の入った記録の親をたどりきれない" % (tag, short_t(L["at"])))
        if L["kind"] != "branch_deletion" and L.get("after") and L["after"] != ZERO_SHA:
            prev_after = L["after"]
    for _, L in chain_breaks(lands):
        ng["ブランチのつながり"].append("%s: 入った記録の鎖が %s で切れている（compare で埋められなかった）" % (tag, short_t(L["at"])))
    rows = read_jsonl(os.path.join(rec, "入ったもの.jsonl"))
    unknown = [r for r in rows if r.get("via_unknown")]
    if unknown:
        ng["入り方の見分け"].append("%s: PR のマージで入ったのに、どの PR か分からないものが %d 件" % (tag, len({r['event'] for r in unknown})))
    guessed = {r.get("via_pr") for r in rows if r.get("via_guess")}
    if guessed:
        notes.append("%s: PR の番号を題名の (#…) から補ったものが %d 件" % (tag, len(guessed)))
    stat["landed"] = len(rows)
    # 入った記録が始まる前の分は、まだ数えていない（推定は 12 章のとおり段 10）。NG にせず注記に出す（K-9）
    acts = [L for L in lands if L["kind"] != "gap"]
    first_at = parse_time(acts[0]["at"]) if acts else None
    if first_at and first_at - start > datetime.timedelta(days=1):
        landed_shas = {r.get("sha") for r in rows}
        n_old = sum(1 for sha, c in g.items() if sha not in landed_shas
                    and start <= (parse_time(c.get("committed_at")) or first_at) < first_at)
        if n_old:
            notes.append("%s: 取り始めた日（%s）から、GitHub の入った記録が始まる日（%s）までの %s コミットは、入ったものに数えていません"
                         % (tag, cfg.get("from"), jst_day(acts[0]["at"]), format(n_old, ",")))
    if f.get("base_head") and prev_after and f["base_head"] != prev_after:
        ng["基準の先頭"].append("%s: %s が動いたのに、入った記録が追いついていない（GitHub の先頭 %s・記録の最後 %s）"
                              % (tag, cfg.get("base"), f["base_head"][:7], prev_after[:7]))
    # 開いている数（GitHub の open_issues_count は PR と issue の合計）
    if f.get("open_issues_count") is not None:
        mine = sum(1 for r in prs if r.get("state") == "open") + sum(1 for r in issues if r.get("state") == "open")
        stat["open"] = (f["open_issues_count"], mine)
        if mine != f["open_issues_count"]:
            ng["開いている数"].append("%s: 開いている PR と issue が GitHub %d / 記録 %d" % (tag, f["open_issues_count"], mine))
    # 出来事のつながり
    ev = f.get("events") or {}
    if ev and not ev.get("found_prev") and not ev.get("first_page_same"):
        ng["出来事のつながり"].append("%s: 前回いちばん新しかった出来事が見つからない（消された issue の出来事かもしれません）" % tag)
    # 出来事と一覧（閉じた・マージしたものに、5 秒以内の出来事がある。読んだ範囲の端から 5 秒は見ない）。
    # discussion に移した issue は、GitHub が閉じるが、出来事は converted_to_discussion で残る（K-3）
    lo = parse_time(ev.get("oldest_read"))
    hi = parse_time(f.get("ended"))
    if lo and hi:
        lo = lo + datetime.timedelta(seconds=5)
        events = {}
        for e in read_jsonl(os.path.join(rec, "出来事.jsonl")):
            events.setdefault((e.get("number"), e.get("event")), []).append(parse_time(e.get("at")))
        miss, n_checked = [], 0
        for r in prs + issues:
            for field, kinds in (("closed_at", ("closed", "converted_to_discussion")), ("merged_at", ("merged",))):
                t = parse_time(r.get(field))
                if not t or t < lo or t > hi:
                    continue
                n_checked += 1
                if not any(x and abs((x - t).total_seconds()) <= 5 for k in kinds for x in events.get((r["number"], k), [])):
                    miss.append("#%d（%s）" % (r["number"], kinds[0]))
        stat["events_checked"] = n_checked
        if miss:
            ng["出来事と一覧"].append("%s: 一覧では閉じた・マージしたのに、出来事が無い: %s%s" % (
                tag, "・".join(miss[:5]), " ほか %d 件" % (len(miss) - 5) if len(miss) > 5 else ""))
    # 原本の形
    broken = (built or {}).get("broken")
    if broken is None:
        broken = broken_raws(rdir)
    if broken:
        ng["原本の形"].append("%s: 読めない原本が %d 個" % (tag, len(broken)))
    return ng, notes, stat, None


def run_checks(repos, built_map=None, skip=None, run_start=None):
    """全部のリポジトリの照合。状態.json の check を作る。確かめていないリポジトリ（最初の取得の途中・古い分を足している途中・
    今回は途中で止まった・取れなかった）は、OK にも NG にもせず、理由を出す（設計書 5 章）。
    項目の ok は真か偽だけ（アプリは null を読めない）。確かめていない項目は ok が偽で、state が unverified。
    返すのは (check, 項目ごとの NG の行, リポジトリごとの数)"""
    exceptions = read_json(EXCEPTIONS_PATH, []) or []
    skip = skip or {}
    total = {n: [] for n in CHECK_NAMES}
    notes, stats, unverified, checked_at = [], {}, [], []
    for cfg in repos:
        tag = cfg.get("tag") or cfg["name"]
        if cfg["id"] in skip:
            unverified.append({"repo": tag, "reason": "取れなかった（%s）" % (skip[cfg["id"]] or "理由は取得ログ")})
            continue
        ng, nt, st, why = check_repo(cfg, (built_map or {}).get(cfg["id"]), run_start)
        if why:
            unverified.append({"repo": tag, "reason": why})
            continue
        for k, v in ng.items():
            total[k].extend(v)
        notes.extend(nt)
        stats[cfg["id"]] = st
        checked_at.append(st.get("checked_at"))
    known = []
    for k in CHECK_NAMES:
        keep = []
        for line in total[k]:
            ex = next((e for e in exceptions if isinstance(e, dict) and e.get("match") and e["match"] in line), None)
            if ex:
                known.append("既知の例外: %s（%s）" % (line, ex.get("reason") or "理由なし"))
            else:
                keep.append(line)
        total[k] = keep
    n_repos = len(stats)
    landed = sum(s.get("landed", 0) for s in stats.values())
    ok_detail = {
        "ページの取りこぼし": "一覧を最後のページまで取れた（%d リポジトリ）・取り直しても取れなかった一覧 0" % n_repos,
        "件数の突き合わせ": "PR %s・issue %s が GitHub の数と一致。コメントの数も %d 件の PR・issue で一致" % (
            format(sum((s.get("pr") or (0, 0))[0] for s in stats.values()), ","),
            format(sum((s.get("issue") or (0, 0))[0] for s in stats.values()), ","),
            sum(s.get("comments_checked", 0) for s in stats.values())),
        "期間の抜け": "取り始めた日から最後の取得まで、すき間なし（%d リポジトリ）" % n_repos,
        "ブランチのつながり": "入った記録が 1 本につながっている（%d リポジトリ）" % n_repos,
        "入り方の見分け": "入ったコミット %s 件すべて、PR 経由か直接か（強制の書き換えは数えない）に分かれた" % format(landed, ","),
        "基準の先頭": "GitHub がいま指している基準の先頭と、記録の最後が同じ（%d リポジトリ）" % n_repos,
        "開いている数": "開いている PR と issue の数が GitHub の数と一致（%s 件）" % format(sum((s.get("open") or (0, 0))[0] for s in stats.values()), ","),
        "出来事のつながり": "前回いちばん新しかった出来事が、今回も見つかった（%d リポジトリ）" % n_repos,
        "出来事と一覧": "一覧で閉じた・マージしたもの %s 件に、同じ時刻の出来事がある" % format(sum(s.get("events_checked", 0) for s in stats.values()), ","),
        "原本の形": "読めない原本 0（%d リポジトリ）" % n_repos,
        "既知の例外": "%d 件（GitHub 側の食い違いで直しようがないもの）" % len(known),
    }
    pend = "・".join("%s（%s）" % (u["repo"], u["reason"]) for u in unverified[:3]) + (
        " ほか %d" % (len(unverified) - 3) if len(unverified) > 3 else "")
    items = []
    for k in CHECK_NAMES:
        if total[k]:
            items.append({"name": k, "ok": False, "state": "ng",
                          "detail": "・".join(total[k][:3]) + ("ほか %d" % (len(total[k]) - 3) if len(total[k]) > 3 else "")})
        elif unverified:
            detail = "確かめていない: %s" % pend
            if n_repos:
                detail += "。確かめた %d リポジトリは OK（%s）" % (n_repos, ok_detail[k])
            items.append({"name": k, "ok": False, "state": "unverified", "detail": detail})
        else:
            items.append({"name": k, "ok": True, "state": "ok", "detail": ok_detail[k]})
    ng_lines = ["NG %s" % line for k in CHECK_NAMES for line in total[k]]   # 頭は Slack 版と同じ「NG 」
    stamps = [c for c in checked_at if c]
    check = {"ng": ng_lines, "notes": notes, "items": items, "exceptions": known, "unverified": unverified,
             "checked_at": local_iso(max(stamps)) if stamps else None}
    return check, total, stats


# ==== 状態.json と取得の記録 ====

def all_stats(repos, run_start=None):
    st = read_json(STATE_PATH, {}) or {}
    keep = {r.get("id"): r.get("delta") for r in st.get("repos") or []}
    out = []
    for cfg in repos:
        out.append(repo_stats(cfg, run_start=run_start, keep_delta=keep.get(int(cfg["id"]))))
    return out


def public_stats(stats, errors=None):
    out = []
    for s in stats:
        s = {k: v for k, v in s.items() if not k.startswith("_")}
        e = (errors or {}).get(s["id"])
        if e:
            s["error"], s["error_kind"] = e
        out.append(s)
    # 取れなかったものを先に（小窓と状況ページで、必ず上に出す）
    out.sort(key=lambda s: (s.get("error") is None, -(parse_time(s.get("last_landed")) or datetime.datetime.min.replace(tzinfo=UTC)).timestamp()))
    return out


def write_running(run, progress, prev_end):
    st = read_json(STATE_PATH, {}) or {}
    st.update(source="github", updated=now_iso(), state="running")   # 取得中（Slack 版と同じ。設計書 3.4）
    st["run"] = {"start": local_iso(iso_z(run.started)), "end": None, "result": None, "note": None,
                 "since": prev_end, "calls": run.calls, "calls_free": run.free, "calls_cap": run.cap,
                 "rate": local_rate(run.rate), "progress": progress}
    write_json(STATE_PATH, st)


def local_rate(rate):
    if not rate:
        return None
    return {"limit": rate.get("limit"), "remaining": rate.get("remaining"), "reset": local_iso(rate.get("reset"))}


# ---- Mac のスリープ（Slack 版と同じ考え。手元のコマンド pmset で読む。GitHub には問い合わせない） ----

PMSET_RE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4}) (Sleep|Wake|DarkWake) +\t")


def mac_sleeps(t0, t1):
    """t0〜t1（UNIX 秒）に Mac が眠っていた区切り [(眠った, 起きた)]。点検で一瞬起きて 2 分以内に眠り直したものは続けて眠っていたことにする"""
    try:
        out = subprocess.run(["/usr/bin/pmset", "-g", "log"], capture_output=True, text=True, timeout=120).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    spans, since, t = [], None, None
    for line in out.splitlines():
        m = PMSET_RE.match(line)
        if not m:
            continue
        try:
            t = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S %z").timestamp()
        except ValueError:
            continue
        if t > t1:
            break
        if m.group(2) == "Sleep":
            if since is None:
                since = t
        elif since is not None:
            spans.append((since, t))
            since = None
    if since is not None:
        spans.append((since, t1))
    merged = []
    for a, b in spans:
        a, b = max(a, t0), min(b, t1)
        if b <= a:
            continue
        if merged and a - merged[-1][1] <= 120:
            merged[-1] = (merged[-1][0], b)
        else:
            merged.append((a, b))
    return merged


def span_text(seconds):
    m = int(seconds // 60)
    if m < 1:
        return "1分未満"
    return "%d時間%d分" % (m // 60, m % 60) if m >= 60 else "%d分" % m


def sleep_info(spans):
    if not spans:
        return None
    iso = lambda t: datetime.datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds")
    return {"count": len(spans), "seconds": int(sum(b - a for a, b in spans)), "spans": [[iso(a), iso(b)] for a, b in spans[:20]]}


def notify(title, text):
    """終わったときの通知（NOTIFY=0 なら出さない。手元のコマンド osascript。GitHub には問い合わせない）"""
    if os.environ.get("NOTIFY", "1") == "0":
        return
    esc = lambda s: (s or "").replace("\\", "\\\\").replace('"', '\\"')
    try:
        subprocess.run(["/usr/bin/osascript", "-e", 'display notification "%s" with title "GitHub 取得" subtitle "%s"'
                        % (esc(text), esc(title))], capture_output=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        pass


# ==== コマンド ====

def acquire_lock():
    """二重に動かさない（毎朝の自動と「今すぐ取る」が重なったときなど）。前の取得が途中で終わった跡は、取得の記録に残す"""
    os.makedirs(DATA, exist_ok=True)
    try:
        os.mkdir(LOCK)
    except FileExistsError:
        pid = None
        try:
            pid = int(open(os.path.join(LOCK, "pid")).read().strip())
        except (OSError, ValueError):
            pass
        if pid:
            try:
                os.kill(pid, 0)
                print("いま別の取得が動いています。終わってからもう一度動かしてください。")
                return False
            except OSError:
                pass
        started = None
        try:
            started = open(os.path.join(LOCK, "start")).read().strip()
        except OSError:
            pass
        if started:
            append_jsonl(HISTORY_PATH, {"start": started, "end": now_iso(), "result": "interrupted", "new": 0, "ng": 0,
                                        "note": "途中で終わった（アプリの終了や Mac の電源などで）。次の取得で続きから取った"})
            print("前の取得が途中で終わった跡があったので、取得の記録に残してから続けます。")
        shutil.rmtree(LOCK, ignore_errors=True)
        os.mkdir(LOCK)
    with open(os.path.join(LOCK, "pid"), "w") as f:
        f.write(str(os.getpid()))
    with open(os.path.join(LOCK, "start"), "w") as f:
        f.write(now_iso())
    return True


def on_term(signum, frame):
    raise Stop("stop", "止めるボタンで止めた（台本を止めた）")


def stop_result(e):
    """止まった理由 → 取得の結果と、平易な 1 行"""
    return {"stop": ("stopped", e.message), "cap": ("stopped", e.message), "rate": ("waiting", e.message),
            "login": ("login", e.message), "network": ("error", e.message),
            "gh_missing": ("error", "gh（GitHub の公式の道具）が見つからない"),
            "refused": ("error", "許可リストの外の問い合わせを止めた（作りのまちがい。取得ログに全文）")}.get(e.kind, ("error", e.message))


def cmd_fetch(_args):
    if data_inside_code():
        print("データの場所（%s）が、取得の仕組みのフォルダの中にあります。外に置いてください（GITHUB_FETCH_DATA）。" % DATA)
        return 2
    no_id = [r.get("name") or "?" for r in (read_json(REPOS_PATH, []) or []) if isinstance(r, dict) and not r.get("id")]
    if no_id:
        # 番号が 0 か無い（例を写したまま）。番号で取るので、知らないリポジトリを取りに行かないように止める（設計書 3.6）
        msg = ("番号が入っていないリポジトリがあります（%s）。python3 github.py setup --find owner/name で調べて、"
               "リポジトリ.json の id に書いてください" % "・".join(no_id))
        print(msg)
        st = read_json(STATE_PATH, {}) or {}
        st.update(source="github", updated=now_iso(), state="error",
                  run=dict(st.get("run") or {}, end=now_iso(), result="error", note=msg, progress=None))
        write_json(STATE_PATH, st)
        return 2
    repos = listed_repos()
    if not repos:
        print("取るリポジトリがありません（リポジトリ.json）。アプリの「はじめの準備」で選んでください。")
        return 2
    if not acquire_lock():
        return 3
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    log = Log(stamp)
    try:
        cap = int(os.environ.get("CALL_CAP", DEFAULT_CAP))
    except ValueError:
        cap = DEFAULT_CAP
    run = Run(cap, log, stamp)
    signal.signal(signal.SIGTERM, on_term)
    try:
        return fetch_all(repos, run, log, cap)
    except BaseException:   # 取る係の中のまちがい。全文を取得ログに残し、状態と取得の記録に「取れなかった」を書く
        import traceback
        log.line("取る係の中でまちがいが起きた（全文）:\n" + traceback.format_exc())
        try:
            st = read_json(STATE_PATH, {}) or {}
            note = "取る係の中でまちがいが起きた（取得ログに全文）"
            st.update(source="github", updated=now_iso(), state="error",
                      run=dict(st.get("run") or {}, end=now_iso(), result="error", note=note, progress=None))
            write_json(STATE_PATH, st)
            append_jsonl(HISTORY_PATH, {"start": local_iso(iso_z(run.started)), "end": now_iso(), "result": "error",
                                        "note": note, "new": 0, "ng": 0, "calls": run.calls, "calls_free": run.free})
            notify("取れませんでした", "取る係の中でまちがいが起きました。取得ログを見てください")
        except Exception:
            pass
        return 1
    finally:
        shutil.rmtree(LOCK, ignore_errors=True)


def fetch_all(repos, run, log, cap):
    st0 = read_json(STATE_PATH, {}) or {}
    prev_end = (st0.get("run") or {}).get("end")
    log.line("取得を始めます（%d リポジトリ・1回の上限 %s 回・データ %s）" % (len(repos), format(cap, ",") if cap else "なし", DATA))
    if os.environ.get("SLEEP_DELAYED"):
        log.line("予定の %s は Mac がスリープしていたので、起きてから始めます" % os.environ["SLEEP_DELAYED"])
    auth = {"login": None, "ok": False, "checked": now_iso()}
    errors, stop, built = {}, None, {}
    try:
        write_running(run, {"done": 0, "total": len(repos), "tag": None}, prev_end)
        me = run.get("user", "user", save=False)
        if me.status != 200:
            raise Stop("login", "GitHub のログインを確かめられなかった（%s）" % me.status)
        auth.update(login=me.data.get("login"), ok=True)
        for i, cfg in enumerate(repos):
            tag = cfg.get("tag") or cfg["name"]
            write_running(run, {"done": i, "total": len(repos), "tag": tag}, prev_end)
            log.line("— %d/%d %s（%s・基準 %s・取り始め %s）" % (i + 1, len(repos), tag, cfg["name"], cfg.get("base"), cfg.get("from")))
            try:
                fetch_repo(run, cfg, log)
            except RepoError as e:
                errors[int(cfg["id"])] = (e.message, e.kind)
                log.line("  取れなかった: %s（%s）" % (e.message, e.kind))
    except Stop as e:
        stop = e
        log.line("止めた: %s" % e.message)
    except Refused as e:
        stop = Stop("refused", "許可リストの外: %s" % e)
        log.line("許可リストの外のコマンドを止めた（全文）: %s" % e)
    # 記録を作る → 照合する（取れなかったリポジトリは前の記録のまま）
    for cfg in repos:
        try:
            built[int(cfg["id"])] = build_records(cfg)
        except Exception as e:   # 1 つが崩れても、ほかの記録は作る。全文は取得ログに
            log.line("記録を作れなかった（%s）: %r" % (cfg.get("tag"), e))
    # 合わないものは、少し待って 1 回だけ取り直す（基準の先頭・開いている数・出来事と一覧）
    skip = {k: v[0] for k, v in errors.items()}
    run_start = iso_z(run.started)
    check, by_item, cstats = run_checks(repos, built, skip=skip, run_start=run_start)
    if stop is None and any(by_item[k] for k in RECHECK):
        def mine(cfg, k, pred=lambda line: True):
            t = (cfg.get("tag") or cfg["name"]) + ":"
            return [line for line in by_item[k] if line.startswith(t) and pred(line)]
        is_comment = lambda line: "コメントの数が合わない" in line
        # 全部取り直すのは、合わなかった番号の一覧から（NG の行から拾わない。1 回で 20 件まで。設計書 5 章）
        fixc = {int(c["id"]): (cstats.get(c["id"]) or {}).get("comment_mismatch") or []
                for c in repos if int(c["id"]) not in errors}
        again = [c for c in repos if int(c["id"]) not in errors and (
            any(mine(c, k) for k in RECHECK - {"件数の突き合わせ"}) or mine(c, "件数の突き合わせ", lambda l: not is_comment(l)))]
        try:
            for c in repos:
                if fixc.get(int(c["id"])):
                    log.line("コメントの数が合わない issue・PR を、全部取り直します（%s: %s）" % (c.get("tag"), "・".join("#%d" % n for n in fixc[int(c["id"])])))
                    refetch_comments(run, c, fixc[int(c["id"])])
                    built[int(c["id"])] = build_records(c)
            if again:
                log.line("照合で合わないものがあったので、%d 秒待って 1 回だけ取り直します（%s）" % (RECHECK_WAIT, "・".join(c.get("tag") for c in again)))
                time.sleep(RECHECK_WAIT * WAIT_SCALE)
                for c in again:
                    fetch_repo(run, c, log)
                    built[int(c["id"])] = build_records(c)
        except (Stop, RepoError) as e:
            log.line("取り直しの途中で止まった: %s" % getattr(e, "message", e))
        check, by_item, cstats = run_checks(repos, built, skip=skip, run_start=run_start)
    stats = all_stats(repos, run_start=iso_z(run.started))
    if stop is not None:
        result, note = stop_result(stop)
    elif errors and len(errors) == len(repos):
        result, note = "error", "どのリポジトリも取れなかった"
    elif errors:
        result, note = "partial", "%d のうち %d つが取れなかった（%s）" % (len(repos), len(errors), "・".join(
            (c.get("tag") or c["name"]) for c in repos if int(c["id"]) in errors))
    elif check["ng"]:
        result, note = "ng", None
    else:
        result, note = "ok", None
    end = now_iso()
    run_info = {"start": local_iso(iso_z(run.started)), "end": end, "result": result, "note": note,
                "new": sum(s.get("delta") or 0 for s in stats), "since": prev_end,
                "calls": run.calls, "calls_free": run.free, "calls_cap": cap, "rate": local_rate(run.rate),
                "wait_until": local_iso(stop.wait_until) if stop is not None and stop.wait_until else None,
                "progress": None, "repos_failed": [(c.get("tag") or c["name"]) for c in repos if int(c["id"]) in errors]}
    if stop is not None and stop.kind == "cap" and any(
            pending_reason(read_json(bm_path(repo_dir(c)), {}) or {}, repo_dir(c)) for c in repos):
        # 最初の取得（または古い分を足している途中）で上限に届いた。大きいリポジトリではふつうの流れなので、
        # アプリは赤の「途中で止まりました」ではなく、黄の「最初の取得の途中です」を出す（設計書 6・7 章）
        run_info["first_partial"] = True
    spans = mac_sleeps(run.started.timestamp(), time.time())
    if spans:
        run_info["sleep"] = sleep_info(spans)
    # 知らせるのは、止まった理由がスリープのときだけ（上限や止めるボタンで止まった回に、少し眠っていただけなら知らせない）
    if spans and result in ("ng", "error", "partial"):
        run_info["sleep_missed"] = True
    if os.environ.get("SLEEP_DELAYED"):
        run_info["delayed_from"] = os.environ["SLEEP_DELAYED"]
    st = read_json(STATE_PATH, {}) or {}
    st.update(source="github", updated=end, state=result, run=run_info, repos=public_stats(stats, errors),
              daily=daily_of(stats), check=check, auth=auth)
    if result == "ok":
        st["last_success"] = end
    if result in ("ok", "ng", "partial"):
        # 最後まで読み切った回の時刻。アプリの「古い」（26 時間）はこれで見る（設計書 3.4・6 章）
        st["last_read"] = end
    write_json(STATE_PATH, st)
    hist = {k: run_info.get(k) for k in ("start", "end", "result", "note", "new", "calls", "calls_free")}
    hist.update(ng=len(check["ng"]), failed=run_info["repos_failed"],
                repos={s["tag"]: s.get("delta") or 0 for s in stats})
    for k in ("sleep", "delayed_from", "sleep_missed"):
        if run_info.get(k):
            hist[k] = run_info[k]
    append_jsonl(HISTORY_PATH, hist)
    log.line("状態: %s（新しく入った %d・照合 NG %d・使った回数 %d・使わなかった問い合わせ %d）%s" % (
        result, run_info["new"], len(check["ng"]), run.calls, run.free, ("・" + note) if note else ""))
    for line in check["ng"]:
        log.line("  " + line)
    if run_info.get("sleep_missed"):
        notify("スリープで取れなかった分があります", "Mac が起きているときに、もう一度取ってください")
    elif result == "ok":
        notify("取得できました", "新しく入ったもの %d・照合 OK" % run_info["new"])
    elif result == "ng":
        notify("照合で合わないものがあります", "メニューバーのアプリで確かめてください")
    elif result == "waiting":
        notify("回数の上限で待っています", "%s に戻ります。そのあと自動で続きを取ります" % short_t(stop.wait_until))
    elif result == "login":
        notify("ログインが必要です", "ターミナルで gh にログインしてから、もう一度取ってください")
    elif result == "partial":
        notify("一部のリポジトリが取れませんでした", note or "")
    elif result == "stopped" and run_info.get("first_partial"):
        notify("最初の取得の途中です", "1,500 回ずつ分けて取ります。続きは次の取得で取ります")
    elif result == "stopped":
        notify("途中で止まりました", note or "")
    else:
        notify("取れませんでした", note or "")
    return 0


def cmd_build(_args):
    repos = listed_repos()
    for cfg in repos:
        b = build_records(cfg)
        print("%s: 入った記録 %d・新しく入ったコミット %d" % (cfg.get("tag"), len(b["model"]["landings"]),
                                                    sum(len(L.get("new") or []) for L in b["model"]["landings"])))
    return 0


def cmd_status(args):
    if not args or args[0] != "refresh":
        print("使い方: python3 github.py status refresh")
        return 2
    repos = listed_repos()
    st = read_json(STATE_PATH, {}) or {}
    stats = all_stats(repos)
    errors = {r["id"]: (r.get("error"), r.get("error_kind")) for r in st.get("repos") or [] if r.get("error")}
    check, _, _ = run_checks(repos, skip={k: v[0] for k, v in errors.items()})
    if st.get("state") in ("ok", "ng"):
        st["state"] = "ng" if check["ng"] else "ok"   # 取得のあとの印は、数え直した照合に合わせる（止まった・失敗はそのまま）
    st.update(source="github", updated=now_iso(), repos=public_stats(stats, errors), daily=daily_of(stats), check=check)
    write_json(STATE_PATH, st)
    print("数え直しました（照合 NG %d・確かめていない %d）" % (len(check["ng"]), len(check["unverified"])))
    return 0


# ---- はじめの準備（アプリの「GitHub にログイン」「リポジトリを選ぶ」） ----

def candidate_of(r):
    return {"id": r["id"], "name": r.get("full_name"), "private": r.get("private"), "archived": r.get("archived"),
            "fork": r.get("fork"), "default_branch": r.get("default_branch"), "created": jst_day(r.get("created_at")),
            "pushed": r.get("pushed_at"), "description": one_line(r.get("description"), 200),
            "open_items": r.get("open_issues_count")}   # 開いている PR と issue の合計（issue の数は --inspect で検索から）


def cmd_setup(args):
    if data_inside_code():
        print("データの場所が、取得の仕組みのフォルダの中にあります。外に置いてください。")
        return 2
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + "_準備"
    log = Log(stamp)
    run = Run(0, log, stamp)
    f = read_json(CANDIDATES_PATH, {}) or {}
    repos = {r["id"]: r for r in f.get("repos") or [] if isinstance(r, dict) and r.get("id")}
    mode = args[0] if args else ""
    last = {"mode": mode.lstrip("-"), "at": now_iso(), "ok": False, "found": 0, "error": None}
    try:
        if mode == "--login":
            login = {"ok": False, "login": None, "gh": None, "error": None, "at": now_iso()}
            try:
                v = run_command([GH, "--version"], timeout=30)
                login["gh"] = (v.stdout.decode().split() + ["", "", ""])[2]
            except FileNotFoundError:
                login["error"] = "gh（GitHub の公式の道具）が見つかりません。入れてから、もう一度確かめてください。"
                f["login"] = login
                raise Stop("gh_missing", login["error"])
            try:
                me = run.get("user", "user", save=False)
            except Stop as e:
                login["error"] = "GitHub にログインしていません（または切れています）。ターミナルで gh にログインしてください。" if e.kind == "login" else e.message
                f["login"] = login
                raise
            login.update(ok=True, login=me.data.get("login"))
            f["login"] = login
            found = 0
            where = "user/repos?" + urllib.parse.urlencode({"affiliation": "owner,collaborator,organization_member",
                                                             "sort": "pushed", "per_page": 100})
            while where:
                r = run.get(where, "user_repos", save=False)
                if r.status != 200:
                    break
                for x in r.data:
                    c = candidate_of(x)
                    c.update({k: v for k, v in (repos.get(x["id"]) or {}).items() if k in ("branches", "hint", "estimate", "prs", "issues", "commits")})
                    repos[x["id"]] = c
                    found += 1
                where = r.next
            last.update(ok=True, found=found)
        elif mode == "--find" and len(args) > 1:
            q = args[1].strip()
            last["query"] = q
            if not re.fullmatch(_NAME + "/" + _NAME, q) or any(x in (".", "..") for x in q.split("/")):
                last["error"] = "owner/name の形で入れてください（例: ggml-org/whisper.cpp）"
            else:
                r = run.get("repos/" + q, "repo", save=False, quiet_404=True)
                if r.status == 200:
                    c = candidate_of(r.data)
                    c.update({k: v for k, v in (repos.get(r.data["id"]) or {}).items() if k in ("branches", "hint", "estimate", "prs", "issues", "commits")})
                    repos[r.data["id"]] = c
                    last.update(ok=True, found=1)
                else:
                    last.update(ok=True, found=0)
        elif mode == "--inspect" and len(args) > 1:
            q = args[1].strip()
            last["query"] = q
            c = next((x for x in repos.values() if x.get("name") == q), None)
            if c is None:
                r = run.get("repos/" + q, "repo", save=False, quiet_404=True)
                if r.status != 200:
                    raise RepoError("not_found", "「%s」は見えません" % q)
                c = candidate_of(r.data)
                repos[c["id"]] = c
            inspect_repo(run, c)
            last.update(ok=True, found=1)
        else:
            print("使い方: python3 github.py setup --login | --find owner/name | --inspect owner/name")
            return 2
    except Stop as e:
        last["error"] = (f.get("login") or {}).get("error") or e.message
    except RepoError as e:
        last["error"] = e.message
    except Refused as e:
        last["error"] = "許可リストの外の問い合わせを止めた（取得ログに全文）"
        log.line("許可リストの外: %s" % e)
    f.update(updated=now_iso(), last=last, repos=sorted(repos.values(), key=lambda r: r.get("pushed") or "", reverse=True))
    write_json(CANDIDATES_PATH, f)
    log.line("準備（%s）: %s・見つけた %s・使った回数 %d%s" % (mode, "OK" if last["ok"] else "NG", last.get("found"), run.calls,
                                                    ("・" + last["error"]) if last.get("error") else ""))
    return 0


def inspect_repo(run, c):
    """基準のブランチの提案（既定が止まっていて、別のブランチで動いているとき）と、最初の取得の見込みの回数（数回の問い合わせ）"""
    P = "repositories/%d" % int(c["id"])
    r = run.get(P + "/branches?per_page=100", "branches", save=False)
    if r.status == 200:
        c["branches"] = [b.get("name") for b in r.data][:100]
    r = run.get(P + "/activity?per_page=100", "activity_all", save=False)
    hint = {}
    if r.status == 200:
        now = utcnow()
        last_by, pushes30 = {}, {}
        for a in r.data:
            b = (a.get("ref") or "").replace("refs/heads/", "")
            t = parse_time(a.get("timestamp"))
            if not t or a.get("activity_type") == "branch_deletion":
                continue
            last_by[b] = max(last_by.get(b, t), t)
            if now - t <= datetime.timedelta(days=30):
                pushes30[b] = pushes30.get(b, 0) + 1
        d = c.get("default_branch")
        quiet = d not in pushes30
        others = sorted(((n, b) for b, n in pushes30.items() if b != d), reverse=True)
        if quiet and others:
            hint = {"suggested": others[0][1], "pushes30": others[0][0],
                    "default_quiet_since": jst_day(iso_z(last_by[d])) if d in last_by else None}
    c["hint"] = hint or {}   # 提案が無いときも空で書く（null だと、アプリが「まだ調べていない」と読んで調べ直す）
    counts = {}
    now = utcnow()
    d90 = iso_z(now - datetime.timedelta(days=90))
    d400 = iso_z(now - datetime.timedelta(days=CI_KEEP_DAYS))
    for key, q in (("pr", "is:pr"), ("issue", "is:issue"), ("pr90", "is:pr updated:>=" + d90),
                   ("issue90", "is:issue updated:>=" + d90), ("pr400", "is:pr updated:>=" + d400)):
        r = run.get("search/issues?" + urllib.parse.urlencode({"q": "repo:%s %s" % (c["name"], q), "per_page": 1}),
                    "search", save=False)
        counts[key] = r.data.get("total_count", 0) if r.status == 200 else 0
    r = run.get(P + "/commits?per_page=1", "commits", save=False)
    commits = 0
    if r.status == 200:
        m = re.search(r'[?&]page=([0-9]+)>; rel="last"', r.headers.get("link", ""))
        commits = int(m.group(1)) if m else len(r.data)
    c.update(prs=counts["pr"], issues=counts["issue"], commits=commits)
    # 見込み（設計書 4.7 の考え方）: 一覧は 100 件で 1 回・PR 1 件で詳しさとレビューの 2 回・出来事は件数の約 1/20 ページ・
    # コメントは PR と issue の約 3 倍・CI は約 13 か月に動いた PR に 2 回（最初の取得）。
    # 「90 日前から」は、検索で数えた最近 90 日に動いた PR と issue から出す（日数の割り合いだと半分ほどに出た。10/20）
    created = parse_time((c.get("created") or "1970-01-01") + "T00:00:00+09:00")
    days = max(1, (now - created).days) if created else 90

    def guess(n_commits, prs, issues, ci_prs):
        items = prs + issues
        return (n_commits // 100 + 1) + (items // 100 + 1) * 2 + prs * 2 + max(1, items // 20) + max(1, (items * 3) // 100) \
            + 20 + ci_prs * 2
    c["estimate"] = {"all": guess(commits, counts["pr"], counts["issue"], counts["pr400"]),
                     "days90": guess(int(commits * min(1.0, 90.0 / days)), counts["pr90"], counts["issue90"], counts["pr90"])}


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    cmd = argv[0]
    if cmd == "fetch":
        return cmd_fetch(argv[1:])
    if cmd == "build":
        return cmd_build(argv[1:])
    if cmd == "status":
        return cmd_status(argv[1:])
    if cmd == "setup":
        return cmd_setup(argv[1:])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
