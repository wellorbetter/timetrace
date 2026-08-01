use std::sync::Arc;
use std::sync::Mutex;
use std::time::Duration;
use chrono::Timelike;
use clap::Parser;
use eframe::egui::{self, Color32, Pos2, Rect, Vec2, Stroke, Rounding};
use timetrace_core::{
    AppConfig, DataStore, EventSink, SessionAggregator, SqliteStore,
    StartupScanner, WindowsStartupScanner,
    Win32IdleDetector, Win32WindowResolver, run_monitor_loop,
};
use std::f32::consts::TAU;

#[derive(Parser)] #[command(name = "tt-gui", version)]
struct Cli { #[arg(long)] db: Option<String> }

static LOG: once_cell::sync::Lazy<Mutex<Vec<String>>> = once_cell::sync::Lazy::new(|| Mutex::new(Vec::new()));
fn log(msg: &str) {
    let mut l = LOG.lock().unwrap();
    l.push(format!("{} {}", chrono::Local::now().format("%H:%M:%S"), msg));
    if l.len() > 50 { l.remove(0); }
}

// ── Material 3 tonal palette ──
mod m3 {
    use eframe::egui::Color32;
    pub const PRIMARY: Color32 = Color32::from_rgb(103, 80, 164);
    pub const ON_PRIMARY: Color32 = Color32::from_rgb(255, 255, 255);
    pub const SURFACE: Color32 = Color32::from_rgb(254, 247, 255);
    pub const ON_SURFACE: Color32 = Color32::from_rgb(28, 27, 31);
    pub const SURFACE_VARIANT: Color32 = Color32::from_rgb(231, 224, 236);
    pub const OUTLINE: Color32 = Color32::from_rgb(121, 116, 126);
    pub const ERROR: Color32 = Color32::from_rgb(179, 38, 30);
    pub const BG: Color32 = Color32::from_rgb(255, 251, 254);
    pub const ON_BG: Color32 = Color32::from_rgb(28, 27, 31);
    pub const SUCCESS: Color32 = Color32::from_rgb(56, 142, 60);
    pub const WARNING: Color32 = Color32::from_rgb(237, 108, 2);
    pub const INFO: Color32 = Color32::from_rgb(25, 118, 210);
}

// ── i18n ──
#[derive(Clone, Copy, PartialEq)]
enum Lang { En, Zh }
impl Lang {
    fn dashboard(&self) -> &str { match self { Lang::En => "Dashboard", Lang::Zh => "仪表盘" } }
    fn startup(&self) -> &str { match self { Lang::En => "Startup", Lang::Zh => "自启动" } }
    fn today(&self) -> &str { match self { Lang::En => "Today", Lang::Zh => "今天" } }
    fn active(&self) -> &str { match self { Lang::En => "active", Lang::Zh => "活跃" } }
    fn since(&self) -> &str { match self { Lang::En => "Since", Lang::Zh => "自" } }
    fn total(&self) -> &str { match self { Lang::En => "Total", Lang::Zh => "总计" } }
    fn tracking_active(&self) -> &str { match self { Lang::En => "Tracking active. Switch apps, then come back.", Lang::Zh => "监控已启动，切换应用后回来查看。" } }
    fn click_log(&self) -> &str { match self { Lang::En => "Click Log for debug.", Lang::Zh => "点左侧 Log 查看实时日志。" } }
    fn usage_by_app(&self) -> &str { match self { Lang::En => "By App", Lang::Zh => "按应用" } }
    fn distribution(&self) -> &str { match self { Lang::En => "Dist", Lang::Zh => "占比" } }
    fn pages(&self) -> &str { match self { Lang::En => "pages", Lang::Zh => "页面" } }
    fn no_page_data(&self) -> &str { match self { Lang::En => "no page data", Lang::Zh => "无页面数据" } }
    fn entries(&self) -> &str { match self { Lang::En => "entries", Lang::Zh => "项" } }
    fn enabled(&self) -> &str { match self { Lang::En => "enabled", Lang::Zh => "已启用" } }
    fn disabled(&self) -> &str { match self { Lang::En => "disabled", Lang::Zh => "已禁用" } }
    fn all(&self) -> &str { "All" }
    fn idle(&self) -> &str { match self { Lang::En => "Idle", Lang::Zh => "挂机" } }
    fn disable(&self) -> &str { match self { Lang::En => "Disable", Lang::Zh => "禁用" } }
    fn enable(&self) -> &str { match self { Lang::En => "Enable", Lang::Zh => "启用" } }
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
        DataStore::upsert_startup_entries(&*db, &entries);
    }

    let sink: Box<dyn EventSink> = Box::new(DebugAggregator::new(SessionAggregator::new(db.clone())));
    let _handle = run_monitor_loop(Win32WindowResolver, Win32IdleDetector::new(),
        Duration::from_millis(config.poll_interval_ms),
        Duration::from_secs(config.idle_threshold_minutes * 60), sink);

    eframe::run_native("TimeTrace",
        eframe::NativeOptions { viewport: egui::ViewportBuilder::default()
            .with_inner_size([960.0, 680.0]).with_min_inner_size([720.0, 500.0]).with_title("TimeTrace"),
            ..Default::default() },
        Box::new(|cc| {
            let mut fonts = egui::FontDefinitions::default();
            if let Ok(bytes) = std::fs::read("C:\\Windows\\Fonts\\msyh.ttc") {
                fonts.font_data.insert("YaHei".into(), egui::FontData::from_owned(bytes).into());
                fonts.families.get_mut(&egui::FontFamily::Proportional).unwrap().insert(0, "YaHei".into());
            }
            cc.egui_ctx.set_fonts(fonts);
            Ok(Box::new(GuiApp::new(db.clone())))
        }),
    )?;
    Ok(())
}

struct DebugAggregator { inner: SessionAggregator }
impl DebugAggregator { fn new(inner: SessionAggregator) -> Self { Self { inner } } }
impl EventSink for DebugAggregator {
    fn accept(&mut self, event: timetrace_core::TrackedEvent) {
        if let timetrace_core::TrackedEvent::AppSwitched { current, .. } = &event {
            log(&format!("{} | {}", current.display_name, current.window_title.as_deref().unwrap_or("-")));
        }
        self.inner.accept(event);
        let today = chrono::Local::now().date_naive();
        let n = self.inner.db().get_sessions_by_date(today).len();
        if n > 0 { log(&format!("db: {} sessions", n)); }
    }
}

#[derive(Clone, Copy, PartialEq)] enum Panel { Dashboard, Startup }
#[derive(Clone, Copy, PartialEq)] enum StartFilter { All, Enabled, Disabled }

struct GuiApp {
    db: Arc<dyn DataStore>,
    panel: Panel, lang: Lang,
    startup: Vec<timetrace_core::StartupEntryRecord>,
    start_filter: StartFilter,
    selected: Option<usize>,
    show_log: bool,
}

impl GuiApp {
    fn new(db: Arc<dyn DataStore>) -> Self {
        Self { startup: DataStore::get_all_startup_entries(&*db), db,
            panel: Panel::Dashboard, lang: Lang::Zh, start_filter: StartFilter::All,
            selected: None, show_log: false }
    }
}

impl eframe::App for GuiApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        egui::SidePanel::left("nav").resizable(false).min_width(140.0).max_width(150.0)
            .show(ctx, |ui| {
                ui.add_space(12.0);
                ui.vertical_centered(|ui| { ui.heading("TimeTrace"); });
                ui.add_space(8.0);
                // Lang toggle
                if ui.button(if self.lang == Lang::En { "EN 中文" } else { "中文 EN" }).clicked() {
                    self.lang = if self.lang == Lang::En { Lang::Zh } else { Lang::En };
                }
                ui.add_space(12.0);
                for (label, p) in [(self.lang.dashboard(), Panel::Dashboard), (self.lang.startup(), Panel::Startup)] {
                    let sel = self.panel == p;
                    let r = ui.selectable_label(sel, label);
                    if r.clicked() { self.panel = p; self.selected = None; }
                }
                ui.add_space(20.0);
                if ui.button("Log").clicked() { self.show_log = !self.show_log; }
            });

        egui::CentralPanel::default().show(ctx, |ui| match self.panel {
            Panel::Dashboard => self.dashboard(ui),
            Panel::Startup => self.startup_panel(ui),
        });

        if self.show_log {
            egui::TopBottomPanel::bottom("log").min_height(120.0).resizable(true).show(ctx, |ui| {
                ui.label("Log:");
                egui::ScrollArea::vertical().stick_to_bottom(true).show(ui, |ui| {
                    for line in LOG.lock().unwrap().iter().rev().take(30) { ui.label(line.as_str()); }
                });
            });
        }
        ctx.request_repaint_after(Duration::from_secs(2));
    }
}

impl GuiApp {
    fn dashboard(&mut self, ui: &mut egui::Ui) {
        let l = self.lang;
        let today = chrono::Local::now().date_naive();
        let apps = DataStore::get_top_apps(&*self.db, today, today, 20);
        let all_total = DataStore::total_tracked_seconds(&*self.db);
        let started = DataStore::recording_started_at(&*self.db);
        let today_s: i64 = apps.iter().map(|a| a.total_seconds).sum();

        // Get idle time for today
        let idle_s = self.db.get_sessions_by_date(today).iter()
            .filter(|s| s.is_idle).filter_map(|s| s.duration_secs).sum::<i64>();

        if apps.is_empty() && idle_s == 0 {
            ui.vertical_centered(|ui| {
                ui.add_space(60.0);
                ui.heading("TimeTrace");
                ui.label(l.tracking_active());
                ui.label(l.click_log());
            });
            return;
        }

        // Header
        let h = today_s / 3600; let m = (today_s % 3600) / 60;
        ui.heading(format!("{}  {}h {}m {}", l.today(), h, m, l.active()));
        if let Some(s) = started {
            let days = (chrono::Utc::now() - s).num_days();
            ui.label(format!("{} {} ({}d)  |  {} {}h {}m",
                l.since(), s.format("%Y-%m-%d"), days, l.total(), all_total / 3600, (all_total % 3600) / 60));
        }
        ui.add_space(8.0);

        // ── Stacked bar chart + Pie ──
        let top8: Vec<_> = apps.iter().take(8).collect();
        let max_val = (top8.first().map(|a| a.total_seconds).unwrap_or(1).max(idle_s) as f32).max(1.0);

        let avail_w = ui.available_width();
        ui.horizontal(|ui| {
            // Bar chart (50% width)
            let bw = avail_w * 0.50;
            ui.vertical(|ui| {
                ui.set_width(bw);
                ui.label(l.usage_by_app());
                let chart_h = 130.0;
                let bar_count = top8.len() + (if idle_s > 0 { 1 } else { 0 });
                let bar_w = (bw - 20.0) / bar_count as f32;
                let (resp, painter) = ui.allocate_painter(Vec2::new(bw, chart_h + 20.0), egui::Sense::hover());

                for (i, app) in top8.iter().enumerate() {
                    let bh = app.total_seconds as f32 / max_val * chart_h;
                    let x = resp.rect.left() + 6.0 + i as f32 * bar_w;
                    let y = resp.rect.bottom() - 20.0 - bh;
                    painter.rect_filled(Rect::from_min_size(Pos2::new(x + 1.0, y), Vec2::new(bar_w - 2.0, bh)), 4.0, clr(&app.app_name));
                    painter.text(Pos2::new(x + bar_w / 2.0, resp.rect.bottom() - 8.0),
                        egui::Align2::CENTER_TOP, trunc6(&app.app_name), egui::FontId::proportional(9.0), m3::ON_SURFACE);
                }
                // Idle bar
                if idle_s > 0 {
                    let i = top8.len();
                    let bh = idle_s as f32 / max_val * chart_h;
                    let x = resp.rect.left() + 6.0 + i as f32 * bar_w;
                    let y = resp.rect.bottom() - 20.0 - bh;
                    painter.rect_filled(Rect::from_min_size(Pos2::new(x + 1.0, y), Vec2::new(bar_w - 2.0, bh)), 4.0, m3::OUTLINE);
                    painter.text(Pos2::new(x + bar_w / 2.0, resp.rect.bottom() - 8.0),
                        egui::Align2::CENTER_TOP, l.idle(), egui::FontId::proportional(9.0), m3::ON_SURFACE);
                }
            });

            ui.add_space(8.0);

            // Pie chart (45% width)
            let pw = avail_w * 0.42;
            ui.vertical(|ui| {
                ui.set_width(pw);
                ui.label(l.distribution());
                let size = 120.0;
                let (resp, painter) = ui.allocate_painter(Vec2::new(size, size), egui::Sense::hover());
                let cx = resp.rect.center().x;
                let cy = resp.rect.center().y;
                let r = size / 2.0 - 2.0;
                let total = top8.iter().map(|a| a.total_seconds).sum::<i64>().max(1) as f32;
                let mut angle = -TAU / 4.0; // start from top

                for app in &top8 {
                    let sweep = (app.total_seconds as f32 / total) * TAU;
                    let color = clr(&app.app_name);
                    // Draw as filled circle segment using many thin triangles
                    let steps = (sweep / 0.05).max(8.0) as usize;
                    for s in 0..steps {
                        let a1 = angle + s as f32 * sweep / steps as f32;
                        let a2 = angle + (s + 1) as f32 * sweep / steps as f32;
                        // Triangle from center to arc
                        let points = [
                            Pos2::new(cx, cy),
                            Pos2::new(cx + r * a1.cos(), cy + r * a1.sin()),
                            Pos2::new(cx + r * a2.cos(), cy + r * a2.sin()),
                        ];
                        painter.rect_filled(Rect::from_points(&points), 0.0, color);
                    }
                    angle += sweep;
                }
            });
        });

        ui.add_space(8.0);

        // ── App list + detail ──
        let sel_idx = self.selected;
        ui.horizontal(|ui| {
            egui::ScrollArea::vertical().max_height(200.0).auto_shrink([false; 2]).id_salt("app_list").show(ui, |ui| {
                for (i, app) in apps.iter().enumerate() {
                    let is_sel = sel_idx == Some(i);
                    let h = app.total_seconds / 3600; let m = (app.total_seconds % 3600) / 60;
                    let r = ui.selectable_label(is_sel, format!("  {:<24} {:>4}h {:>2}m", trunc24(&app.app_name), h, m));
                    if r.clicked() { self.selected = if is_sel { None } else { Some(i) }; }
                    ui.add(egui::ProgressBar::new(app.total_seconds as f32 / max_val).fill(clr(&app.app_name)).desired_height(4.0));
                }
                // Idle row
                if idle_s > 0 {
                    let h = idle_s / 3600; let m = (idle_s % 3600) / 60;
                    ui.selectable_label(false, format!("  {:<24} {:>4}h {:>2}m", l.idle(), h, m));
                    ui.add(egui::ProgressBar::new(idle_s as f32 / max_val).fill(m3::OUTLINE).desired_height(4.0));
                }
            });

            if let Some(idx) = sel_idx {
                if let Some(app) = apps.get(idx) {
                    ui.add_space(8.0);
                    ui.label("-->");
                    ui.vertical(|ui| {
                        ui.label(format!("{} {}", app.app_name, l.pages())); ui.separator();
                        let titles = DataStore::get_window_titles(&*self.db, &app.app_name, today);
                        if titles.is_empty() { ui.label(l.no_page_data()); }
                        else {
                            let tot: i64 = titles.iter().map(|(_,d)| d).sum();
                            for (t, d) in &titles {
                                let label = if t.is_empty() { "(main)" } else { t.as_str() };
                                let pct = if tot > 0 { (*d as f32 / tot as f32 * 100.0) as i64 } else { 0 };
                                ui.horizontal(|ui| {
                                    ui.label(trunc40(label));
                                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                                        ui.label(format!("{}m ({}%)", d / 60, pct));
                                    });
                                });
                                ui.add(egui::ProgressBar::new(*d as f32 / tot.max(1) as f32).fill(clr(label)).desired_height(3.0));
                            }
                        }
                    });
                }
            }
        });
    }

    fn startup_panel(&mut self, ui: &mut egui::Ui) {
        let l = self.lang;
        let filtered: Vec<_> = self.startup.iter().enumerate().filter(|(_, e)| match self.start_filter {
            StartFilter::All => true, StartFilter::Enabled => e.enabled, StartFilter::Disabled => !e.enabled,
        }).collect();
        let on = self.startup.iter().filter(|e| e.enabled).count();

        ui.heading(format!("Startup  |  {} {}, {} {}, {} {}",
            self.startup.len(), l.entries(), on, l.enabled(), self.startup.len() - on, l.disabled()));
        ui.horizontal(|ui| {
            for (label, f) in [(l.all(), StartFilter::All), (l.enabled(), StartFilter::Enabled), (l.disabled(), StartFilter::Disabled)] {
                if ui.selectable_label(self.start_filter == f, label).clicked() { self.start_filter = f; }
            }
        });
        ui.separator();

        let mut toggle: Option<(usize, bool)> = None;
        egui::ScrollArea::vertical().show(ui, |ui| {
            for (orig_i, e) in &filtered {
                let is_sys = e.source == "HKLM" || e.command.to_lowercase().contains("\\system32\\") || e.command.to_lowercase().contains("\\windows\\");
                let st = if e.enabled { "ON" } else { "OFF" };
                let st_c = if e.enabled { m3::SUCCESS } else { m3::OUTLINE };

                ui.horizontal(|ui| {
                    // System badge
                    let badge = if is_sys { "SYS" } else { "USR" };
                    let badge_c = if is_sys { m3::WARNING } else { m3::INFO };
                    ui.label(egui::RichText::new(format!("[{}]", badge)).color(badge_c).size(10.0));

                    ui.colored_label(st_c, st);
                    // Only show app name, not full path
                    let name = extract_exe_name(&e.command).unwrap_or_else(|| e.name.clone());
                    ui.label(trunc24(&name));

                    if ui.small_button(if e.enabled { l.disable() } else { l.enable() }).clicked() {
                        toggle = Some((*orig_i, !e.enabled));
                    }
                });
            }
        });

        if let Some((i, enable)) = toggle {
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

// ── Helpers ──

fn clr(name: &str) -> Color32 {
    let hue = (seahash::hash(name.as_bytes()) % 360) as f32;
    let colors: [(f32, Color32); 8] = [
        (0.0, Color32::from_rgb(103, 80, 164)),      // M3 purple
        (45.0, Color32::from_rgb(25, 118, 210)),      // blue
        (90.0, Color32::from_rgb(56, 142, 60)),       // green  
        (135.0, Color32::from_rgb(237, 108, 2)),      // orange
        (180.0, Color32::from_rgb(0, 150, 136)),      // teal
        (225.0, Color32::from_rgb(211, 47, 47)),      // red
        (270.0, Color32::from_rgb(156, 39, 176)),     // purple
        (315.0, Color32::from_rgb(121, 85, 72)),      // brown
    ];
    let idx = (hue / 45.0) as usize % colors.len();
    colors[idx].1
}

fn trunc6(s: &str) -> String { trunc(s, 6) }
fn trunc24(s: &str) -> String { trunc(s, 24) }
fn trunc40(s: &str) -> String { trunc(s, 40) }
fn trunc(s: &str, max: usize) -> String {
    if s.chars().count() <= max { s.to_string() } else { format!("{}…", &s.chars().take(max-1).collect::<String>()) }
}

fn extract_exe_name(cmd: &str) -> Option<String> {
    // Extract exe name from paths like "C:\Program Files\App\app.exe" or "\"D:\App\app.exe\" -arg"
    let cleaned = cmd.trim_matches('"').trim();
    // Try to find .exe in the string
    if let Some(idx) = cleaned.to_lowercase().rfind(".exe") {
        let before = &cleaned[..idx + 4];
        // Get last component
        if let Some(last_slash) = before.rfind('\\') {
            return Some(before[last_slash + 1..].to_string());
        }
        return Some(before.to_string());
    }
    None
}
