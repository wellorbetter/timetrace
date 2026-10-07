use std::sync::{Arc, mpsc};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use timetrace_core::{run_monitor_loop, AppInfo, DataStore, EventSink, IdleDetector, SessionAggregator, SqliteStore, TrackedEvent, WindowResolver};

struct Resolver { available: Arc<AtomicBool>, calls: mpsc::Sender<bool>, app: AppInfo }
impl WindowResolver for Resolver {
    fn get_foreground_app(&self) -> Option<AppInfo> {
        let value = self.available.load(Ordering::SeqCst);
        let _ = self.calls.send(value);
        value.then(|| self.app.clone())
    }
    fn get_window_title(&self, _hwnd: isize) -> Option<String> { None }
}

struct Idle { value: Arc<AtomicBool>, calls: mpsc::Sender<bool> }
impl IdleDetector for Idle {
    fn is_idle(&self, _threshold: Duration) -> bool {
        let value = self.value.load(Ordering::SeqCst);
        let _ = self.calls.send(value);
        value
    }
    fn idle_duration(&self) -> Duration { Duration::from_secs(60) }
}

fn wait_for(rx: &mpsc::Receiver<bool>, expected: bool) {
    loop {
        if rx.recv_timeout(Duration::from_secs(1)).expect("monitor probe") == expected { return; }
    }
}

fn test_store() -> Arc<SqliteStore> {
    static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let id = NEXT.fetch_add(1, Ordering::SeqCst);
    let path = std::env::temp_dir().join(format!("timetrace-lifecycle-{}-{id}.sqlite3", std::process::id()));
    let _ = std::fs::remove_file(&path);
    Arc::new(SqliteStore::open(path).unwrap())
}

#[test]
fn default_adapter_fences_unresolved_pause_and_stop_without_backfill() {
    let available = Arc::new(AtomicBool::new(true));
    let idle_value = Arc::new(AtomicBool::new(false));
    let (resolver_tx, resolver_rx) = mpsc::channel();
    let (idle_tx, idle_rx) = mpsc::channel();
    let db = test_store();
    let handle = run_monitor_loop(
        Resolver { available: available.clone(), calls: resolver_tx, app: AppInfo::new("C:/work-editor.exe".into(), "work-editor".into()).with_title("main".into()) },
        Idle { value: idle_value.clone(), calls: idle_tx }, Duration::from_millis(1), Duration::from_millis(4), vec![],
        Box::new(SessionAggregator::new(db.clone())),
    );
    wait_for(&resolver_rx, true); wait_for(&resolver_rx, true);
    available.store(false, Ordering::SeqCst);
    wait_for(&resolver_rx, false); wait_for(&resolver_rx, false);
    available.store(true, Ordering::SeqCst);
    wait_for(&resolver_rx, true); wait_for(&resolver_rx, true);
    idle_value.store(true, Ordering::SeqCst);
    wait_for(&idle_rx, true); wait_for(&idle_rx, true);
    assert!(handle.pause());
    assert!(db.get_active_session().is_none());
    let today = chrono::Local::now().date_naive();
    let sessions = db.get_sessions_by_date(today);
    let apps: Vec<_> = sessions.iter().filter(|row| row.app_name == "work-editor").collect();
    assert_eq!(apps.len(), 2, "recovery must open a fresh same-app session");
    assert!(apps.iter().all(|row| row.ended_at.is_some()));
    assert!(apps[0].ended_at.unwrap() <= apps[1].started_at, "unresolved interval was backfilled");
    assert!(sessions.iter().any(|row| row.app_name == "__IDLE__" && row.ended_at.is_some()));
    idle_value.store(false, Ordering::SeqCst);
    assert!(handle.resume());
    wait_for(&resolver_rx, true); wait_for(&resolver_rx, true);
    assert!(handle.stop());
    assert!(db.get_active_session().is_none());
}

struct PanicOnFence(mpsc::Sender<()>);
impl EventSink for PanicOnFence {
    fn accept(&mut self, event: TrackedEvent) {
        if matches!(event, TrackedEvent::GapDetected { .. }) { panic!("synthetic fence failure"); }
        let _ = self.0.send(());
    }
}

#[test]
fn stop_reports_monitor_join_failure() {
    let (resolver_tx, _) = mpsc::channel();
    let (idle_tx, _) = mpsc::channel();
    let (started_tx, started_rx) = mpsc::channel();
    let handle = run_monitor_loop(
        Resolver { available: Arc::new(AtomicBool::new(true)), calls: resolver_tx, app: AppInfo::new("C:/work-editor.exe".into(), "work-editor".into()) },
        Idle { value: Arc::new(AtomicBool::new(false)), calls: idle_tx }, Duration::from_millis(1), Duration::from_millis(4), vec![], Box::new(PanicOnFence(started_tx)),
    );
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(!handle.stop());
}
