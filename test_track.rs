use std::sync::Arc;
use std::time::Duration;

fn main() {
    // Quick test: does the monitor produce any events?
    use timetrace_core::*;
    
    let db = Arc::new(MemoryStore::new());
    
    let sink: Box<dyn EventSink> = Box::new(SessionAggregator::new(db.clone()));
    let handle = run_monitor_loop(
        Win32WindowResolver,
        Win32IdleDetector::new(),
        Duration::from_secs(1),
        Duration::from_secs(30),
        sink,
    );
    
    // Let it run for 5 seconds to capture foreground window
    println!("Monitoring for 5 seconds... switch to another window!");
    std::thread::sleep(Duration::from_secs(5));
    
    handle.stop();
    std::thread::sleep(Duration::from_millis(500));
    
    let sessions = db.get_sessions_by_date(chrono::Local::now().date_naive());
    println!("Sessions recorded: {}", sessions.len());
    for s in &sessions {
        println!("  {} | {} | {}s | idle={}", s.app_name, s.window_title.as_deref().unwrap_or("-"), s.duration_secs.unwrap_or(0), s.is_idle);
    }
    
    if sessions.is_empty() {
        println!("WARNING: No sessions recorded. The foreground window monitor may not be working.");
    }
}
