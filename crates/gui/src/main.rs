use std::sync::Arc;
use std::sync::Mutex;
use std::time::Duration;
use chrono::Timelike;
use clap::Parser;
use eframe::egui::{self, Color32, Pos2, Rect, Vec2, Stroke, Rounding, Shape};
use timetrace_core::{
    AppConfig, AppUsageSplit, DataStore, EventSink, SessionAggregator, SqliteStore,
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

// ── Material 3 (default theme) ──
mod m3 {
    use eframe::egui::Color32;
    pub const PRIMARY: Color32 = Color32::from_rgb(103, 80, 164);
    pub const SURFACE: Color32 = Color32::from_rgb(254, 247, 255);
    pub const ON_SURFACE: Color32 = Color32::from_rgb(28, 27, 31);
    pub const SURFACE_VARIANT: Color32 = Color32::from_rgb(231, 224, 236);
    pub const OUTLINE: Color32 = Color32::from_rgb(121, 116, 126);
    pub const ERROR: Color32 = Color32::from_rgb(179, 38, 30);
    pub const BG: Color32 = Color32::from_rgb(255, 251, 254);
    pub const SUCCESS: Color32 = Color32::from_rgb(56, 142, 60);
    pub const WARNING: Color32 = Color32::from_rgb(237, 108, 2);
    pub const INFO: Color32 = Color32::from_rgb(25, 118, 210);
}

#[derive(Clone, Copy, PartialEq)] enum Lang { En, Zh }
impl Lang {
    fn dashboard(&self) -> &str { match self { Lang::En => "Dashboard", Lang::Zh => "仪表盘" } }
    fn startup(&self) -> &str { match self { Lang::En => "Startup", Lang::Zh => "自启动" } }
    fn today(&self) -> &str { match self { Lang::En => "Today", Lang::Zh => "今天" } }
    fn active(&self) -> &str { match self { Lang::En => "active", Lang::Zh => "活跃" } }
    fn idle(&self) -> &str { match self { Lang::En => "Idle", Lang::Zh => "挂机" } }
    fn since(&self) -> &str { match self { Lang::En => "Since", Lang::Zh => "自" } }
    fn total(&self) -> &str { match self { Lang::En => "Total", Lang::Zh => "总计" } }
    fn tracking(&self) -> &str { match self { Lang::En => "Tracking active. Switch apps, then come back.", Lang::Zh => "监控中，切换应用后回来查看。" } }
    fn by_app(&self) -> &str { match self { Lang::En => "By App", Lang::Zh => "按应用" } }
    fn dist(&self) -> &str { match self { Lang::En => "Distribution", Lang::Zh => "占比" } }
    fn pages(&self) -> &str { match self { Lang::En => "pages", Lang::Zh => "页面" } }
    fn entries(&self) -> &str { match self { Lang::En => "entries", Lang::Zh => "项" } }
    fn enabled(&self) -> &str { match self { Lang::En => "enabled", Lang::Zh => "已启用" } }
    fn disabled(&self) -> &str { match self { Lang::En => "disabled", Lang::Zh => "已禁用" } }
    fn disable(&self) -> &str { match self { Lang::En => "Disable", Lang::Zh => "禁用" } }
    fn enable(&self) -> &str { match self { Lang::En => "Enable", Lang::Zh => "启用" } }
    fn all(&self) -> &str { "All" }
    fn empty(&self) -> &str { match self { Lang::En => "No data yet", Lang::Zh => "暂无数据" } }
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
            .with_inner_size([980.0, 700.0]).with_min_inner_size([760.0, 520.0]).with_title("TimeTrace"),
            ..Default::default() },
        Box::new(|cc| {
            let mut fonts = egui::FontDefinitions::default();
            if let Ok(bytes) = std::fs::read("C:\\Windows\\Fonts\\msyh.ttc") {
                fonts.font_data.insert("YaHei".into(), egui::FontData::from_owned(bytes).into());
                fonts.families.get_mut(&egui::FontFamily::Proportional).unwrap().insert(0, "YaHei".into());
            }
            cc.egui_ctx.set_fonts(fonts);
            // Material 3 light theme
            let mut v = egui::Visuals::light();
            v.panel_fill = m3::BG;
            v.window_fill = m3::SURFACE;
            v.faint_bg_color = m3::SURFACE_VARIANT;
            v.extreme_bg_color = m3::SURFACE_VARIANT;
            v.selection.bg_fill = m3::PRIMARY;
            v.selection.stroke = Stroke::new(1.0, m3::ON_SURFACE);
            v.widgets.inactive.bg_fill = m3::SURFACE_VARIANT;
            v.widgets.hovered.bg_fill = m3::SURFACE_VARIANT;
            v.widgets.active.bg_fill = m3::PRIMARY;
            v.override_text_color = Some(m3::ON_SURFACE);
            cc.egui_ctx.set_visuals(v);
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
        let n = self.inner.db().get_sessions_by_date(chrono::Local::now().date_naive()).len();
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
        egui::SidePanel::left("nav").resizable(false).min_width(150.0).max_width(160.0)
            .show(ctx, |ui| {
                ui.add_space(14.0);
                ui.vertical_centered(|ui| { ui.heading("TimeTrace"); });
                ui.add_space(8.0);
                if ui.button(if self.lang == Lang::En { "EN  中文" } else { "中文  EN" }).clicked() {
                    self.lang = if self.lang == Lang::En { Lang::Zh } else { Lang::En };
                }
                ui.add_space(12.0);
                for (label, p) in [(self.lang.dashboard(), Panel::Dashboard), (self.lang.startup(), Panel::Startup)] {
                    if ui.selectable_label(self.panel == p, label).clicked() { self.panel = p; self.selected = None; }
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
        let split = DataStore::get_usage_split(&*self.db, today, today);
        let all_total = DataStore::total_tracked_seconds(&*self.db);
        let started = DataStore::recording_started_at(&*self.db);

        // Add active session's elapsed time
        let active_extra = DataStore::get_active_session(&*self.db).map(|s| {
            (chrono::Utc::now() - s.started_at).num_seconds().max(0)
        }).unwrap_or(0);

        let active_s: i64 = split.iter().map(|s| s.active_seconds).sum::<i64>() + active_extra;
        let idle_s: i64 = split.iter().map(|s| s.idle_seconds).sum::<i64>();

        if split.is_empty() && active_extra == 0 {
            ui.vertical_centered(|ui| {
                ui.add_space(80.0);
                ui.heading("TimeTrace");
                ui.label(l.tracking());
            });
            return;
        }

        // Header
        ui.heading(format!("{}  {}h {}m {}", l.today(), active_s / 3600, (active_s % 3600) / 60, l.active()));
        if idle_s > 0 {
            ui.label(format!("{} {}h {}m", l.idle(), idle_s / 3600, (idle_s % 3600) / 60));
        }
        if let Some(s) = started {
            let days = (chrono::Utc::now() - s).num_days();
            ui.label(format!("{} {} ({}d)  |  {} {}h {}m", l.since(), s.format("%Y-%m-%d"), days, l.total(), all_total / 3600, (all_total % 3600) / 60));
        }
        ui.add_space(8.0);

        // Include active extra in the top entry
        let mut top8: Vec<AppUsageSplit> = split.clone();
        if active_extra > 0 {
            if let Some(first) = top8.first_mut() { first.active_seconds += active_extra; }
        }
        if top8.len() > 8 { top8.truncate(8); }

        let max_val = top8.iter().map(|s| s.active_seconds + s.idle_seconds).max().unwrap_or(1).max(1) as f32;

        // ── Charts row ──
        let avail_w = ui.available_width();
        ui.horizontal(|ui| {
            // Stacked bar chart (50%)
            let bw = (avail_w * 0.50).min(420.0);
            ui.vertical(|ui| {
                ui.set_width(bw);
                ui.label(l.by_app());
                let chart_h = 140.0;
                let bar_w = (bw - 20.0) / top8.len().max(1) as f32;
                let (resp, painter) = ui.allocate_painter(Vec2::new(bw, chart_h + 26.0), egui::Sense::hover());

                for (i, s) in top8.iter().enumerate() {
                    let total_h = (s.active_seconds + s.idle_seconds) as f32 / max_val * chart_h;
                    let x = resp.rect.left() + 6.0 + i as f32 * bar_w;
                    let bottom = resp.rect.bottom() - 26.0;

                    // Active part (colored, rounded top)
                    if s.active_seconds > 0 {
                        let ah = s.active_seconds as f32 / max_val * chart_h;
                        let active_rect = Rect::from_min_size(Pos2::new(x + 1.0, bottom - ah), Vec2::new(bar_w - 2.0, ah));
                        painter.rect_filled(active_rect, Rounding::same(if s.idle_seconds > 0 { 0 } else { 4 }), clr(&s.app_name));
                    }
                    // Idle part stacked on top (gray, rounded top)
                    if s.idle_seconds > 0 {
                        let ih = s.idle_seconds as f32 / max_val * chart_h;
                        let idle_rect = Rect::from_min_size(Pos2::new(x + 1.0, bottom - total_h), Vec2::new(bar_w - 2.0, ih));
                        painter.rect_filled(idle_rect, Rounding::same(4), m3::OUTLINE.gamma_multiply(0.45));
                    }
                    // Value label above bar
                    let mins = (s.active_seconds + s.idle_seconds) / 60;
                    painter.text(Pos2::new(x + bar_w / 2.0, bottom - total_h - 11.0),
                        egui::Align2::CENTER_BOTTOM, format!("{}m", mins), egui::FontId::proportional(9.0), m3::ON_SURFACE.gamma_multiply(0.7));
                    // Name label
                    painter.text(Pos2::new(x + bar_w / 2.0, resp.rect.bottom() - 8.0),
                        egui::Align2::CENTER_TOP, trunc(&s.app_name, 6), egui::FontId::proportional(9.0), m3::ON_SURFACE);
                }
            });

            ui.add_space(10.0);

            // Pie chart (45%)
            let pw = (avail_w * 0.42).min(300.0);
            ui.vertical(|ui| {
                ui.set_width(pw);
                ui.label(l.dist());
                let size = 130.0;
                let (resp, painter) = ui.allocate_painter(Vec2::new(size, size), egui::Sense::hover());
                let cx = resp.rect.center().x;
                let cy = resp.rect.center().y;
                let r = size / 2.0 - 3.0;
                let total = top8.iter().map(|s| s.active_seconds).sum::<i64>().max(1) as f32;
                let mut angle = -TAU / 4.0;

                for s in &top8 {
                    let sweep = (s.active_seconds as f32 / total) * TAU;
                    let color = clr(&s.app_name);
                    let steps = (sweep / 0.04).max(12.0) as usize;
                    let mut pts = Vec::with_capacity(steps + 2);
                    pts.push(Pos2::new(cx, cy));
                    for k in 0..=steps {
                        let a = angle + k as f32 * sweep / steps as f32;
                        pts.push(Pos2::new(cx + r * a.cos(), cy + r * a.sin()));
                    }
                    painter.add(Shape::convex_polygon(pts, color, Stroke::NONE));
                    angle += sweep;
                }
                // Ring separator + percentage labels
                let mut a = -TAU / 4.0;
                for s in &top8 {
                    let sweep = (s.active_seconds as f32 / total) * TAU;
                    let mid = a + sweep / 2.0;
                    let pct = (s.active_seconds as f32 / total * 100.0).round() as i32;
                    if pct >= 5 {
                        let lx = cx + (r * 0.62) * mid.cos();
                        let ly = cy + (r * 0.62) * mid.sin();
                        painter.text(Pos2::new(lx, ly), egui::Align2::CENTER_CENTER, format!("{}%", pct),
                            egui::FontId::proportional(9.0), Color32::WHITE);
                    }
                    a += sweep;
                }
            });
        });

        ui.add_space(10.0);

        // ── App list + detail ──
        let sel_idx = self.selected;
        ui.horizontal(|ui| {
            egui::ScrollArea::vertical().max_height(200.0).auto_shrink([false; 2]).id_salt("list").show(ui, |ui| {
                for (i, s) in split.iter().enumerate() {
                    let is_sel = sel_idx == Some(i);
                    let ah = s.active_seconds / 3600; let am = (s.active_seconds % 3600) / 60;
                    let bar = if is_sel { "  > " } else { "    " };
                    let r = ui.selectable_label(is_sel, format!("{}{:<20} {:>3}h {:>2}m", bar, trunc(&s.app_name, 20), ah, am));
                    if r.clicked() { self.selected = if is_sel { None } else { Some(i) }; }
                    ui.add(egui::ProgressBar::new((s.active_seconds + s.idle_seconds) as f32 / max_val)
                        .fill(clr(&s.app_name)).desired_height(4.0));
                }
            });

            if let Some(idx) = sel_idx {
                if let Some(s) = split.get(idx) {
                    ui.add_space(8.0);
                    ui.label("-->");
                    ui.vertical(|ui| {
                        ui.label(format!("{} {}", s.app_name, l.pages())); ui.separator();
                        let titles = DataStore::get_window_titles(&*self.db, &s.app_name, today);
                        if titles.is_empty() { ui.label(l.empty()); }
                        else {
                            let tot: i64 = titles.iter().map(|(_,d)| d).sum();
                            for (t, d) in &titles {
                                let label = if t.is_empty() { "(main)" } else { t.as_str() };
                                let pct = if tot > 0 { (*d as f32 / tot as f32 * 100.0) as i64 } else { 0 };
                                ui.horizontal(|ui| {
                                    ui.label(trunc(label, 32));
                                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                                        ui.label(format!("{}m {}%", d / 60, pct));
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

        ui.heading(format!("{}  |  {} {}, {} {}, {} {}",
            l.startup(), self.startup.len(), l.entries(), on, l.enabled(), self.startup.len() - on, l.disabled()));
        ui.horizontal(|ui| {
            for (label, f) in [(l.all(), StartFilter::All), (l.enabled(), StartFilter::Enabled), (l.disabled(), StartFilter::Disabled)] {
                if ui.selectable_label(self.start_filter == f, label).clicked() { self.start_filter = f; }
            }
        });
        ui.separator();

        let mut toggle: Option<(usize, bool)> = None;
        egui::ScrollArea::vertical().show(ui, |ui| {
            egui::Grid::new("startup_grid").striped(true).min_col_width(90.0).show(ui, |ui| {
                ui.label(""); ui.strong("App"); ui.strong("Status"); ui.strong("Source"); ui.strong("");
                ui.end_row();
                for (orig_i, e) in &filtered {
                    let is_sys = e.source == "HKLM" || e.command.to_lowercase().contains("\\system32\\") || e.command.to_lowercase().contains("\\windows\\");
                    let name = extract_exe_name(&e.command).unwrap_or_else(|| e.name.clone());
                    // Letter avatar (Material style)
                    let first = name.chars().next().unwrap_or('?').to_uppercase().to_string();
                    let bg = if is_sys { m3::WARNING } else { m3::INFO };
                    let (resp, painter) = ui.allocate_painter(Vec2::new(24.0, 24.0), egui::Sense::hover());
                    painter.circle_filled(resp.rect.center(), 12.0, bg);
                    painter.text(resp.rect.center(), egui::Align2::CENTER_CENTER, first, egui::FontId::proportional(11.0), Color32::WHITE);

                    ui.label(trunc(&name, 22));
                    if e.enabled { ui.colored_label(m3::SUCCESS, "ON"); }
                    else { ui.colored_label(m3::OUTLINE, "OFF"); }
                    ui.colored_label(if is_sys { m3::WARNING } else { m3::INFO }, &e.source);
                    if ui.small_button(if e.enabled { l.disable() } else { l.enable() }).clicked() {
                        toggle = Some((*orig_i, !e.enabled));
                    }
                    ui.end_row();
                }
            });
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

fn clr(name: &str) -> Color32 {
    let idx = (seahash::hash(name.as_bytes()) % 8) as usize;
    let colors = [
        Color32::from_rgb(103, 80, 164), Color32::from_rgb(25, 118, 210),
        Color32::from_rgb(56, 142, 60), Color32::from_rgb(237, 108, 2),
        Color32::from_rgb(0, 150, 136), Color32::from_rgb(211, 47, 47),
        Color32::from_rgb(156, 39, 176), Color32::from_rgb(121, 85, 72),
    ];
    colors[idx]
}

fn trunc(s: &str, max: usize) -> String {
    if s.chars().count() <= max { s.to_string() } else { format!("{}…", &s.chars().take(max - 1).collect::<String>()) }
}

fn extract_exe_name(cmd: &str) -> Option<String> {
    let cleaned = cmd.trim_matches('"').trim();
    if let Some(idx) = cleaned.to_lowercase().rfind(".exe") {
        let before = &cleaned[..idx + 4];
        if let Some(last_slash) = before.rfind('\\') { return Some(before[last_slash + 1..].to_string()); }
        return Some(before.to_string());
    }
    None
}
