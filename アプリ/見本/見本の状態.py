#!/usr/bin/env python3
"""GitHub 取得の画面を、作り物の数字で描くための「作り物の状態フォルダ」を作る。
使い方: python3 見本の状態.py <出力フォルダ>
  → <出力フォルダ>/ に リポジトリ.json・状態.json・取得の記録.jsonl ができる（全部作り物。本物のデータは使わない）
  → GitHubFetch --snapshot <画像の出力先> -baseDir <台本を写したフォルダ> -dataDir <出力フォルダ> で、数字の入った画面が出る
形は 設計書.md の 3.4（状態.json）・3.5（取得の記録.jsonl）・3.6（リポジトリ.json）と同じ。
最後の取得は「昨日 9:02」。日ごとの数は、最後の取得の日（昨日）までの14日。"""
import json
import os
import random
import sys
from datetime import datetime, timedelta

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
random.seed(20261018)
now = datetime.now().astimezone()


def iso(dt):
    return dt.isoformat(timespec="seconds")


def day(n):
    """n 日前の日付"""
    return (now - timedelta(days=n)).date()


def at(n, h, m):
    """n 日前の h:m"""
    return (now - timedelta(days=n)).replace(hour=h, minute=m, second=0, microsecond=0)


last_end = at(1, 9, 2).replace(second=14)
last_start = at(1, 9, 0).replace(second=21)

# 呼び名・名前・基準・取り始めた日（何日前）・公開か
REPOS = [
    ("音声", "open-voice/speech-engine", "master", 90, "public"),
    ("web", "sample-org/web-app", "develop", 160, "private"),
    ("窓", "sample-user/menu-bar-app", "main", 1, "public"),
    ("文字", "sample-user/transcriber", "main", 19, "public"),
    ("取得", "sample-user/chat-fetch", "main", 9, "public"),
    ("注釈", "sample-user/comment-layer", "main", 72, "public"),
    ("図解", "sample-user/diagram-parts", "main", 57, "public"),
    ("資料", "sample-user/slide-deck", "main", 71, "public"),
    ("作図", "sample-user/drawio-skills", "main", 123, "public"),
    ("見積", "sample-user/estimate-brief", "main", 123, "public"),
    ("調査", "sample-user/bug-report", "main", 123, "public"),
    ("変換", "sample-user/image-to-md", "main", 93, "public"),
]

# 14 日分（i=0 が14日前、i=13 が昨日）の (PR 経由, 直接)
DAYS = [day(14 - i) for i in range(14)]


def weekday(i):
    return DAYS[i].weekday() < 5


def series(tag):
    pr, direct = [0] * 14, [0] * 14
    if tag == "音声":
        for i in range(14):
            pr[i] = random.randint(1, 4) if weekday(i) else random.randint(0, 1)
            direct[i] = 1 if random.random() < 0.15 else 0
        direct[4] += 48     # 別のリポジトリからの同期（まとめて push）
        direct[11] += 92
    elif tag == "web":
        for i in range(14):
            if weekday(i):
                pr[i] = random.randint(0, 2)
                direct[i] = random.randint(1, 5)
    elif tag == "窓":
        direct[13] = 25     # 作った日に、25 コミットを1回で push
    elif tag == "文字":
        direct[2], direct[5], direct[10], direct[11] = 3, 3, 2, 1
    elif tag == "取得":
        direct[6], direct[7], direct[12] = 3, 1, 2
    return pr, direct


# 最後に入った日（動きのないリポジトリは何日前か）
DORMANT = {"注釈": 70, "図解": 57, "資料": 71, "作図": 123, "見積": 123, "調査": 123, "変換": 93}
TOTALS = {"音声": 612, "web": 230, "窓": 25, "文字": 13, "取得": 6, "注釈": 34, "図解": 1, "資料": 1,
          "作図": 2, "見積": 2, "調査": 2, "変換": 1}

ACTIVE = {
    "音声": [
        ("pr", 3456, "Add streaming output to the server example", 1, ["承認済み"]),
        ("pr", 3449, "Fix crash when the model file is missing", 1, ["CI 失敗"]),
        ("issue", 3451, "Transcription stops after 30 minutes on macOS", 2, []),
        ("pr", 3440, "Update build docs for Windows", 3, ["下書き"]),
        ("issue", 3438, "Support for a new model file format", 5, []),
    ],
    "web": [
        ("pr", 412, "お知らせ一覧にページ送りを足す", 1, ["承認済み"]),
        ("pr", 409, "ログインの失敗を記録する", 2, ["CI 失敗"]),
        ("pr", 405, "検索の並び順を直す", 4, ["変更の依頼"]),
        ("pr", 398, "決済の画面（下書き）", 6, ["下書き"]),
    ],
}

repos, daily_counts, daily_pr = [], [dict() for _ in range(14)], [dict() for _ in range(14)]
for tag, name, base, from_days, vis in REPOS:
    pr, direct = series(tag)
    for i in range(14):
        daily_counts[i][tag] = pr[i] + direct[i]
        daily_pr[i][tag] = pr[i]
    last7 = sum(pr[7:]) + sum(direct[7:])
    last7_pr = sum(pr[7:])
    prev7 = sum(pr[:7]) + sum(direct[:7])
    landed_days = [i for i in range(14) if pr[i] + direct[i] > 0]
    if tag in DORMANT:
        last_landed = at(DORMANT[tag], 22, 14)
    elif landed_days:
        i = landed_days[-1]
        # 昨日の分は、最後の取得（昨日 9:02）より前に入ったもの
        last_landed = at(14 - i, 0, 58) if tag == "窓" else at(14 - i, 7, 12) if i == 13 else at(14 - i, 21, 37)
    else:
        last_landed = None
    r = {
        "id": 600000000 + len(repos) * 1111, "tag": tag, "name": name, "base": base,
        "visibility": vis, "archived": False, "from": str(day(from_days)),
        "fetched": iso(last_end), "error": None, "error_kind": None,
        "total": TOTALS[tag], "total_pr": {"音声": 141, "web": 58}.get(tag, 0),
        "delta": pr[13] + direct[13],
        "last7": last7, "last7_pr": last7_pr, "prev7": prev7,
        "week": [{"date": str(DAYS[i]), "pr": pr[i], "direct": direct[i]} for i in range(7, 14)],
        "last_landed": iso(last_landed) if last_landed else None,
        "release": None, "stages": [],
        "open_prs": 0, "open_prs_active": 0, "open_issues": 0, "open_issues_active": 0,
        "pr_flags": None, "active": [],
        "counts": {"prs": 0, "issues": 0, "comments": 0, "reviews": 0},
    }
    if tag == "音声":
        r.update(open_prs=179, open_prs_active=11, open_issues=178, open_issues_active=20,
                 pr_flags={"draft": 2, "changes_requested": 1, "approved": 3, "ci_failed": 2},
                 release={"tag": "v1.9.5", "date": iso(at(11, 2, 39)), "after": 96},
                 counts={"prs": 118, "issues": 141, "comments": 1203, "reviews": 236})
    elif tag == "web":
        r.update(open_prs=7, open_prs_active=4,
                 pr_flags={"draft": 1, "changes_requested": 1, "approved": 1, "ci_failed": 1},
                 stages=[{"name": "確認環境", "branch": "staging", "behind": 9, "updated": iso(at(8, 18, 5))},
                         {"name": "本番", "branch": "production", "behind": 21, "updated": iso(at(18, 19, 30))}],
                 counts={"prs": 58, "issues": 0, "comments": 212, "reviews": 71})
    elif tag == "窓":
        r.update(release={"tag": "v1.0.1", "date": iso(at(1, 1, 20)), "after": 0},
                 counts={"prs": 0, "issues": 0, "comments": 0, "reviews": 0})
    elif tag == "文字":
        r.update(release={"tag": "1.1.2", "date": iso(at(3, 16, 40)), "after": 0},
                 counts={"prs": 0, "issues": 0, "comments": 0, "reviews": 0})
    elif tag == "作図":
        r.update(counts={"prs": 1, "issues": 0, "comments": 0, "reviews": 0})
    r["active"] = [{"kind": k, "number": n, "title": t, "updated": iso(at(d, 7 + d, 41)), "flags": f}
                   for k, n, t, d, f in ACTIVE.get(tag, [])]
    repos.append(r)

json.dump([{"id": r["id"], "name": r["name"], "tag": r["tag"], "base": r["base"],
            "stages": [{"name": s["name"], "branch": s["branch"]} for s in r["stages"]],
            "from": r["from"], "added": str(day(20))} for r in repos],
          open(os.path.join(out, "リポジトリ.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)

daily = [{"date": str(DAYS[i]), "counts": daily_counts[i], "pr": daily_pr[i]} for i in range(14)]
landed_total = sum(r["total"] for r in repos)
items = [
    {"name": "ページの取りこぼし", "ok": True, "detail": "一覧を最後のページまで取れた（今回 173 ページ）・途中で切れたページ 0"},
    {"name": "件数の突き合わせ", "ok": True,
     "detail": "PR 183・issue 141 が GitHub の数と一致。コメントの数も PR・issue ごとに一致（324 件を確かめた）"},
    {"name": "期間の抜け", "ok": True, "detail": "取り始めた日から最後の取得まで、すき間なし（%d リポジトリ・5 種類）" % len(repos)},
    {"name": "ブランチのつながり", "ok": True, "detail": "入った記録が1本につながっている（%d リポジトリ）・強制の書き換え 0" % len(repos)},
    {"name": "入り方の見分け", "ok": True, "detail": "入ったコミット %s 件すべて、PR 経由か直接かに分かれた" % format(landed_total, ",")},
    {"name": "原本の形", "ok": True, "detail": "形の崩れた原本 0・ID の無いもの 0"},
    {"name": "既知の例外", "ok": True, "detail": "0件（GitHub 側の食い違いで直しようがないもの）"},
]
state = {
    "source": "github", "updated": iso(last_end), "state": "ok",
    "run": {"start": iso(last_start), "end": iso(last_end), "result": "ok", "note": None,
            "new": sum(r["delta"] for r in repos), "since": iso(at(2, 9, 1)),
            "calls": 142, "calls_free": 388, "calls_cap": 1500,
            "rate": {"limit": 5000, "remaining": 4812, "reset": iso(at(1, 10, 0))},
            "wait_until": None, "progress": None, "repos_failed": []},
    "repos": repos, "daily": daily,
    "check": {"ng": [], "notes": [], "items": items, "exceptions": []},
    "last_success": iso(last_end),
    "auth": {"login": "sample-user", "ok": True, "checked": iso(last_start)},
}
json.dump(state, open(os.path.join(out, "状態.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)

# 取得の記録（新しい順に作って、古い順に書く）。いちばん古い3回は、最初の取得（1回の上限で2回止まり、3回目で取り終えた）
kinds = [
    ("ok", None, 31, 142, 388, None),
    ("ok", None, 4, 61, 401, None),
    ("ok", None, 18, 88, 371, "sleep"),
    ("ng", None, 12, 97, 360, None),
    ("ok", None, 3, 40, 412, "delayed"),
    ("partial", "1つのリポジトリが見えなかった（変換）", 6, 52, 395, None),
    ("ok", "GitHub の回数の上限で 38分 待ってから続けた", 22, 120, 344, None),
    ("login", "GitHub のログインが切れていた", 0, 1, 0, None),
    ("ok", None, 9, 70, 380, None),
    ("ok", "最初の取得の3回目で取り終えた", 212, 640, 12, None),
    ("stopped", "1回の上限（1,500 回）に届いた（最初の取得の2回目）", 380, 1500, 9, None),
    ("stopped", "1回の上限（1,500 回）に届いた（最初の取得の1回目）", 337, 1500, 0, None),
]
hist = []
for i, (k, note, new, calls, free, extra) in enumerate(kinds):
    end = at(i + 1, 9, random.randint(1, 4)).replace(second=random.randint(0, 59))
    start = end - timedelta(minutes=random.randint(1, 3) if calls < 1000 else random.randint(18, 26))
    e = {"start": iso(start), "end": iso(end), "result": k, "note": note, "new": new,
         "calls": calls, "calls_free": free, "ng": 1 if k == "ng" else 0,
         "failed": ["変換"] if k == "partial" else []}
    if extra == "sleep":
        e["sleep"] = {"count": 1, "seconds": 2340, "spans": [[iso(end - timedelta(minutes=50)), iso(end - timedelta(minutes=11))]]}
    if extra == "delayed":
        e["delayed_from"] = "9:00"
    hist.append(e)
with open(os.path.join(out, "取得の記録.jsonl"), "w", encoding="utf-8") as f:
    for e in reversed(hist):
        f.write(json.dumps(e, ensure_ascii=False) + "\n")
print("作った:", out, "（リポジトリ", len(repos), "・取得の記録", len(hist), "件）")
