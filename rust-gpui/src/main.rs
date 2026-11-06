//! Task Manager for macOS in Rust and GPUI: the Swift/SwiftUI app's Processes and Performance
//! pages, built the same way (1 s sampling on the main thread, 60 s graphs), so the two can be
//! compared for memory and CPU use.
//!
//! Usage: TaskManagerGPUI [--page performance|processes] [--resource cpu|memory|gpu]

mod graph;
mod monitor;
mod performance;
mod processes;
mod theme;
mod ui;

use gpui::prelude::*;
use gpui::{
    App, Application, Bounds, Context, FontWeight, MouseButton, Subscription, Task,
    TitlebarOptions, Window, WindowBounds, WindowOptions, div, point, px, size,
};
use monitor::Monitor;
use performance::{CpuMode, Resource};
use processes::ProcessesState;
use std::time::Duration;
use theme::{Palette, p, space};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Page {
    Processes,
    Performance,
}

pub struct Root {
    monitor: Monitor,
    page: Page,
    selection: Resource,
    cpu_mode: CpuMode,
    processes: ProcessesState,
    _tick: Task<()>,
    _appearance: Subscription,
}

impl Root {
    fn new(page: Page, selection: Resource, window: &mut Window, cx: &mut Context<Self>) -> Self {
        // Same cadence as the Swift app's Normal update speed.
        let tick = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(Duration::from_secs(1)).await;
                let alive = this.update(cx, |this, cx| {
                    this.monitor.tick();
                    if this.page == Page::Processes {
                        this.processes.rebuild(&this.monitor.processes);
                    }
                    cx.notify();
                });
                if alive.is_err() {
                    break;
                }
            }
        });
        let appearance = cx.observe_window_appearance(window, |_, _, cx| cx.notify());
        let mut root = Root {
            monitor: Monitor::new(),
            page: Page::Performance,
            selection,
            cpu_mode: CpuMode::Logical,
            processes: ProcessesState::default(),
            _tick: tick,
            _appearance: appearance,
        };
        root.show(page);
        root
    }

    fn show(&mut self, page: Page) {
        self.page = page;
        // Processes are only sampled while their page is open, like the Swift version.
        self.monitor.set_samples_processes(page == Page::Processes);
        if page == Page::Processes {
            self.processes.rebuild(&self.monitor.processes);
        } else {
            self.processes.rows = Default::default();
        }
    }

    fn title_bar(&self, palette: &Palette) -> impl IntoElement {
        div()
            .flex()
            .flex_none()
            .items_center()
            .h(p(theme::size::TITLE_BAR))
            // Leaves room for the traffic-light buttons.
            .pl(p(86.))
            .gap(p(space::S))
            .child(
                div()
                    .w(p(14.))
                    .h(p(14.))
                    .rounded(p(3.))
                    .bg(theme::resource::cpu()),
            )
            .child(
                div()
                    .text_size(p(11.))
                    .text_color(palette.text)
                    .child("Task Manager"),
            )
            .child(
                div()
                    .text_size(p(11.))
                    .text_color(palette.secondary_text)
                    .child("· Rust + GPUI"),
            )
    }

    fn navigation(&self, palette: &Palette, cx: &mut Context<Self>) -> impl IntoElement {
        let item = |page: Page, title: &'static str, cx: &mut Context<Self>| {
            let selected = self.page == page;
            div()
                .id(title)
                .flex()
                .items_center()
                .h(p(theme::size::NAV_ROW))
                .mx(p(space::XS))
                .px(p(space::M))
                .gap(p(space::M))
                .rounded(p(4.))
                .text_size(p(13.))
                .when(selected, |row| {
                    row.bg(palette.selected).font_weight(FontWeight::SEMIBOLD)
                })
                .when(!selected, |row| row.hover(|s| s.bg(palette.hover)))
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(move |this, _, _, cx| {
                        this.show(page);
                        cx.notify();
                    }),
                )
                // Windows' accent pill on the selected item.
                .child(
                    div()
                        .w(p(3.))
                        .h(p(16.))
                        .rounded(p(2.))
                        .when(selected, |pill| pill.bg(palette.accent)),
                )
                .child(title)
        };
        div()
            .flex()
            .flex_col()
            .flex_none()
            .w(p(theme::size::NAV_EXPANDED))
            .gap(p(space::XXS))
            .child(item(Page::Processes, "Processes", cx))
            .child(item(Page::Performance, "Performance", cx))
    }
}

impl Render for Root {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let palette = Palette::for_appearance(window.appearance());
        let page = match self.page {
            Page::Processes => self.render_processes(window, cx, &palette),
            Page::Performance => self.render_performance(window, cx, &palette),
        };
        div()
            .flex()
            .flex_col()
            .size_full()
            .font_family(".SystemUIFont")
            .text_color(palette.text)
            .bg(palette.window_background)
            .child(self.title_bar(&palette))
            .child(
                div()
                    .flex()
                    .flex_1()
                    .min_h(p(0.))
                    .child(self.navigation(&palette, cx))
                    .child(
                        div()
                            .flex_1()
                            .min_w(p(0.))
                            .bg(palette.card_background)
                            .border_t_1()
                            .border_l_1()
                            .border_color(palette.stroke)
                            .rounded_tl(p(8.))
                            .overflow_hidden()
                            .child(page),
                    ),
            )
    }
}

fn main() {
    let mut page = Page::Performance;
    let mut selection = Resource::Cpu;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match (arg.as_str(), args.next().as_deref()) {
            ("--page", Some("processes")) => page = Page::Processes,
            ("--page", Some("performance")) => page = Page::Performance,
            ("--resource", Some("memory")) => selection = Resource::Memory,
            ("--resource", Some("gpu")) => selection = Resource::Gpu(0),
            ("--resource", Some("cpu")) => selection = Resource::Cpu,
            _ => {
                eprintln!(
                    "usage: TaskManagerGPUI [--page performance|processes] [--resource cpu|memory|gpu]"
                );
                std::process::exit(2);
            }
        }
    }

    Application::new().run(move |cx: &mut App| {
        let bounds = Bounds::centered(None, size(px(1100.), px(720.)), cx);
        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                titlebar: Some(TitlebarOptions {
                    title: Some("Task Manager".into()),
                    appears_transparent: true,
                    traffic_light_position: Some(point(px(20.), px(18.))),
                }),
                window_min_size: Some(size(px(980.), px(660.))),
                focus: true,
                ..Default::default()
            },
            |window, cx| cx.new(|cx| Root::new(page, selection, window, cx)),
        )
        .expect("failed to open the window");
        cx.on_window_closed(|cx| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();
        cx.activate(true);
    });
}
