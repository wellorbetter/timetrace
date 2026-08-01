//! TimeTrace TUI — terminal dashboard binary.
//!
//! ```bash
//! cargo run -p timetrace-tui
//! ```

use std::sync::Arc;
use std::time::Duration;

use clap::Parser;
use timetrace_core::{
    AppConfig, EventSink, SessionAggregator, SqliteStore,
    SysinfoProcessQuery, Win32IdleDetector, Win32WindowResolver,
    run_monitor_loop,
};

mod tui;
use tui::App;

/// TimeTrace — app usage tracker & startup manager (TUI edition)
#[derive(Parser)]
#[command(name = "tt", version)]
struct Cli {
    /// Custom database path
    #[arg(long)]
    db: Option<String>,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "timetrace=info".into()),
        )
        .init();

    let cli = Cli::parse();
    let config = AppConfig::load();

    let db_path = cli.db.unwrap_or_else(|| {
        dirs::data_local_dir()
            .unwrap_or_else(|| std::path::PathBuf::from("."))
            .join("TimeTrace")
            .join("time.db")
            .to_string_lossy()
    });

    let db = Arc::new(SqliteStore::open(std::path::PathBuf::from(&db_path))?);

    // Start background monitor
    let sink: Box<dyn EventSink> = Box::new(SessionAggregator::new(db.clone()));
    let _handle = run_monitor_loop(
        Win32WindowResolver,
        Win32IdleDetector,
        Duration::from_millis(config.poll_interval_ms),
        Duration::from_secs(config.idle_threshold_minutes * 60),
        sink,
    );

    // Launch TUI
    let mut terminal = ratatui::init();
    let process_query = Box::new(SysinfoProcessQuery::new());
    let mut app = App::new(db.clone(), process_query);

    while !app.should_quit() {
        terminal.draw(|frame| app.render(frame))?;
        if crossterm::event::poll(Duration::from_millis(100))? {
            app.handle_event(crossterm::event::read()?);
        }
    }

    ratatui::restore();
    Ok(())
}
