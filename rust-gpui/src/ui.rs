//! Shared page chrome: page header, captions, stats and labeled graphs.

use crate::graph::Graph;
use crate::theme::{Palette, p, size, space};
use gpui::{AnyElement, Div, FontWeight, IntoElement, ParentElement, Styled, div};

/// Top bar of every page: title on the left, command buttons on the right.
pub fn page_header(title: &str, palette: &Palette, actions: impl IntoElement) -> Div {
    div()
        .flex()
        .flex_none()
        .items_center()
        .justify_between()
        .h(p(size::PAGE_HEADER))
        .px(p(space::XL))
        .border_b_1()
        .border_color(palette.stroke)
        .child(
            div()
                .text_size(p(20.))
                .font_weight(FontWeight::SEMIBOLD)
                .child(title.to_string()),
        )
        .child(actions)
}

pub fn resource_header(title: String, subtitle: String, palette: &Palette) -> Div {
    div()
        .flex()
        .flex_none()
        .items_end()
        .justify_between()
        .gap(p(space::L))
        .child(div().text_size(p(28.)).child(title))
        .child(
            div()
                .text_size(p(14.))
                .text_color(palette.secondary_text)
                .whitespace_nowrap()
                .overflow_hidden()
                .text_ellipsis()
                .child(subtitle),
        )
}

pub fn caption_row(leading: String, trailing: String, palette: &Palette) -> Div {
    div()
        .flex()
        .flex_none()
        .justify_between()
        .text_size(p(11.))
        .text_color(palette.secondary_text)
        .child(leading)
        .child(trailing)
}

/// Caption, graph that fills the remaining height, and a "0" caption, like Windows.
pub fn labeled_graph(title: &str, graph: Graph, top_label: String, palette: &Palette) -> Div {
    div()
        .flex()
        .flex_col()
        .flex_1()
        .min_h(p(60.))
        .gap(p(space::XS))
        .child(caption_row(title.to_string(), top_label, palette))
        .child(div().flex_1().child(graph.element()))
}

pub struct Stat {
    pub label: String,
    pub value: String,
    /// Legend swatch drawn before the label (solid, or dashed for the second series).
    pub legend: Option<(gpui::Rgba, bool)>,
}

pub fn stat(label: impl Into<String>, value: impl Into<String>) -> Stat {
    Stat {
        label: label.into(),
        value: value.into(),
        legend: None,
    }
}

impl Stat {
    pub fn legend(mut self, color: gpui::Rgba, dashed: bool) -> Self {
        self.legend = Some((color, dashed));
        self
    }
}

/// Large values in rows on the left, a two-column label/value list on the right.
pub fn stats_area(rows: Vec<Vec<Stat>>, info: Vec<(String, String)>, palette: &Palette) -> Div {
    let stats = div()
        .flex()
        .flex_col()
        .gap(p(space::M))
        .children(rows.into_iter().map(|row| {
            div()
                .flex()
                .gap(p(space::XL))
                .children(row.into_iter().map(|stat| stat_element(stat, palette)))
        }));
    let info = div()
        .flex()
        .gap(p(space::L))
        .text_size(p(13.))
        .child(
            div()
                .flex()
                .flex_col()
                .gap(p(space::XXS))
                .text_color(palette.secondary_text)
                .children(info.iter().map(|(label, _)| div().child(label.clone()))),
        )
        .child(
            div()
                .flex()
                .flex_col()
                .gap(p(space::XXS))
                .children(info.iter().map(|(_, value)| div().child(value.clone()))),
        );
    div()
        .flex()
        .flex_none()
        .gap(p(48.))
        .pt(p(space::S))
        .child(stats)
        .child(info)
}

fn stat_element(stat: Stat, palette: &Palette) -> AnyElement {
    let label = div()
        .flex()
        .items_center()
        .gap(p(space::XS))
        .text_size(p(11.))
        .text_color(palette.secondary_text)
        .when_some(stat.legend, |label, (color, dashed)| {
            let swatch = div().w(p(12.)).h(p(0.)).border_t_1().border_color(color);
            label.child(if dashed {
                swatch.border_dashed()
            } else {
                swatch
            })
        })
        .child(stat.label);
    div()
        .flex()
        .flex_col()
        .min_w(p(90.))
        .child(label)
        .child(div().text_size(p(20.)).child(stat.value))
        .into_any_element()
}

use gpui::prelude::FluentBuilder;
