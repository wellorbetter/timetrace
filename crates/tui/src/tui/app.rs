//! TimeTrace TUI — terminal dashboard.
//!
//! Three tabs: Dashboard (usage stats), Processes (task manager), Startup (boot entries).

use std::sync::Arc;

use chrono::{Local, NaiveDate, Timelike, Utc};
use crossterm::event::{self, Event, KeyCode, KeyEventKind};
use ratatui::{
    layout::{Alignment, Constraint, Direction, Layout, Rect},
    style::{Modifier, Style, Stylize},
    text::{Line, Span},
    widgets::{Block, BorderType, Borders, Cell, List, ListItem, Paragraph, Row, Tabs, Table},
    Frame,
};

use timetrace_core::{
    AppUsageSummary, DataStore, SessionRecord,
    ProcessInfo, ProcessQuery,
    StartupEntryRecord, StartupScanner,
};

use super::theme::{current_palette, Palette};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Tab {
    Dashboard,
    Processes,
    Startup,
}

impl Tab {
    fn all() -> &'static [Tab] { &[Tab::Dashboard, Tab::Processes, Tab::Startup] }
    fn title(&self) -> &'static str {
        match self { Tab::Dashboard => "📊 Dashboard", Tab::Processes => "⚡ Processes", Tab::Startup => "🚀 Startup" }
    }
}

enum Dialog { None, ConfirmKill { pid: u32, name: String }, Info(String) }

pub struct App {
    db: Arc<dyn DataStore>,
    process_query: Box<dyn ProcessQuery>,
    tab: Tab,
    palette: Palette,
    dialog: Dialog,
    should_quit: bool,
    process_filter: String,
    process_sort: ProcessSort,
    startup_entries: Vec<StartupEntryRecord>,
    startup_filter: StartupFilter,
    selected_row: usize,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ProcessSort { Cpu, Memory, Name, Pid }

#[derive(Clone, Copy, PartialEq, Eq)]
enum StartupFilter { All, Enabled, Disabled }

impl App {
    pub fn new(db: Arc<dyn DataStore>, process_query: Box<dyn ProcessQuery>) -> Self {
        let startup_entries = db.get_all_startup_entries();
        Self {
            db, process_query, tab: Tab::Dashboard, palette: current_palette(),
            dialog: Dialog::None, should_quit: false,
            process_filter: String::new(), process_sort: ProcessSort::Cpu,
            startup_entries, startup_filter: StartupFilter::All, selected_row: 0,
        }
    }

    pub fn should_quit(&self) -> bool { self.should_quit }

    pub fn handle_event(&mut self, event: Event) {
        if let Event::Key(key) = event {
            if key.kind != KeyEventKind::Press { return; }
            match key.code {
                KeyCode::Char('q') => self.should_quit = true,
                KeyCode::Char('1') => self.tab = Tab::Dashboard,
                KeyCode::Char('2') => self.tab = Tab::Processes,
                KeyCode::Char('3') => self.tab = Tab::Startup,
                KeyCode::Tab => self.next_tab(),
                KeyCode::Esc => self.dialog = Dialog::None,
                KeyCode::Up => self.selected_row = self.selected_row.saturating_sub(1),
                KeyCode::Down => self.selected_row += 1,
                KeyCode::Char('s') => { self.process_sort = match self.process_sort {
                    ProcessSort::Cpu => ProcessSort::Memory,
                    ProcessSort::Memory => ProcessSort::Name,
                    ProcessSort::Name => ProcessSort::Pid,
                    ProcessSort::Pid => ProcessSort::Cpu,
                }; }
                KeyCode::Char('f') => { self.startup_filter = match self.startup_filter {
                    StartupFilter::All => StartupFilter::Enabled,
                    StartupFilter::Enabled => StartupFilter::Disabled,
                    StartupFilter::Disabled => StartupFilter::All,
                }; }
                KeyCode::Char('k') => {
                    if self.tab == Tab::Processes {
                        if let Ok(procs) = self.filtered_processes() {
                            if let Some(p) = procs.get(self.selected_row) {
                                self.dialog = Dialog::ConfirmKill { pid: p.pid, name: p.name.clone() };
                            }
                        }
                    }
                }
                KeyCode::Enter => {
                    if let Dialog::ConfirmKill { pid, .. } = &self.dialog {
                        let id = *pid;
                        let _ = self.process_query.terminate_process(id);
                        self.dialog = Dialog::None;
                    }
                }
                KeyCode::Char(' ') => {
                    if self.tab == Tab::Startup {
                        let entry = self.filtered_startup().get(self.selected_row).map(|e| (*e).clone());
                        if let Some(e) = entry {
                            if e.enabled { self.disable_entry(&e); }
                            else { self.enable_entry(&e); }
                        }
                    }
                }
                KeyCode::Char('r') => {
                    if self.tab == Tab::Startup {
                        let scanner = timetrace_core::engine::WindowsStartupScanner::new();
                        let entries = scanner.scan();
                        self.db.upsert_startup_entries(&entries);
                        self.startup_entries = self.db.get_all_startup_entries();
                    }
                }
                KeyCode::Char(c) => {
                    if self.tab == Tab::Processes { self.process_filter.push(c); }
                }
                KeyCode::Backspace => { self.process_filter.pop(); }
                _ => {}
            }
        }
    }

    fn next_tab(&mut self) {
        let tabs = Tab::all();
        let idx = tabs.iter().position(|t| *t == self.tab).unwrap_or(0);
        self.tab = tabs[(idx + 1) % tabs.len()];
        self.selected_row = 0;
    }

    fn disable_entry(&mut self, entry: &StartupEntryRecord) {
        let scanner = timetrace_core::engine::WindowsStartupScanner::new();
        if let Ok(result) = scanner.disable(entry) {
            self.db.set_startup_enabled(entry.id, false, result.backup_value.as_deref(), result.backup_path.as_deref());
            self.startup_entries = self.db.get_all_startup_entries();
        }
    }

    fn enable_entry(&mut self, entry: &StartupEntryRecord) {
        let scanner = timetrace_core::engine::WindowsStartupScanner::new();
        if scanner.enable(entry).is_ok() {
            self.db.set_startup_enabled(entry.id, true, None, None);
            self.startup_entries = self.db.get_all_startup_entries();
        }
    }

    fn filtered_processes(&self) -> Result<Vec<ProcessInfo>, ()> {
        self.process_query.refresh();
        let mut procs = self.process_query.list_processes();
        let f = self.process_filter.to_lowercase();
        if !f.is_empty() {
            procs.retain(|p| p.name.to_lowercase().contains(&f) || p.pid.to_string().contains(&f));
        }
        match self.process_sort {
            ProcessSort::Cpu => procs.sort_by(|a, b| b.cpu_percent.partial_cmp(&a.cpu_percent).unwrap()),
            ProcessSort::Memory => procs.sort_by(|a, b| b.memory_mb.partial_cmp(&a.memory_mb).unwrap()),
            ProcessSort::Name => procs.sort_by(|a, b| a.name.cmp(&b.name)),
            ProcessSort::Pid => procs.sort_by(|a, b| a.pid.cmp(&b.pid)),
        }
        Ok(procs)
    }

    fn filtered_startup(&self) -> Vec<&StartupEntryRecord> {
        self.startup_entries.iter().filter(|e| match self.startup_filter {
            StartupFilter::All => true, StartupFilter::Enabled => e.enabled, StartupFilter::Disabled => !e.enabled,
        }).collect()
    }

    // ── Render ──

    pub fn render(&mut self, frame: &mut Frame) {
        let p = self.palette.clone();
        let area = frame.area();

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Length(2), Constraint::Min(0), Constraint::Length(1)])
            .split(area);

        // Tab bar
        let titles: Vec<Line> = Tab::all().iter().map(|t| {
            let s = if *t == self.tab { Style::default().fg(p.accent).add_modifier(Modifier::BOLD) }
            else { Style::default().fg(p.text_dim) };
            Line::from(Span::styled(t.title(), s))
        }).collect();

        frame.render_widget(
            Tabs::new(titles).highlight_style(Style::default().fg(p.accent)).divider("│"),
            chunks[0],
        );

        // Content
        match self.tab {
            Tab::Dashboard => self.render_dashboard(frame, chunks[1], &p),
            Tab::Processes => self.render_processes(frame, chunks[1], &p),
            Tab::Startup => self.render_startup(frame, chunks[1], &p),
        }

        // Status bar
        let help = match self.tab {
            Tab::Dashboard => "1-3:tab  q:quit",
            Tab::Processes => "type:filter  ↑↓:nav  s:sort  k:kill  1-3:tab  q:quit",
            Tab::Startup => "↑↓:nav  space:toggle  r:rescan  f:filter  1-3:tab  q:quit",
        };
        frame.render_widget(
            Paragraph::new(help).style(Style::default().fg(p.text_dim).bg(p.bg_secondary)).alignment(Alignment::Center),
            chunks[2],
        );

        if !matches!(self.dialog, Dialog::None) { self.render_dialog(frame, &p); }
    }

    // ── Dashboard ──

    fn render_dashboard(&self, frame: &mut Frame, area: Rect, p: &Palette) {
        let today = Local::now().date_naive();
        let top_apps = self.db.get_top_apps(today, today, 10);
        let total_all = self.db.total_tracked_seconds();
        let started = self.db.recording_started_at();

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Length(2), Constraint::Length(4), Constraint::Length(1), Constraint::Min(0)])
            .split(area);

        // Header
        let today_s: i64 = top_apps.iter().map(|a| a.total_seconds).sum();
        let all_h = total_all / 3600; let all_m = (total_all % 3600) / 60;
        let mut lines = vec![Line::from(Span::styled(
            format!("Today: {}h {}m active", today_s / 3600, (today_s % 3600) / 60),
            Style::default().fg(p.text).add_modifier(Modifier::BOLD),
        ))];
        if let Some(s) = started {
            let days = (Utc::now() - s).num_days();
            lines.push(Line::from(Span::styled(
                format!("Recording since {} ({}d) · Lifetime: {}h {}m", s.format("%Y-%m-%d"), days, all_h, all_m),
                Style::default().fg(p.text_dim),
            )));
        }
        frame.render_widget(Paragraph::new(lines), chunks[0]);

        // Timeline
        let sessions = self.db.get_sessions_by_date(today);
        let timeline = self.build_timeline(&sessions, chunks[1].width as usize, p);
        frame.render_widget(timeline, chunks[1]);

        // Section
        frame.render_widget(Paragraph::new("Top Applications").style(Style::default().fg(p.text_dim)), chunks[2]);

        // App list
        let items: Vec<ListItem> = top_apps.iter().map(|a| self.render_app_row(a, p)).collect();
        frame.render_widget(List::new(items), chunks[3]);
    }

    fn build_timeline(&self, sessions: &[SessionRecord], width: usize, p: &Palette) -> Paragraph {
        let mut hour_buckets: [Vec<&SessionRecord>; 24] = Default::default();
        for s in sessions { let h = s.started_at.hour() as usize; if h < 24 { hour_buckets[h].push(s); } }

        let chars_per_hour = (width.saturating_sub(24)) / 24;
        let mut line = String::with_capacity(width);

        for hour in 0..24 {
            let has_active = hour_buckets[hour].iter().any(|s| !s.is_idle);
            let has_idle = hour_buckets[hour].iter().any(|s| s.is_idle);

            if has_active { line.push('█'); }
            else if has_idle { line.push('░'); }
            else { line.push('·'); }

            for _ in 0..chars_per_hour { line.push(if has_active { '▌' } else { ' ' }); }

            if hour % 3 == 0 {
                let label = format!("{:02}", hour);
                line.push_str(&label);
            }
        }

        Paragraph::new(line)
            .style(Style::default().fg(p.accent))
            .block(Block::default().borders(Borders::NONE))
    }

    fn render_app_row(&self, app: &AppUsageSummary, p: &Palette) -> ListItem {
        let h = app.total_seconds / 3600;
        let m = (app.total_seconds % 3600) / 60;
        let time = if h > 0 { format!("{}h {}m", h, m) } else { format!("{}m", m) };
        let bar_w = ((app.total_seconds as f64 / 9000.0).min(1.0) * 30.0) as usize;
        let bar = "█".repeat(bar_w);

        let color = p.app_colors.color_for(&app.app_name);
        ListItem::new(Line::from(vec![
            Span::styled(format!(" {:>2} ", app.rank), Style::default().fg(p.text_dim)),
            Span::styled(truncate(&app.app_name, 25), Style::default().fg(color)),
            Span::styled(format!(" {:>8}  {}", time, bar), Style::default().fg(color)),
        ]))
    }

    // ── Processes ──

    fn render_processes(&mut self, frame: &mut Frame, area: Rect, p: &Palette) {
        let Ok(procs) = self.filtered_processes() else { return };

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Length(1), Constraint::Min(0)])
            .split(area);

        let sort_label = match self.process_sort {
            ProcessSort::Cpu => "CPU▼", ProcessSort::Memory => "Mem▼", ProcessSort::Name => "Name▼", ProcessSort::Pid => "PID▼",
        };
        frame.render_widget(
            Paragraph::new(format!("🔍 {}_  [{}]  {} procs", self.process_filter, sort_label, procs.len()))
                .style(Style::default().fg(p.accent)),
            chunks[0],
        );

        let header = Row::new(vec!["Name", "CPU%", "Memory", "PID"])
            .style(Style::default().fg(p.text_dim).add_modifier(Modifier::BOLD));

        let rows: Vec<Row> = procs.iter().enumerate().map(|(i, proc)| {
            let is_selected = i == self.selected_row;
            let bg = if is_selected { p.bg_selected } else { p.bg };
            let color = if proc.cpu_percent > 50.0 { p.danger } else if proc.cpu_percent > 10.0 { p.warning } else { p.text };

            Row::new(vec![
                Cell::from(truncate(&proc.name, 28)),
                Cell::from(format!("{:.1}", proc.cpu_percent)),
                Cell::from(if proc.memory_mb > 1024.0 { format!("{:.1}G", proc.memory_mb / 1024.0) } else { format!("{:.0}M", proc.memory_mb) }),
                Cell::from(format!("{}", proc.pid)),
            ]).style(Style::default().fg(color).bg(bg))
        }).collect();

        let table = Table::new(rows, [
            Constraint::Percentage(40), Constraint::Percentage(15), Constraint::Percentage(15), Constraint::Percentage(30),
        ]).header(header).column_spacing(2);

        frame.render_widget(table, chunks[1]);
    }

    // ── Startup ──

    fn render_startup(&self, frame: &mut Frame, area: Rect, p: &Palette) {
        let entries = self.filtered_startup();

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Length(1), Constraint::Min(0)])
            .split(area);

        let filter_label = match self.startup_filter {
            StartupFilter::All => "All", StartupFilter::Enabled => "Enabled", StartupFilter::Disabled => "Disabled",
        };
        let enabled_count = self.startup_entries.iter().filter(|e| e.enabled).count();
        frame.render_widget(
            Paragraph::new(format!("[{}]  {} entries ({} enabled)  r:rescan  space:toggle", filter_label, entries.len(), enabled_count))
                .style(Style::default().fg(p.accent)),
            chunks[0],
        );

        let header = Row::new(vec!["Name", "Source", "St", "Command"])
            .style(Style::default().fg(p.text_dim).add_modifier(Modifier::BOLD));

        let rows: Vec<Row> = entries.iter().enumerate().map(|(i, e)| {
            let is_sel = i == self.selected_row;
            let bg = if is_sel { p.bg_selected } else { p.bg };
            let status = if e.enabled { Span::styled("●", Style::default().fg(p.success)) }
            else { Span::styled("○", Style::default().fg(p.text_dim)) };
            let src_color = match e.source.as_str() {
                "HKLM" => p.warning, "HKCU" => p.accent, "StartupFolder" => p.success, _ => p.text_dim,
            };

            Row::new(vec![
                Cell::from(truncate(&e.name, 24)),
                Cell::from(Span::styled(&e.source, Style::default().fg(src_color))),
                Cell::from(status),
                Cell::from(truncate(&e.command, 45)),
            ]).style(Style::default().bg(bg))
        }).collect();

        frame.render_widget(
            Table::new(rows, [
                Constraint::Percentage(25), Constraint::Percentage(15), Constraint::Percentage(5), Constraint::Percentage(55),
            ]).header(header).column_spacing(1),
            chunks[1],
        );
    }

    // ── Dialog ──

    fn render_dialog(&self, frame: &mut Frame, p: &Palette) {
        match &self.dialog {
            Dialog::ConfirmKill { name, pid } => {
                let area = centered_rect(50, 30, frame.area());
                let block = Block::default().borders(Borders::ALL).border_type(BorderType::Rounded)
                    .border_style(Style::default().fg(p.danger)).style(Style::default().bg(p.bg_secondary));
                frame.render_widget(
                    Paragraph::new(format!("End Process?\n\n{}\nPID: {}\n\nEnter: confirm  Esc: cancel", name, pid))
                        .block(block).alignment(Alignment::Center).style(Style::default().fg(p.text)),
                    area,
                );
            }
            Dialog::Info(msg) => {
                let area = centered_rect(60, 20, frame.area());
                let block = Block::default().borders(Borders::ALL).border_type(BorderType::Rounded)
                    .style(Style::default().bg(p.bg_secondary));
                frame.render_widget(
                    Paragraph::new(msg.as_str()).block(block).alignment(Alignment::Center),
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

fn centered_rect(px: u16, py: u16, r: Rect) -> Rect {
    let popup = Layout::default().direction(Direction::Vertical)
        .constraints([Constraint::Percentage((100 - py) / 2), Constraint::Percentage(py), Constraint::Percentage((100 - py) / 2)])
        .split(r);
    Layout::default().direction(Direction::Horizontal)
        .constraints([Constraint::Percentage((100 - px) / 2), Constraint::Percentage(px), Constraint::Percentage((100 - px) / 2)])
        .split(popup[1])[1]
}
