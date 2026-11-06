//! A Task Manager style graph: grid, filled area and line, newest value on the right.
//! An optional second series is drawn as a dashed line (write vs read, send vs receive).
//!
//! Painted with quads only, one or two per pixel column. GPUI draws paths through a 4x MSAA
//! texture the size of the window, which costs over 60 MB of GPU memory once any path is drawn
//! (measured on the Performance page); quads go straight into the frame.

use crate::monitor::{HISTORY_LENGTH, History};
use crate::theme::with_alpha;
use gpui::{Bounds, Canvas, Pixels, Rgba, Styled, Window, canvas, fill, outline, point, px, size};

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
        if width <= px(1.) || height <= px(1.) {
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

        self.paint_series(&self.values, bounds, window, true);
        if let Some(secondary) = &self.secondary {
            self.paint_series(secondary, bounds, window, false);
        }

        window.paint_quad(outline(bounds, self.color, Default::default()));
    }

    /// Walks the graph one pixel column at a time: the area below the line as one translucent
    /// quad, and the line as a 1 px wide quad spanning this column's and the next one's height.
    /// The secondary series skips columns to look dashed (4 on, 3 off).
    fn paint_series(
        &self,
        history: &History,
        bounds: Bounds<Pixels>,
        window: &mut Window,
        primary: bool,
    ) {
        let samples = history.values();
        let count = samples.len().min(HISTORY_LENGTH);
        if count < 2 || self.max_value <= 0. {
            return;
        }
        let width = f32::from(bounds.size.width);
        let height = f32::from(bounds.size.height);
        let step = width / (HISTORY_LENGTH - 1) as f32;
        let start_x = step * (HISTORY_LENGTH - count) as f32;
        let y_at = |x: f32| -> f32 {
            let position = ((x - start_x) / step).clamp(0., (count - 1) as f32);
            let index = (position.floor() as usize).min(count - 2);
            let fraction = (position - index as f32) as f64;
            let value = samples[index] * (1. - fraction) + samples[index + 1] * fraction;
            height * (1. - (value / self.max_value).clamp(0., 1.) as f32)
        };

        let line = self.color;
        let area = with_alpha(self.color, 0.15);
        let columns = (width - start_x).floor().max(0.) as usize;
        let mut y = y_at(start_x);
        for column in 0..columns {
            let x = start_x + column as f32;
            let next = y_at(x + 1.);
            if primary && y < height {
                window.paint_quad(fill(
                    Bounds::new(
                        point(bounds.origin.x + px(x), bounds.origin.y + px(y)),
                        size(px(1.), px(height - y)),
                    ),
                    area,
                ));
            }
            if primary || column % 7 < 4 {
                let top = y.min(next).min(height - 1.);
                let bottom = y.max(next).max(top + 1.);
                window.paint_quad(fill(
                    Bounds::new(
                        point(bounds.origin.x + px(x), bounds.origin.y + px(top)),
                        size(px(1.), px(bottom - top)),
                    ),
                    line,
                ));
            }
            y = next;
        }
    }
}
