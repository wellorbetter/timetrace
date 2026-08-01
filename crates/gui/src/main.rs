#![windows_subsystem = "windows"]

use std::sync::Arc;
use std::time::Duration;
use chrono::Timelike;
use clap::Parser;
use eframe::egui;
use timetrace_core::{AppConfig, DataStore, EventSink, SessionAggregator, SqliteStore, StartupScanner, WindowsStartupScanner, Win32IdleDetector, Win32WindowResolver, run_monitor_loop};

#[derive(Parser)] #[command(name = "tt-gui", version)]
struct Cli { #[arg(long)] db: Option<String> }

fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt().with_env_filter(
        tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "timetrace=info".into())).init();

    let cli = Cli::parse();
    let config = AppConfig::load();
    let db_path = cli.db.unwrap_or_else(|| dirs::data_local_dir()
        .unwrap_or_else(|| std::path::PathBuf::from(".")).join("TimeTrace").join("time.db").to_string_lossy().to_string());
    let db = Arc::new(SqliteStore::open(std::path::PathBuf::from(&db_path))?);

    // Auto-scan startup on first launch
    if DataStore::get_all_startup_entries(&*db).is_empty() {
        let entries = WindowsStartupScanner::new().scan();
        DataStore::upsert_startup_entries(&*db, &entries);
    }

    let sink: Box<dyn EventSink> = Box::new(SessionAggregator::new(db.clone()));
    let _handle = run_monitor_loop(Win32WindowResolver, Win32IdleDetector::new(),
        Duration::from_millis(config.poll_interval_ms), Duration::from_secs(config.idle_threshold_minutes * 60), sink);

    eframe::run_native("TimeTrace",
        eframe::NativeOptions { viewport: egui::ViewportBuilder::default()
            .with_inner_size([860.0, 540.0]).with_min_inner_size([640.0, 400.0]), ..Default::default() },
        Box::new(|_cc| Ok(Box::new(GuiApp::new(db.clone())))),
    )?;
    Ok(())
}

struct GuiApp { db: Arc<dyn DataStore>, panel: Panel, startup: Vec<timetrace_core::StartupEntryRecord>, detail: Option<String> }
#[derive(Clone, Copy, PartialEq, Eq)] enum Panel { Dashboard, Startup }

impl GuiApp {
    fn new(db: Arc<dyn DataStore>) -> Self {
        Self { startup: DataStore::get_all_startup_entries(&*db), db, panel: Panel::Dashboard, detail: None }
    }
}

impl eframe::App for GuiApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        egui::SidePanel::left("nav").resizable(false).min_width(130.0).max_width(150.0).show(ctx, |ui| {
            ui.add_space(8.0);
            for (label, p) in [("Dashboard", Panel::Dashboard), ("Startup", Panel::Startup)] {
                if ui.selectable_label(self.panel == p, label).clicked() { self.panel = p; self.detail = None; }
            }
        });
        egui::CentralPanel::default().show(ctx, |ui| match self.panel {
            Panel::Dashboard => self.dashboard(ui),
            Panel::Startup => self.startup(ui),
        });
        ctx.request_repaint_after(Duration::from_secs(2));
    }
}

impl GuiApp {
    fn dashboard(&mut self, ui: &mut egui::Ui) {
        let today = chrono::Local::now().date_naive();
        let apps = DataStore::get_top_apps(&*self.db, today, today, 20);
        let total_all = DataStore::total_tracked_seconds(&*self.db);
        let started = DataStore::recording_started_at(&*self.db);
        let today_s: i64 = apps.iter().map(|a| a.total_seconds).sum();

        ui.heading(format!("Today {}h {}m active", today_s / 3600, (today_s % 3600) / 60));
        if let Some(s) = started {
            ui.label(format!("Since {} ({}d)  Total {}h {}m", s.format("%Y-%m-%d"), (chrono::Utc::now() - s).num_days(), total_all / 3600, (total_all % 3600) / 60));
        }
        ui.separator();

        if apps.is_empty() {
            ui.label("Waiting for data — tracking is active. Switch between apps.");
            return;
        }

        let max = apps[0].total_seconds.max(1) as f32;
        for app in &apps {
            let h = app.total_seconds / 3600; let m = (app.total_seconds % 3600) / 60;
            let expanded = self.detail.as_deref() == Some(&app.app_name);
            ui.horizontal(|ui| {
                if ui.selectable_label(expanded, format!("{} {:<28} {}h{}m", if expanded { ">" } else { " " }, trunc(&app.app_name, 28), h, m)).clicked() {
                    self.detail = if expanded { None } else { Some(app.app_name.clone()) };
                }
            });
            ui.add(egui::ProgressBar::new(app.total_seconds as f32 / max).fill(clr(&app.app_name)).animate(false).desired_height(6.0));
            if expanded {
                let titles = DataStore::get_window_titles(&*self.db, &app.app_name, today);
                ui.indent("pages", |ui| {
                    for (t, d) in &titles { ui.label(format!("{} {}m{}s", if t.is_empty() { "(main)" } else { t }, d/60, d%60)); }
                });
            }
        }
    }

    fn startup(&self, ui: &mut egui::Ui) {
        let on = self.startup.iter().filter(|e| e.enabled).count();
        ui.heading(format!("{} entries ({} enabled)", self.startup.len(), on));
        for e in &self.startup {
            let (st, c) = if e.enabled { ("ON", egui::Color32::GREEN) } else { ("OFF", egui::Color32::GRAY) };
            ui.horizontal(|ui| {
                ui.colored_label(c, st);
                ui.label(&e.name);
                ui.label(format!("[{}]", e.source));
                ui.label(trunc(&e.command, 35));
            });
        }
    }
}

fn clr(n: &str) -> egui::Color32 { let h = (seahash::hash(n.as_bytes()) % 360) as f32; egui::Color32::from(egui::ecolor::Hsva::new(h/360.0, 0.5, 0.7, 1.0)) }
fn trunc(s: &str, max: usize) -> String { if s.chars().count() <= max { s.to_string() } else { format!("{}…", &s.chars().take(max-1).collect::<String>()) } }
