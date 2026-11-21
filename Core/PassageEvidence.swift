import Foundation

/// Upright 96 × 96 samples from the current luminance plane.
struct FloorImage {
    let w=96, h=96
    let pixels: [UInt8]
    init(pixels:[UInt8]) {
        precondition(pixels.count == 96 * 96)
        self.pixels = pixels
    }
    func value(_ x:Int,_ y:Int) -> Int { Int(pixels[max(0,min(h-1,y))*w+max(0,min(w-1,x))]) }
    var visible: Bool {
        let mean=pixels.reduce(0){$0+Int($1)}/pixels.count
        var edges=0
        for y in stride(from:2,to:h-2,by:3) { for x in stride(from:2,to:w-2,by:3) {
            if abs(value(x-1,y)-value(x+1,y))+abs(value(x,y-1)-value(x,y+1)) > 14 { edges += 1 }
        } }
        return mean > 18 && mean < 238 && edges > 39
    }
    func signature(_ box:ImageBox) -> UInt64 {
        var bits:UInt64=0
        for y in 0..<8 { for x in 0..<8 {
            let xx=(box.left+(Double(x)+0.5)/9*(box.right-box.left))*Double(w)
            let yy=(box.top+(Double(y)+0.5)/8*(box.bottom-box.top))*Double(h)
            if value(Int(xx),Int(yy)) > value(Int(xx+max(1,(box.right-box.left)*Double(w)/9)),Int(yy)) { bits |= 1 << (y*8+x) }
        } }; return bits
    }
    /// Appearance cue shared by tile seams, shadows and stair nosings.
    var hasHorizontalBands: Bool {
        var rows:[Int]=[]
        for y in 51..<89 {
            let xs=27..<69
            let dark=xs.filter { value($0,y+1)-value($0,y-1) < -21 }.count
            let light=xs.filter { value($0,y+1)-value($0,y-1) > 21 }.count
            if max(dark,light)>30 && y-(rows.last ?? 0)>4 { rows.append(y) }
        }; return rows.count>=2
    }
}

struct FloorPatch {
    let y:Double, polygon:[V3]
    func contains(_ p:V3) -> Bool {
        var inside=false, j=polygon.count-1
        for i in polygon.indices {
            let a=polygon[i], b=polygon[j]
            if (a.z>p.z) != (b.z>p.z), p.x < (b.x-a.x)*(p.z-a.z)/(b.z-a.z)+a.x { inside.toggle() }
            j=i
        }; return inside
    }
}

/// Shared by the camera adapter and pixel/pose replays. Ranges are optical-axis depths in metres.
final class GroundAssessment {
    private var previous: (pose: FramePose, image: FloorImage)?
    private var floorHeight: Double?
    private let distances = [0.75, 1.10, 1.50, 1.85]
    private let laterals = [-0.27, 0.0, 0.27]

    func inspect(image: FloorImage?, pose p: FramePose, planes: [FloorPatch], features: [V3],
                 observations: [Sighting], personOK: Bool, depth: (((Double, Double)) -> Double?)? = nil) -> NearField {
        var field = NearField(pose: p, visible: false,
                              sectors: stride(from: -60, through: 60, by: 15).map { Sector(angle: $0, state: .unknown) },
                              hazards: observations.filter { $0.kind.mobile })
        guard let image, image.visible, p.normal else {
            previous = nil
            floorHeight = nil
            field.reason = "画面或位置追踪不清。"
            return field
        }
        field.visible = true
        let prior = previous
        previous = (p, image)
        let comparable = prior.flatMap { old in
            old.pose.id.sameWorld(p.id) && old.pose.id.frame < p.id.frame &&
                p.time > old.pose.time && p.time - old.pose.time < 0.5 &&
                old.pose.sameView(as: p, within: 10) && (p.position - old.pose.position).length < 0.23 ? old : nil
        }
        // Only a surface reaching the observer can establish the approach level. A landing seen
        // across an opening must not become the assumed ground beneath the camera.
        let ground = planes.filter { $0.y < p.position.y && $0.contains(p.position) }.max { $0.y < $1.y }
        if !personOK { field.reason = "人员检测暂不可用。" }
        if !(14...55).contains(p.pitchDown) { field.reason = "前方地面未进入有效视野。" }
        if let ground, let old = floorHeight, prior?.pose.id.sameWorld(p.id) == true, abs(ground.y - old) > 0.15 {
            field.reason = "地面基准高度发生变化。"
        }
        floorHeight = ground?.y
        let bands = image.hasHorizontalBands
        let bandRegion = ImageBox(0.28, 0.53, 0.72, 0.93)
        let classified = observations.filter { $0.kind == .steps && $0.box.valid }
        let lowerPlanes = ground.map { top in planes.filter { top.y - $0.y >= 0.12 } } ?? []

        for i in field.sectors.indices {
            var sector = field.sectors[i]
            let radians = (p.heading + Double(sector.angle)) * .pi / 180
            let aim = V3(sin(radians), 0, -cos(radians)), side = V3(cos(radians), 0, sin(radians))
            if bands && p.stripIntersects(bandRegion, at: sector.angle) { sector.stepEvidence = .horizontalBands }
            if classified.contains(where: { p.stripIntersects($0.box, at: sector.angle) }) { sector.stepEvidence = .systemClassification }
            let mobile = field.hazards.contains { $0.kind.mobile && p.stripIntersects($0.box, at: sector.angle) }
            if let ground {
                let elevated = features.compactMap { f -> Double? in
                    let offset = f - p.position, ahead = offset.dot(aim)
                    guard (0.18...2.05).contains(ahead), abs(offset.dot(side)) < 0.35,
                          (0.075...1.95).contains(f.y - ground.y), inView(f, p) != nil else { return nil }
                    return ahead
                }.min()
                let descent = landingEvidence(p, ground: ground, lower: lowerPlanes, aim: aim, side: side,
                                              features: features, depth: depth)
                if let descent { sector.stepEvidence = descent }
                if !sector.hasMeasuredDrop && (depth != nil || (!mobile && elevated == nil)) {
                    sampleStrip(&sector, p, ground: ground, aim: aim, side: side, image: image, previous: comparable,
                                features: features, depth: depth, canClear: field.reason == nil && !mobile && elevated == nil)
                }
                if let elevated {
                    sector.state = .occupied
                    sector.nearest = elevated
                }
                if case let .measuredDrop(point) = sector.stepEvidence {
                    sector.state = .occupied
                    sector.nearest = min(sector.nearest ?? .infinity, (point - p.position).dot(aim))
                    if let (u, v) = inView(point, p), !field.hazards.contains(where: { $0.kind == .steps }) {
                        field.hazards.append(.init(kind: .steps, box: .init(u-0.025, v-0.02, u+0.025, v+0.02), confidence: 0.85))
                    }
                }
            }
            if mobile { sector.state = .occupied }
            field.sectors[i] = sector
        }
        return field
    }

    private func inView(_ point: V3, _ p: FramePose) -> (Double, Double)? {
        guard let uv = p.project(point), (0.025...0.975).contains(uv.0), (0.025...0.975).contains(uv.1) else { return nil }
        return uv
    }

    /// A visible, adjacent lower landing must have some surface area. Overlapping fitted planes
    /// need current returns at the lower level before we can resolve which surface is exposed.
    private func landingEvidence(_ p: FramePose, ground: FloorPatch, lower: [FloorPatch], aim: V3, side: V3,
                                 features: [V3], depth: (((Double, Double)) -> Double?)?) -> StepEvidence? {
        guard !lower.isEmpty else { return nil }
        var ambiguous = false
        for distance in stride(from: 0.35, through: 1.95, by: 0.15) {
            for lateral in [0.0, -0.22, 0.22] {
                let sample = p.position + aim * distance + side * lateral
                for patch in lower where patch.contains(sample) {
                    let q = V3(sample.x, patch.y, sample.z)
                    guard inView(q, p) != nil else { continue }
                    ambiguous = true
                    let left = q - side * 0.08, right = q + side * 0.08
                    guard patch.contains(left), patch.contains(right), patch.contains(q + aim * 0.05),
                          let l = inView(left, p), let r = inView(right, p) else { continue }
                    let touchesLip = !ground.contains(q) && ground.contains(q - aim * 0.36)
                    if let depth {
                        let residuals = [(left, l), (right, r)].compactMap { point, uv -> Double? in
                            guard let range = depth(p.sensor(uv.0, uv.1)), range.isFinite, range > 0 else { return nil }
                            return abs(range - (point - p.position).dot(p.forward))
                        }
                        if residuals.contains(where: { $0 > 0.09 }) { continue }
                        if touchesLip || (residuals.count == 2 && residuals.allSatisfy { $0 < 0.055 }) { return .measuredDrop(q) }
                    } else {
                        if touchesLip { return .measuredDrop(q) }
                        let hits = features.filter { abs($0.y - patch.y) < 0.05 && $0.groundDistance(q) < 0.23 && patch.contains($0) }
                        if hits.contains(where: { ($0 - q).dot(side) < -0.04 }) && hits.contains(where: { ($0 - q).dot(side) > 0.04 }) {
                            return .measuredDrop(q)
                        }
                    }
                }
            }
        }
        return ambiguous ? .conflictingPlanes : nil
    }

    private func sampleStrip(_ sector: inout Sector, _ p: FramePose, ground: FloorPatch, aim: V3, side: V3,
                             image: FloorImage, previous: (pose: FramePose, image: FloorImage)?, features: [V3],
                             depth: (((Double, Double)) -> Double?)?, canClear: Bool) {
        var checked = 0
        var previousLowerRow: V3?
        let coarse = sector.stepEvidence == .systemClassification
        let approach = p.position + aim * 0.55
        let upper = V3(approach.x, ground.y, approach.z)
        var sawUpper = false
        if let depth, ground.contains(upper), let (u, v) = inView(upper, p), let range = depth(p.sensor(u, v)) {
            sawUpper = abs(range - (upper - p.position).dot(p.forward)) < 0.08
        }
        for distance in distances {
            var lowerRow: [V3] = []
            var flatInRow = 0
            for lateral in laterals {
                let onStrip = p.position + aim * distance + side * lateral
                let q = V3(onStrip.x, ground.y, onStrip.z)
                guard let (u, v) = inView(q, p) else { continue }
                if let depth {
                    guard let measured = depth(p.sensor(u, v)), measured.isFinite, measured > 0 else { continue }
                    let expected = (q - p.position).dot(p.forward)
                    if measured < expected - 0.14 {
                        sector.state = .occupied
                        sector.nearest = min(sector.nearest ?? .infinity, distance * measured / expected)
                    }
                    let hit = p.position + (q - p.position) * (measured / expected)
                    if ground.y - hit.y >= 0.12, (hit - p.position).dot(aim) <= 2.15, abs((hit - p.position).dot(side)) < 0.38 {
                        lowerRow.append(hit)
                    }
                    if ground.contains(q) && abs(measured - expected) < 0.10 {
                        flatInRow += 1
                        if let previous, let ab = inView(q, previous.pose),
                           agrees(image, at: (u, v), with: previous.image, at: ab, needsTexture: false) {
                            checked += 1
                        }
                    }
                } else if let previous, ground.contains(q), let (a, b) = inView(q, previous.pose),
                          agrees(image, at: (u, v), with: previous.image, at: (a, b)),
                          features.contains(where: { point in
                              abs(point.y - ground.y) < (coarse ? 0.04 : 0.065) &&
                                  abs((point - q).dot(side)) < 0.16 && point.groundDistance(q) < (coarse ? 0.16 : 0.32)
                          }) {
                    checked += 1
                }
            }
            // Two neighbouring rows with separated returns at a consistent lower elevation.
            // One distant or missing depth sample leaves the strip unknown.
            if let first = lowerRow.first, let last = lowerRow.last, last.groundDistance(first) >= 0.22, abs(last.y-first.y) < 0.06 {
                let middle = (first + last) * 0.5
                if sawUpper, let previousLowerRow, abs(previousLowerRow.y-middle.y) < 0.06 { sector.stepEvidence = .measuredDrop(previousLowerRow); return }
                previousLowerRow = middle
            } else { previousLowerRow = nil }
            if flatInRow >= 2 { sawUpper = true }
        }
        guard canClear, previous != nil, sector.state != .occupied, checked == distances.count * laterals.count,
              sector.stepEvidence != .conflictingPlanes else { return }
        sector.state = .free
    }

    private func agrees(_ current: FloorImage, at uv: (Double, Double), with prior: FloorImage, at ab: (Double, Double),
                        needsTexture: Bool = true) -> Bool {
        let x = Int(uv.0 * Double(current.w)), y = Int(uv.1 * Double(current.h))
        let a = Int(ab.0 * Double(prior.w)), b = Int(ab.1 * Double(prior.h))
        var difference = 0, minimum = current.value(x, y), maximum = minimum
        for dy in -1...1 { for dx in -1...1 {
            let sample = current.value(x+dx, y+dy)
            difference += abs(sample - prior.value(a+dx, b+dy))
            minimum = min(minimum, sample)
            maximum = max(maximum, sample)
        } }
        guard difference < 9*15 else { return false }
        if !needsTexture { return true } // A co-located depth return supplies the range on plain surfaces.
        // Include the neighbourhood of a projected floor feature on broad, flat tile stripes.
        for (dx, dy) in [(-4,0), (4,0), (0,-4), (0,4)] {
            let sample = current.value(x+dx, y+dy)
            minimum = min(minimum, sample)
            maximum = max(maximum, sample)
        }
        return maximum - minimum >= 4
    }
}
