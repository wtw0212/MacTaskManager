//! Performance page: resource tiles on the left, the selected resource's details on the right.

use crate::Root;
use crate::graph::Graph;
use crate::monitor::{GpuState, History, Monitor, NetworkState};
use crate::theme::{self, Palette, p, resource, size, space};
use crate::ui::*;
use gpui::prelude::*;
use gpui::{AnyElement, Context, Div, MouseButton, Window, div};
use sampler::CoreGroup;

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Resource {
    Cpu,
    Memory,
    Disk(String),
    Network(String),
    Gpu(usize),
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum CpuMode {
    Logical,
    Overall,
}

impl Root {
    pub fn render_performance(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
        palette: &Palette,
    ) -> Div {
        let tiles = self.tiles(cx, palette);
        let detail = match self.selection.clone() {
            Resource::Memory if self.monitor.memory.is_some() => {
                memory_detail(&self.monitor, palette)
            }
            Resource::Disk(id) => match self
                .monitor
                .disks
                .iter()
                .position(|d| d.counters.bsd_name == id)
            {
                Some(index) => disk_detail(&self.monitor, index, palette),
                None => self.cpu_detail(window, cx, palette),
            },
            Resource::Network(id) => match self
                .monitor
                .networks
                .iter()
                .find(|n| n.counters.bsd_name == id)
            {
                Some(network) => network_detail(network, palette),
                None => self.cpu_detail(window, cx, palette),
            },
            Resource::Gpu(index) if index < self.monitor.gpus.len() => {
                gpu_detail(&self.monitor, &self.monitor.gpus[index], palette)
            }
            _ => self.cpu_detail(window, cx, palette),
        };

        div()
            .flex()
            .flex_col()
            .size_full()
            .child(page_header("Performance", palette, div()))
            .child(
                div()
                    .flex()
                    .flex_1()
                    .min_h(p(0.))
                    .child(
                        div()
                            .id("resource-list")
                            .flex_none()
                            .w(p(size::RESOURCE_LIST))
                            .h_full()
                            .overflow_y_scroll()
                            .p(p(space::S))
                            .border_r_1()
                            .border_color(palette.stroke)
                            .child(div().flex().flex_col().gap(p(space::XXS)).children(tiles)),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .flex_1()
                            .min_w(p(0.))
                            .px(p(space::XL))
                            .py(p(space::L))
                            .gap(p(space::M))
                            .child(detail),
                    ),
            )
    }

    fn tiles(&mut self, cx: &mut Context<Self>, palette: &Palette) -> Vec<AnyElement> {
        let monitor = &self.monitor;
        let mut tiles = Vec::new();

        let cpu_temperature = monitor
            .temperature
            .cpu
            .map(|t| format!("  {}", theme::temperature(Some(t))))
            .unwrap_or_default();
        tiles.push((
            Resource::Cpu,
            "CPU".to_string(),
            vec![format!(
                "{}{}",
                theme::percent(Some(monitor.current_total())),
                cpu_temperature
            )],
            Graph::new(&monitor.total_history, resource::cpu()),
        ));

        if let Some(memory) = &monitor.memory {
            tiles.push((
                Resource::Memory,
                "Memory".into(),
                vec![format!(
                    "{}/{} ({})",
                    theme::gigabytes(memory.used(), false),
                    theme::gigabytes(memory.total, true),
                    theme::percent(Some(memory.used_fraction()))
                )],
                Graph::new(&monitor.memory_history, resource::memory()),
            ));
        }

        for (index, disk) in monitor.disks.iter().enumerate() {
            tiles.push((
                Resource::Disk(disk.counters.bsd_name.clone()),
                format!("Disk {index} ({})", disk.counters.bsd_name),
                vec![
                    if disk.counters.is_internal == Some(false) {
                        "External".into()
                    } else {
                        "SSD".into()
                    },
                    theme::percent(Some(disk.active_time)),
                ],
                Graph::new(&disk.active_history, resource::disk()),
            ));
        }

        for network in &monitor.networks {
            tiles.push((
                Resource::Network(network.counters.bsd_name.clone()),
                network.display_name.clone(),
                vec![network.counters.bsd_name.clone(), rates(network)],
                Graph::new(&network.receive_history, resource::network())
                    .secondary(&network.send_history)
                    .max_value(network.scale()),
            ));
        }

        for (index, gpu) in monitor.gpus.iter().enumerate() {
            let temperature = monitor
                .temperature
                .gpu
                .map(|t| format!(" ({})", theme::temperature(Some(t))))
                .unwrap_or_default();
            tiles.push((
                Resource::Gpu(index),
                format!("GPU {index}"),
                vec![
                    gpu.reading.name.clone(),
                    format!("{}{}", theme::percent(gpu.reading.utilization), temperature),
                ],
                Graph::new(&gpu.history, resource::gpu()),
            ));
        }

        tiles
            .into_iter()
            .enumerate()
            .map(|(index, (resource, title, lines, graph))| {
                let selected = self.selection == resource;
                div()
                    .id(("tile", index))
                    .flex()
                    .items_center()
                    .gap(p(space::M))
                    .p(p(space::S))
                    .rounded(p(4.))
                    .when(selected, |tile| tile.bg(palette.selected))
                    .when(!selected, |tile| {
                        tile.hover(|style| style.bg(palette.hover))
                    })
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(move |this, _, _, cx| {
                            this.selection = resource.clone();
                            cx.notify();
                        }),
                    )
                    .child(
                        div()
                            .flex_none()
                            .w(p(size::TILE_GRAPH_W))
                            .h(p(size::TILE_GRAPH_H))
                            .child(graph.without_grid().element()),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .min_w(p(0.))
                            .gap(p(space::XXS))
                            .child(div().text_size(p(14.)).whitespace_nowrap().child(title))
                            .children(lines.into_iter().map(|line| {
                                div()
                                    .text_size(p(11.))
                                    .text_color(palette.secondary_text)
                                    .whitespace_nowrap()
                                    .overflow_hidden()
                                    .text_ellipsis()
                                    .child(line)
                            })),
                    )
                    .into_any_element()
            })
            .collect()
    }

    fn cpu_detail(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
        palette: &Palette,
    ) -> Div {
        let monitor = &self.monitor;
        let mode = self.cpu_mode;
        let graph: AnyElement = match mode {
            CpuMode::Overall => Graph::new(&monitor.total_history, resource::cpu())
                .element()
                .into_any_element(),
            CpuMode::Logical => core_grid(monitor, window, palette).into_any_element(),
        };

        let mut rows = vec![
            vec![
                stat("Utilization", theme::percent(Some(monitor.current_total()))),
                stat("Temperature", theme::temperature(monitor.temperature.cpu)),
                stat("Processes", monitor.process_count.to_string()),
            ],
            Vec::new(),
        ];
        for group in monitor.core_groups.iter().take(2) {
            let label = if monitor.core_groups.len() > 1 {
                format!("{} cores", group.name)
            } else {
                "All cores".into()
            };
            rows[1].push(stat(
                label,
                theme::percent(Some(monitor.utilization(group))),
            ));
        }
        rows[1].push(stat("Up time", theme::uptime(monitor.uptime)));

        let mut info = Vec::new();
        if monitor.core_groups.len() > 1 {
            for group in &monitor.core_groups {
                info.push((
                    format!("{} cores:", group.name),
                    group.cores.len().to_string(),
                ));
            }
        } else if let Some(cores) = monitor.physical_cores {
            info.push(("Cores:".into(), cores.to_string()));
        }
        info.push((
            "Logical processors:".into(),
            monitor.core_histories.len().to_string(),
        ));
        info.push((
            "Thermal state:".into(),
            monitor.thermal_state.label().into(),
        ));

        let other = match mode {
            CpuMode::Logical => "Overall utilization",
            CpuMode::Overall => "Logical processors",
        };
        div()
            .flex()
            .flex_col()
            .size_full()
            .gap(p(space::M))
            .child(resource_header(
                "CPU".into(),
                monitor.cpu_name.clone(),
                palette,
            ))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_h(p(0.))
                    .gap(p(space::XS))
                    .child(caption_row(
                        format!(
                            "% Utilization over {} seconds",
                            crate::monitor::HISTORY_LENGTH
                        ),
                        "100%".into(),
                        palette,
                    ))
                    .child(
                        div()
                            .id("cpu-graph")
                            .flex_1()
                            .min_h(p(0.))
                            // Windows switches views from the graph's context menu; GPUI has no
                            // native context menus, so a right-click toggles between the two.
                            .on_mouse_down(
                                MouseButton::Right,
                                cx.listener(|this, _, _, cx| {
                                    this.cpu_mode = match this.cpu_mode {
                                        CpuMode::Logical => CpuMode::Overall,
                                        CpuMode::Overall => CpuMode::Logical,
                                    };
                                    cx.notify();
                                }),
                            )
                            .child(graph),
                    )
                    .child(caption_row(
                        format!("Right-click for {}", other.to_lowercase()),
                        "0".into(),
                        palette,
                    )),
            )
            .child(stats_area(rows, info, palette))
    }
}

/// One section per core type (e.g. Super, Performance), each a grid of per-core graphs
/// that fills the available space.
fn core_grid(monitor: &Monitor, window: &Window, palette: &Palette) -> Div {
    let groups = &monitor.core_groups;
    // Layout isn't known while building elements, so estimate the graph area from the window.
    let viewport = window.viewport_size();
    let width =
        f32::from(viewport.width) - size::NAV_EXPANDED - size::RESOURCE_LIST - 2. * space::XL - 2.;
    let height =
        f32::from(viewport.height) - size::TITLE_BAR - size::PAGE_HEADER - 2. * space::L - 330.;
    let columns = best_column_count(groups, width.max(100.), height.max(100.));
    let show_headers = groups.len() > 1;

    div()
        .flex()
        .flex_col()
        .size_full()
        .gap(p(space::M))
        .children(groups.iter().map(|group| {
            let rows = group.cores.len().div_ceil(columns);
            div()
                .flex()
                .flex_col()
                .flex_grow()
                .flex_basis(p(0.))
                // Each section gets height in proportion to its row count.
                .flex_grow_factor(rows as f32)
                .gap(p(space::XS))
                .when(show_headers, |section| {
                    section.child(caption_row(
                        format!("{} cores ({})", group.name, group.cores.len()),
                        theme::percent(Some(monitor.utilization(group))),
                        palette,
                    ))
                })
                .children((0..rows).map(|row| {
                    div()
                        .flex()
                        .flex_1()
                        .gap(p(space::XS))
                        .children((0..columns).map(|column| {
                            let cell = div().flex_1().min_w(p(0.));
                            match group.cores.get(row * columns + column) {
                                Some(&core) => {
                                    let history = monitor
                                        .core_histories
                                        .get(core)
                                        .cloned()
                                        .unwrap_or_else(History::new);
                                    cell.child(Graph::new(&history, resource::cpu()).element())
                                }
                                None => cell,
                            }
                        }))
                }))
        }))
}

trait FlexGrowFactor {
    fn flex_grow_factor(self, factor: f32) -> Self;
}

impl<T: Styled> FlexGrowFactor for T {
    fn flex_grow_factor(mut self, factor: f32) -> Self {
        self.style().flex_grow = Some(factor);
        self
    }
}

/// Picks the column count that makes each cell closest to a 2:1 shape while leaving few
/// empty slots at the end of each section.
fn best_column_count(groups: &[CoreGroup], width: f32, height: f32) -> usize {
    let largest = groups
        .iter()
        .map(|g| g.cores.len())
        .max()
        .unwrap_or(1)
        .max(1);
    let total: usize = groups.iter().map(|g| g.cores.len()).sum();
    let mut best = largest;
    let mut best_score = f64::INFINITY;
    for columns in 1..=largest {
        let rows: usize = groups
            .iter()
            .map(|g| g.cores.len().div_ceil(columns))
            .sum::<usize>()
            .max(1);
        let aspect = (width as f64 / columns as f64) / (height as f64 / rows as f64);
        let empty = (rows * columns - total) as f64 / (rows * columns) as f64;
        let score = (aspect / 2.).ln().abs() + 3. * empty;
        if score < best_score {
            best_score = score;
            best = columns;
        }
    }
    best
}

fn memory_detail(monitor: &Monitor, palette: &Palette) -> Div {
    let memory = monitor.memory.clone().unwrap_or_default();
    let pressure = match memory.pressure_level {
        Some(1) => "Normal",
        Some(2) => "Warning",
        Some(4) => "Critical",
        _ => "N/A",
    };
    div()
        .flex()
        .flex_col()
        .size_full()
        .gap(p(space::M))
        .child(resource_header(
            "Memory".into(),
            format!("{} unified memory", theme::gigabytes(memory.total, true)),
            palette,
        ))
        .child(labeled_graph(
            "Memory usage",
            Graph::new(&monitor.memory_history, resource::memory()),
            theme::gigabytes(memory.total, true),
            palette,
        ))
        .child(
            div()
                .flex()
                .flex_col()
                .flex_none()
                .gap(p(space::XS))
                .child(caption_row(
                    "Memory composition".into(),
                    String::new(),
                    palette,
                ))
                .child(composition_bar(&memory)),
        )
        .child(stats_area(
            vec![
                vec![
                    stat(
                        "In use (Compressed)",
                        format!(
                            "{} ({})",
                            theme::gigabytes(memory.used(), true),
                            theme::bytes(Some(memory.compressed))
                        ),
                    ),
                    stat("Available", theme::gigabytes(memory.available(), true)),
                ],
                vec![
                    stat("Memory pressure", pressure),
                    stat(
                        "Swap used",
                        format!(
                            "{} / {}",
                            theme::bytes(Some(memory.swap_used)),
                            theme::bytes(Some(memory.swap_total))
                        ),
                    ),
                ],
            ],
            vec![
                ("App memory:".into(), theme::bytes(Some(memory.app))),
                ("Wired memory:".into(), theme::bytes(Some(memory.wired))),
                ("Compressed:".into(), theme::bytes(Some(memory.compressed))),
                ("Cached files:".into(), theme::bytes(Some(memory.cached))),
            ],
            palette,
        ))
}

/// Stacked bar like Windows' memory composition: wired, app, compressed, cached, free.
fn composition_bar(memory: &sampler::MemoryReading) -> Div {
    let total = memory.total.max(1) as f32;
    let cached = memory.cached.min(memory.available());
    let parts = [
        (memory.wired, 0.55),
        (memory.app, 0.35),
        (memory.compressed, 0.22),
        (cached, 0.10),
        (memory.available() - cached, 0.0),
    ];
    let color = resource::memory();
    div()
        .flex()
        .flex_none()
        .h(p(40.))
        .border_1()
        .border_color(color)
        .children(parts.into_iter().map(move |(bytes, alpha)| {
            div()
                .h_full()
                .flex_grow()
                .flex_basis(p(0.))
                .flex_grow_factor(bytes as f32 / total)
                .bg(theme::with_alpha(color, alpha))
                .border_r_1()
                .border_color(color)
        }))
}

fn disk_detail(monitor: &Monitor, index: usize, palette: &Palette) -> Div {
    let disk = &monitor.disks[index];
    let scale = theme::nice_scale(
        disk.read_history.max().max(disk.write_history.max()),
        1_000_000.,
    );
    let mut info = Vec::new();
    if let Some(size) = disk.counters.size {
        info.push(("Capacity:".into(), theme::file_bytes(size)));
    }
    if let Some(internal) = disk.counters.is_internal {
        info.push((
            "Type:".into(),
            if internal {
                "Internal SSD".into()
            } else {
                "External".into()
            },
        ));
    }
    // On Apple Silicon and T2 Macs the startup volume lives on disk0.
    if disk.counters.bsd_name == "disk0"
        && let Some((free, total)) = monitor.startup_volume
    {
        info.push((
            "Startup volume:".into(),
            format!(
                "{} free of {}",
                theme::file_bytes(free),
                theme::file_bytes(total)
            ),
        ));
    }
    div()
        .flex()
        .flex_col()
        .size_full()
        .gap(p(space::M))
        .child(resource_header(
            format!("Disk {index} ({})", disk.counters.bsd_name),
            disk.counters.name.clone(),
            palette,
        ))
        .child(labeled_graph(
            "Active time",
            Graph::new(&disk.active_history, resource::disk()),
            "100%".into(),
            palette,
        ))
        .child(
            labeled_graph(
                "Disk transfer rate",
                Graph::new(&disk.read_history, resource::disk())
                    .secondary(&disk.write_history)
                    .max_value(scale),
                theme::byte_rate(scale),
                palette,
            )
            .flex_none()
            .h(p(140.)),
        )
        .child(stats_area(
            vec![vec![
                stat("Active time", theme::percent(Some(disk.active_time))),
                stat("Read speed", theme::byte_rate(disk.read_rate))
                    .legend(resource::disk(), false),
                stat("Write speed", theme::byte_rate(disk.write_rate))
                    .legend(resource::disk(), true),
            ]],
            info,
            palette,
        ))
}

fn network_detail(network: &NetworkState, palette: &Palette) -> Div {
    let scale = network.scale();
    div()
        .flex()
        .flex_col()
        .size_full()
        .gap(p(space::M))
        .child(resource_header(
            network.display_name.clone(),
            network.counters.bsd_name.clone(),
            palette,
        ))
        .child(labeled_graph(
            "Throughput",
            Graph::new(&network.receive_history, resource::network())
                .secondary(&network.send_history)
                .max_value(scale),
            theme::bit_rate(scale),
            palette,
        ))
        .child(stats_area(
            vec![vec![
                stat("Send", theme::bit_rate(network.send_rate)).legend(resource::network(), true),
                stat("Receive", theme::bit_rate(network.receive_rate))
                    .legend(resource::network(), false),
            ]],
            vec![
                ("Interface:".into(), network.counters.bsd_name.clone()),
                (
                    "IPv4 address:".into(),
                    network.ipv4.clone().unwrap_or_else(|| "N/A".into()),
                ),
                (
                    "IPv6 address:".into(),
                    network.ipv6.clone().unwrap_or_else(|| "N/A".into()),
                ),
                (
                    "Total received:".into(),
                    theme::bytes(Some(network.counters.bytes_in)),
                ),
                (
                    "Total sent:".into(),
                    theme::bytes(Some(network.counters.bytes_out)),
                ),
            ],
            palette,
        ))
}

fn gpu_detail(monitor: &Monitor, gpu: &GpuState, palette: &Palette) -> Div {
    let reading = &gpu.reading;
    let mut info = Vec::new();
    if let Some(cores) = reading.core_count {
        info.push(("GPU cores:".into(), cores.to_string()));
    }
    info.push(("Renderer:".into(), theme::percent(reading.renderer)));
    info.push(("Tiler:".into(), theme::percent(reading.tiler)));
    let temperature_label = if monitor.temperature.gpu_is_soc {
        "SoC temperature"
    } else {
        "GPU temperature"
    };

    div()
        .flex()
        .flex_col()
        .size_full()
        .gap(p(space::M))
        .child(resource_header("GPU".into(), reading.name.clone(), palette))
        .child(labeled_graph(
            "Utilization",
            Graph::new(&gpu.history, resource::gpu()),
            "100%".into(),
            palette,
        ))
        // Apple Silicon also reports the renderer (3D) and tiler stages separately.
        .when(
            reading.renderer.is_some() || reading.tiler.is_some(),
            |detail| {
                detail.child(
                    div()
                        .flex()
                        .flex_none()
                        .h(p(130.))
                        .gap(p(space::L))
                        .child(labeled_graph(
                            "Renderer",
                            Graph::new(&gpu.renderer_history, resource::gpu()),
                            "100%".into(),
                            palette,
                        ))
                        .child(labeled_graph(
                            "Tiler",
                            Graph::new(&gpu.tiler_history, resource::gpu()),
                            "100%".into(),
                            palette,
                        )),
                )
            },
        )
        .child(stats_area(
            vec![vec![
                stat("Utilization", theme::percent(reading.utilization)),
                stat("GPU memory in use", theme::bytes(reading.memory_in_use)),
                stat(
                    temperature_label,
                    theme::temperature(monitor.temperature.gpu),
                ),
            ]],
            info,
            palette,
        ))
}

/// "S: 8.0  R: 16.4 Kbps": like Windows, the unit is printed once when both rates share it.
fn rates(network: &NetworkState) -> String {
    let send = theme::bit_rate(network.send_rate);
    let receive = theme::bit_rate(network.receive_rate);
    let unit = |rate: &str| rate.rsplit(' ').next().unwrap_or("").to_string();
    let send_value = if unit(&send) == unit(&receive) {
        send[..send.len() - unit(&send).len() - 1].to_string()
    } else {
        send
    };
    format!("S: {send_value}  R: {receive}")
}
