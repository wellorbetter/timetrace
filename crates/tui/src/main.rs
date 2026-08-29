#[cfg(target_os = "windows")]
mod tui;

#[cfg(target_os = "windows")]
mod windows_app {
    use std::sync::Arc;
    use std::time::Duration;

    use clap::Parser;
    use timetrace_core::{
        AppConfig, EventSink, PlatformIdleDetector, PlatformWindowResolver, SessionAggregator,
        SqliteStore, run_monitor_loop,
    };

    use super::tui::App;

    #[derive(Parser)]
    #[command(name = "tt", version)]
    struct Cli {
        #[arg(long)]
        db: Option<String>,
    }

    pub fn run() -> Result<(), Box<dyn std::error::Error>> {
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
                .to_string()
        });
        let db = Arc::new(SqliteStore::open(std::path::PathBuf::from(&db_path))?);

        let sink: Box<dyn EventSink> = Box::new(SessionAggregator::new(db.clone()));
        let _handle = run_monitor_loop(
            PlatformWindowResolver::new(),
            PlatformIdleDetector::new(),
            Duration::from_millis(config.poll_interval_ms),
            Duration::from_secs(config.idle_threshold_minutes * 60),
            config.excluded_apps.clone(),
            sink,
        );

        let mut terminal = ratatui::init();
        let mut app = App::new(db.clone());
        if app.needs_startup_scan() {
            app.do_startup_scan();
        }

        while !app.should_quit() {
            terminal.draw(|frame| app.render(frame))?;
            if crossterm::event::poll(Duration::from_millis(100))? {
                app.handle_event(crossterm::event::read()?);
            }
        }
        ratatui::restore();
        Ok(())
    }
}

#[cfg(target_os = "windows")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    windows_app::run()
}

#[cfg(not(target_os = "windows"))]
fn main() {
    eprintln!("The legacy TimeTrace TUI is Windows-only. Use the Flutter desktop app on this platform.");
}
