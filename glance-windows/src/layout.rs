use crate::types::{Rect, ScreenRegion, WindowMetrics, WindowSlot};
use std::collections::HashMap;

/// Mission Control-style layout engine.
///
/// Distributes thumbnail windows across multiple screens in a grid,
/// avoiding the main window's area on its screen.
///
/// This is a faithful port of the macOS `MissionControlLayoutEngine`
/// (ThumbnailLayoutEngine.swift).
pub struct MissionControlLayoutEngine {
    pub edge_padding: f64,
    pub item_spacing: f64,
    pub minimum_thumbnail_height: f64,
    /// Space reserved above each thumbnail for the title header.
    pub header_height: f64,
}

impl Default for MissionControlLayoutEngine {
    fn default() -> Self {
        Self {
            edge_padding: 8.0,
            item_spacing: 16.0,
            minimum_thumbnail_height: 80.0,
            header_height: 32.0,
        }
    }
}

impl MissionControlLayoutEngine {
    // ------------------------------------------------------------------
    // Public entry point
    // ------------------------------------------------------------------

    pub fn layout(&self, screens: &[ScreenRegion], windows: &[WindowMetrics]) -> Vec<WindowSlot> {
        if windows.is_empty() || screens.is_empty() {
            return Vec::new();
        }

        // Step 1: Compute available zones per screen.
        let mut screen_zones: Vec<(usize, Vec<Rect>)> = Vec::new();
        for region in screens {
            let zones = self.compute_zones(&region.screen_frame, region.excluded_rect.as_ref());
            if !zones.is_empty() {
                screen_zones.push((region.screen_index, zones));
            }
        }
        if screen_zones.is_empty() {
            return Vec::new();
        }

        // Step 2: Distribute windows to screens (prefer original screen).
        let distribution = self.distribute_windows(windows, &screen_zones);

        // Step 3: Layout each screen's windows within its zones.
        let mut all_slots: Vec<WindowSlot> = Vec::new();
        for (screen_index, assigned_windows) in &distribution {
            if let Some(entry) = screen_zones.iter().find(|(idx, _)| idx == screen_index) {
                let slots =
                    self.layout_in_zones(&entry.1, assigned_windows, *screen_index);
                all_slots.extend(slots);
            }
        }

        all_slots
    }

    // ------------------------------------------------------------------
    // Zone Computation
    // ------------------------------------------------------------------

    /// Compute available rectangular zones from a screen, excluding the main
    /// window rect.
    ///
    /// Adaptively prioritises the direction (horizontal or vertical) with more
    /// available space, giving those zones full extent while constraining the
    /// other direction to the excluded rect's span.
    pub fn compute_zones(&self, screen_frame: &Rect, excluded_rect: Option<&Rect>) -> Vec<Rect> {
        let padded = screen_frame.inset_by(self.edge_padding, self.edge_padding);

        let excluded = match excluded_rect {
            Some(ex) => ex,
            None => return vec![padded],
        };

        let ex = match padded.intersection(excluded) {
            Some(r) if r.width > 10.0 && r.height > 10.0 => r,
            _ => return vec![padded],
        };

        let top_gap = padded.max_y() - ex.max_y() - self.item_spacing;
        let bottom_gap = ex.min_y() - padded.min_y() - self.item_spacing;
        let left_gap = ex.min_x() - padded.min_x() - self.item_spacing;
        let right_gap = padded.max_x() - ex.max_x() - self.item_spacing;

        // Decide which direction has more usable space and give it priority.
        let prioritize_sides = f64::max(left_gap, right_gap) > f64::max(top_gap, bottom_gap);

        let mut zones: Vec<Rect> = Vec::new();

        if prioritize_sides {
            // Side zones get full screen height.
            let has_left = left_gap >= self.minimum_thumbnail_height;
            if has_left {
                zones.push(Rect::new(
                    padded.min_x(),
                    padded.min_y(),
                    left_gap,
                    padded.height(),
                ));
            }

            let has_right = right_gap >= self.minimum_thumbnail_height;
            if has_right {
                zones.push(Rect::new(
                    ex.max_x() + self.item_spacing,
                    padded.min_y(),
                    right_gap,
                    padded.height(),
                ));
            }

            // Top/bottom zones span only the inner width.
            let inner_min_x = if has_left {
                padded.min_x() + left_gap + self.item_spacing
            } else {
                padded.min_x()
            };
            let inner_max_x = if has_right {
                padded.max_x() - right_gap - self.item_spacing
            } else {
                padded.max_x()
            };
            let inner_w = inner_max_x - inner_min_x;

            if top_gap >= self.minimum_thumbnail_height && inner_w >= self.minimum_thumbnail_height {
                zones.push(Rect::new(
                    inner_min_x,
                    ex.max_y() + self.item_spacing,
                    inner_w,
                    top_gap,
                ));
            }

            if bottom_gap >= self.minimum_thumbnail_height
                && inner_w >= self.minimum_thumbnail_height
            {
                zones.push(Rect::new(inner_min_x, padded.min_y(), inner_w, bottom_gap));
            }
        } else {
            // Top/bottom zones get full screen width.
            let has_top = top_gap >= self.minimum_thumbnail_height;
            if has_top {
                zones.push(Rect::new(
                    padded.min_x(),
                    ex.max_y() + self.item_spacing,
                    padded.width(),
                    top_gap,
                ));
            }

            let has_bottom = bottom_gap >= self.minimum_thumbnail_height;
            if has_bottom {
                zones.push(Rect::new(
                    padded.min_x(),
                    padded.min_y(),
                    padded.width(),
                    bottom_gap,
                ));
            }

            // Side zones span only the inner height.
            let side_min_y = if has_bottom {
                padded.min_y() + bottom_gap + self.item_spacing
            } else {
                padded.min_y()
            };
            let side_max_y = if has_top {
                padded.max_y() - top_gap - self.item_spacing
            } else {
                padded.max_y()
            };
            let side_h = side_max_y - side_min_y;

            if left_gap >= self.minimum_thumbnail_height && side_h >= self.minimum_thumbnail_height {
                zones.push(Rect::new(padded.min_x(), side_min_y, left_gap, side_h));
            }

            if right_gap >= self.minimum_thumbnail_height && side_h >= self.minimum_thumbnail_height
            {
                zones.push(Rect::new(
                    ex.max_x() + self.item_spacing,
                    side_min_y,
                    right_gap,
                    side_h,
                ));
            }
        }

        if zones.is_empty() {
            // No excluded rect (non-work-area screen) -> use the full screen.
            // Has excluded rect but no usable space around it -> return empty
            // so all windows overflow to other screens.
            if excluded_rect.is_none() {
                vec![padded]
            } else {
                Vec::new()
            }
        } else {
            zones
        }
    }

    // ------------------------------------------------------------------
    // Window Distribution
    // ------------------------------------------------------------------

    fn distribute_windows(
        &self,
        windows: &[WindowMetrics],
        screen_zones: &[(usize, Vec<Rect>)],
    ) -> Vec<(usize, Vec<WindowMetrics>)> {
        let mut assignments: HashMap<usize, Vec<WindowMetrics>> = HashMap::new();
        for entry in screen_zones {
            assignments.insert(entry.0, Vec::new());
        }

        // Compute area per screen for load balancing.
        let screen_areas: HashMap<usize, f64> = screen_zones
            .iter()
            .map(|(idx, zones)| {
                let area: f64 = zones.iter().map(|z| z.width() * z.height()).sum();
                (*idx, area)
            })
            .collect();
        let total_area: f64 = screen_areas.values().sum();
        if total_area <= 0.0 {
            return assignments.into_iter().collect();
        }

        // Phase 1: Place manually-assigned windows unconditionally.
        let mut auto_windows: Vec<WindowMetrics> = Vec::new();
        for w in windows {
            if w.is_manually_assigned {
                if let Some(pref_idx) = w.original_screen_index {
                    if assignments.contains_key(&pref_idx) {
                        assignments.get_mut(&pref_idx).unwrap().push(w.clone());
                        continue;
                    }
                }
            }
            auto_windows.push(w.clone());
        }

        // Phase 2: Group remaining by preferred screen, then cap to fair share.
        let mut preferred: HashMap<usize, Vec<WindowMetrics>> = HashMap::new();
        for key in assignments.keys() {
            preferred.insert(*key, Vec::new());
        }
        let mut overflow: Vec<WindowMetrics> = Vec::new();

        for w in &auto_windows {
            if let Some(pref_idx) = w.original_screen_index {
                if preferred.contains_key(&pref_idx) {
                    preferred.get_mut(&pref_idx).unwrap().push(w.clone());
                    continue;
                }
            }
            overflow.push(w.clone());
        }

        let total_windows = windows.len();
        let mut capacities: HashMap<usize, usize> = HashMap::new();

        for (screen_idx, window_list) in &preferred {
            let area = *screen_areas.get(screen_idx).unwrap_or(&1.0);
            let base_capacity =
                ((total_windows as f64) * area / total_area).ceil().max(1.0) as usize;
            let manual_count = assignments.get(screen_idx).map_or(0, |v| v.len());
            let remaining = base_capacity.saturating_sub(manual_count);
            capacities.insert(*screen_idx, base_capacity);

            if window_list.len() > remaining {
                let (take, spill) = window_list.split_at(remaining);
                assignments.get_mut(screen_idx).unwrap().extend_from_slice(take);
                overflow.extend_from_slice(spill);
            } else {
                assignments
                    .get_mut(screen_idx)
                    .unwrap()
                    .extend_from_slice(window_list);
            }
        }

        // Phase 3: Distribute overflow to screens that still have room.
        // Tiebreaker by screen index for deterministic ordering.
        for w in overflow {
            let under_capacity: Vec<usize> = assignments
                .iter()
                .filter(|(k, v)| v.len() < *capacities.get(k).unwrap_or(&usize::MAX))
                .map(|(k, _)| *k)
                .collect();

            let pool: Vec<usize> = if under_capacity.is_empty() {
                assignments.keys().copied().collect()
            } else {
                under_capacity
            };

            let target = pool.iter().min_by(|&&a, &&b| {
                let a_area = screen_areas.get(&a).copied().unwrap_or(1.0);
                let b_area = screen_areas.get(&b).copied().unwrap_or(1.0);
                let a_count = assignments.get(&a).map_or(0, |v| v.len());
                let b_count = assignments.get(&b).map_or(0, |v| v.len());
                let density_a = a_count as f64 / a_area;
                let density_b = b_count as f64 / b_area;
                if (density_a - density_b).abs() > 1e-9 {
                    density_a.partial_cmp(&density_b).unwrap()
                } else {
                    a.cmp(&b)
                }
            });

            if let Some(&key) = target {
                assignments.get_mut(&key).unwrap().push(w);
            }
        }

        assignments.into_iter().collect()
    }

    // ------------------------------------------------------------------
    // Grid Layout Within Zones
    // ------------------------------------------------------------------

    fn layout_in_zones(
        &self,
        zones: &[Rect],
        windows: &[WindowMetrics],
        screen_index: usize,
    ) -> Vec<WindowSlot> {
        if windows.is_empty() || zones.is_empty() {
            return Vec::new();
        }

        if zones.len() == 1 {
            return self.grid_layout(&zones[0], windows, screen_index);
        }

        // Sort zones by area descending — fill the best zones first so overflow
        // (from rounding) lands in the largest zone rather than a thin strip.
        // Tiebreaker by position for deterministic ordering.
        let mut sorted_zones: Vec<Rect> = zones.to_vec();
        sorted_zones.sort_by(|a, b| {
            let a_area = a.width() * a.height();
            let b_area = b.width() * b.height();
            if (a_area - b_area).abs() > 1.0 {
                return b_area.partial_cmp(&a_area).unwrap(); // descending
            }
            if (a.min_y() - b.min_y()).abs() > 1.0 {
                return b.min_y().partial_cmp(&a.min_y()).unwrap(); // descending
            }
            a.min_x().partial_cmp(&b.min_x()).unwrap() // ascending
        });

        let total_area: f64 = sorted_zones.iter().map(|z| z.width() * z.height()).sum();

        // Compute proportional window counts per zone.
        let mut counts: Vec<usize> = sorted_zones
            .iter()
            .map(|zone| {
                (windows.len() as f64 * (zone.width() * zone.height() / total_area)).round()
                    as usize
            })
            .collect();

        // Fix rounding drift — add/remove difference to the largest zone.
        let sum: usize = counts.iter().sum();
        if windows.len() >= sum {
            counts[0] += windows.len() - sum;
        } else {
            counts[0] = counts[0].saturating_sub(sum - windows.len());
        }

        let mut remaining = &windows[..];
        let mut all_slots: Vec<WindowSlot> = Vec::new();

        for (i, zone) in sorted_zones.iter().enumerate() {
            let count = counts[i].min(remaining.len());
            if count == 0 {
                continue;
            }
            let (batch, rest) = remaining.split_at(count);
            remaining = rest;
            all_slots.extend(self.grid_layout(zone, batch, screen_index));
        }

        // Safety: any remaining go to the largest zone.
        if !remaining.is_empty() {
            all_slots.extend(self.grid_layout(&sorted_zones[0], remaining, screen_index));
        }

        all_slots
    }

    /// Lay out windows in a grid: binary search for the max thumbnail height
    /// that fits all windows using greedy line-wrapping (like text reflow).
    ///
    /// Each slot includes `header_height` at the top for the title label;
    /// aspect-ratio math uses only the image portion (slot height - header).
    fn grid_layout(
        &self,
        rect: &Rect,
        windows: &[WindowMetrics],
        screen_index: usize,
    ) -> Vec<WindowSlot> {
        if windows.is_empty() {
            return Vec::new();
        }

        let avail_w = rect.width();
        let avail_h = rect.height();
        let ratios: Vec<f64> = windows.iter().map(|w| w.aspect_ratio.max(0.3)).collect();
        let h_h = self.header_height;

        // Cap the search to the tallest original window (+ header) — never upscale beyond native size.
        let max_orig_h = windows
            .iter()
            .map(|w| w.original_height)
            .fold(f64::NEG_INFINITY, f64::max)
            .max(avail_h)
            .min(f64::INFINITY);
        // Use avail_h as fallback if no valid heights.
        let max_orig_h = if max_orig_h.is_finite() {
            max_orig_h + h_h
        } else {
            avail_h
        };

        // Binary search for the maximum slot height (image + header) that fits.
        let mut lo = self.minimum_thumbnail_height;
        let mut hi = avail_h.min(max_orig_h);
        let mut best_h = lo;

        for _ in 0..30 {
            let mid = (lo + hi) / 2.0;
            let img_h = mid - h_h;
            if img_h <= 0.0 {
                hi = mid;
                continue;
            }
            let rows = self.pack_rows(&ratios, img_h, avail_w);
            let total_h = (rows.len() as f64) * mid
                + (rows.len().saturating_sub(1) as f64) * self.item_spacing;
            if total_h <= avail_h {
                best_h = mid;
                lo = mid;
            } else {
                hi = mid;
            }
            if hi - lo < 0.5 {
                break;
            }
        }

        let image_h = best_h - h_h;
        if image_h <= 0.0 {
            return Vec::new();
        }

        // Generate final layout at best_h.
        let rows = self.pack_rows(&ratios, image_h, avail_w);
        let total_h = (rows.len() as f64) * best_h
            + (rows.len().saturating_sub(1) as f64) * self.item_spacing;

        // Center the entire grid vertically.
        let start_y = rect.min_y() + (avail_h - total_h) / 2.0;

        let mut slots: Vec<WindowSlot> = Vec::new();

        for (row_idx, row_indices) in rows.iter().enumerate() {
            // Row 0 at top. On Windows (top-left origin), top = lowest y value.
            // row_idx=0 → y = start_y, row_idx=1 → y = start_y + best_h + spacing, etc.
            let row_y = start_y
                + row_idx as f64 * best_h
                + row_idx as f64 * self.item_spacing;

            // Width is based on image height, not total slot height.
            let mut widths: Vec<f64> = row_indices.iter().map(|&i| ratios[i] * image_h).collect();
            let total_w: f64 = widths.iter().sum::<f64>()
                + (row_indices.len().saturating_sub(1) as f64) * self.item_spacing;

            let mut row_img_h = image_h;
            let mut row_slot_h = best_h;
            if total_w > avail_w {
                let net_w: f64 = widths.iter().sum();
                let scale = (avail_w
                    - (row_indices.len().saturating_sub(1) as f64) * self.item_spacing)
                    / net_w;
                widths = widths.iter().map(|&w| w * scale).collect();
                row_img_h = image_h * scale;
                row_slot_h = row_img_h + h_h;
            }

            let actual_total_w: f64 = widths.iter().sum::<f64>()
                + (row_indices.len().saturating_sub(1) as f64) * self.item_spacing;
            let mut x = rect.min_x() + (avail_w - actual_total_w) / 2.0;
            let y = row_y + (best_h - row_slot_h) / 2.0;

            for (i, &win_idx) in row_indices.iter().enumerate() {
                // Cap each window to its original image size — never upscale.
                let orig_h = windows[win_idx].original_height;
                let capped_img_h = row_img_h.min(orig_h);
                let capped_w = widths[i].min(ratios[win_idx] * orig_h);
                let slot_h = capped_img_h + h_h;
                let slot_rect = Rect::new(
                    x + (widths[i] - capped_w) / 2.0,
                    y + (row_slot_h - slot_h) / 2.0,
                    capped_w,
                    slot_h,
                );
                slots.push(WindowSlot {
                    window_id: windows[win_idx].window_id,
                    rect: slot_rect,
                    screen_index,
                });
                x += widths[i] + self.item_spacing;
            }
        }

        slots
    }

    /// Greedy line-wrap: pack window indices into rows at a given image height.
    fn pack_rows(&self, ratios: &[f64], image_h: f64, avail_w: f64) -> Vec<Vec<usize>> {
        let mut rows: Vec<Vec<usize>> = vec![Vec::new()];
        let mut current_row_width: f64 = 0.0;

        for i in 0..ratios.len() {
            let w = ratios[i] * image_h;
            let width_with_spacing = if current_row_width > 0.0 {
                current_row_width + self.item_spacing + w
            } else {
                w
            };

            if width_with_spacing <= avail_w || rows.last().unwrap().is_empty() {
                // Fits in current row (or row is empty — must place at least one).
                rows.last_mut().unwrap().push(i);
                current_row_width = width_with_spacing;
            } else {
                // Start a new row.
                rows.push(vec![i]);
                current_row_width = w;
            }
        }

        rows
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_engine() -> MissionControlLayoutEngine {
        MissionControlLayoutEngine::default()
    }

    #[test]
    fn empty_input_returns_empty() {
        let engine = make_engine();
        assert!(engine.layout(&[], &[]).is_empty());
        let screen = ScreenRegion {
            screen_index: 0,
            screen_frame: Rect::new(0.0, 0.0, 1920.0, 1080.0),
            excluded_rect: None,
        };
        assert!(engine.layout(&[screen], &[]).is_empty());
    }

    #[test]
    fn single_window_single_screen() {
        let engine = make_engine();
        let screen = ScreenRegion {
            screen_index: 0,
            screen_frame: Rect::new(0.0, 0.0, 1920.0, 1080.0),
            excluded_rect: None,
        };
        let win = WindowMetrics {
            window_id: 1,
            aspect_ratio: 16.0 / 9.0,
            original_screen_index: Some(0),
            original_height: 600.0,
            is_manually_assigned: false,
        };
        let slots = engine.layout(&[screen], &[win]);
        assert_eq!(slots.len(), 1);
        assert_eq!(slots[0].screen_index, 0);
        assert!(slots[0].rect.width() > 0.0);
        assert!(slots[0].rect.height() > 0.0);
    }

    #[test]
    fn zones_without_exclusion() {
        let engine = make_engine();
        let zones = engine.compute_zones(
            &Rect::new(0.0, 0.0, 1920.0, 1080.0),
            None,
        );
        assert_eq!(zones.len(), 1);
        // Should be the padded rect.
        let z = &zones[0];
        assert!((z.min_x() - 8.0).abs() < 0.01);
        assert!((z.min_y() - 8.0).abs() < 0.01);
        assert!((z.width() - 1904.0).abs() < 0.01);
        assert!((z.height() - 1064.0).abs() < 0.01);
    }

    #[test]
    fn pack_rows_basic() {
        let engine = make_engine();
        // Three windows with 16:9 ratio at image height 200 => width = ~355.56 each
        // Available width = 1000 => first row fits 2 (711.12 + 16 = 727.12 ok; + 355.56 + 16 = 1098.68 > 1000)
        // Second row gets 1
        let ratios = vec![16.0 / 9.0, 16.0 / 9.0, 16.0 / 9.0];
        let rows = engine.pack_rows(&ratios, 200.0, 1000.0);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].len(), 2);
        assert_eq!(rows[1].len(), 1);
    }

    #[test]
    fn rect_intersection() {
        let a = Rect::new(0.0, 0.0, 100.0, 100.0);
        let b = Rect::new(50.0, 50.0, 100.0, 100.0);
        let inter = a.intersection(&b).unwrap();
        assert!((inter.x - 50.0).abs() < 0.01);
        assert!((inter.y - 50.0).abs() < 0.01);
        assert!((inter.width() - 50.0).abs() < 0.01);
        assert!((inter.height() - 50.0).abs() < 0.01);

        let c = Rect::new(200.0, 200.0, 10.0, 10.0);
        assert!(a.intersection(&c).is_none());
    }

    #[test]
    fn rect_to_win_rect() {
        let r = Rect::new(10.5, 20.3, 100.7, 50.9);
        let wr = r.to_win_rect();
        assert_eq!(wr.left, 11); // 10.5 rounds to 11
        assert_eq!(wr.top, 20);  // 20.3 rounds to 20
        assert_eq!(wr.right, 111); // (10.5 + 100.7 = 111.2) rounds to 111
        assert_eq!(wr.bottom, 71); // (20.3 + 50.9 = 71.2) rounds to 71
    }
}
