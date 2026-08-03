//! Monitor harness — runs the REAL monitor loop with a short idle threshold,
//! verifies idle detection + session recording end-to-end.
//!
//! Run: cargo run -p timetrace-bridge --example monitor_harness
//!
//! Behavior: opens a temp DB, starts Win32 monitor with 3s idle threshold,
//! runs 25s. During the run: if the user stops touching mouse/keyboard for
//! 3s+, IdleStarted fires → __IDLE__ session recorded.
//! Afterwards: prints and logs the recorded sessions.

use std::sync::Arc;
use std::time::Duration;

use timetrace_core::*;

fn main() {
    // File logging
    let dir = dirs::config_dir().unwrap_or_else(|| std::path::PathBuf::from(".")).join("TimeTrace");
    let _ = std::fs::create_dir_all(&dir);
    let log_path = dir.join("timetrace.log");
    if let Ok(file) = std::fs::OpenOptions::new().create(true).append(true).open(&log_path) {
        let _ = tracing_subscriber::fmt()
            .with_max_level(tracing::Level::INFO)
            .with_writer(file)
            .with_ansi(false)
            .try_init();
    }
    tracing::info!("=== MONITOR HARNESS START ===");

    // Temp DB
    let db_path = std::env::temp_dir().join("timetrace_harness.db");
    let _ = std::fs::remove_file(&db_path);
    let db = Arc::new(SqliteStore::open(db_path.clone()).expect("open db"));

    // Real monitor with 3-second idle threshold
    let sink: Box<dyn EventSink> = Box::new(SessionAggregator::new(db.clone()));
    let handle = run_monitor_loop(
        Win32WindowResolver,
        Win32IdleDetector::new(),
        Duration::from_millis(500),
        Duration::from_secs(3),
        sink,
    );

    tracing::info!("Monitor running 25s — stay idle (no mouse/keyboard) for 5s to trigger idle detection");
    println!("Monitor running 25s. 请保持 5 秒不动鼠标键盘以触发挂机检测...");
    std::thread::sleep(Duration::from_secs(25));
    handle.stop();

    // Inspect results
    let today = chrono::Local::now().date_naive();
    let sessions = db.get_sessions_by_date(today);
    tracing::info!("Harness: {} sessions recorded today", sessions.len());
    println!("\n=== 记录到的会话 ===");
    for s in &sessions {
        let idle = if s.is_idle { " [IDLE]" } else { "" };
        tracing::info!("  {} | {}s{}", s.app_name, s.duration_secs.unwrap_or(0), idle);
        println!("  {:<20} | {:>5}s{}", s.app_name, s.duration_secs.unwrap_or(0), idle);
    }

    let idle_count = sessions.iter().filter(|s| s.is_idle).count();
    println!("\n挂机会话数: {}", idle_count);
    if idle_count > 0 {
        println!("✅ 挂机检测正常");
    } else {
        println!("❌ 未检测到挂机 —— 请确认测试期间保持了 5 秒以上不动");
    }
}
