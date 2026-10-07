-- TimeTrace P0 legacy semantic fixture, version 1.
-- All identifiers are synthetic. Timestamps use an explicit UTC offset.
-- The hourly schedule repeats for a complete 24-hour cycle so bucket totals
-- are invariant under execution-machine fixed UTC offsets.

PRAGMA foreign_keys = OFF;

CREATE TABLE usage_sessions (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    app_path      TEXT NOT NULL,
    app_name      TEXT NOT NULL,
    window_title  TEXT,
    started_at    TEXT NOT NULL,
    ended_at      TEXT,
    duration_secs INTEGER,
    is_idle       INTEGER NOT NULL DEFAULT 0,
    date          TEXT NOT NULL
);

CREATE TABLE page_visits (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id    INTEGER NOT NULL,
    app_name      TEXT NOT NULL,
    window_title  TEXT,
    started_at    TEXT NOT NULL,
    ended_at      TEXT,
    duration_secs INTEGER,
    date          TEXT NOT NULL
);

CREATE TABLE diary_entries (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    date       TEXT NOT NULL,
    content    TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    status     TEXT NOT NULL DEFAULT 'published'
);

-- Deliberately pre-MIGRATIONS_V2: entry_id is absent. SqliteStore::open must
-- add it and preserve the legacy same-date latest-entry association.
CREATE TABLE diary_images (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    date       TEXT NOT NULL,
    path       TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE INDEX idx_sessions_date ON usage_sessions(date);
CREATE INDEX idx_sessions_app_date ON usage_sessions(app_name, date);
CREATE INDEX idx_page_visits_app ON page_visits(app_name, date);
CREATE INDEX idx_diary_entries_date ON diary_entries(date);
CREATE INDEX idx_diary_entries_date_id ON diary_entries(date, id);
CREATE INDEX idx_diary_images_date ON diary_images(date);

-- app-alpha: one ten-minute session each UTC hour, crossing the hour boundary.
-- The final row crosses midnight while retaining the legacy date key.
WITH RECURSIVE hour(h) AS (
    VALUES(0)
    UNION ALL SELECT h + 1 FROM hour WHERE h < 23
)
INSERT INTO usage_sessions (
    id, app_path, app_name, window_title, started_at, ended_at,
    duration_secs, is_idle, date
)
SELECT
    h + 1,
    '',
    'app-alpha',
    NULL,
    printf('2024-01-15T%02d:55:00+00:00', h),
    CASE WHEN h = 23
        THEN '2024-01-16T00:05:00+00:00'
        ELSE printf('2024-01-15T%02d:05:00+00:00', h + 1)
    END,
    600,
    0,
    '2024-01-15'
FROM hour;

WITH RECURSIVE hour(h) AS (
    VALUES(0)
    UNION ALL SELECT h + 1 FROM hour WHERE h < 23
)
INSERT INTO page_visits (
    id, session_id, app_name, window_title, started_at, ended_at,
    duration_secs, date
)
SELECT
    h + 1,
    h + 1,
    'app-alpha',
    CASE WHEN h < 16 THEN 'window-alpha-primary' ELSE 'window-alpha-secondary' END,
    printf('2024-01-15T%02d:55:00+00:00', h),
    CASE WHEN h = 23
        THEN '2024-01-16T00:05:00+00:00'
        ELSE printf('2024-01-15T%02d:05:00+00:00', h + 1)
    END,
    600,
    '2024-01-15'
FROM hour;

-- app-beta: five minutes in every UTC hour. Empty app_path is intentional:
-- the fixture carries no executable path content.
WITH RECURSIVE hour(h) AS (
    VALUES(0)
    UNION ALL SELECT h + 1 FROM hour WHERE h < 23
)
INSERT INTO usage_sessions (
    id, app_path, app_name, window_title, started_at, ended_at,
    duration_secs, is_idle, date
)
SELECT
    101 + h,
    '',
    'app-beta',
    NULL,
    printf('2024-01-15T%02d:15:00+00:00', h),
    printf('2024-01-15T%02d:20:00+00:00', h),
    300,
    0,
    '2024-01-15'
FROM hour;

WITH RECURSIVE hour(h) AS (
    VALUES(0)
    UNION ALL SELECT h + 1 FROM hour WHERE h < 23
)
INSERT INTO page_visits (
    id, session_id, app_name, window_title, started_at, ended_at,
    duration_secs, date
)
SELECT
    101 + h,
    101 + h,
    'app-beta',
    'window-beta-primary',
    printf('2024-01-15T%02d:15:00+00:00', h),
    printf('2024-01-15T%02d:20:00+00:00', h),
    300,
    '2024-01-15'
FROM hour;

INSERT INTO usage_sessions (
    id, app_path, app_name, window_title, started_at, ended_at,
    duration_secs, is_idle, date
) VALUES (
    1000, '', '__IDLE__', NULL,
    '2024-01-15T12:30:00+00:00', '2024-01-15T12:45:00+00:00',
    900, 1, '2024-01-15'
);

-- Empty content locks status and relation semantics without fixture diary text.
INSERT INTO diary_entries (id, date, content, created_at, updated_at, status) VALUES
    (101, '2024-01-15', '', '2024-01-15T18:00:00+00:00', '2024-01-15T18:00:00+00:00', 'published'),
    (102, '2024-01-15', '', '2024-01-15T19:00:00+00:00', '2024-01-15T19:05:00+00:00', 'draft'),
    (103, '2024-01-16', '', '2024-01-16T18:00:00+00:00', '2024-01-16T18:00:00+00:00', 'published');

-- Opaque tokens are not filesystem paths. The legacy migration associates
-- each row with MAX(diary_entries.id) for the same date.
INSERT INTO diary_images (id, date, path, created_at) VALUES
    (201, '2024-01-15', 'image-token-alpha', '2024-01-15T19:10:00+00:00'),
    (202, '2024-01-16', 'image-token-beta', '2024-01-16T18:10:00+00:00');
