//! Processes page: apps (with their helper processes folded in) and background processes,
//! with CPU, memory and disk columns shaded by load, like Windows Task Manager.

use crate::Root;
use crate::theme::{self, Palette, p, size, space};
use gpui::prelude::*;
use gpui::{AnyElement, Context, Div, FontWeight, Hsla, MouseButton, Window, div, uniform_list};
use sampler::{ProcessRow, ProcessStatus};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Column {
    Name,
    Status,
    Cpu,
    Memory,
    Disk,
}

impl Column {
    fn title(self) -> &'static str {
        match self {
            Column::Name => "Name",
            Column::Status => "Status",
            Column::Cpu => "CPU",
            Column::Memory => "Memory",
            Column::Disk => "Disk",
        }
    }
}

const VALUE_COLUMNS: [Column; 3] = [Column::Cpu, Column::Memory, Column::Disk];

#[derive(Clone)]
pub enum DisplayRow {
    Group { title: &'static str, count: usize },
    Entry(Entry),
}

/// One visible line: a process, or an app with its helpers' totals.
#[derive(Clone)]
pub struct Entry {
    pub pid: i32,
    pub name: String,
    pub status: ProcessStatus,
    /// None when another user's process can't be read.
    pub cpu: Option<f64>,
    pub memory: Option<u64>,
    pub disk: Option<f64>,
    pub child_count: usize,
    pub expanded: bool,
    pub is_child: bool,
}

pub struct ProcessesState {
    pub sort: Column,
    pub ascending: bool,
    pub expanded: HashSet<i32>,
    pub selected: Option<i32>,
    pub rows: Rc<Vec<DisplayRow>>,
    pub scroll: gpui::UniformListScrollHandle,
}

impl Default for ProcessesState {
    fn default() -> Self {
        ProcessesState {
            sort: Column::Cpu,
            ascending: false,
            expanded: HashSet::new(),
            selected: None,
            rows: Rc::new(Vec::new()),
            scroll: gpui::UniformListScrollHandle::new(),
        }
    }
}

impl ProcessesState {
    /// Rebuilds the visible rows after a sample, a sort change or an expand/collapse.
    pub fn rebuild(&mut self, processes: &[ProcessRow]) {
        let app_pids: HashSet<i32> = processes
            .iter()
            .filter(|p| p.is_app)
            .map(|p| p.pid)
            .collect();
        let mut children: HashMap<i32, Vec<&ProcessRow>> = HashMap::new();
        for process in processes {
            if !process.is_app && app_pids.contains(&process.responsible_pid) {
                children
                    .entry(process.responsible_pid)
                    .or_default()
                    .push(process);
            }
        }

        let mut apps: Vec<(Entry, Vec<Entry>)> = processes
            .iter()
            .filter(|p| p.is_app)
            .map(|app| {
                let mut kids: Vec<Entry> = children
                    .get(&app.pid)
                    .map(|k| k.iter().map(|p| entry(p, true)).collect())
                    .unwrap_or_default();
                let mut total = entry(app, false);
                total.child_count = kids.len();
                total.expanded = self.expanded.contains(&app.pid);
                for kid in &kids {
                    total.cpu = sum(total.cpu, kid.cpu);
                    total.memory = sum(total.memory, kid.memory);
                    total.disk = sum(total.disk, kid.disk);
                }
                self.sort_entries(&mut kids);
                (total, kids)
            })
            .collect();
        apps.sort_by(|a, b| self.compare(&a.0, &b.0));

        let mut background: Vec<Entry> = processes
            .iter()
            .filter(|p| !p.is_app && !app_pids.contains(&p.responsible_pid))
            .map(|p| entry(p, false))
            .collect();
        self.sort_entries(&mut background);

        let mut rows = Vec::with_capacity(processes.len() + 2);
        rows.push(DisplayRow::Group {
            title: "Apps",
            count: apps.len(),
        });
        for (app, kids) in apps {
            let expanded = app.expanded;
            rows.push(DisplayRow::Entry(app));
            if expanded {
                rows.extend(kids.into_iter().map(DisplayRow::Entry));
            }
        }
        rows.push(DisplayRow::Group {
            title: "Background processes",
            count: background.len(),
        });
        rows.extend(background.into_iter().map(DisplayRow::Entry));
        self.rows = Rc::new(rows);
    }

    pub fn toggle(&mut self, pid: i32, processes: &[ProcessRow]) {
        if !self.expanded.remove(&pid) {
            self.expanded.insert(pid);
        }
        self.rebuild(processes);
    }

    fn sort_entries(&self, entries: &mut [Entry]) {
        entries.sort_by(|a, b| self.compare(a, b));
    }

    fn compare(&self, a: &Entry, b: &Entry) -> std::cmp::Ordering {
        let order = match self.sort {
            Column::Name => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
            Column::Status => status_text(a.status).cmp(status_text(b.status)),
            Column::Cpu => a.cpu.unwrap_or(-1.).total_cmp(&b.cpu.unwrap_or(-1.)),
            Column::Memory => a.memory.unwrap_or(0).cmp(&b.memory.unwrap_or(0)),
            Column::Disk => a.disk.unwrap_or(-1.).total_cmp(&b.disk.unwrap_or(-1.)),
        };
        let order = if self.ascending {
            order
        } else {
            order.reverse()
        };
        order.then_with(|| a.pid.cmp(&b.pid))
    }
}

fn sum<T: std::ops::Add<Output = T>>(a: Option<T>, b: Option<T>) -> Option<T> {
    match (a, b) {
        (Some(a), Some(b)) => Some(a + b),
        (a, None) => a,
        (None, b) => b,
    }
}

fn entry(process: &ProcessRow, is_child: bool) -> Entry {
    let readable = process.cpu >= 0.;
    Entry {
        pid: process.pid,
        name: process.name.clone(),
        status: process.status,
        cpu: readable.then_some(process.cpu),
        memory: readable.then_some(process.memory),
        disk: (process.disk_rate >= 0.).then_some(process.disk_rate),
        child_count: 0,
        expanded: false,
        is_child,
    }
}

fn status_text(status: ProcessStatus) -> &'static str {
    match status {
        ProcessStatus::Running => "",
        ProcessStatus::Suspended => "Suspended",
        ProcessStatus::Efficiency => "Efficiency mode",
    }
}

/// Column totals shown in the header, like Windows: "12%" over "CPU".
struct Totals {
    cpu: f64,
    memory: f64,
    disk: f64,
    total_memory: f64,
}

impl Root {
    pub fn render_processes(
        &mut self,
        _window: &mut Window,
        cx: &mut Context<Self>,
        palette: &Palette,
    ) -> Div {
        let monitor = &self.monitor;
        let totals = Totals {
            cpu: monitor.current_total(),
            memory: monitor.memory.as_ref().map_or(0., |m| m.used_fraction()),
            disk: monitor
                .disks
                .iter()
                .map(|d| d.active_time)
                .fold(0., f64::max),
            total_memory: monitor.memory.as_ref().map_or(1., |m| m.total as f64),
        };
        let state = &self.processes;
        let has_selection = state.selected.is_some();

        let end_task = div()
            .id("end-task")
            .flex()
            .items_center()
            .h(p(size::COMMAND_BUTTON))
            .px(p(space::M))
            .rounded(p(4.))
            .text_size(p(13.))
            .when(!has_selection, |b| b.opacity(0.4))
            .when(has_selection, |b| b.hover(|s| s.bg(palette.hover)))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, _, _, cx| {
                    if let Some(pid) = this.processes.selected.take() {
                        sampler::terminate(pid, false);
                        cx.notify();
                    }
                }),
            )
            .child("End task");

        let header = div()
            .flex()
            .flex_none()
            .h(p(52.))
            .border_b_1()
            .border_color(palette.stroke)
            .child(
                self.header_cell(Column::Name, None, palette, cx)
                    .flex_1()
                    .min_w(p(220.)),
            )
            .child(
                self.header_cell(Column::Status, None, palette, cx)
                    .w(p(size::STATUS_COLUMN)),
            )
            .children(VALUE_COLUMNS.map(|column| {
                let total = match column {
                    Column::Cpu => totals.cpu,
                    Column::Memory => totals.memory,
                    _ => totals.disk,
                };
                self.header_cell(column, Some(theme::percent(Some(total))), palette, cx)
                    .w(p(size::VALUE_COLUMN))
            }));

        let rows = state.rows.clone();
        let selected = state.selected;
        let palette_copy = *palette;
        let total_memory = totals.total_memory;
        let list = uniform_list(
            "processes",
            rows.len(),
            cx.processor(move |_this, range: std::ops::Range<usize>, _window, cx| {
                range
                    .filter_map(|index| rows.get(index).map(|row| (index, row)))
                    .map(|(index, row)| {
                        render_row(index, row, selected, total_memory, &palette_copy, cx)
                    })
                    .collect::<Vec<_>>()
            }),
        )
        .track_scroll(state.scroll.clone())
        .flex_1();

        div()
            .flex()
            .flex_col()
            .size_full()
            .child(crate::ui::page_header("Processes", palette, end_task))
            .child(header)
            .child(list)
    }

    fn header_cell(
        &self,
        column: Column,
        total: Option<String>,
        palette: &Palette,
        cx: &mut Context<Self>,
    ) -> Div {
        let sorted = self.processes.sort == column;
        let arrow = if sorted {
            if self.processes.ascending {
                " ▲"
            } else {
                " ▼"
            }
        } else {
            ""
        };
        let numeric = total.is_some();
        div()
            .flex()
            .flex_col()
            .justify_end()
            .px(p(space::S))
            .pb(p(space::XS))
            .border_r_1()
            .border_color(palette.stroke)
            .hover(|s| s.bg(palette.hover))
            .when(numeric, |cell| cell.items_end())
            .when(column == Column::Name, |cell| cell.pl(p(space::XL)))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(move |this, _, _, cx| {
                    let state = &mut this.processes;
                    if state.sort == column {
                        state.ascending = !state.ascending;
                    } else {
                        state.sort = column;
                        // Names sort A to Z first; numbers biggest first, like Windows.
                        state.ascending = column == Column::Name || column == Column::Status;
                    }
                    state.rebuild(&this.monitor.processes);
                    cx.notify();
                }),
            )
            .when_some(total, |cell, total| {
                cell.child(div().text_size(p(15.)).child(total))
            })
            .child(
                div()
                    .text_size(p(11.))
                    .text_color(palette.secondary_text)
                    .whitespace_nowrap()
                    .child(format!("{}{}", column.title(), arrow)),
            )
    }
}

fn render_row(
    index: usize,
    row: &DisplayRow,
    selected: Option<i32>,
    total_memory: f64,
    palette: &Palette,
    cx: &mut Context<Root>,
) -> AnyElement {
    match row {
        DisplayRow::Group { title, count } => div()
            .id(("row", index))
            .flex()
            .items_end()
            .h(p(size::LIST_ROW))
            .pl(p(space::XL))
            .pb(p(space::XS))
            .text_size(p(13.))
            .font_weight(FontWeight::SEMIBOLD)
            .child(format!("{title} ({count})"))
            .into_any_element(),
        DisplayRow::Entry(entry) => {
            let pid = entry.pid;
            let is_selected = selected == Some(pid);
            let expandable = entry.child_count > 0;
            let chevron = if expandable {
                if entry.expanded { "⌄" } else { "›" }
            } else {
                ""
            };
            let name = if expandable {
                format!("{} ({})", entry.name, entry.child_count + 1)
            } else {
                entry.name.clone()
            };

            let cells: [(String, f64); 3] = [
                (
                    entry.cpu.map_or("–".into(), theme::precise_percent),
                    entry.cpu.unwrap_or(0.) / 0.25,
                ),
                (
                    entry.memory.map_or("–".into(), theme::megabytes),
                    entry
                        .memory
                        .map_or(0., |m| m as f64 / total_memory.max(1.) / 0.15),
                ),
                (
                    entry.disk.map_or("–".into(), theme::megabyte_rate),
                    entry.disk.unwrap_or(0.) / 20_000_000.,
                ),
            ];

            div()
                .id(("row", index))
                .flex()
                .h(p(size::LIST_ROW))
                .text_size(p(13.))
                .when(is_selected, |row| row.bg(palette.selected))
                .when(!is_selected, |row| row.hover(|s| s.bg(palette.hover)))
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(move |this, event: &gpui::MouseDownEvent, _, cx| {
                        // Double-clicking an app shows or hides its helper processes.
                        if expandable && event.click_count == 2 {
                            this.processes.toggle(pid, &this.monitor.processes);
                        }
                        this.processes.selected = Some(pid);
                        cx.notify();
                    }),
                )
                .child(
                    div()
                        .flex()
                        .items_center()
                        .flex_1()
                        .min_w(p(220.))
                        .pl(p(if entry.is_child { 44. } else { space::S }))
                        .gap(p(space::XS))
                        .overflow_hidden()
                        .child(
                            div()
                                .w(p(12.))
                                .flex_none()
                                .text_color(palette.secondary_text)
                                .child(chevron)
                                .when(expandable, |chevron| {
                                    chevron.on_mouse_down(
                                        MouseButton::Left,
                                        cx.listener(move |this, _, _, cx| {
                                            this.processes.toggle(pid, &this.monitor.processes);
                                            cx.stop_propagation();
                                            cx.notify();
                                        }),
                                    )
                                }),
                        )
                        .child(
                            div()
                                .whitespace_nowrap()
                                .overflow_hidden()
                                .text_ellipsis()
                                .child(name),
                        ),
                )
                .child(
                    div()
                        .flex()
                        .items_center()
                        .w(p(size::STATUS_COLUMN))
                        .px(p(space::S))
                        .text_color(palette.secondary_text)
                        .whitespace_nowrap()
                        .child(status_text(entry.status)),
                )
                .children(cells.into_iter().map(|(text, heat)| {
                    let background: Hsla = palette.heat(heat);
                    div()
                        .flex()
                        .items_center()
                        .justify_end()
                        .w(p(size::VALUE_COLUMN))
                        .px(p(space::S))
                        .bg(background)
                        .whitespace_nowrap()
                        .child(text)
                }))
                .into_any_element()
        }
    }
}
