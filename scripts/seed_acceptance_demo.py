#!/usr/bin/env python3
"""Seed a disposable TimeTrace database for desktop demo recordings.

This script is never invoked by the shipped application. Acceptance workflows
point it at the runner user's throw-away TimeTrace data directory so screenshots
and videos exercise the real production UI with representative local data.
"""

from __future__ import annotations

import argparse
import datetime as dt
import sqlite3
from pathlib import Path


APPS = [
    ("Visual Studio Code", "/Applications/Visual Studio Code.app", 52),
    ("Google Chrome", "/Applications/Google Chrome.app", 23),
    ("Terminal", "/Applications/Utilities/Terminal.app", 14),
    ("Android Studio", "/Applications/Android Studio.app", 8),
    ("Finder", "/System/Library/CoreServices/Finder.app", 3),
]


def iso(local_date: dt.date, hour: int, minute: int) -> str:
    return dt.datetime.combine(local_date, dt.time(hour, minute)).isoformat()


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

    # Idempotent on a fresh or retried runner.
    cur.execute("DELETE FROM page_visits")
    cur.execute("DELETE FROM usage_sessions")
    cur.execute("DELETE FROM diary_entries")

    today = dt.datetime.now().astimezone().date()
    base_total = 7 * 3600 + 20 * 60

    for day_offset in range(6, -1, -1):
        day = today - dt.timedelta(days=day_offset)
        # Slightly different total every day so weekly/monthly trend visuals are
        # populated without making the fixture random.
        total = base_total - day_offset * 17 * 60
        cursor_minutes = 9 * 60 + 10
        session_no = 0

        for app_name, app_path, share in APPS:
            app_seconds = max(12 * 60, total * share // 100)
            # Split each app into multiple visits to create realistic context
            # switches and page-level details.
            parts = 3 if share >= 14 else 2
            part_seconds = app_seconds // parts
            for part in range(parts):
                hour, minute = divmod(cursor_minutes, 60)
                start = dt.datetime.combine(day, dt.time(hour % 24, minute))
                end = start + dt.timedelta(seconds=part_seconds)
                title = {
                    "Visual Studio Code": "TimeTrace — Visual Studio Code",
                    "Google Chrome": "GitHub · TimeTrace pull requests",
                    "Terminal": "cargo test --workspace",
                    "Android Studio": "TimeTrace desktop acceptance",
                    "Finder": "TimeTrace artifacts",
                }[app_name]
                cur.execute(
                    """
                    INSERT INTO usage_sessions
                    (app_path, app_name, window_title, started_at, ended_at,
                     duration_secs, is_idle, date)
                    VALUES (?, ?, ?, ?, ?, ?, 0, ?)
                    """,
                    (
                        app_path,
                        app_name,
                        title,
                        start.isoformat(),
                        end.isoformat(),
                        part_seconds,
                        day.isoformat(),
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
                        session_id,
                        app_name,
                        title,
                        start.isoformat(),
                        end.isoformat(),
                        part_seconds,
                        day.isoformat(),
                    ),
                )
                session_no += 1
                cursor_minutes += max(18, part_seconds // 60) + 6

        diary = (
            "继续完善 TimeTrace：整理桌面端体验、检查统计与日记时间线，"
            "并验证 AI Recap 的本地事实回顾。"
            if day == today
            else "完成一轮桌面端开发与测试，记录当天的主要工作和时间分配。"
        )
        now = dt.datetime.combine(day, dt.time(20, 30)).isoformat()
        cur.execute(
            """
            INSERT INTO diary_entries(date, content, created_at, updated_at, status)
            VALUES (?, ?, ?, ?, 'published')
            """,
            (day.isoformat(), diary, now, now),
        )

    conn.commit()
    conn.close()
    print(f"seeded acceptance demo database: {db}")


if __name__ == "__main__":
    main()
