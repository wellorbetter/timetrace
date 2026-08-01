use std::sync::Arc;
use std::sync::Mutex;
use std::time::Duration;
use chrono::Timelike;
use clap::Parser;
use eframe::egui::{self, Color32, Pos2, Rect, Vec2};
use timetrace_core::{
    AppConfig, DataStore, EventSink, SessionAggregator, SqliteStore,
    StartupScanner, WindowsStartupScanner,
    Win32IdleDetector, Win32WindowResolver, run_monitor_loop,
};
use std::f32::consts::TAU;

#[derive(Parser)] #[command(name = "tt-gui", version)]
struct Cli { #[arg(long)] db: Option<String> }

// Shared log buffer for debugging
static LOG: once_cell::sync::Lazy<Mutex<Vec<String>>> = once_cell::sync::Lazy::new(|| Mutex::new(Vec::new()));
fn log(msg: &str) {
    let mut l = LOG.lock().unwrap();
    l.push(format!("{} {}", chrono::Local::now().format("%H:%M:%S"), msg));
    if l.len() > 50 { l.remove(0); }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();
    let config = AppConfig::load();
    let db_path = cli.db.unwrap_or_else(|| dirs::data_local_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join("TimeTrace").join("time.db").to_string_lossy().to_string());
    let db = Arc::new(SqliteStore::open(std::path::PathBuf::from(&db_path))?);

    if DataStore::get_all_startup_entries(&*db).is_empty() {
        let entries = WindowsStartupScanner::new().scan();
        log(&format!("startup scan: {} entries", entries.len()));
        DataStore::upsert_startup_entries(&*db, &entries);
    }

    let sink: Box<dyn EventSink> = Box::new(DebugAggregator::new(SessionAggregator::new(db.clone())));
    let _handle = run_monitor_loop(Win32WindowResolver, Win32IdleDetector::new(),
        Duration::from_millis(config.poll_interval_ms),
        Duration::from_secs(config.idle_threshold_minutes * 60), sink);

    log("monitor started — switch to another app to record");

    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([960.0, 680.0])
            .with_min_inner_size([720.0, 500.0])
            .with_title("TimeTrace"),
        ..Default::default()
    };

    eframe::run_native("TimeTrace", options,
        Box::new(|cc| {
            // Load CJK-capable font for Chinese display
            let mut fonts = egui::FontDefinitions::default();
            // Try Microsoft YaHei (Windows CJK font)
            if let Ok(bytes) = std::fs::read("C:\\Windows\\Fonts\\msyh.ttc") {
                fonts.font_data.insert("YaHei".into(), egui::FontData::from_owned(bytes).into());
                fonts.families.get_mut(&egui::FontFamily::Proportional).unwrap()
                    .insert(0, "YaHei".into());
            }
            cc.egui_ctx.set_fonts(fonts);
            Ok(Box::new(GuiApp::new(db.clone())))
        }),
    )?;
    Ok(())
}

// Debug wrapper around EventSink that logs events
struct DebugAggregator { inner: SessionAggregator }
impl DebugAggregator {
    fn new(inner: SessionAggregator) -> Self { Self { inner } }
}
impl EventSink for DebugAggregator {
    fn accept(&mut self, event: timetrace_core::TrackedEvent) {
        match &event {
            timetrace_core::TrackedEvent::AppSwitched { previous: _, current, .. } => {
                log(&format!("app: {} | {}", current.display_name, current.window_title.as_deref().unwrap_or("-")));
            }
            timetrace_core::TrackedEvent::IdleStarted { .. } => log("idle start"),
            timetrace_core::TrackedEvent::IdleEnded { current_app, .. } => {
                log(&format!("idle end → {}", current_app.display_name));
            }
            _ => {}
        }
        self.inner.accept(event);
        let today = chrono::Local::now().date_naive();
        let count = self.inner.db().get_sessions_by_date(today).len();
        log(&format!("db: {} sessions", count));
    }
}

#[derive(Clone, Copy, PartialEq)] enum Panel { Dashboard, Startup }
#[derive(Clone, Copy, PartialEq)] enum StartFilter { All, Enabled, Disabled }

struct GuiApp {
    db: Arc<dyn DataStore>,
    panel: Panel,
    startup: Vec<timetrace_core::StartupEntryRecord>,
    start_filter: StartFilter,
    selected: Option<usize>,
    show_log: bool,
}

impl GuiApp {
    fn new(db: Arc<dyn DataStore>) -> Self {
        Self { startup: DataStore::get_all_startup_entries(&*db), db,
            panel: Panel::Dashboard, start_filter: StartFilter::All,
            selected: None, show_log: false }
    }
}

impl eframe::App for GuiApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        egui::SidePanel::left("nav").resizable(false).min_width(140.0).max_width(150.0)
            .show(ctx, |ui| {
                ui.add_space(12.0);
                ui.vertical_centered(|ui| { ui.heading("TimeTrace"); });
                ui.add_space(16.0);
                for (label, p) in [("Dashboard", Panel::Dashboard), ("Startup", Panel::Startup)] {
                    let sel = self.panel == p;
                    let r = ui.selectable_label(sel, label);
                    if r.clicked() { self.panel = p; self.selected = None; }
                    if sel { r.highlight(); }
                }
                ui.add_space(20.0);
                if ui.button("Log").clicked() { self.show_log = !self.show_log; }
            });

        egui::CentralPanel::default().show(ctx, |ui| match self.panel {
            Panel::Dashboard => self.dashboard(ui),
            Panel::Startup => self.startup_panel(ui),
        });

        // Debug log overlay (bottom)
        if self.show_log {
            egui::TopBottomPanel::bottom("log").min_height(120.0).resizable(true).show(ctx, |ui| {
                ui.label("Monitor Log:");
                egui::ScrollArea::vertical().stick_to_bottom(true).show(ui, |ui| {
                    let logs = LOG.lock().unwrap();
                    for line in logs.iter().rev().take(30) {
                        ui.label(line.as_str());
                    }
                });
            });
        }

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

        // Header
        if apps.is_empty() {
            ui.vertical_centered(|ui| {
                ui.add_space(60.0);
                ui.heading("TimeTrace");
                ui.label("Tracking is active. Switch to another app, then come back.");
                ui.add_space(8.0);
                ui.label("Click 'Log' in sidebar to see live monitor events.");
            });
            return;
        }

        ui.heading(format!("Today  {}h {}m active", today_s / 3600, (today_s % 3600) / 60));
        if let Some(s) = started {
            let days = (chrono::Utc::now() - s).num_days();
            ui.label(format!("Since {} ({}d)  |  Total {}h {}m",
                s.format("%Y-%m-%d"), days, total_all / 3600, (total_all % 3600) / 60));
        }
        ui.add_space(8.0);

        // Charts
        let top8: Vec<_> = apps.iter().take(8).collect();
        let max_s = top8.first().map(|a| a.total_seconds).unwrap_or(1).max(1) as f32;

        ui.horizontal(|ui| {
            // Bar chart
            ui.vertical(|ui| {
                ui.label("Usage by application");
                let h = 120.0; let w = 280.0;
                let bar_w = (w - 20.0) / top8.len() as f32;
                let (resp, painter) = ui.allocate_painter(Vec2::new(w, h + 20.0), egui::Sense::hover());
                for (i, app) in top8.iter().enumerate() {
                    let bh = app.total_seconds as f32 / max_s * h;
                    let x = resp.rect.left() + 10.0 + i as f32 * bar_w;
                    let y = resp.rect.bottom() - 20.0 - bh;
                    painter.rect_filled(Rect::from_min_size(Pos2::new(x + 2.0, y), Vec2::new(bar_w - 4.0, bh)), 0.0, clr(&app.app_name));
                    painter.text(Pos2::new(x + bar_w / 2.0, resp.rect.bottom() - 10.0),
                        egui::Align2::CENTER_TOP, trunc(&app.app_name, 6), egui::FontId::proportional(10.0), Color32::GRAY);
                }
            });
            ui.add_space(16.0);
            // Pie
            ui.vertical(|ui| {
                ui.label("Distribution");
                let size = 120.0;
                let (resp, painter) = ui.allocate_painter(Vec2::new(size, size), egui::Sense::hover());
                let center = resp.rect.center(); let radius = size / 2.0 - 4.0;
                let total = top8.iter().map(|a| a.total_seconds).sum::<i64>().max(1) as f32;
                let mut angle = 0.0f32;
                for app in &top8 {
                    let sweep = (app.total_seconds as f32 / total) * TAU;
                    let steps = 32; let step = sweep / steps as f32;
                    for s in 0..steps {
                        let a1 = angle + s as f32 * step; let a2 = angle + (s+1) as f32 * step;
                        let p1 = Pos2::new(center.x + radius * a1.cos(), center.y + radius * a1.sin());
                        let p2 = Pos2::new(center.x + radius * a2.cos(), center.y + radius * a2.sin());
                        painter.rect_filled(Rect::from_two_pos(p1, p2), 0.0, clr(&app.app_name));
                    }
                    angle += sweep;
                }
            });
        });

        ui.add_space(8.0);

        // App list + detail
        let sel_idx = self.selected;
        ui.horizontal(|ui| {
            egui::ScrollArea::vertical().max_height(240.0).auto_shrink([false; 2]).show(ui, |ui| {
                for (i, app) in apps.iter().enumerate() {
                    let h = app.total_seconds / 3600; let m = (app.total_seconds % 3600) / 60;
                    let is_sel = sel_idx == Some(i);
                    let r = ui.selectable_label(is_sel, format!("  {:<28} {:>4}h {:>2}m", trunc(&app.app_name, 28), h, m));
                    if r.clicked() { self.selected = if is_sel { None } else { Some(i) }; }
                    ui.add(egui::ProgressBar::new(app.total_seconds as f32 / max_s).fill(clr(&app.app_name)).animate(true).desired_height(4.0));
                }
            });
            if let Some(idx) = sel_idx {
                if let Some(app) = apps.get(idx) {
                    ui.add_space(8.0);
                    ui.vertical_centered(|ui| { ui.label("-->"); });
                    ui.vertical(|ui| {
                        ui.label(format!("{} pages", app.app_name)); ui.separator();
                        let titles = DataStore::get_window_titles(&*self.db, &app.app_name, today);
                        if titles.is_empty() { ui.label("  (no page data)"); }
                        else {
                            let tot: i64 = titles.iter().map(|(_,d)| d).sum();
                            for (t, d) in &titles {
                                let pct = if tot > 0 { (*d as f32 / tot as f32 * 100.0) as i64 } else { 0 };
                                let label = if t.is_empty() { "(main)" } else { t.as_str() };
                                ui.horizontal(|ui| {
                                    ui.label(format!("  {}", label));
                                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                                        ui.label(format!("{}m {}%", d/60, pct));
                                    });
                                });
                                ui.add(egui::ProgressBar::new(*d as f32 / tot.max(1) as f32).fill(clr(label)).animate(true).desired_height(3.0));
                            }
                        }
                    });
                }
            }
        });
    }

    fn startup_panel(&mut self, ui: &mut egui::Ui) {
        let filtered: Vec<_> = self.startup.iter().enumerate().filter(|(_, e)| match self.start_filter {
            StartFilter::All => true, StartFilter::Enabled => e.enabled, StartFilter::Disabled => !e.enabled,
        }).collect();
        let on = self.startup.iter().filter(|e| e.enabled).count();

        ui.heading(format!("Startup  |  {} entries, {} enabled, {} disabled",
            self.startup.len(), on, self.startup.len() - on));
        ui.horizontal(|ui| {
            for (label, f) in [("All", StartFilter::All), ("Enabled", StartFilter::Enabled), ("Disabled", StartFilter::Disabled)] {
                if ui.selectable_label(self.start_filter == f, label).clicked() { self.start_filter = f; }
            }
        });
        ui.separator();

        let mut to_toggle: Option<(usize, bool)> = None;
        egui::ScrollArea::vertical().show(ui, |ui| {
            for (orig_i, e) in &filtered {
                let is_sys = e.source == "HKLM" || e.command.contains("\\system32\\") || e.command.contains("\\WINDOWS\\");
                let icon = if is_sys { "SYS" } else { "USR" };
                let icon_color = if is_sys { Color32::YELLOW } else { Color32::LIGHT_BLUE };
                let st = if e.enabled { "ON " } else { "OFF" };
                let st_c = if e.enabled { Color32::GREEN } else { Color32::GRAY };

                ui.horizontal(|ui| {
                    ui.colored_label(icon_color, format!("[{}]", icon));
                    ui.colored_label(st_c, st);
                    ui.label(trunc(&e.name, 24));
                    ui.label(trunc(&e.command, 40));
                    if ui.small_button(if e.enabled { "Disable" } else { "Enable" }).clicked() {
                        to_toggle = Some((*orig_i, !e.enabled));
                    }
                });
            }
        });

        if let Some((i, enable)) = to_toggle {
            let entry = &self.startup[i];
            let scanner = WindowsStartupScanner::new();
            if enable {
                if scanner.enable(entry).is_ok() { DataStore::set_startup_enabled(&*self.db, entry.id, true, None, None); }
            } else {
                if let Ok(r) = scanner.disable(entry) { DataStore::set_startup_enabled(&*self.db, entry.id, false, r.backup_value.as_deref(), r.backup_path.as_deref()); }
            }
            self.startup = DataStore::get_all_startup_entries(&*self.db);
        }
    }
}

fn clr(name: &str) -> Color32 {
    Color32::from(egui::ecolor::Hsva::new((seahash::hash(name.as_bytes()) % 360) as f32 / 360.0, 0.55, 0.72, 1.0))
}
fn trunc(s: &str, max: usize) -> String {
    if s.chars().count() <= max { s.to_string() } else { format!("{}…", &s.chars().take(max-1).collect::<String>()) }
}
