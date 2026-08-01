//! # TimeTrace TUI Application
//!
//! Terminal-based dashboard with three tabs:
//! - Dashboard: usage timeline + top apps
//! - Processes: running process list + kill
//! - Startup: auto-start entry manager

use std::sync::Arc;

use chrono::{Local, NaiveDate, Utc};
use crossterm::event::{self, Event, KeyCode, KeyEventKind};
use ratatui::{
    layout::{Alignment, Constraint, Direction, Layout, Rect},
    style::{Modifier, Style, Stylize},
    text::{Line, Span},
    widgets::{Block, BorderType, Borders, List, ListItem, Paragraph, Tabs},
    Frame,
};

use crate::contracts::{
    storage::{AppUsageSummary, DataStore},
    process::{ProcessInfo, ProcessQuery},
    startup::{StartupEntryRecord, StartupScanner},
};
use crate::tui::theme::{current_palette, Palette};

// ── Application State ──

#[derive(Clone, Copy, PartialEq, Eq)]
enum Tab {
    Dashboard,
    Processes,
    Startup,
}

impl Tab {
    fn all() -> &'static [Tab] {
        &[Tab::Dashboard, Tab::Processes, Tab::Startup]
    }

    fn title(&self) -> &'static str {
        match self {
            Tab::Dashboard => "📊 Dashboard",
            Tab::Processes => "⚡ Processes",
            Tab::Startup => "🚀 Startup",
        }
    }
}

enum Dialog {
    None,
    ConfirmKill { pid: u32, name: String },
    ConfirmDisable { entry: StartupEntryRecord },
    Info(String),
}

pub struct App {
    // ── Dependencies (traits only!) ──
    db: Arc<dyn DataStore>,
    process_query: Box<dyn ProcessQuery>,

    // ── UI State ──
    tab: Tab,
    palette: Palette,
    dialog: Dialog,
    should_quit: bool,

    // ── Process tab state ──
    process_list: Vec<ProcessInfo>,
    process_filter: String,
    process_sort_col: ProcessSortCol,

    // ── Startup tab state ──
    startup_entries: Vec<StartupEntryRecord>,
    startup_filter: StartupFilter,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ProcessSortCol { Name, Cpu, Memory, Pid }

#[derive(Clone, Copy, PartialEq, Eq)]
enum StartupFilter { All, Enabled, Disabled }

impl App {
    pub fn new(
        db: Arc<dyn DataStore>,
        process_query: Box<dyn ProcessQuery>,
    ) -> Self {
        let startup_entries = db.get_all_startup_entries();
        Self {
            db,
            process_query,
            tab: Tab::Dashboard,
            palette: current_palette(),
            dialog: Dialog::None,
            should_quit: false,
            process_list: Vec::new(),
            process_filter: String::new(),
            process_sort_col: ProcessSortCol::Cpu,
            startup_entries,
            startup_filter: StartupFilter::All,
        }
    }

    pub fn should_quit(&self) -> bool {
        self.should_quit
    }

    pub fn handle_event(&mut self, event: Event) {
        if let Event::Key(key) = event {
            if key.kind != KeyEventKind::Press {
                return;
            }

            // Global keybindings
            match key.code {
                KeyCode::Char('q') => self.should_quit = true,
                KeyCode::Char('1') => self.tab = Tab::Dashboard,
                KeyCode::Char('2') => self.tab = Tab::Processes,
                KeyCode::Char('3') => self.tab = Tab::Startup,
                KeyCode::Tab => self.next_tab(),
                KeyCode::Esc => self.dialog = Dialog::None,
                _ => {}
            }

            // Tab-specific
            match self.tab {
                Tab::Processes => self.handle_process_key(key),
                Tab::Startup => self.handle_startup_key(key),
                _ => {}
            }
        }
    }

    fn next_tab(&mut self) {
        let tabs = Tab::all();
        let idx = tabs.iter().position(|t| *t == self.tab).unwrap_or(0);
        self.tab = tabs[(idx + 1) % tabs.len()];
    }

    fn handle_process_key(&mut self, key: event::KeyEvent) {
        match key.code {
            KeyCode::Char(c) => {
                self.process_filter.push(c);
            }
            KeyCode::Backspace => {
                self.process_filter.pop();
            }
            KeyCode::Char('k') => {
                // Kill selected process
                if let Some(proc) = self.process_list.first() {
                    self.dialog = Dialog::ConfirmKill {
                        pid: proc.pid,
                        name: proc.name.clone(),
                    };
                }
            }
            KeyCode::Enter => {
                if let Dialog::ConfirmKill { pid, .. } = self.dialog {
                    let _ = self.process_query.terminate_process(pid);
                    self.dialog = Dialog::None;
                }
            }
            _ => {}
        }
    }

    fn handle_startup_key(&mut self, key: event::KeyEvent) {
        match key.code {
            KeyCode::Char(' ') => {
                // Toggle selected entry
                if let Some(entry) = self.startup_entries.first().cloned() {
                    if entry.enabled {
                        self.disable_startup_entry(&entry);
                    } else {
                        self.enable_startup_entry(&entry);
                    }
                }
            }
            KeyCode::Enter => {
                if let Dialog::ConfirmDisable { entry } = &self.dialog {
                    let entry = entry.clone();
                    self.disable_startup_entry(&entry);
                    self.dialog = Dialog::None;
                }
            }
            _ => {}
        }
    }

    fn disable_startup_entry(&mut self, entry: &StartupEntryRecord) {
        let scanner = crate::engine::startup_win32::WindowsStartupScanner::new();
        match scanner.disable(entry) {
            Ok(result) => {
                self.db.set_startup_enabled(
                    entry.id,
                    false,
                    result.backup_value.as_deref(),
                    result.backup_path.as_deref(),
                );
                self.startup_entries = self.db.get_all_startup_entries();
            }
            Err(e) => {
                self.dialog = Dialog::Info(format!("Failed: {e}"));
            }
        }
    }

    fn enable_startup_entry(&mut self, entry: &StartupEntryRecord) {
        let scanner = crate::engine::startup_win32::WindowsStartupScanner::new();
        match scanner.enable(entry) {
            Ok(()) => {
                self.db.set_startup_enabled(entry.id, true, None, None);
                self.startup_entries = self.db.get_all_startup_entries();
            }
            Err(e) => {
                self.dialog = Dialog::Info(format!("Failed: {e}"));
            }
        }
    }

    // ── Rendering ──

    pub fn render(&mut self, frame: &mut Frame) {
        let p = &self.palette;
        let area = frame.area();

        // Main layout: tabs on top, content below
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Length(2), Constraint::Min(0)].as_ref())
            .split(area);

        // ── Tab bar ──
        let titles: Vec<Line> = Tab::all()
            .iter()
            .map(|t| {
                let style = if *t == self.tab {
                    Style::default().fg(p.accent).add_modifier(Modifier::BOLD)
                } else {
                    Style::default().fg(p.text_dim)
                };
                Line::from(Span::styled(t.title(), style))
            })
            .collect();

        let tabs = Tabs::new(titles)
            .block(Block::default().style(Style::default().bg(p.bg)))
            .highlight_style(Style::default().fg(p.accent))
            .divider("│");

        frame.render_widget(tabs, chunks[0]);

        // ── Content ──
        match self.tab {
            Tab::Dashboard => self.render_dashboard(frame, chunks[1], p),
            Tab::Processes => self.render_processes(frame, chunks[1], p),
            Tab::Startup => self.render_startup(frame, chunks[1], p),
        }

        // ── Dialog overlay ──
        if !matches!(self.dialog, Dialog::None) {
            self.render_dialog(frame, p);
        }
    }

    // ── Dashboard Tab ──

    fn render_dashboard(&self, frame: &mut Frame, area: Rect, p: &Palette) {
        let today = Local::now().date_naive();
        let top_apps = self.db.get_top_apps(today, today, 10);

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(1),  // header
                Constraint::Length(3),  // timeline placeholder
                Constraint::Length(1),  // section title
                Constraint::Min(0),     // app list
            ])
            .split(area);

        // Header
        let total_secs: i64 = top_apps.iter().map(|a| a.total_seconds).sum();
        let hours = total_secs / 3600;
        let mins = (total_secs % 3600) / 60;

        let header = Paragraph::new(format!(
            "Today — {}h {}m active",
            hours, mins
        ))
        .style(Style::default().fg(p.text).add_modifier(Modifier::BOLD));
        frame.render_widget(header, chunks[0]);

        // Timeline (simplified: horizontal bar)
        let timeline = self.render_timeline(today, chunks[1].width as usize, p);
        frame.render_widget(timeline, chunks[1]);

        // Section title
        let title = Paragraph::new("Top Applications")
            .style(Style::default().fg(p.text_dim));
        frame.render_widget(title, chunks[2]);

        // App list
        let app_items: Vec<ListItem> = top_apps
            .iter()
            .map(|app| self.render_app_row(app, chunks[3].width as usize, p))
            .collect();

        let list = List::new(app_items)
            .block(Block::default().style(Style::default().bg(p.bg)));

        frame.render_widget(list, chunks[3]);
    }

    fn render_timeline(&self, date: NaiveDate, width: usize, p: &Palette) -> Paragraph {
        // Simplified timeline: a single line showing active hours
        let sessions = self.db.get_sessions_by_date(date);
        let mut hours_active = [false; 24];

        for s in &sessions {
            if !s.is_idle {
                let hour = s.started_at.hour() as usize;
                if hour < 24 {
                    hours_active[hour] = true;
                }
            }
        }

        let chars_per_hour = width.max(24) / 24;
        let mut line = String::with_capacity(width);
        for hour in 0..24 {
            if hours_active[hour] {
                // Active hour — use accent color
                line.push('█');
            } else {
                // Inactive — dim
                line.push('░');
            }
            // Label every 3 hours
            if hour % 3 == 0 {
                line.push_str(&format!("{:02}", hour));
            }
        }

        Paragraph::new(line)
            .style(Style::default().fg(p.accent))
            .block(Block::default().style(Style::default().bg(p.bg)))
    }

    fn render_app_row(&self, app: &AppUsageSummary, width: usize, p: &Palette) -> ListItem {
        let h = app.total_seconds / 3600;
        let m = (app.total_seconds % 3600) / 60;
        let time_str = if h > 0 {
            format!("{}h {}m", h, m)
        } else {
            format!("{}m", m)
        };

        let bar_width = ((app.total_seconds as f64 / 3600.0).min(8.0) * 10.0) as usize;
        let bar = "█".repeat(bar_width.min(width.saturating_sub(30)));

        let color = p.app_colors.color_for(&app.app_name);
        let text = format!(
            " {:2}. {:<30} {:>8}  {}",
            app.rank,
            truncate(&app.app_name, 30),
            time_str,
            bar,
        );

        ListItem::new(Line::from(Span::styled(text, Style::default().fg(color))))
    }

    // ── Processes Tab ──

    fn render_processes(&mut self, frame: &mut Frame, area: Rect, p: &Palette) {
        self.process_query.refresh();
        self.process_list = self.process_query.list_processes();

        // Filter
        let filter = self.process_filter.to_lowercase();
        let mut filtered: Vec<&ProcessInfo> = self.process_list
            .iter()
            .filter(|proc| {
                filter.is_empty()
                    || proc.name.to_lowercase().contains(&filter)
                    || proc.pid.to_string().contains(&filter)
            })
            .collect();

        // Sort
        match self.process_sort_col {
            ProcessSortCol::Cpu => filtered.sort_by(|a, b| b.cpu_percent.partial_cmp(&a.cpu_percent).unwrap()),
            ProcessSortCol::Memory => filtered.sort_by(|a, b| b.memory_mb.partial_cmp(&a.memory_mb).unwrap()),
            ProcessSortCol::Name => filtered.sort_by(|a, b| a.name.cmp(&b.name)),
            ProcessSortCol::Pid => filtered.sort_by(|a, b| a.pid.cmp(&b.pid)),
        }

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(1),  // filter bar
                Constraint::Length(1),  // header
                Constraint::Min(0),     // process list
                Constraint::Length(1),  // help
            ])
            .split(area);

        // Filter input
        let filter_text = format!("🔍 Filter: {}_", self.process_filter);
        frame.render_widget(
            Paragraph::new(filter_text).style(Style::default().fg(p.accent)),
            chunks[0],
        );

        // Header
        let header = Line::from(vec![
            Span::styled(
                format!("{:<30} {:>6} {:>10} {:>8}", "Name", "CPU%", "Memory", "PID"),
                Style::default().fg(p.text_dim).add_modifier(Modifier::BOLD),
            ),
        ]);
        frame.render_widget(Paragraph::new(header), chunks[1]);

        // Process rows
        let items: Vec<ListItem> = filtered
            .iter()
            .take(area.height as usize - 4)
            .map(|proc| {
                let cpu_str = format!("{:.1}", proc.cpu_percent);
                let mem_str = if proc.memory_mb > 1024.0 {
                    format!("{:.1} GB", proc.memory_mb / 1024.0)
                } else {
                    format!("{:.0} MB", proc.memory_mb)
                };

                let color = if proc.cpu_percent > 50.0 {
                    p.danger
                } else if proc.cpu_percent > 10.0 {
                    p.warning
                } else {
                    p.text
                };

                ListItem::new(Line::from(Span::styled(
                    format!(
                        "{:<30} {:>5}% {:>10} {:>8}",
                        truncate(&proc.name, 30),
                        cpu_str,
                        mem_str,
                        proc.pid,
                    ),
                    Style::default().fg(color),
                )))
            })
            .collect();

        frame.render_widget(
            List::new(items).block(Block::default().style(Style::default().bg(p.bg))),
            chunks[2],
        );

        // Help bar
        let help = Span::styled(
            "Type to filter | k: kill process | 1-3: switch tab | q: quit",
            Style::default().fg(p.text_dim),
        );
        frame.render_widget(Paragraph::new(help), chunks[3]);
    }

    // ── Startup Tab ──

    fn render_startup(&self, frame: &mut Frame, area: Rect, p: &Palette) {
        let filtered: Vec<&StartupEntryRecord> = self.startup_entries
            .iter()
            .filter(|e| match self.startup_filter {
                StartupFilter::All => true,
                StartupFilter::Enabled => e.enabled,
                StartupFilter::Disabled => !e.enabled,
            })
            .collect();

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(1),  // filter chips
                Constraint::Length(1),  // header
                Constraint::Min(0),     // entry list
                Constraint::Length(1),  // help
            ])
            .split(area);

        // Filter chips
        let chips = format!(
            " [All]  [Enabled]  [Disabled]     {} entries",
            filtered.len()
        );
        frame.render_widget(
            Paragraph::new(chips).style(Style::default().fg(p.accent)),
            chunks[0],
        );

        // Header
        let header = Line::from(vec![
            Span::styled(
                format!("{:<25} {:<12} {:<8} {:<40}", "Name", "Source", "Status", "Command"),
                Style::default().fg(p.text_dim).add_modifier(Modifier::BOLD),
            ),
        ]);
        frame.render_widget(Paragraph::new(header), chunks[1]);

        // Entry rows
        let items: Vec<ListItem> = filtered
            .iter()
            .map(|entry| {
                let status = if entry.enabled {
                    Span::styled("● ON ", Style::default().fg(p.success))
                } else {
                    Span::styled("○ OFF", Style::default().fg(p.text_dim))
                };

                let source_color = match entry.source.as_str() {
                    "HKLM" => p.warning,
                    "HKCU" => p.accent,
                    "StartupFolder" => p.success,
                    "TaskScheduler" => p.text_dim,
                    _ => p.text,
                };

                ListItem::new(Line::from(vec![
                    Span::styled(
                        format!("{:<25}", truncate(&entry.name, 25)),
                        Style::default().fg(p.text),
                    ),
                    Span::styled(
                        format!("{:<12}", entry.source),
                        Style::default().fg(source_color),
                    ),
                    status,
                    Span::styled(
                        truncate(&entry.command, 40),
                        Style::default().fg(p.text_dim),
                    ),
                ]))
            })
            .collect();

        frame.render_widget(
            List::new(items).block(Block::default().style(Style::default().bg(p.bg))),
            chunks[2],
        );

        // Help
        let help = Span::styled(
            "Space: toggle | r: rescan | 1-3: switch tab | q: quit",
            Style::default().fg(p.text_dim),
        );
        frame.render_widget(Paragraph::new(help), chunks[3]);
    }

    // ── Dialog ──

    fn render_dialog(&self, frame: &mut Frame, p: &Palette) {
        let area = frame.area();
        let dialog_area = centered_rect(50, 20, area);

        match &self.dialog {
            Dialog::ConfirmKill { name, pid } => {
                let text = format!(
                    "End Process?\n\n{}\nPID: {}\n\nPress Enter to confirm, Esc to cancel",
                    name, pid
                );
                let block = Block::default()
                    .borders(Borders::ALL)
                    .border_type(BorderType::Rounded)
                    .border_style(Style::default().fg(p.danger))
                    .style(Style::default().bg(p.bg_secondary));

                frame.render_widget(
                    Paragraph::new(text)
                        .block(block)
                        .alignment(Alignment::Center)
                        .style(Style::default().fg(p.text)),
                    dialog_area,
                );
            }
            Dialog::ConfirmDisable { entry } => {
                let text = format!(
                    "Disable Startup Entry?\n\n{}\nSource: {}\n\nPress Enter to confirm, Esc to cancel",
                    entry.name, entry.source
                );
                let block = Block::default()
                    .borders(Borders::ALL)
                    .border_type(BorderType::Rounded)
                    .border_style(Style::default().fg(p.warning))
                    .style(Style::default().bg(p.bg_secondary));

                frame.render_widget(
                    Paragraph::new(text).block(block).alignment(Alignment::Center),
                    dialog_area,
                );
            }
            Dialog::Info(msg) => {
                let block = Block::default()
                    .borders(Borders::ALL)
                    .border_type(BorderType::Rounded)
                    .style(Style::default().bg(p.bg_secondary));

                frame.render_widget(
                    Paragraph::new(msg.as_str())
                        .block(block)
                        .alignment(Alignment::Center),
                    dialog_area,
                );
            }
            Dialog::None => {}
        }
    }
}

// ── Helpers ──

fn truncate(s: &str, max_len: usize) -> String {
    if s.chars().count() <= max_len {
        s.to_string()
    } else {
        format!("{}…", &s.chars().take(max_len - 1).collect::<String>())
    }
}

fn centered_rect(percent_x: u16, percent_y: u16, r: Rect) -> Rect {
    let popup_layout = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage((100 - percent_y) / 2),
            Constraint::Percentage(percent_y),
            Constraint::Percentage((100 - percent_y) / 2),
        ])
        .split(r);

    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage((100 - percent_x) / 2),
            Constraint::Percentage(percent_x),
            Constraint::Percentage((100 - percent_x) / 2),
        ])
        .split(popup_layout[1])[1]
}
