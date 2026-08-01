//! TimeTrace TUI — left sidebar + right content layout.
//!
//! ┌──────────┬─────────────────────────────────────┐
//! │ Dashboard │  Today     5h 23m active            │
//! │          │  Since 2026-08-01 · Total 12h 45m   │
//! │ Processes │                                     │
//! │          │  ████████████░░░░░░░░░░  VS Code    │
//! │ Startup  │  ██████░░░░░░░░░░░░░░░░  Chrome    │
//! │          │  ████░░░░░░░░░░░░░░░░░░  Terminal  │
//! │          │                                     │
//! │          │  Chrome — bilibili.com    45m     │
//! │          │    Chrome — github.com      32m     │
//! │          │    Chrome — (other)         13m     │
//! ├──────────┴─────────────────────────────────────┤
//! │  ↑↓:nav  ←→:detail  q:quit                     │
//! └────────────────────────────────────────────────┘

use std::sync::Arc;

use chrono::{Local, NaiveDate, Timelike, Utc};
use crossterm::event::{self, Event, KeyCode, KeyEventKind};
use ratatui::{
    layout::{Alignment, Constraint, Direction, Layout, Rect},
    style::{Modifier, Style, Stylize},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, Paragraph, Tabs},
    Frame,
};

use timetrace_core::{
    AppUsageSummary, DataStore, ProcessInfo, ProcessQuery,
    StartupEntryRecord, StartupScanner, SessionRecord,
};

use super::theme::{current_palette, Palette};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Panel { Dashboard, Processes, Startup }

enum Detail { None, AppDetail { app_path: String, app_name: String } }
enum Dialog { None, ConfirmKill { pid: u32, name: String }, Info(String) }

enum ProcessFilter { All, User, System }

pub struct App {
    db: Arc<dyn DataStore>,
    process_query: Box<dyn ProcessQuery>,
    panel: Panel,
    palette: Palette,
    detail: Detail,
    dialog: Dialog,
    should_quit: bool,
    proc_filter: String,
    proc_show: ProcessFilter,
    startup_entries: Vec<StartupEntryRecord>,
    startup_scanned: bool,
    row: usize,
}

impl App {
    pub fn new(db: Arc<dyn DataStore>, process_query: Box<dyn ProcessQuery>) -> Self {
        let entries = db.get_all_startup_entries();
        let scanned = !entries.is_empty();
        Self {
            db, process_query, panel: Panel::Dashboard, palette: current_palette(),
            detail: Detail::None, dialog: Dialog::None, should_quit: false,
            proc_filter: String::new(), proc_show: ProcessFilter::All,
            startup_entries: entries, startup_scanned: scanned,
            row: 0,
        }
    }

    pub fn should_quit(&self) -> bool { self.should_quit }

    pub fn needs_startup_scan(&self) -> bool { !self.startup_scanned }

    pub fn do_startup_scan(&mut self) {
        let scanner = timetrace_core::engine::WindowsStartupScanner::new();
        let entries = scanner.scan();
        self.db.upsert_startup_entries(&entries);
        self.startup_entries = self.db.get_all_startup_entries();
        self.startup_scanned = true;
    }

    pub fn handle_event(&mut self, event: Event) {
        if let Event::Key(key) = event {
            if key.kind != KeyEventKind::Press { return; }
            match key.code {
                KeyCode::Char('q') => self.should_quit = true,
                KeyCode::Char('1') => { self.panel = Panel::Dashboard; self.detail = Detail::None; self.row = 0; }
                KeyCode::Char('2') => { self.panel = Panel::Processes; self.detail = Detail::None; self.row = 0; }
                KeyCode::Char('3') => { self.panel = Panel::Startup; self.detail = Detail::None; self.row = 0; }
                KeyCode::Esc => {
                    if !matches!(self.dialog, Dialog::None) { self.dialog = Dialog::None; }
                    else { self.detail = Detail::None; }
                }
                KeyCode::Up => self.row = self.row.saturating_sub(1),
                KeyCode::Down => self.row += 1,
                KeyCode::Enter => self.handle_enter(),
                KeyCode::Right | KeyCode::Char('l') => self.handle_expand(),
                KeyCode::Left | KeyCode::Char('h') => { self.detail = Detail::None; }
                KeyCode::Char(' ') => self.handle_toggle(),
                KeyCode::Char('r') => self.do_startup_scan(),
                KeyCode::Char('f') => {
                    self.proc_show = match self.proc_show {
                        ProcessFilter::All => ProcessFilter::User,
                        ProcessFilter::User => ProcessFilter::System,
                        ProcessFilter::System => ProcessFilter::All,
                    };
                    self.row = 0;
                }
                KeyCode::Char('k') => self.handle_kill(),
                KeyCode::Char(c) => { if self.panel == Panel::Processes { self.proc_filter.push(c); } }
                KeyCode::Backspace => { self.proc_filter.pop(); }
                _ => {}
            }
        }
    }

    fn handle_enter(&mut self) {
        if let Dialog::ConfirmKill { pid, .. } = &self.dialog {
            let id = *pid;
            let _ = self.process_query.terminate_process(id);
            self.dialog = Dialog::None;
        }
    }

    fn handle_expand(&mut self) {
        if self.panel == Panel::Dashboard {
            let today = Local::now().date_naive();
            let apps = self.db.get_top_apps(today, today, 20);
            if let Some(app) = apps.get(self.row) {
                self.detail = Detail::AppDetail {
                    app_path: app.app_name.clone(), // app_name IS exe_path in our model
                    app_name: app.app_name.clone(),
                };
            }
        }
    }

    fn handle_toggle(&mut self) {
        if self.panel == Panel::Startup {
            let entries: Vec<_> = self.startup_entries.iter().collect();
            if let Some(e) = entries.get(self.row).cloned().cloned() {
                if e.enabled { self.disable(e); } else { self.enable(e); }
            }
        }
    }

    fn handle_kill(&mut self) {
        if self.panel == Panel::Processes {
            self.process_query.refresh();
            let procs = self.filtered_procs();
            if let Some(p) = procs.get(self.row) {
                self.dialog = Dialog::ConfirmKill { pid: p.pid, name: p.name.clone() };
            }
        }
    }

    fn disable(&mut self, entry: StartupEntryRecord) {
        let scanner = timetrace_core::engine::WindowsStartupScanner::new();
        if let Ok(r) = scanner.disable(&entry) {
            self.db.set_startup_enabled(entry.id, false, r.backup_value.as_deref(), r.backup_path.as_deref());
            self.startup_entries = self.db.get_all_startup_entries();
        }
    }

    fn enable(&mut self, entry: StartupEntryRecord) {
        let scanner = timetrace_core::engine::WindowsStartupScanner::new();
        if scanner.enable(&entry).is_ok() {
            self.db.set_startup_enabled(entry.id, true, None, None);
            self.startup_entries = self.db.get_all_startup_entries();
        }
    }

    fn filtered_procs(&self) -> Vec<ProcessInfo> {
        let mut procs = self.process_query.list_processes();
        let f = self.proc_filter.to_lowercase();
        if !f.is_empty() { procs.retain(|p| p.name.to_lowercase().contains(&f) || p.pid.to_string().contains(&f)); }
        match self.proc_show {
            ProcessFilter::User => procs.retain(|p| !is_system_process(&p.name)),
            ProcessFilter::System => procs.retain(|p| is_system_process(&p.name)),
            _ => {}
        }
        procs.sort_by(|a, b| b.cpu_percent.partial_cmp(&a.cpu_percent).unwrap());
        procs
    }

    // ── Render ──

    pub fn render(&mut self, frame: &mut Frame) {
        let p = self.palette.clone();
        let area = frame.area();

        let chunks = Layout::default().direction(Direction::Horizontal)
            .constraints([Constraint::Length(18), Constraint::Min(0)])
            .split(area);

        // Left sidebar
        self.render_sidebar(frame, chunks[0], &p);

        // Right content
        let right = Layout::default().direction(Direction::Vertical)
            .constraints([Constraint::Min(0), Constraint::Length(1)])
            .split(chunks[1]);

        match self.panel {
            Panel::Dashboard => self.render_dashboard(frame, right[0], &p),
            Panel::Processes => self.render_processes(frame, right[0], &p),
            Panel::Startup => self.render_startup(frame, right[0], &p),
        }

        // Status bar
        let help = match self.panel {
            Panel::Dashboard => "↑↓ nav  → detail  Esc back  q quit",
            Panel::Processes => "type filter  f:sys/usr  ↑↓ nav  k kill  q quit",
            Panel::Startup => "↑↓ nav  Space toggle  r rescan  q quit",
        };
        frame.render_widget(
            Paragraph::new(help).style(Style::default().fg(p.text_dim).bg(p.bg_secondary)).alignment(Alignment::Center),
            right[1],
        );

        if !matches!(self.dialog, Dialog::None) { self.render_dialog(frame, &p); }
    }

    fn render_sidebar(&self, frame: &mut Frame, area: Rect, p: &Palette) {
        let items = vec![
            ("  Dashboard ",  self.panel == Panel::Dashboard),
            ("  Processes ",  self.panel == Panel::Processes),
            ("  Startup   ",  self.panel == Panel::Startup),
        ];

        let list: Vec<ListItem> = items.iter().enumerate().map(|(i, (label, active))| {
            let style = if *active {
                Style::default().fg(p.accent).bg(p.bg_selected).add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(p.text_dim)
            };
            ListItem::new(Line::from(Span::styled(*label, style)))
        }).collect();

        let sidebar = List::new(list)
            .block(Block::default().borders(Borders::RIGHT).border_style(Style::default().fg(p.border))
                .style(Style::default().bg(p.bg_secondary)))
            .highlight_style(Style::default().fg(p.accent).bg(p.bg_selected));

        frame.render_widget(sidebar, area);
    }

    // ── Dashboard ──

    fn render_dashboard(&self, frame: &mut Frame, area: Rect, p: &Palette) {
        let today = Local::now().date_naive();
        let apps = self.db.get_top_apps(today, today, 20);
        let total_all = self.db.total_tracked_seconds();
        let started = self.db.recording_started_at();

        let today_s: i64 = apps.iter().map(|a| a.total_seconds).sum();
        let max_s = apps.first().map(|a| a.total_seconds).unwrap_or(1).max(1) as f32;

        let chunks = Layout::default().direction(Direction::Vertical)
            .constraints([
                Constraint::Length(2),  // header
                Constraint::Length(1),  // chart
                Constraint::Min(0),     // list
            ])
            .split(area);

        // Header
        let mut hdr = vec![Line::from(Span::styled(
            format!("Today  {}h {}m active", today_s / 3600, (today_s % 3600) / 60),
            Style::default().fg(p.text).add_modifier(Modifier::BOLD),
        ))];
        if let Some(s) = started {
            let days = (Utc::now() - s).num_days();
            let ah = total_all / 3600; let am = (total_all % 3600) / 60;
            hdr.push(Line::from(Span::styled(
                format!("Since {} ({}d)  ·  Total {}h {}m", s.format("%Y-%m-%d"), days, ah, am),
                Style::default().fg(p.text_dim),
            )));
        }
        frame.render_widget(Paragraph::new(hdr), chunks[0]);

        // Bar chart (simple horizontal bars)
        let mut chart = String::new();
        let w = (chunks[1].width as usize).saturating_sub(5);
        for (i, app) in apps.iter().take(8).enumerate() {
            let frac = app.total_seconds as f32 / max_s;
            let bar_w = (frac * w as f32) as usize;
            let bar = "█".repeat(bar_w.min(w));
            let h = app.total_seconds / 3600; let m = (app.total_seconds % 3600) / 60;
            chart.push_str(&format!("{} ", if h > 0 { format!("{}h{}m", h, m) } else { format!("{}m", m) }));
        }
        frame.render_widget(Paragraph::new(chart).style(Style::default().fg(p.accent)), chunks[1]);

        // App list + detail
        if let Detail::AppDetail { app_name, .. } = &self.detail {
            // Split: top half = app detail, bottom half = window titles
            let detail_chunks = Layout::default().direction(Direction::Vertical)
                .constraints([Constraint::Percentage(40), Constraint::Percentage(60)])
                .split(chunks[2]);

            let app_list: Vec<ListItem> = apps.iter().enumerate().map(|(i, a)| {
                let sel = i == self.row;
                self.render_app_row(a, sel, p)
            }).collect();
            frame.render_widget(List::new(app_list), detail_chunks[0]);

            // Window title breakdown
            let titles = self.db.get_window_titles(&app_name, today);
            let title_items: Vec<ListItem> = if titles.is_empty() {
                vec![ListItem::new(Span::styled("  (no page-level data yet)", Style::default().fg(p.text_dim)))]
            } else {
                let total: i64 = titles.iter().map(|(_, d)| d).sum();
                titles.iter().map(|(t, d)| {
                    let m = d / 60; let s = d % 60;
                    let pct = if total > 0 { (*d as f32 / total as f32 * 100.0) as i64 } else { 0 };
                    ListItem::new(Line::from(vec![
                        Span::styled(format!("  {}  ", if t.is_empty() { "(main window)" } else { t }), Style::default().fg(p.text)),
                        Span::styled(format!("{}m{}s  {}%", m, s, pct), Style::default().fg(p.text_dim)),
                    ]))
                }).collect()
            };
            let title_block = Block::default().borders(Borders::TOP).border_style(Style::default().fg(p.border))
                .title(Span::styled(format!(" > {} — pages ", app_name), Style::default().fg(p.accent)));
            frame.render_widget(List::new(title_items).block(title_block), detail_chunks[1]);

        } else {
            let items: Vec<ListItem> = apps.iter().enumerate().map(|(i, a)| {
                let sel = i == self.row;
                self.render_app_row(a, sel, p)
            }).collect();
            if items.is_empty() {
                frame.render_widget(
                    Paragraph::new("No data yet — tracking is active.\nSwitch between apps to start recording.")
                        .style(Style::default().fg(p.text_dim)).alignment(Alignment::Center),
                    chunks[2],
                );
            } else {
                frame.render_widget(List::new(items), chunks[2]);
            }
        }
    }

    fn render_app_row(&self, app: &AppUsageSummary, selected: bool, p: &Palette) -> ListItem {
        let h = app.total_seconds / 3600; let m = (app.total_seconds % 3600) / 60;
        let time = if h > 0 { format!("{}h{}m", h, m) } else { format!("{}m", m) };
        let color = p.app_colors.color_for(&app.app_name);
        let bg = if selected { p.bg_selected } else { p.bg };
        let prefix = if selected { ">" } else { " " };
        let bar_w = ((app.total_seconds as f32 / 3600.0).min(8.0) * 8.0) as usize;
        let bar = "█".repeat(bar_w.min(60));
        ListItem::new(Line::from(vec![
            Span::styled(format!("{} ", prefix), Style::default().fg(p.accent)),
            Span::styled(format!("{:<25}", truncate(&app.app_name, 25)), Style::default().fg(color)),
            Span::styled(format!("{:>8}  {}", time, bar), Style::default().fg(color)),
        ])).style(Style::default().bg(bg))
    }

    // ── Processes ──

    fn render_processes(&mut self, frame: &mut Frame, area: Rect, p: &Palette) {
        self.process_query.refresh();
        let procs = self.filtered_procs();

        let chunks = Layout::default().direction(Direction::Vertical)
            .constraints([Constraint::Length(1), Constraint::Min(0)])
            .split(area);

        let filter_label = match self.proc_show {
            ProcessFilter::All => "All", ProcessFilter::User => "User", ProcessFilter::System => "System",
        };
        frame.render_widget(
            Paragraph::new(format!("Filter: {}_  [{}]  {} procs  f:filter", self.proc_filter, filter_label, procs.len()))
                .style(Style::default().fg(p.accent)),
            chunks[0],
        );

        let items: Vec<ListItem> = procs.iter().enumerate().map(|(i, proc)| {
            let sel = i == self.row;
            let bg = if sel { p.bg_selected } else { p.bg };
            let color = if proc.cpu_percent > 50.0 { p.danger } else if proc.cpu_percent > 10.0 { p.warning } else { p.text };
            let sys = if is_system_process(&proc.name) { "[S]" } else { "[U]" };
            let mem = if proc.memory_mb > 1024.0 { format!("{:.1}G", proc.memory_mb / 1024.0) } else { format!("{:.0}M", proc.memory_mb) };
            ListItem::new(Line::from(vec![
                Span::styled(format!("{} ", if sel { ">" } else { " " }), Style::default().fg(p.accent)),
                Span::styled(format!("{:<30}", truncate(&proc.name, 30)), Style::default().fg(color)),
                Span::styled(format!("{:>5.1}% ", proc.cpu_percent), Style::default().fg(color)),
                Span::styled(format!("{:>6} ", mem), Style::default().fg(p.text_dim)),
                Span::styled(format!("PID:{} ", proc.pid), Style::default().fg(p.text_dim)),
                Span::styled(sys, Style::default().fg(if proc.name.contains("svchost") || proc.name.contains("winlogon") { p.warning } else { p.text_dim })),
            ])).style(Style::default().bg(bg))
        }).collect();
        frame.render_widget(List::new(items), chunks[1]);
    }

    // ── Startup ──

    fn render_startup(&self, frame: &mut Frame, area: Rect, p: &Palette) {
        let entries: Vec<&StartupEntryRecord> = self.startup_entries.iter().collect();
        let enabled = entries.iter().filter(|e| e.enabled).count();

        let chunks = Layout::default().direction(Direction::Vertical)
            .constraints([Constraint::Length(2), Constraint::Min(0)])
            .split(area);

        frame.render_widget(
            Paragraph::new(vec![
                Line::from(Span::styled(
                    format!("{} entries  ·  {} enabled  ·  {} disabled  r:rescan  Space:toggle", entries.len(), enabled, entries.len() - enabled),
                    Style::default().fg(p.accent),
                )),
                Line::from(Span::styled(
                    if self.startup_scanned { "  Last scan: on launch" } else { "  Not yet scanned" },
                    Style::default().fg(p.text_dim),
                )),
            ]),
            chunks[0],
        );

        let items: Vec<ListItem> = entries.iter().enumerate().map(|(i, e)| {
            let sel = i == self.row;
            let bg = if sel { p.bg_selected } else { p.bg };
            let status = if e.enabled {
                Span::styled("ON  ", Style::default().fg(p.success))
            } else {
                Span::styled("OFF ", Style::default().fg(p.text_dim))
            };
            let src_color = match e.source.as_str() {
                "HKLM" => p.warning, "HKCU" => p.accent, "StartupFolder" => p.success, _ => p.text_dim,
            };
            // Check if this process is currently running
            let running = is_process_running(&e.name);
            let run_mark = if running { Span::styled(" *running*", Style::default().fg(p.success)) } else { Span::styled("", Style::default()) };

            ListItem::new(Line::from(vec![
                Span::styled(format!("{} ", if sel { ">" } else { " " }), Style::default().fg(p.accent)),
                Span::styled(format!("{:<28}", truncate(&e.name, 28)), Style::default().fg(p.text)),
                status,
                Span::styled(format!("[{}]", e.source), Style::default().fg(src_color)),
                run_mark,
                Span::styled(truncate(&e.command, 30), Style::default().fg(p.text_dim)),
            ])).style(Style::default().bg(bg))
        }).collect();

        frame.render_widget(List::new(items), chunks[1]);
    }

    fn render_dialog(&self, frame: &mut Frame, p: &Palette) {
        let area = ratatui::layout::Rect {
            x: frame.area().width / 4,
            y: frame.area().height / 3,
            width: frame.area().width / 2,
            height: 8,
        };
        match &self.dialog {
            Dialog::ConfirmKill { name, pid } => {
                frame.render_widget(
                    Paragraph::new(format!("End Process?\n\n{}\nPID: {}\n\nEnter: confirm  Esc: cancel", name, pid))
                        .block(Block::default().borders(Borders::ALL).border_style(Style::default().fg(p.danger)).style(Style::default().bg(p.bg_secondary)))
                        .alignment(Alignment::Center),
                    area,
                );
            }
            Dialog::Info(msg) => {
                frame.render_widget(
                    Paragraph::new(msg.as_str()).block(Block::default().borders(Borders::ALL).style(Style::default().bg(p.bg_secondary))).alignment(Alignment::Center),
                    area,
                );
            }
            Dialog::None => {}
        }
    }
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max { s.to_string() } else { format!("{}…", &s.chars().take(max - 1).collect::<String>()) }
}

fn is_system_process(name: &str) -> bool {
    let sys: &[&str] = &["svchost", "winlogon", "csrss", "smss", "wininit", "services", "lsass", "dwm", "System", "Idle", "Registry", "spoolsv", "fontdrvhost", "WmiPrvSE", "SearchIndexer", "SecurityHealth"];
    sys.iter().any(|s| name.to_lowercase().contains(&s.to_lowercase()))
}

fn is_process_running(name: &str) -> bool {
    use sysinfo::System;
    let sys = System::new_all();
    sys.processes_by_name(&name.replace(".exe", "").as_ref()).count() > 0
}
