#![windows_subsystem = "windows"]

use std::sync::Arc;
use std::time::Duration;

use chrono::Timelike;

use clap::Parser;
use eframe::egui;
use egui_plot::{Bar, BarChart, Legend, Plot};
use timetrace_core::{
    AppConfig, EventSink, SessionAggregator, SqliteStore,
    SysinfoProcessQuery, Win32IdleDetector, Win32WindowResolver, run_monitor_loop,
};

#[derive(Parser)]
#[command(name = "tt-gui", version)]
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

    let sink: Box<dyn EventSink> = Box::new(SessionAggregator::new(db.clone()));
    let _handle = run_monitor_loop(
        Win32WindowResolver, Win32IdleDetector::new(),
        Duration::from_millis(config.poll_interval_ms),
        Duration::from_secs(config.idle_threshold_minutes * 60),
        sink,
    );

    eframe::run_native(
        "TimeTrace",
        eframe::NativeOptions { viewport: egui::ViewportBuilder::default()
            .with_inner_size([860.0, 560.0]).with_min_inner_size([640.0, 400.0]), ..Default::default() },
        Box::new(|_cc| Ok(Box::new(GuiApp::new(db.clone())))),
    )?;
    Ok(())
}

struct GuiApp {
    db: Arc<dyn timetrace_core::DataStore>,
    process_query: Box<dyn timetrace_core::ProcessQuery>,
    tab: GuiTab,
    process_filter: String,
    startup_filter: GuiStartupFilter,
}

#[derive(Clone, Copy, PartialEq, Eq)] enum GuiTab { Dashboard, Processes, Startup }
#[derive(Clone, Copy, PartialEq, Eq)] enum GuiStartupFilter { All, Enabled, Disabled }

impl GuiApp {
    fn new(db: Arc<dyn timetrace_core::DataStore>) -> Self {
        Self { db, process_query: Box::new(SysinfoProcessQuery::new()),
            tab: GuiTab::Dashboard, process_filter: String::new(), startup_filter: GuiStartupFilter::All }
    }
}

impl eframe::App for GuiApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        egui::TopBottomPanel::top("tabs").show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.selectable_value(&mut self.tab, GuiTab::Dashboard, "📊 Dashboard");
                ui.selectable_value(&mut self.tab, GuiTab::Processes, "⚡ Processes");
                ui.selectable_value(&mut self.tab, GuiTab::Startup, "🚀 Startup");
            });
        });

        egui::CentralPanel::default().show(ctx, |ui| match self.tab {
            GuiTab::Dashboard => self.dashboard(ui),
            GuiTab::Processes => self.processes(ui),
            GuiTab::Startup => self.startup(ui),
        });

        egui::TopBottomPanel::bottom("status").show(ctx, |ui| {
            ui.label("TimeTrace  ·  100% local  ·  zero network");
        });

        ctx.request_repaint_after(Duration::from_secs(2));
    }
}

impl GuiApp {
    fn dashboard(&self, ui: &mut egui::Ui) {
        let today = chrono::Local::now().date_naive();
        let top_apps = self.db.get_top_apps(today, today, 10);
        let total_all = self.db.total_tracked_seconds();
        let started = self.db.recording_started_at();
        let sessions = self.db.get_sessions_by_date(today);

        let today_s: i64 = top_apps.iter().map(|a| a.total_seconds).sum();
        ui.heading(format!("Today — {}h {}m active", today_s / 3600, (today_s % 3600) / 60));

        if let Some(s) = started {
            let days = (chrono::Utc::now() - s).num_days();
            ui.label(format!("Since {} ({}d) · Lifetime: {}h {}m",
                s.format("%Y-%m-%d"), days, total_all / 3600, (total_all % 3600) / 60));
        }

        // Timeline chart
        let mut hour_data: [f64; 24] = [0.0; 24];
        for s in &sessions {
            let h = s.started_at.hour() as usize;
            if h < 24 && !s.is_idle {
                hour_data[h] += s.duration_secs.unwrap_or(0) as f64 / 60.0;
            }
        }
        let bars: Vec<Bar> = hour_data.iter().enumerate().map(|(i, &m)| {
            Bar::new(i as f64 + 0.5, m).width(0.85).fill(color_for_app_idx(i))
        }).collect();

        Plot::new("timeline").height(80.0).show_axes(false).show_x(false).legend(Legend::default()).show(ui, |plot_ui| {
            plot_ui.bar_chart(BarChart::new(bars).color(egui::Color32::from_rgb(100, 149, 237)));
        });

        // Top apps
        ui.separator();
        ui.strong("Top Applications");
        for app in &top_apps {
            let h = app.total_seconds / 3600; let m = (app.total_seconds % 3600) / 60;
            let time = if h > 0 { format!("{}h {}m", h, m) } else { format!("{}m", m) };
            let frac = app.total_seconds as f32 / today_s.max(1) as f32;
            let color = color_for_app(&app.app_name);

            ui.horizontal(|ui| {
                ui.label(format!("#{}", app.rank));
                ui.colored_label(color, &app.app_name);
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| { ui.label(time); });
            });
            ui.add(egui::ProgressBar::new(frac).fill(color).animate(false).desired_height(8.0));
        }
    }

    fn processes(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            ui.label("🔍");
            ui.text_edit_singleline(&mut self.process_filter);
        });

        self.process_query.refresh();
        let procs = self.process_query.list_processes();
        let f = self.process_filter.to_lowercase();
        let filtered: Vec<_> = procs.iter()
            .filter(|p| f.is_empty() || p.name.to_lowercase().contains(&f) || p.pid.to_string().contains(&f))
            .collect();

        ui.label(format!("{} processes", filtered.len()));

        egui::ScrollArea::vertical().show(ui, |ui| {
            egui::Grid::new("procs").striped(true).num_columns(5).show(ui, |ui| {
                ui.strong("Name"); ui.strong("CPU%"); ui.strong("Memory"); ui.strong("PID"); ui.strong("Action"); ui.end_row();
                for proc in filtered.iter().take(100) {
                    let color = if proc.cpu_percent > 50.0 { egui::Color32::RED }
                        else if proc.cpu_percent > 10.0 { egui::Color32::YELLOW } else { egui::Color32::WHITE };
                    ui.colored_label(color, &proc.name);
                    ui.label(format!("{:.1}", proc.cpu_percent));
                    ui.label(format!("{:.0} MB", proc.memory_mb));
                    ui.label(format!("{}", proc.pid));
                    if ui.small_button("Kill").clicked() {
                        let _ = self.process_query.terminate_process(proc.pid);
                    }
                    ui.end_row();
                }
            });
        });
    }

    fn startup(&mut self, ui: &mut egui::Ui) {
        let entries = self.db.get_all_startup_entries();
        let enabled = entries.iter().filter(|e| e.enabled).count();

        ui.horizontal(|ui| {
            ui.heading(format!("{} entries ({} enabled)", entries.len(), enabled));
            ui.selectable_value(&mut self.startup_filter, GuiStartupFilter::All, "All");
            ui.selectable_value(&mut self.startup_filter, GuiStartupFilter::Enabled, "Enabled");
            ui.selectable_value(&mut self.startup_filter, GuiStartupFilter::Disabled, "Disabled");
        });

        let filtered: Vec<_> = entries.iter().filter(|e| match self.startup_filter {
            GuiStartupFilter::All => true, GuiStartupFilter::Enabled => e.enabled, GuiStartupFilter::Disabled => !e.enabled,
        }).collect();

        egui::ScrollArea::vertical().show(ui, |ui| {
            for e in &filtered {
                let (status, color) = if e.enabled { ("● ON", egui::Color32::GREEN) } else { ("○ OFF", egui::Color32::GRAY) };
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

fn color_for_app(name: &str) -> egui::Color32 {
    let hue = (seahash::hash(name.as_bytes()) % 360) as f32;
    egui::Color32::from(egui::ecolor::Hsva::new(hue / 360.0, 0.6, 0.7, 1.0))
}

fn color_for_app_idx(i: usize) -> egui::Color32 {
    let hues = [210.0, 30.0, 120.0, 280.0, 50.0, 180.0, 330.0, 90.0];
    egui::Color32::from(egui::ecolor::Hsva::new(hues[i % hues.len()] / 360.0, 0.5, 0.65, 1.0))
}

fn trunc(s: &str, max: usize) -> String {
    if s.chars().count() <= max { s.to_string() } else { format!("{}…", &s.chars().take(max - 1).collect::<String>()) }
}
