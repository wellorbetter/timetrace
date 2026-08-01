//! TimeTrace GUI — native desktop window binary.
//!
//! ```bash
//! cargo run -p timetrace-gui
//! ```

#![windows_subsystem = "windows"]

use std::sync::Arc;
use std::time::Duration;

use clap::Parser;
use eframe::egui;
use timetrace_core::{
    AppConfig, EventSink, SessionAggregator, SqliteStore,
    SysinfoProcessQuery, Win32IdleDetector, Win32WindowResolver,
    run_monitor_loop,
};

/// TimeTrace — app usage tracker & startup manager (GUI edition)
#[derive(Parser)]
#[command(name = "tt-gui", version)]
struct Cli {
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

    // Launch GUI
    let native_options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([800.0, 520.0])
            .with_min_inner_size([640.0, 400.0])
            .with_title("TimeTrace"),
        ..Default::default()
    };

    eframe::run_native(
        "TimeTrace",
        native_options,
        Box::new(|_cc| Ok(Box::new(GuiApp::new(db.clone())))),
    )?;

    Ok(())
}

// ── egui Application ──

struct GuiApp {
    db: Arc<dyn timetrace_core::DataStore>,
    process_query: Box<dyn timetrace_core::ProcessQuery>,
    tab: GuiTab,
    process_filter: String,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum GuiTab { Dashboard, Processes, Startup }

impl GuiApp {
    fn new(db: Arc<dyn timetrace_core::DataStore>) -> Self {
        Self {
            db,
            process_query: Box::new(SysinfoProcessQuery::new()),
            tab: GuiTab::Dashboard,
            process_filter: String::new(),
        }
    }
}

impl eframe::App for GuiApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        // Top bar with tabs
        egui::TopBottomPanel::top("tabs").show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.selectable_value(&mut self.tab, GuiTab::Dashboard, "📊 Dashboard");
                ui.selectable_value(&mut self.tab, GuiTab::Processes, "⚡ Processes");
                ui.selectable_value(&mut self.tab, GuiTab::Startup, "🚀 Startup");
            });
        });

        // Main content
        egui::CentralPanel::default().show(ctx, |ui| {
            match self.tab {
                GuiTab::Dashboard => self.show_dashboard(ui),
                GuiTab::Processes => self.show_processes(ui),
                GuiTab::Startup => self.show_startup(ui),
            }
        });
    }
}

impl GuiApp {
    fn show_dashboard(&self, ui: &mut egui::Ui) {
        let today = chrono::Local::now().date_naive();
        let top_apps = self.db.get_top_apps(today, today, 10);
        let total_all_time = self.db.total_tracked_seconds();
        let started_at = self.db.recording_started_at();

        let today_secs: i64 = top_apps.iter().map(|a| a.total_seconds).sum();
        let today_h = today_secs / 3600;
        let today_m = (today_secs % 3600) / 60;

        ui.heading(format!("Today — {}h {}m active", today_h, today_m));

        if let Some(start) = started_at {
            let days = (chrono::Utc::now() - start).num_days();
            let all_h = total_all_time / 3600;
            let all_m = (total_all_time % 3600) / 60;
            ui.label(format!(
                "Since {} ({}d ago)  ·  Total: {}h {}m tracked",
                start.format("%Y-%m-%d"), days, all_h, all_m
            ));
        }

        // Top apps list
        egui::ScrollArea::vertical().show(ui, |ui| {
            for app in &top_apps {
                let h = app.total_seconds / 3600;
                let m = (app.total_seconds % 3600) / 60;
                let time_str = if h > 0 { format!("{}h {}m", h, m) } else { format!("{}m", m) };
                let fraction = (app.total_seconds as f32 / total_secs.max(1) as f32).clamp(0.0, 1.0);

                ui.horizontal(|ui| {
                    ui.label(format!("#{}", app.rank));
                    ui.label(&app.app_name);
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        ui.label(time_str);
                    });
                });

                // Progress bar
                let color = color_for_app(&app.app_name);
                let bar = egui::ProgressBar::new(fraction)
                    .fill(color)
                    .animate(false);
                ui.add(bar);
            }
        });
    }

    fn show_processes(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            ui.label("🔍");
            ui.text_edit_singleline(&mut self.process_filter);
        });

        self.process_query.refresh();
        let procs = self.process_query.list_processes();
        let filter = self.process_filter.to_lowercase();

        let filtered: Vec<_> = procs.iter()
            .filter(|p| filter.is_empty() || p.name.to_lowercase().contains(&filter))
            .collect();

        egui::ScrollArea::vertical().show(ui, |ui| {
            egui::Grid::new("proc_grid").striped(true).show(ui, |ui| {
                ui.strong("Name"); ui.strong("CPU%"); ui.strong("Memory"); ui.strong("PID");
                ui.end_row();

                for proc in filtered.iter().take(50) {
                    let color = if proc.cpu_percent > 50.0 {
                        egui::Color32::RED
                    } else if proc.cpu_percent > 10.0 {
                        egui::Color32::YELLOW
                    } else {
                        egui::Color32::WHITE
                    };

                    ui.colored_label(color, &proc.name);
                    ui.label(format!("{:.1}", proc.cpu_percent));
                    ui.label(format!("{:.0} MB", proc.memory_mb));
                    ui.label(format!("{}", proc.pid));
                    ui.end_row();
                }
            });
        });
    }

    fn show_startup(&self, ui: &mut egui::Ui) {
        let entries = self.db.get_all_startup_entries();

        ui.heading(format!("{} startup entries", entries.len()));

        egui::ScrollArea::vertical().show(ui, |ui| {
            for entry in &entries {
                ui.horizontal(|ui| {
                    let status = if entry.enabled { "● ON" } else { "○ OFF" };
                    let color = if entry.enabled {
                        egui::Color32::GREEN
                    } else {
                        egui::Color32::GRAY
                    };
                    ui.colored_label(color, status);
                    ui.label(&entry.name);
                    ui.label(format!("[{}]", entry.source));
                    ui.label(truncate_str(&entry.command, 40));
                });
            }
        });
    }
}

fn color_for_app(name: &str) -> egui::Color32 {
    let hue = (seahash::hash(name.as_bytes()) % 360) as f32;
    egui::Color32::from(egui::ecolor::Hsva::new(hue / 360.0, 0.6, 0.7, 1.0))
}

fn truncate_str(s: &str, max: usize) -> String {
    if s.chars().count() <= max { s.to_string() }
    else { format!("{}…", &s.chars().take(max - 1).collect::<String>()) }
}
