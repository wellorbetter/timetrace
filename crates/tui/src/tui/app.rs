use std::sync::Arc;
use chrono::{Local, NaiveDate, Timelike, Utc};
use crossterm::event::{self, Event, KeyCode, KeyEventKind};
use ratatui::{
    layout::{Alignment, Constraint, Direction, Layout, Rect},
    style::{Modifier, Style, Stylize},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, Paragraph},
    Frame,
};
use timetrace_core::{AppUsageSummary, DataStore, SessionRecord, StartupEntryRecord, StartupScanner};
use super::theme::{current_palette, Palette};

#[derive(Clone, Copy, PartialEq, Eq)] enum Panel { Dashboard, Startup }
enum Detail { None, AppDetail { app_path: String, app_name: String } }
enum Dialog { None, Info(String) }

pub struct App {
    db: Arc<dyn DataStore>,
    panel: Panel, palette: Palette, detail: Detail, dialog: Dialog,
    should_quit: bool, startup_entries: Vec<StartupEntryRecord>, scanned: bool, row: usize,
}

impl App {
    pub fn new(db: Arc<dyn DataStore>) -> Self {
        let entries = db.get_all_startup_entries();
        let scanned = !entries.is_empty();
        Self { db, panel: Panel::Dashboard, palette: current_palette(),
            detail: Detail::None, dialog: Dialog::None, should_quit: false,
            startup_entries: entries, scanned, row: 0 }
    }

    pub fn should_quit(&self) -> bool { self.should_quit }
    pub fn needs_startup_scan(&self) -> bool { !self.scanned }

    pub fn do_startup_scan(&mut self) {
        let scanner = timetrace_core::engine::WindowsStartupScanner::new();
        self.db.upsert_startup_entries(&scanner.scan());
        self.startup_entries = self.db.get_all_startup_entries();
        self.scanned = true;
    }

    pub fn handle_event(&mut self, event: Event) {
        if let Event::Key(key) = event {
            if key.kind != KeyEventKind::Press { return; }
            match key.code {
                KeyCode::Char('q') => self.should_quit = true,
                KeyCode::Char('1') | KeyCode::Char('d') => { self.panel = Panel::Dashboard; self.detail = Detail::None; self.row = 0; }
                KeyCode::Char('2') | KeyCode::Char('s') => { self.panel = Panel::Startup; self.detail = Detail::None; self.row = 0; }
                KeyCode::Esc => { if !matches!(self.dialog, Dialog::None) { self.dialog = Dialog::None; } else { self.detail = Detail::None; } }
                KeyCode::Up => self.row = self.row.saturating_sub(1),
                KeyCode::Down => self.row += 1,
                KeyCode::Right | KeyCode::Char('l') => {
                    if self.panel == Panel::Dashboard {
                        let today = Local::now().date_naive();
                        if let Some(app) = self.db.get_top_apps(today, today, 20).get(self.row) {
                            self.detail = Detail::AppDetail { app_path: app.app_name.clone(), app_name: app.app_name.clone() };
                        }
                    }
                }
                KeyCode::Left | KeyCode::Char('h') => { self.detail = Detail::None; }
                KeyCode::Char(' ') => { if self.panel == Panel::Startup { self.toggle_startup(); } }
                KeyCode::Char('r') => self.do_startup_scan(),
                _ => {}
            }
        }
    }

    fn toggle_startup(&mut self) {
        let e = self.startup_entries.get(self.row).cloned();
        if let Some(entry) = e {
            let scanner = timetrace_core::engine::WindowsStartupScanner::new();
            if entry.enabled {
                if let Ok(r) = scanner.disable(&entry) {
                    self.db.set_startup_enabled(entry.id, false, r.backup_value.as_deref(), r.backup_path.as_deref());
                }
            } else if scanner.enable(&entry).is_ok() {
                self.db.set_startup_enabled(entry.id, true, None, None);
            }
            self.startup_entries = self.db.get_all_startup_entries();
        }
    }

    // ── Render ──

    pub fn render(&mut self, frame: &mut Frame) {
        let p = self.palette.clone();
        let area = frame.area();
        let chunks = Layout::default().direction(Direction::Horizontal)
            .constraints([Constraint::Length(18), Constraint::Min(0)]).split(area);

        // Sidebar
        let sidebar_items: Vec<ListItem> = [("Dashboard", Panel::Dashboard), ("Startup", Panel::Startup)]
            .iter().map(|(label, panel)| {
                let active = self.panel == *panel;
                ListItem::new(Line::from(Span::styled(format!("  {}", label),
                    if active { Style::default().fg(p.accent).bg(p.bg_selected).add_modifier(Modifier::BOLD) }
                    else { Style::default().fg(p.text_dim) })))
            }).collect();
        frame.render_widget(
            List::new(sidebar_items).block(Block::default().borders(Borders::RIGHT)
                .border_style(Style::default().fg(p.border)).style(Style::default().bg(p.bg_secondary))),
            chunks[0],
        );

        // Content
        let right = Layout::default().direction(Direction::Vertical)
            .constraints([Constraint::Min(0), Constraint::Length(1)]).split(chunks[1]);
        match self.panel {
            Panel::Dashboard => self.render_dashboard(frame, right[0], &p),
            Panel::Startup => self.render_startup(frame, right[0], &p),
        }

        let help = match self.panel {
            Panel::Dashboard => "↑↓ nav  → detail  Esc back  1/2 switch  q quit",
            Panel::Startup => "↑↓ nav  Space toggle  r rescan  1/2 switch  q quit",
        };
        frame.render_widget(Paragraph::new(help).style(Style::default().fg(p.text_dim).bg(p.bg_secondary)).alignment(Alignment::Center), right[1]);
        if !matches!(self.dialog, Dialog::None) { self.render_dialog(frame, &p); }
    }

    fn render_dashboard(&self, frame: &mut Frame, area: Rect, p: &Palette) {
        let today = Local::now().date_naive();
        let apps = self.db.get_top_apps(today, today, 20);
        let total_all = self.db.total_tracked_seconds();
        let started = self.db.recording_started_at();
        let today_s: i64 = apps.iter().map(|a| a.total_seconds).sum();

        let chunks = Layout::default().direction(Direction::Vertical)
            .constraints([Constraint::Length(2), Constraint::Length(8), Constraint::Min(0)]).split(area);

        // ── Header ──
        let mut hdr = vec![Line::from(Span::styled(
            format!("Today  {}h {}m active", today_s / 3600, (today_s % 3600) / 60),
            Style::default().fg(p.text).add_modifier(Modifier::BOLD)))];
        if let Some(s) = started {
            let days = (Utc::now() - s).num_days();
            hdr.push(Line::from(Span::styled(
                format!("Since {} ({}d)  Total {}h {}m", s.format("%Y-%m-%d"), days, total_all / 3600, (total_all % 3600) / 60),
                Style::default().fg(p.text_dim))));
        }
        frame.render_widget(Paragraph::new(hdr), chunks[0]);

        if apps.is_empty() {
            frame.render_widget(Paragraph::new("Waiting for data — tracking is active. Switch between apps.")
                .style(Style::default().fg(p.text_dim)).alignment(Alignment::Center), chunks[1]);
            return;
        }

        // ── Vertical bar chart ──
        let max_s = apps[0].total_seconds.max(1) as f32;
        let chart_h = (chunks[1].height as usize).saturating_sub(2);
        let bar_count = apps.len().min(8);
        let bar_w = (chunks[1].width as usize).saturating_sub(2) / bar_count.max(1);
        let mut chart_lines = vec![String::new(); chart_h];

        for (i, app) in apps.iter().take(8).enumerate() {
            let frac = app.total_seconds as f32 / max_s;
            let h = (frac * chart_h as f32) as usize;
            let color = p.app_colors.color_for(&app.app_name);
            // Build vertical bar from top
            for row in 0..chart_h {
                let filled = row >= chart_h.saturating_sub(h);
                let ch = if filled { "█" } else { " " };
                let pad = " ".repeat(bar_w.saturating_sub(1));
                chart_lines[row].push_str(&format!("{}{}", ch, pad));
            }
        }
        // Labels
        let mut label_line = String::new();
        for app in apps.iter().take(8) {
            label_line.push_str(&format!("{:width$}", trunc(&app.app_name, bar_w.saturating_sub(1)), width = bar_w));
        }
        chart_lines.push(label_line);

        let chart_text: Vec<Line<'static>> = chart_lines.into_iter().map(|s| Line::from(s.to_string())).collect();
        frame.render_widget(Paragraph::new(chart_text).style(Style::default().fg(p.accent)), chunks[1]);

        // ── App list + page detail (side by side) ──
        let detail_area = chunks[2];
        if let Detail::AppDetail { app_name, .. } = &self.detail {
            let dc = Layout::default().direction(Direction::Horizontal)
                .constraints([Constraint::Percentage(50), Constraint::Percentage(50)]).split(detail_area);

            let items: Vec<ListItem> = apps.iter().enumerate().map(|(i,a)| app_row(a, i == self.row, max_s, p)).collect();
            frame.render_widget(List::new(items), dc[0]);

            let titles = self.db.get_window_titles(app_name, today);
            let t2: Vec<ListItem> = if titles.is_empty() {
                vec![ListItem::new(Span::styled("  no page data yet", Style::default().fg(p.text_dim)))]
            } else {
                let tot: i64 = titles.iter().map(|(_,d)| d).sum();
                titles.iter().map(|(t,d)| {
                    let pct = if tot > 0 { (*d as f32 / tot as f32 * 100.0) as i64 } else { 0 };
                    ListItem::new(Line::from(vec![
                        Span::styled(format!("  {}  ", if t.is_empty() { "(main)" } else { t }), Style::default().fg(p.text)),
                        Span::styled(format!("{}m{}s ({}%)", d/60, d%60, pct), Style::default().fg(p.text_dim)),
                    ]))
                }).collect()
            };
            frame.render_widget(List::new(t2).block(Block::default().borders(Borders::LEFT)
                .border_style(Style::default().fg(p.border))
                .title(Span::styled(format!(" {} pages ", app_name), Style::default().fg(p.accent)))), dc[1]);
        } else {
            let items: Vec<ListItem> = apps.iter().enumerate().map(|(i,a)| app_row(a, i == self.row, max_s, p)).collect();
            frame.render_widget(List::new(items), detail_area);
        }
    }

    fn render_startup(&self, frame: &mut Frame, area: Rect, p: &Palette) {
        let entries: Vec<_> = self.startup_entries.iter().collect();
        let on = entries.iter().filter(|e| e.enabled).count();

        let chunks = Layout::default().direction(Direction::Vertical)
            .constraints([Constraint::Length(2), Constraint::Min(0)]).split(area);

        frame.render_widget(Paragraph::new(vec![
            Line::from(Span::styled(format!("{} entries  {} enabled  {} disabled", entries.len(), on, entries.len() - on), Style::default().fg(p.accent))),
            Line::from(Span::styled("Space: toggle  r: rescan", Style::default().fg(p.text_dim))),
        ]), chunks[0]);

        let items: Vec<ListItem> = entries.iter().enumerate().map(|(i, e)| {
            let sel = i == self.row;
            let bg = if sel { p.bg_selected } else { p.bg };
            let st = if e.enabled { Span::styled("ON ", Style::default().fg(p.success)) } else { Span::styled("OFF", Style::default().fg(p.text_dim)) };
            let sc = match e.source.as_str() { "HKLM" => p.warning, "HKCU" => p.accent, "StartupFolder" => p.success, _ => p.text_dim };
            let running = is_running(&e.name);
            let rm = if running { Span::styled(" running", Style::default().fg(p.success)) } else { Span::styled("", Style::default()) };
            ListItem::new(Line::from(vec![
                Span::styled(format!("{} ", if sel { ">" } else { " " }), Style::default().fg(p.accent)),
                Span::styled(format!("{:<28}", trunc(&e.name, 28)), Style::default().fg(p.text)),
                st, Span::styled(format!("[{}]", e.source), Style::default().fg(sc)), rm,
                Span::styled(trunc(&e.command, 30), Style::default().fg(p.text_dim)),
            ])).style(Style::default().bg(bg))
        }).collect();
        frame.render_widget(List::new(items), chunks[1]);
    }

    fn render_dialog(&self, frame: &mut Frame, p: &Palette) {
        if let Dialog::Info(msg) = &self.dialog {
            let a = Rect { x: frame.area().width/4, y: frame.area().height/3, width: frame.area().width/2, height: 6 };
            frame.render_widget(Paragraph::new(msg.as_str()).block(Block::default().borders(Borders::ALL).style(Style::default().bg(p.bg_secondary))).alignment(Alignment::Center), a);
        }
    }
}

fn app_row<'a>(app: &AppUsageSummary, sel: bool, max_s: f32, p: &Palette) -> ListItem<'a> {
    let h = app.total_seconds / 3600; let m = (app.total_seconds % 3600) / 60;
    let time = if h > 0 { format!("{}h{}m", h, m) } else { format!("{}m", m) };
    let frac = app.total_seconds as f32 / max_s;
    let bar_w = (frac * 60.0) as usize;
    let bar = "█".repeat(bar_w.min(60));
    let color = p.app_colors.color_for(&app.app_name);
    ListItem::new(Line::from(vec![
        Span::styled(format!("{} ", if sel { ">" } else { " " }), Style::default().fg(p.accent)),
        Span::styled(format!("{:<28}", trunc(&app.app_name, 28)), Style::default().fg(color)),
        Span::styled(format!("{:>8} {}", time, bar), Style::default().fg(color)),
    ])).style(Style::default().bg(if sel { p.bg_selected } else { p.bg }))
}

fn trunc(s: &str, max: usize) -> String {
    if s.chars().count() <= max { s.to_string() } else { format!("{}…", &s.chars().take(max-1).collect::<String>()) }
}

fn is_running(name: &str) -> bool {
    let n = name.replace(".exe", "").to_lowercase();
    let s = sysinfo::System::new_all();
    s.processes().iter().any(|(_, p)| p.name().to_string_lossy().to_lowercase().contains(&n))
}
