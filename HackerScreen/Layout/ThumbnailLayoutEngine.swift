import AppKit

// MARK: - Shared Types

struct WindowMetrics {
    let windowID: CGWindowID
    let aspectRatio: CGFloat      // width / height
    let originalScreenIndex: Int? // preferred screen
    let originalHeight: CGFloat   // original window height (for capping upscale)
    let isManuallyAssigned: Bool  // user dragged to this screen — exempt from capacity cap
}

struct WindowSlot {
    let windowID: CGWindowID
    let rect: CGRect              // AppKit coordinates (bottom-left origin)
    let screenIndex: Int
}

struct ScreenRegion {
    let screenIndex: Int
    let screenFrame: CGRect       // visibleFrame in AppKit coords
    let excludedRect: CGRect?     // main window frame (AppKit coords), nil if main is on another screen
}

/// Mission Control-style layout engine.
/// Distributes thumbnail windows across multiple screens in a grid,
/// avoiding the main window's area on its screen.
struct MissionControlLayoutEngine {

    // MARK: - Parameters

    let edgePadding: CGFloat = 8
    let itemSpacing: CGFloat = 16
    let minimumThumbnailHeight: CGFloat = 80
    /// Space reserved above each thumbnail for the title header.
    let headerHeight: CGFloat = 32

    // MARK: - Public

    func layout(screens: [ScreenRegion], windows: [WindowMetrics]) -> [WindowSlot] {
        guard !windows.isEmpty, !screens.isEmpty else { return [] }

        // Step 1: Compute available zones per screen
        var screenZones: [(screenIndex: Int, zones: [CGRect])] = []
        for region in screens {
            let zones = computeZones(screenFrame: region.screenFrame, excludedRect: region.excludedRect)
            if !zones.isEmpty {
                screenZones.append((region.screenIndex, zones))
            }
        }
        guard !screenZones.isEmpty else { return [] }

        // Step 2: Distribute windows to screens (prefer original screen)
        let distribution = distributeWindows(windows: windows, screenZones: screenZones)

        // Step 3: Layout each screen's windows within its zones
        var allSlots: [WindowSlot] = []
        for (screenIndex, assignedWindows) in distribution {
            guard let entry = screenZones.first(where: { $0.screenIndex == screenIndex }) else { continue }
            let slots = layoutInZones(zones: entry.zones, windows: assignedWindows, screenIndex: screenIndex)
            allSlots.append(contentsOf: slots)
        }

        return allSlots
    }

    // MARK: - Zone Computation

    /// Compute available rectangular zones from a screen, excluding the main window rect.
    /// Adaptively prioritizes the direction (horizontal or vertical) with more available space,
    /// giving those zones full extent while constraining the other direction to the excluded rect's span.
    private func computeZones(screenFrame: CGRect, excludedRect: CGRect?) -> [CGRect] {
        let padded = screenFrame.insetBy(dx: edgePadding, dy: edgePadding)

        guard let excluded = excludedRect else {
            return [padded]
        }

        let ex = excluded.intersection(padded)
        guard !ex.isNull && ex.width > 10 && ex.height > 10 else {
            return [padded]
        }

        let topGap = padded.maxY - ex.maxY - itemSpacing
        let bottomGap = ex.minY - padded.minY - itemSpacing
        let leftGap = ex.minX - padded.minX - itemSpacing
        let rightGap = padded.maxX - ex.maxX - itemSpacing

        // Decide which direction has more usable space and give it priority.
        // The prioritized direction gets full-extent zones; the other direction
        // gets zones constrained to the excluded rect's span.
        let prioritizeSides = max(leftGap, rightGap) > max(topGap, bottomGap)

        var zones: [CGRect] = []

        if prioritizeSides {
            // Side zones get full screen height
            let hasLeft = leftGap >= minimumThumbnailHeight
            if hasLeft {
                zones.append(CGRect(x: padded.minX, y: padded.minY,
                                    width: leftGap, height: padded.height))
            }

            let hasRight = rightGap >= minimumThumbnailHeight
            if hasRight {
                zones.append(CGRect(x: ex.maxX + itemSpacing, y: padded.minY,
                                    width: rightGap, height: padded.height))
            }

            // Top/bottom zones span only the inner width (between side zones)
            let innerMinX = hasLeft ? (padded.minX + leftGap + itemSpacing) : padded.minX
            let innerMaxX = hasRight ? (padded.maxX - rightGap - itemSpacing) : padded.maxX
            let innerW = innerMaxX - innerMinX

            if topGap >= minimumThumbnailHeight && innerW >= minimumThumbnailHeight {
                zones.append(CGRect(x: innerMinX, y: ex.maxY + itemSpacing,
                                    width: innerW, height: topGap))
            }

            if bottomGap >= minimumThumbnailHeight && innerW >= minimumThumbnailHeight {
                zones.append(CGRect(x: innerMinX, y: padded.minY,
                                    width: innerW, height: bottomGap))
            }
        } else {
            // Top/bottom zones get full screen width
            let hasTop = topGap >= minimumThumbnailHeight
            if hasTop {
                zones.append(CGRect(x: padded.minX, y: ex.maxY + itemSpacing,
                                    width: padded.width, height: topGap))
            }

            let hasBottom = bottomGap >= minimumThumbnailHeight
            if hasBottom {
                zones.append(CGRect(x: padded.minX, y: padded.minY,
                                    width: padded.width, height: bottomGap))
            }

            // Side zones span only the inner height (between top/bottom zones)
            let sideMinY = hasBottom ? (padded.minY + bottomGap + itemSpacing) : padded.minY
            let sideMaxY = hasTop ? (padded.maxY - topGap - itemSpacing) : padded.maxY
            let sideH = sideMaxY - sideMinY

            if leftGap >= minimumThumbnailHeight && sideH >= minimumThumbnailHeight {
                zones.append(CGRect(x: padded.minX, y: sideMinY,
                                    width: leftGap, height: sideH))
            }

            if rightGap >= minimumThumbnailHeight && sideH >= minimumThumbnailHeight {
                zones.append(CGRect(x: ex.maxX + itemSpacing, y: sideMinY,
                                    width: rightGap, height: sideH))
            }
        }

        if zones.isEmpty {
            // No excluded rect (non-work-area screen) → use the full screen.
            // Has excluded rect but no usable space around it → return empty
            // so all windows overflow to other screens.
            return excludedRect == nil ? [padded] : []
        }
        return zones
    }

    // MARK: - Window Distribution

    private func distributeWindows(
        windows: [WindowMetrics],
        screenZones: [(screenIndex: Int, zones: [CGRect])]
    ) -> [(Int, [WindowMetrics])] {

        var assignments: [Int: [WindowMetrics]] = [:]
        for entry in screenZones {
            assignments[entry.screenIndex] = []
        }

        // Compute area per screen for load balancing
        let screenAreas: [Int: CGFloat] = Dictionary(uniqueKeysWithValues:
            screenZones.map { ($0.screenIndex, $0.zones.reduce(0) { $0 + $1.width * $1.height }) }
        )
        let totalArea = screenAreas.values.reduce(0, +)
        guard totalArea > 0 else { return assignments.map { ($0.key, $0.value) } }

        // Phase 1: Place manually-assigned windows unconditionally (user dragged them here).
        var autoWindows: [WindowMetrics] = []
        for w in windows {
            if w.isManuallyAssigned, let prefIdx = w.originalScreenIndex, assignments[prefIdx] != nil {
                assignments[prefIdx]!.append(w)
            } else {
                autoWindows.append(w)
            }
        }

        // Phase 2: Group remaining by preferred screen, then cap to fair share.
        var preferred: [Int: [WindowMetrics]] = [:]
        for key in assignments.keys { preferred[key] = [] }
        var overflow: [WindowMetrics] = []

        for w in autoWindows {
            if let prefIdx = w.originalScreenIndex, preferred[prefIdx] != nil {
                preferred[prefIdx]!.append(w)
            } else {
                overflow.append(w)
            }
        }

        let totalWindows = windows.count
        var capacities: [Int: Int] = [:]
        for (screenIdx, windowList) in preferred {
            let area = screenAreas[screenIdx] ?? 1
            let baseCapacity = max(1, Int(ceil(CGFloat(totalWindows) * area / totalArea)))
            // Subtract manually-assigned windows already placed on this screen
            let manualCount = assignments[screenIdx]?.count ?? 0
            let remaining = max(0, baseCapacity - manualCount)
            capacities[screenIdx] = baseCapacity
            if windowList.count > remaining {
                assignments[screenIdx]! += Array(windowList.prefix(remaining))
                overflow.append(contentsOf: windowList.dropFirst(remaining))
            } else {
                assignments[screenIdx]! += windowList
            }
        }

        // Phase 3: Distribute overflow to screens that still have room.
        // Tiebreaker by screen index for deterministic ordering.
        for w in overflow {
            let underCapacity = assignments.filter { $0.value.count < (capacities[$0.key] ?? Int.max) }
            let pool = underCapacity.isEmpty ? assignments : underCapacity
            let target = pool.min { a, b in
                let aArea = screenAreas[a.key] ?? 1
                let bArea = screenAreas[b.key] ?? 1
                let densityA = CGFloat(a.value.count) / aArea
                let densityB = CGFloat(b.value.count) / bArea
                if abs(densityA - densityB) > 1e-9 { return densityA < densityB }
                return a.key < b.key
            }
            if let key = target?.key {
                assignments[key]!.append(w)
            }
        }

        return assignments.map { ($0.key, $0.value) }
    }

    // MARK: - Grid Layout Within Zones

    private func layoutInZones(zones: [CGRect], windows: [WindowMetrics], screenIndex: Int) -> [WindowSlot] {
        guard !windows.isEmpty, !zones.isEmpty else { return [] }

        if zones.count == 1 {
            return gridLayout(in: zones[0], windows: windows, screenIndex: screenIndex)
        }

        // Sort zones by area descending — fill the best zones first so overflow
        // (from rounding) lands in the largest zone rather than a thin strip.
        // Tiebreaker by position for deterministic ordering.
        let sortedZones = zones.sorted {
            let a0 = $0.width * $0.height, a1 = $1.width * $1.height
            if abs(a0 - a1) > 1 { return a0 > a1 }
            if abs($0.minY - $1.minY) > 1 { return $0.minY > $1.minY }
            return $0.minX < $1.minX
        }
        let totalArea = sortedZones.reduce(0) { $0 + $1.width * $1.height }

        // Compute proportional window counts per zone
        var counts = sortedZones.map { zone -> Int in
            Int(round(CGFloat(windows.count) * (zone.width * zone.height / totalArea)))
        }

        // Fix rounding drift — add/remove difference to the largest zone
        let diff = windows.count - counts.reduce(0, +)
        counts[0] += diff

        var remaining = windows[...]
        var allSlots: [WindowSlot] = []

        for (i, zone) in sortedZones.enumerated() {
            let count = min(remaining.count, max(0, counts[i]))
            guard count > 0 else { continue }

            let batch = Array(remaining.prefix(count))
            remaining = remaining.dropFirst(count)
            allSlots.append(contentsOf: gridLayout(in: zone, windows: batch, screenIndex: screenIndex))
        }

        // Safety: any remaining go to the largest zone
        if !remaining.isEmpty {
            allSlots.append(contentsOf: gridLayout(in: sortedZones[0], windows: Array(remaining), screenIndex: screenIndex))
        }

        return allSlots
    }

    /// Lay out windows in a grid: binary search for the max thumbnail height
    /// that fits all windows using greedy line-wrapping (like text reflow).
    /// Each slot includes `headerHeight` at the top for the title label;
    /// aspect-ratio math uses only the image portion (slot height − header).
    private func gridLayout(in rect: CGRect, windows: [WindowMetrics], screenIndex: Int) -> [WindowSlot] {
        guard !windows.isEmpty else { return [] }

        let availW = rect.width
        let availH = rect.height
        let ratios = windows.map { max($0.aspectRatio, 0.3) }
        let hH = headerHeight

        // Cap the search to the tallest original window (+ header) — never upscale beyond native size
        let maxOrigH = (windows.map(\.originalHeight).max() ?? availH) + hH

        // Binary search for the maximum slot height (image + header) that fits
        var lo: CGFloat = minimumThumbnailHeight
        var hi: CGFloat = min(availH, maxOrigH)
        var bestH: CGFloat = lo

        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            let imgH = mid - hH
            guard imgH > 0 else { hi = mid; continue }
            let rows = packRows(ratios: ratios, imageH: imgH, availW: availW)
            let totalH = CGFloat(rows.count) * mid + CGFloat(max(0, rows.count - 1)) * itemSpacing
            if totalH <= availH {
                bestH = mid
                lo = mid
            } else {
                hi = mid
            }
            if hi - lo < 0.5 { break }
        }

        let imageH = bestH - hH
        guard imageH > 0 else { return [] }

        // Generate final layout at bestH
        let rows = packRows(ratios: ratios, imageH: imageH, availW: availW)
        let totalH = CGFloat(rows.count) * bestH + CGFloat(max(0, rows.count - 1)) * itemSpacing

        // Center the entire grid vertically
        let startY = rect.minY + (availH - totalH) / 2

        var slots: [WindowSlot] = []
        for (rowIdx, rowIndices) in rows.enumerated() {
            // AppKit: row 0 at top (highest y)
            let rowY = startY + totalH - CGFloat(rowIdx + 1) * bestH - CGFloat(rowIdx) * itemSpacing

            // Width is based on image height, not total slot height
            var widths = rowIndices.map { ratios[$0] * imageH }
            let totalW = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * itemSpacing

            var rowImgH = imageH
            var rowSlotH = bestH
            if totalW > availW {
                let scale = (availW - CGFloat(max(0, widths.count - 1)) * itemSpacing) / widths.reduce(0, +)
                widths = widths.map { $0 * scale }
                rowImgH = imageH * scale
                rowSlotH = rowImgH + hH
            }

            let actualTotalW = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * itemSpacing
            var x = rect.minX + (availW - actualTotalW) / 2
            let y = rowY + (bestH - rowSlotH) / 2

            for (i, winIdx) in rowIndices.enumerated() {
                // Cap each window to its original image size — never upscale
                let origH = windows[winIdx].originalHeight
                let cappedImgH = min(rowImgH, origH)
                let cappedW = min(widths[i], ratios[winIdx] * origH)
                let slotH = cappedImgH + hH
                let slotRect = CGRect(
                    x: x + (widths[i] - cappedW) / 2,
                    y: y + (rowSlotH - slotH) / 2,
                    width: cappedW,
                    height: slotH
                )
                slots.append(WindowSlot(
                    windowID: windows[winIdx].windowID,
                    rect: slotRect,
                    screenIndex: screenIndex
                ))
                x += widths[i] + itemSpacing
            }
        }

        return slots
    }

    /// Greedy line-wrap: pack window indices into rows at a given image height.
    private func packRows(ratios: [CGFloat], imageH: CGFloat, availW: CGFloat) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var currentRowWidth: CGFloat = 0

        for i in ratios.indices {
            let w = ratios[i] * imageH
            let widthWithSpacing = currentRowWidth > 0 ? currentRowWidth + itemSpacing + w : w

            if widthWithSpacing <= availW || rows.last!.isEmpty {
                // Fits in current row (or row is empty — must place at least one)
                rows[rows.count - 1].append(i)
                currentRowWidth = widthWithSpacing
            } else {
                // Start a new row
                rows.append([i])
                currentRowWidth = w
            }
        }

        return rows
    }
}
