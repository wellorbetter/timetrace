#![windows_subsystem = "windows"]

use std::sync::Arc;
use std::time::Duration;

use chrono::Timelike;
use clap::Parser;
use eframe::egui;
use timetrace_core::{
    AppConfig, DataStore, EventSink, SessionAggregator, SqliteStore,
    StartupScanner, WindowsStartupScanner,
    SysinfoProcessQuery, Win32IdleDetector, Win32WindowResolver, run_monitor_loop,
};

#[derive(Parser)] #[command(name = "tt-gui", version)]
struct Cli { #[arg(long)] db: Option<String> }

fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "timetrace=info".into()))
        .init();

    let cli = Cli::parse();
    let config = AppConfig::load();
    let db_path = cli.db.unwrap_or_else(|| {
        dirs::data_local_dir().unwrap_or_else(|| std::path::PathBuf::from("."))
            .join("TimeTrace").join("time.db").to_string_lossy().to_string()
    });

    let db = Arc::new(SqliteStore::open(std::path::PathBuf::from(&db_path))?);

    // Auto-scan startup entries on first launch
    let db_ref: &dyn DataStore = &*db;
    if db_ref.get_all_startup_entries().is_empty() {
        let scanner = WindowsStartupScanner::new();
        let entries = scanner.scan();
        db_ref.upsert_startup_entries(&entries);
    }

    let sink: Box<dyn EventSink> = Box::new(SessionAggregator::new(db.clone()));
    let _handle = run_monitor_loop(
        Win32WindowResolver, Win32IdleDetector::new(),
        Duration::from_millis(config.poll_interval_ms),
        Duration::from_secs(config.idle_threshold_minutes * 60),
        sink,
    );

    eframe::run_native("TimeTrace",
        eframe::NativeOptions { viewport: egui::ViewportBuilder::default()
            .with_inner_size([900.0, 580.0]).with_min_inner_size([680.0, 420.0]), ..Default::default() },
        Box::new(|_cc| Ok(Box::new(GuiApp::new(db.clone())))),
    )?;
    Ok(())
}

struct GuiApp {
    db: Arc<dyn timetrace_core::DataStore>,
    process_query: Box<dyn timetrace_core::ProcessQuery>,
    panel: Panel,
    proc_filter: String,
    proc_show: ProcFilter,
    startup_filter: StartFilter,
    startup_entries: Vec<timetrace_core::StartupEntryRecord>,
    selected_app: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)] enum Panel { Dashboard, Processes, Startup }
#[derive(Clone, Copy, PartialEq, Eq)] enum ProcFilter { All, User, System }
#[derive(Clone, Copy, PartialEq, Eq)] enum StartFilter { All, Enabled, Disabled }

impl GuiApp {
    fn new(db: Arc<dyn timetrace_core::DataStore>) -> Self {
        let entries = DataStore::get_all_startup_entries(&*db);
        Self { db, process_query: Box::new(SysinfoProcessQuery::new()),
            panel: Panel::Dashboard, proc_filter: String::new(), proc_show: ProcFilter::All,
            startup_filter: StartFilter::All, startup_entries: entries,
            selected_app: None }
    }
}

impl eframe::App for GuiApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        // Left sidebar
        egui::SidePanel::left("sidebar").resizable(false).min_width(140.0).max_width(160.0).show(ctx, |ui| {
            ui.add_space(8.0);
            ui.vertical(|ui| {
                for (label, panel) in [("Dashboard", Panel::Dashboard), ("Processes", Panel::Processes), ("Startup", Panel::Startup)] {
                    let selected = self.panel == panel;
                    if ui.selectable_label(selected, label).clicked() {
                        self.panel = panel; self.selected_app = None;
                    }
                }
            });
        });

        // Right content
        egui::CentralPanel::default().show(ctx, |ui| match self.panel {
            Panel::Dashboard => self.dashboard(ui),
            Panel::Processes => self.processes(ui),
            Panel::Startup => self.startup(ui),
        });

        egui::TopBottomPanel::bottom("status").show(ctx, |ui| {
            ui.label("TimeTrace  ·  100% local  ·  zero network");
        });
        ctx.request_repaint_after(Duration::from_secs(2));
    }
}

impl GuiApp {
    fn dashboard(&mut self, ui: &mut egui::Ui) {
        let today = chrono::Local::now().date_naive();
        let apps = self.db.get_top_apps(today, today, 20);
        let total_all = self.db.total_tracked_seconds();
        let started = self.db.recording_started_at();

        let today_s: i64 = apps.iter().map(|a| a.total_seconds).sum();
        ui.heading(format!("Today — {}h {}m active", today_s / 3600, (today_s % 3600) / 60));
        if let Some(s) = started {
            let days = (chrono::Utc::now() - s).num_days();
            ui.label(format!("Since {} ({}d) · Total {}h {}m",
                s.format("%Y-%m-%d"), days, total_all / 3600, (total_all % 3600) / 60));
        }

        let max_s = apps.first().map(|a| a.total_seconds).unwrap_or(1).max(1) as f32;
        ui.separator();

        // App list
        egui::ScrollArea::vertical().show(ui, |ui| {
            for app in &apps {
                let h = app.total_seconds / 3600; let m = (app.total_seconds % 3600) / 60;
                let time = if h > 0 { format!("{}h{}m", h, m) } else { format!("{}m", m) };
                let frac = app.total_seconds as f32 / max_s;
                let color = color_for(&app.app_name);
                let selected = self.selected_app.as_deref() == Some(&app.app_name);

                ui.horizontal(|ui| {
                    if ui.selectable_label(selected, format!("{} {:<28} {:>8}",
                        if selected { ">" } else { " " }, trunc(&app.app_name, 28), time)).clicked() {
                        self.selected_app = Some(if selected { String::new() } else { app.app_name.clone() });
                    }
                });
                ui.add(egui::ProgressBar::new(frac).fill(color).animate(false).desired_height(6.0));

                // Show page breakdown if selected
                if selected {
                    let titles = self.db.get_window_titles(&app.app_name, today);
                    if !titles.is_empty() {
                        let total: i64 = titles.iter().map(|(_, d)| d).sum();
                        ui.indent("pages", |ui| {
                            for (t, d) in &titles {
                                let dm = d / 60;
                                let pct = if total > 0 { (*d as f32 / total as f32 * 100.0) as i64 } else { 0 };
                                let label = if t.is_empty() { "(main window)" } else { t.as_str() };
                                ui.label(format!("  {} — {}m ({}%)", label, dm, pct));
                            }
                        });
                    }
                }
            }
        });
    }

    fn processes(&mut self, ui: &mut egui::Ui) {
        self.process_query.refresh();
        let procs = self.process_query.list_processes();

        ui.horizontal(|ui| {
            ui.label("Filter:");
            ui.text_edit_singleline(&mut self.proc_filter);
            ui.selectable_value(&mut self.proc_show, ProcFilter::All, "All");
            ui.selectable_value(&mut self.proc_show, ProcFilter::User, "User");
            ui.selectable_value(&mut self.proc_show, ProcFilter::System, "System");
        });

        let f = self.proc_filter.to_lowercase();
        let filtered: Vec<_> = procs.iter().filter(|p| {
            (f.is_empty() || p.name.to_lowercase().contains(&f)) && match self.proc_show {
                ProcFilter::All => true, ProcFilter::User => !is_sys(&p.name),
                ProcFilter::System => is_sys(&p.name),
            }
        }).collect();

        ui.label(format!("{} processes", filtered.len()));
        egui::ScrollArea::vertical().show(ui, |ui| {
            egui::Grid::new("proc").striped(true).show(ui, |ui| {
                ui.strong("Name"); ui.strong("CPU%"); ui.strong("Memory"); ui.strong("PID"); ui.strong(""); ui.end_row();
                for p in filtered.iter().take(100) {
                    let c = if p.cpu_percent > 50.0 { egui::Color32::RED } else if p.cpu_percent > 10.0 { egui::Color32::YELLOW } else { egui::Color32::WHITE };
                    ui.colored_label(c, &p.name);
                    ui.label(format!("{:.1}", p.cpu_percent));
                    ui.label(format!("{:.0}M", p.memory_mb));
                    ui.label(format!("{}", p.pid));
                    if ui.small_button("Kill").clicked() { let _ = self.process_query.terminate_process(p.pid); }
                    ui.end_row();
                }
            });
        });
    }

    fn startup(&mut self, ui: &mut egui::Ui) {
        let entries: Vec<_> = self.startup_entries.iter().filter(|e| match self.startup_filter {
            StartFilter::All => true, StartFilter::Enabled => e.enabled, StartFilter::Disabled => !e.enabled,
        }).collect();

        ui.horizontal(|ui| {
            ui.heading(format!("{} entries ({} enabled)", entries.len(), self.startup_entries.iter().filter(|e| e.enabled).count()));
            ui.selectable_value(&mut self.startup_filter, StartFilter::All, "All");
            ui.selectable_value(&mut self.startup_filter, StartFilter::Enabled, "Enabled");
            ui.selectable_value(&mut self.startup_filter, StartFilter::Disabled, "Disabled");
        });

        egui::ScrollArea::vertical().show(ui, |ui| {
            for e in &entries {
                let (status, color) = if e.enabled { ("ON", egui::Color32::GREEN) } else { ("OFF", egui::Color32::GRAY) };
                let src_color = match e.source.as_str() {
                    "HKLM" => egui::Color32::YELLOW, "HKCU" => egui::Color32::LIGHT_BLUE, _ => egui::Color32::GRAY,
                };
                ui.horizontal(|ui| {
                    ui.colored_label(color, status);
                    ui.label(&e.name);
                    ui.colored_label(src_color, format!("[{}]", e.source));
                    ui.label(trunc(&e.command, 40));
                });
            }
        });
    }
}

fn color_for(name: &str) -> egui::Color32 {
    let hue = (seahash::hash(name.as_bytes()) % 360) as f32;
    egui::Color32::from(egui::ecolor::Hsva::new(hue / 360.0, 0.5, 0.7, 1.0))
}

fn is_sys(name: &str) -> bool {
    ["svchost", "winlogon", "csrss", "smss", "wininit", "services", "lsass", "dwm", "System", "Idle"]
        .iter().any(|s| name.to_lowercase().contains(s))
}

fn trunc(s: &str, max: usize) -> String {
    if s.chars().count() <= max { s.to_string() } else { format!("{}…", &s.chars().take(max - 1).collect::<String>()) }
}
