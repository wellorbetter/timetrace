#!/usr/bin/env python3
"""Seed a deterministic, disposable TimeTrace database for desktop demos.

The shipped application never invokes this script. CI points it at the runner's
throw-away TimeTrace directory so screenshots/videos exercise the production UI
with rich but clearly synthetic data.
"""

from __future__ import annotations

import argparse
import datetime as dt
import sqlite3
from pathlib import Path


APPS = {
    "Visual Studio Code": "demo://vscode",
    "Google Chrome": "demo://chrome",
    "Terminal": "demo://terminal",
    "Android Studio": "demo://android-studio",
    "Figma": "demo://figma",
    "Obsidian": "demo://obsidian",
    "Slack": "demo://slack",
    "Finder": "demo://files",
}

TITLES = {
    "Visual Studio Code": [
        "TimeTrace · dashboard_screen.dart",
        "TimeTrace · recap_provider.dart",
        "TimeTrace · desktop acceptance workflow",
        "TimeTrace · README.md",
    ],
    "Google Chrome": [
        "GitHub · TimeTrace pull requests",
        "GitHub Actions · Desktop Acceptance",
        "Flutter desktop documentation",
        "Rust docs · rusqlite",
    ],
    "Terminal": [
        "cargo test --workspace",
        "flutter analyze --no-fatal-infos",
        "git diff --stat",
        "ffprobe timetrace-demo.mp4",
    ],
    "Android Studio": [
        "TimeTrace · desktop runner",
        "Flutter DevTools · TimeTrace",
    ],
    "Figma": [
        "TimeTrace · desktop UI review",
        "TimeTrace · recap layout",
    ],
    "Obsidian": [
        "TimeTrace release notes",
        "Daily engineering notes",
    ],
    "Slack": [
        "#desktop-release",
        "#product-review",
    ],
    "Finder": [
        "TimeTrace artifacts",
        "Screenshots",
    ],
}

BASE_TIMELINE = [
    (9, 5, "Visual Studio Code", 38),
    (9, 45, "Google Chrome", 11),
    (9, 58, "Terminal", 9),
    (10, 9, "Visual Studio Code", 31),
    (10, 42, "Slack", 7),
    (10, 51, "Visual Studio Code", 27),
    (11, 20, "Google Chrome", 13),
    (11, 35, "Terminal", 8),
    (11, 45, "Visual Studio Code", 24),
    # lunch / away: 12:09 -> 13:14
    (13, 14, "Android Studio", 32),
    (13, 48, "Terminal", 10),
    (14, 0, "Visual Studio Code", 37),
    (14, 39, "Google Chrome", 12),
    (14, 53, "Visual Studio Code", 26),
    # short break: 15:19 -> 15:31
    (15, 31, "Figma", 17),
    (15, 50, "Visual Studio Code", 29),
    (16, 21, "Obsidian", 10),
    (16, 33, "Google Chrome", 12),
    (16, 47, "Terminal", 9),
    (16, 58, "Visual Studio Code", 34),
    (17, 34, "Slack", 8),
    (17, 44, "Finder", 6),
    (17, 52, "Figma", 13),
    (18, 7, "Visual Studio Code", 26),
    (18, 35, "Terminal", 7),
    (18, 44, "Google Chrome", 9),
]


def insert_session(
    cur: sqlite3.Cursor,
    day: dt.date,
    start: dt.datetime,
    app_name: str,
    duration_minutes: int,
    title_index: int,
) -> None:
    duration_seconds = duration_minutes * 60
    end = start + dt.timedelta(seconds=duration_seconds)
    titles = TITLES[app_name]
    title = titles[title_index % len(titles)]
    cur.execute(
        """
        INSERT INTO usage_sessions
        (app_path, app_name, window_title, started_at, ended_at,
         duration_secs, is_idle, date)
        VALUES (?, ?, ?, ?, ?, ?, 0, ?)
        """,
        (
            APPS[app_name], app_name, title, start.isoformat(), end.isoformat(),
            duration_seconds, day.isoformat(),
        ),
    )
    session_id = cur.lastrowid
    cur.execute(
        """
        INSERT INTO page_visits
        (session_id, app_name, window_title, started_at, ended_at,
         duration_secs, date)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            session_id, app_name, title, start.isoformat(), end.isoformat(),
            duration_seconds, day.isoformat(),
        ),
    )


def insert_idle(
    cur: sqlite3.Cursor,
    day: dt.date,
    hour: int,
    minute: int,
    duration_minutes: int,
) -> None:
    start = dt.datetime.combine(day, dt.time(hour, minute))
    end = start + dt.timedelta(minutes=duration_minutes)
    cur.execute(
        """
        INSERT INTO usage_sessions
        (app_path, app_name, window_title, started_at, ended_at,
         duration_secs, is_idle, date)
        VALUES ('', '__IDLE__', NULL, ?, ?, ?, 1, ?)
        """,
        (start.isoformat(), end.isoformat(), duration_minutes * 60, day.isoformat()),
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", required=True)
    args = parser.parse_args()

    db = Path(args.db).expanduser().resolve()
    db.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db)
    cur = conn.cursor()

    cur.executescript(
        """
        CREATE TABLE IF NOT EXISTS usage_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            app_path TEXT NOT NULL,
            app_name TEXT NOT NULL,
            window_title TEXT,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            duration_secs INTEGER,
            is_idle INTEGER NOT NULL DEFAULT 0,
            date TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_sessions_date ON usage_sessions(date);
        CREATE INDEX IF NOT EXISTS idx_sessions_app_date ON usage_sessions(app_name, date);
        CREATE TABLE IF NOT EXISTS page_visits (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL,
            app_name TEXT NOT NULL,
            window_title TEXT,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            duration_secs INTEGER,
            date TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_page_visits_app ON page_visits(app_name, date);
        CREATE TABLE IF NOT EXISTS diary_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            date TEXT NOT NULL,
            content TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'published'
        );
        CREATE INDEX IF NOT EXISTS idx_diary_entries_date ON diary_entries(date);
        """
    )

    cur.execute("DELETE FROM page_visits")
    cur.execute("DELETE FROM usage_sessions")
    cur.execute("DELETE FROM diary_entries")

    today = dt.datetime.now().astimezone().date()
    total_sessions = 0

    for day_offset in range(13, -1, -1):
        day = today - dt.timedelta(days=day_offset)
        weekday = day.weekday()
        variant = (13 - day_offset) % 5

        if weekday >= 5:
            timeline = [
                (10, 18, "Google Chrome", 18),
                (10, 40, "Obsidian", 16),
                (11, 1, "Visual Studio Code", 35 + variant * 2),
                (11, 39, "Terminal", 8),
                (14, 30, "Figma", 18),
                (14, 51, "Visual Studio Code", 28),
                (15, 22, "Google Chrome", 13),
            ]
        else:
            timeline = BASE_TIMELINE

        for index, (hour, minute, app_name, base_minutes) in enumerate(timeline):
            duration = max(5, base_minutes + ((variant + index) % 3 - 1) * 2)
            start = dt.datetime.combine(day, dt.time(hour, minute))
            insert_session(cur, day, start, app_name, duration, index + variant)
            total_sessions += 1

        if weekday >= 5:
            insert_idle(cur, day, 11, 49, 155)
        else:
            insert_idle(cur, day, 12, 9, 65)
            insert_idle(cur, day, 15, 19, 12)
        total_sessions += 1 if weekday >= 5 else 2

        evening = dt.datetime.combine(day, dt.time(20, 20))
        daily_text = (
            "完成 TimeTrace 的桌面端迭代：上午集中在统计与交互，下午处理跨平台验收，"
            "晚上复盘构建结果并整理下一步。"
        )
        cur.execute(
            """
            INSERT INTO diary_entries(date, content, created_at, updated_at, status)
            VALUES (?, ?, ?, ?, 'published')
            """,
            (day.isoformat(), daily_text, evening.isoformat(), evening.isoformat()),
        )

        if day == today:
            morning = dt.datetime.combine(day, dt.time(12, 12))
            cur.execute(
                """
                INSERT INTO diary_entries(date, content, created_at, updated_at, status)
                VALUES (?, ?, ?, ?, 'published')
                """,
                (
                    day.isoformat(),
                    "上午把 AI Recap 的事实层和桌面概览重新核了一遍，重点检查数据是否能解释真实工作节奏。",
                    morning.isoformat(),
                    morning.isoformat(),
                ),
            )

    conn.commit()

    active_today = cur.execute(
        "SELECT COALESCE(SUM(duration_secs), 0) FROM usage_sessions WHERE date = ? AND is_idle = 0",
        (today.isoformat(),),
    ).fetchone()[0]
    idle_today = cur.execute(
        "SELECT COALESCE(SUM(duration_secs), 0) FROM usage_sessions WHERE date = ? AND is_idle = 1",
        (today.isoformat(),),
    ).fetchone()[0]
    today_sessions = cur.execute(
        "SELECT COUNT(*) FROM usage_sessions WHERE date = ? AND is_idle = 0",
        (today.isoformat(),),
    ).fetchone()[0]
    conn.close()

    print(
        "seeded acceptance demo database: "
        f"{db} (14 days, {total_sessions} sessions, today={today_sessions} active sessions, "
        f"active={active_today // 3600}h{(active_today % 3600) // 60:02d}m, "
        f"idle={idle_today // 60}m)"
    )


if __name__ == "__main__":
    main()
