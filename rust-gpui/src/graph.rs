//! A Task Manager style graph: grid, filled area and line, newest value on the right.
//! An optional second series is drawn as a dashed line (write vs read, send vs receive).
//! Painted directly with GPUI quads and paths, so a graph has no element tree of its own.

use crate::monitor::{HISTORY_LENGTH, History};
use crate::theme::with_alpha;
use gpui::{
    Bounds, Canvas, PathBuilder, Pixels, Point, Rgba, Styled, Window, canvas, fill, outline, point,
    px, size,
};

pub struct Graph {
    pub values: History,
    pub color: Rgba,
    pub secondary: Option<History>,
    pub max_value: f64,
    pub shows_grid: bool,
}

impl Graph {
    pub fn new(values: &History, color: Rgba) -> Self {
        Graph {
            values: values.clone(),
            color,
            secondary: None,
            max_value: 1.,
            shows_grid: true,
        }
    }

    pub fn secondary(mut self, values: &History) -> Self {
        self.secondary = Some(values.clone());
        self
    }

    pub fn max_value(mut self, value: f64) -> Self {
        self.max_value = value;
        self
    }

    pub fn without_grid(mut self) -> Self {
        self.shows_grid = false;
        self
    }

    pub fn element(self) -> Canvas<()> {
        canvas(
            |_, _, _| {},
            move |bounds, _, window, _| self.paint(bounds, window),
        )
        .size_full()
    }

    fn paint(&self, bounds: Bounds<Pixels>, window: &mut Window) {
        let width = bounds.size.width;
        let height = bounds.size.height;
        if width <= px(0.) || height <= px(0.) {
            return;
        }
        let origin = bounds.origin;

        if self.shows_grid {
            let grid = with_alpha(self.color, 0.12);
            for i in 1..10 {
                let x = (width * (i as f32 / 10.)).round();
                window.paint_quad(fill(
                    Bounds::new(point(origin.x + x, origin.y), size(px(1.), height)),
                    grid,
                ));
                let y = (height * (i as f32 / 10.)).round();
                window.paint_quad(fill(
                    Bounds::new(point(origin.x, origin.y + y), size(width, px(1.))),
                    grid,
                ));
            }
        }

        if let Some(points) = self.points(self.values.values().iter().copied(), bounds) {
            let mut area = PathBuilder::fill();
            area.move_to(points[0]);
            for point in &points[1..] {
                area.line_to(*point);
            }
            area.line_to(point(points[points.len() - 1].x, origin.y + height));
            area.line_to(point(points[0].x, origin.y + height));
            area.close();
            if let Ok(path) = area.build() {
                window.paint_path(path, with_alpha(self.color, 0.15));
            }
            stroke(window, &points, self.color, None);
        }

        if let Some(secondary) = &self.secondary
            && let Some(points) = self.points(secondary.values().iter().copied(), bounds)
        {
            stroke(window, &points, self.color, Some(&[px(4.), px(3.)]));
        }

        window.paint_quad(outline(bounds, self.color, Default::default()));
    }

    fn points(
        &self,
        samples: impl ExactSizeIterator<Item = f64>,
        bounds: Bounds<Pixels>,
    ) -> Option<Vec<Point<Pixels>>> {
        let count = samples.len().min(HISTORY_LENGTH);
        if count < 2 || self.max_value <= 0. {
            return None;
        }
        let step = bounds.size.width / (HISTORY_LENGTH - 1) as f32;
        let offset = HISTORY_LENGTH - count;
        let height = bounds.size.height;
        Some(
            samples
                .take(count)
                .enumerate()
                .map(|(i, value)| {
                    let value = (value / self.max_value).clamp(0., 1.) as f32;
                    point(
                        bounds.origin.x + step * (offset + i) as f32,
                        bounds.origin.y + height * (1. - value),
                    )
                })
                .collect(),
        )
    }
}

fn stroke(window: &mut Window, points: &[Point<Pixels>], color: Rgba, dashes: Option<&[Pixels]>) {
    let mut line = PathBuilder::stroke(px(1.));
    if let Some(dashes) = dashes {
        line = line.dash_array(dashes);
    }
    line.move_to(points[0]);
    for point in &points[1..] {
        line.line_to(*point);
    }
    if let Ok(path) = line.build() {
        window.paint_path(path, color);
    }
}
