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
    // Plain, evenly lit flooring can have good LiDAR returns. Only the monocular path needs edges.
    var exposed: Bool {
        pixels.lazy.filter { (19..<238).contains($0) }.count >= pixels.count / 3
    }
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
    enum Surface { case unclassified, floor, nonFloor }
    let y:Double, polygon:[V3]
    var surface: Surface = .unclassified
    func contains(_ p:V3) -> Bool {
        var inside=false, j=polygon.count-1
        for i in polygon.indices {
            let a=polygon[i], b=polygon[j]
            if (a.z>p.z) != (b.z>p.z), p.x < (b.x-a.x)*(p.z-a.z)/(b.z-a.z)+a.x { inside.toggle() }
            j=i
        }; return inside
    }
}

private struct StripAxes {
    let along, across: V3
    init(_ pose: FramePose, _ angle: Int) {
        let a = (pose.heading + Double(angle)) * .pi / 180
        along = V3(sin(a), 0, -cos(a))
        across = V3(cos(a), 0, sin(a))
    }
}

private func unassessed(_ pose: FramePose, _ observations: [Sighting]) -> NearField {
    NearField(pose: pose, visible: false,
              sectors: stride(from: -60, through: 60, by: 15).map { Sector(angle: $0, state: .unknown) },
              hazards: observations.filter { $0.kind.mobile })
}

private func comparable(_ earlier: FramePose, _ now: FramePose, angle: Double, displacement: Double) -> Bool {
    earlier.id.sameWorld(now.id) && earlier.id.frame < now.id.frame && now.time > earlier.time &&
        now.time - earlier.time < 0.5 && earlier.sameView(as: now, within: angle) &&
        (earlier.position - now.position).length < displacement
}

private extension FramePose {
    var hasDepthCalibration: Bool {
        width > 0 && height > 0 && time.isFinite && transform.count == 16 && intrinsics.count == 9 &&
            transform.allSatisfy(\.isFinite) && intrinsics.allSatisfy(\.isFinite) && intrinsics[0] > 0 && intrinsics[4] > 0
    }
}

/// Shared by the camera adapter and pixel/pose replays. Ranges are optical-axis depths in metres.
final class GroundAssessment {
    private var previous: (pose: FramePose, image: FloorImage)?
    private var floorHeight: Double?
    private var viewpoints: [(pose: FramePose, image: FloorImage)] = []
    private var visualBody = StepBodySurvey()
    private var lidar = LidarPassage()
    private let distances = [0.75, 1.10, 1.50, 1.85]
    private let laterals = [-0.27, 0.0, 0.27]

    func inspect(image: FloorImage?, pose p: FramePose, planes: [FloorPatch], features: [V3],
                 observations: [Sighting], personOK: Bool, depth: (((Double, Double)) -> Double?)? = nil) -> NearField {
        // Range-only replays supply already confidence-filtered native sensor coordinates.
        if let depth {
            let map = LidarDepthFrame(pose: p, width: p.width, height: p.height) { x, y in
                depth(((Double(x) + 0.5) / Double(p.width), (Double(y) + 0.5) / Double(p.height))).map { ($0, 2) }
            }
            return inspectLidar(pose: p, depth: map, planes: planes, observations: observations,
                                personOK: personOK, exposed: image?.exposed == true, image: image)
        }
        lidar = LidarPassage()
        visualBody.expire(at: p)
        viewpoints.removeAll { !$0.pose.id.sameWorld(p.id) || p.time - $0.pose.time > 0.5 }
        let planes = planes.filter { $0.surface != .nonFloor }
        var field = unassessed(p, observations)
        guard let image, image.visible, p.normal else {
            previous = nil
            floorHeight = nil
            if !p.normal { visualBody = StepBodySurvey(); viewpoints.removeAll() }
            field.reason = "画面或位置追踪不清。"
            return field
        }
        field.visible = true
        field.canCoachFraming = personOK
        let prior = previous
        previous = (p, image)
        let secondView = viewpoints.last { reference in
            comparable(reference.pose, p, angle: 10, displacement: 0.20) && reference.pose.position.groundDistance(p.position) >= 0.04
        }
        if viewpoints.last?.pose.id != p.id { viewpoints.append((p, image)) }
        if viewpoints.count > 10 { viewpoints.removeFirst() }
        let priorView = prior.flatMap { comparable($0.pose, p, angle: 10, displacement: 0.23) ? $0 : nil }
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
                                              features: features)
                if let descent { sector.stepEvidence = descent }
                if !sector.hasMeasuredDrop && !mobile && elevated == nil {
                    sampleStrip(&sector, p, ground: ground, aim: aim, side: side, image: image, previous: priorView,
                                features: features, canClear: field.reason == nil)
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
        guard let center = field.sectors.firstIndex(where: { $0.angle == 0 }), let ground,
              personOK, ground.surface == .floor || (1.10...1.95).contains(p.position.y-ground.y),
              field.sectors[center].state != .occupied, field.sectors[center].stepEvidence != .conflictingPlanes else {
            visualBody = StepBodySurvey()
            return field
        }
        // A normal camera cannot frame the floor and an adult's head at every holding angle.
        // At this station combine only sites individually seen in two matching, translated views.
        let pair = secondView.map { reference -> VisualStepRays in
            let matches = features.compactMap { point -> VisualStepRays.Match? in
                guard let here = inView(point, p), let there = inView(point, reference.pose),
                      agrees(image, at: here, with: reference.image, at: there) else { return nil }
                return .init(point: point, u: here.0, v: here.1, oldU: there.0, oldV: there.1)
            }
            return .init(pose: p, peer: reference.pose, ground: ground, matches: matches)
        }
        let axes = StripAxes(p, 0), sites = StepVolume.sites(p, axes.along, axes.across, ground.y)
        let witnesses = visualBody.observe(sites, at: p, level: ground.y, peer: secondView?.pose) { site in
            pair?.seesThrough(site) == true
        }
        if var coverage = field.sectors[center].stepCoverage {
            coverage.body = witnesses != nil; coverage.bodyFrame = witnesses?.oldest.id; coverage.bodyTime = witnesses?.oldest.time
            coverage.bodyFrames = witnesses?.frames; coverage.checkedBodySites = visualBody.checkedSites
            field.sectors[center].stepCoverage = coverage
        }
        if let pair, field.reason == nil { field.liveStepView = LiveStepView(pair) }
        return field
    }

    func inspectLidar(pose p: FramePose, depth: LidarDepthFrame?, planes: [FloorPatch], observations: [Sighting],
                      personOK: Bool, exposed: Bool, image: FloorImage? = nil) -> NearField {
        // On a monocular-to-depth transition a matched, reprojected previous image and near
        // plane can corroborate a fully measured current strip. Live LiDAR uses depth/depth pairs.
        let prior = previous, priorLevel = floorHeight
        visualBody = StepBodySurvey(); viewpoints.removeAll()
        previous = nil
        floorHeight = nil
        return lidar.inspect(p, depth: depth, planes: planes, observations: observations, personOK: personOK,
                             exposed: exposed, bands: image?.hasHorizontalBands == true) { axes, level in
            guard let prior, let priorLevel, let image, abs(level - priorLevel) < 0.05,
                  comparable(prior.pose, p, angle: 5, displacement: 0.10) else { return false }
            for d in distances {
                for x in laterals {
                    let site = p.position + axes.along * d + axes.across * x
                    let q = V3(site.x, level, site.z)
                    guard let uv = inView(q, p), let ab = inView(q, prior.pose),
                          agrees(image, at: uv, with: prior.image, at: ab, needsTexture: false) else { return false }
                }
            }
            return true
        }
    }

    private func inView(_ point: V3, _ p: FramePose) -> (Double, Double)? {
        guard let uv = p.project(point), (0.025...0.975).contains(uv.0), (0.025...0.975).contains(uv.1) else { return nil }
        return uv
    }

    /// A visible, adjacent lower landing must have some surface area. Overlapping fitted planes
    /// need current returns at the lower level before we can resolve which surface is exposed.
    private func landingEvidence(_ p: FramePose, ground: FloorPatch, lower: [FloorPatch], aim: V3, side: V3,
                                 features: [V3]) -> StepEvidence? {
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
                          inView(left, p) != nil, inView(right, p) != nil else { continue }
                    if !ground.contains(q) && ground.contains(q - aim * 0.36) { return .measuredDrop(q) }
                    let hits = features.filter { abs($0.y - patch.y) < 0.05 && $0.groundDistance(q) < 0.23 && patch.contains($0) }
                    if hits.contains(where: { ($0 - q).dot(side) < -0.04 }) && hits.contains(where: { ($0 - q).dot(side) > 0.04 }) {
                        return .measuredDrop(q)
                    }
                }
            }
        }
        return ambiguous ? .conflictingPlanes : nil
    }

    private func sampleStrip(_ sector: inout Sector, _ p: FramePose, ground: FloorPatch, aim: V3, side: V3,
                             image: FloorImage, previous: (pose: FramePose, image: FloorImage)?, features: [V3],
                             canClear: Bool) {
        guard canClear, let previous, sector.stepEvidence != .conflictingPlanes else { return }
        let coarse = sector.stepEvidence == .systemClassification
        for distance in distances {
            for lateral in laterals {
                let onStrip = p.position + aim * distance + side * lateral
                let q = V3(onStrip.x, ground.y, onStrip.z)
                guard ground.contains(q), let uv = inView(q, p), let ab = inView(q, previous.pose),
                      agrees(image, at: uv, with: previous.image, at: ab),
                      features.contains(where: { point in
                          abs(point.y - ground.y) < (coarse ? 0.04 : 0.065) &&
                              abs((point - q).dot(side)) < 0.16 && point.groundDistance(q) < (coarse ? 0.16 : 0.32)
                      }) else { return }
            }
        }
        sector.state = .free
        // A positive visual-inertial fallback requires the close floor and actual feature rays
        // reaching behind the walking volume in two views. Empty space between sparse features is unknown.
        guard sector.angle == 0 else { return }
        func floorSeen(_ depths: [Double]) -> Bool {
            depths.allSatisfy { d in [-0.24, -0.12, 0, 0.12, 0.24].allSatisfy { x in
                let site = p.position + aim * d + side * x, q = V3(site.x, ground.y, site.z)
                guard ground.contains(q), let uv = inView(q, p), let ab = inView(q, previous.pose),
                      agrees(image, at: uv, with: previous.image, at: ab) else { return false }
                return features.contains { abs($0.y - ground.y) < 0.05 && $0.groundDistance(q) <= 0.11 }
            } }
        }
        let near = floorSeen([0.30, 0.46]), landing = floorSeen([0.62, 0.78, 0.96])
        sector.stepCoverage = StepCoverage(source: .multiView, nearGround: near, landing: landing, body: false)
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

/// One capture in native (unrotated) sensor coordinates. The read callback is synchronous.
/// Only the temporary numeric lattice and its near-field hits survive the pixel-buffer locks.
struct LidarDepthFrame {
    let capture: FrameID
    fileprivate let hits: [V3]
    private let columns, rows: Int
    private let ranges: [Float]

    init?(pose p: FramePose, width: Int, height: Int, sample: (Int, Int) -> (metres: Double, confidence: UInt8)?) {
        guard width > 0, height > 0, p.hasDepthCalibration, p.normal,
              abs((Double(width) / Double(height)) / (Double(p.width) / Double(p.height)) - 1) < 0.02 else { return nil }
        capture = p.id
        let stride = max(1, Int(ceil(Double(max(width, height)) / 144)))
        let columns = max(1, width / stride), rows = max(1, height / stride)
        self.columns = columns
        self.rows = rows
        var ranges = [Float](repeating: 0, count: columns * rows), hits: [V3] = []
        hits.reserveCapacity(ranges.count)
        let right = V3(p.transform[0], p.transform[1], p.transform[2])
        let up = V3(p.transform[4], p.transform[5], p.transform[6])
        let position = p.position, forward = p.forward
        // Pixel centres in the depth raster map into the full-resolution camera intrinsics.
        // The ray has optical-axis component 1. Normalizing it would turn axial depth into range.
        let xs = (0..<columns).map { (2 * $0 + 1) * width / (2 * columns) }
        let rays = xs.map { x in
            forward + right * (((Double(x) + 0.5) * Double(p.width) / Double(width) - p.intrinsics[6]) / p.intrinsics[0])
        }
        for j in 0..<rows {
            let y = (2 * j + 1) * height / (2 * rows)
            let row = up * ((p.intrinsics[7] - (Double(y) + 0.5) * Double(p.height) / Double(height)) / p.intrinsics[4])
            for i in 0..<columns {
                guard let s = sample(xs[i], y), (1...2).contains(s.confidence), (0.20...5.0).contains(s.metres) else { continue }
                ranges[j * columns + i] = Float(s.metres)
                let offset = (rays[i] + row) * s.metres
                if offset.x * offset.x + offset.z * offset.z <= 2.15 * 2.15 { hits.append(position + offset) }
            }
        }
        self.hits = hits
        self.ranges = ranges
    }

    fileprivate func measuresFloor(_ point: V3, at p: FramePose) -> Bool {
        guard let uv = p.project(point) else { return false }
        let (u,v) = p.sensor(uv.0,uv.1)
        guard (0.02...0.98).contains(u), (0.02...0.98).contains(v) else { return false }
        let x = Int(u * Double(columns)), y = Int(v * Double(rows))
        guard x > 0, x < columns-1, y > 0, y < rows-1 else { return false }
        let expected = Float((point - p.position).dot(p.forward))
        var agreeing = 0
        for j in (y-1)...(y+1) { for i in (x-1)...(x+1) {
            if abs(ranges[j * columns + i] - expected) < 0.06 { agreeing += 1 }
        } }
        return agreeing >= 5
    }

    /// Clearance through a body-volume site also needs rays reaching at least that far.
    /// A nearer occluder or a blind depth region cannot be filled from visible floor behind it.
    fileprivate func seesThrough(_ point: V3, at p: FramePose) -> Bool {
        guard let uv = p.project(point) else { return false }
        let (u, v) = p.sensor(uv.0, uv.1)
        guard (0..<1).contains(u), (0..<1).contains(v) else { return false }
        let x = Int(u * Double(columns)), y = Int(v * Double(rows))
        guard x > 0, x < columns - 1, y > 0, y < rows - 1 else { return false }
        let needed = Float((point - p.position).dot(p.forward) + 0.03)
        var through = 0
        for j in (y-1)...(y+1) { for i in (x-1)...(x+1) {
            if ranges[j * columns + i] >= needed { through += 1 }
        } }
        return through >= 5
    }
}

/// Pixel-matched AR features at two capture poses. A distant feature only witnesses a
/// body sample when its ray passes the same site in both images.
struct VisualStepRays {
    struct Match { let point: V3, u: Double, v: Double, oldU: Double, oldV: Double }
    let pose: FramePose, peer: FramePose, ground: FloorPatch, matches: [Match]
    func measuresFloor(_ site: V3) -> Bool {
        ground.contains(site) && abs(ground.y-site.y) < 0.045 && matches.contains {
            abs($0.point.y-site.y) < 0.045 && site.groundDistance($0.point) <= 0.11
        }
    }
    func seesThrough(_ site: V3) -> Bool {
        guard let here = pose.project(site), let there = peer.project(site),
              (0.025...0.975).contains(there.0), (0.025...0.975).contains(there.1) else { return false }
        let toward = pose.forward, earlier = peer.forward
        var left = false, right = false
        for match in matches where hypot(match.u-here.0, match.v-here.1) < 0.035 && hypot(match.oldU-there.0, match.oldV-there.1) < 0.035 {
            let beyond = match.point-site
            guard beyond.dot(toward) > 0.12, beyond.dot(earlier) > 0.12 else { continue }
            if match.u < here.0 { left = true } else if match.u > here.0 { right = true }
            if left && right { return true }
        }
        return false
    }
}

/// Keep a body-height sample across a pitch sweep at the same station. A newer in-frame
/// observation that cannot confirm the sample invalidates its immediately preceding witness.
struct StepBodySurvey {
    private struct Witness { let pose: FramePose, first: FramePose, level: Double, site: V3 }
    private var witnesses: [Int: Witness] = [:]
    var checkedSites: UInt32 { witnesses.keys.reduce(0) { $0 | (1 << $1) } }
    mutating func expire(at pose: FramePose) {
        witnesses = witnesses.filter { _, w in
            w.pose.id.sameWorld(pose.id) && (0...0.65).contains(pose.time-w.first.time) &&
                (pose.position-w.pose.position).length < 0.055 && abs(turnAngle(pose.heading-w.pose.heading)) < 5
        }
    }
    mutating func observe(_ sites: [V3], at pose: FramePose, level: Double, peer: FramePose? = nil,
                          through: (V3) -> Bool) -> (oldest: FramePose, frames: [FrameID])? {
        for (index, site) in sites.enumerated() {
            if let uv = pose.project(site), (0.025...0.975).contains(uv.0), (0.025...0.975).contains(uv.1) {
                witnesses[index] = through(site) ? .init(pose: pose, first: peer ?? pose, level: level, site: site) : nil
            } else if let old = witnesses[index], abs(old.level-level) >= 0.045 || (old.site-site).length >= 0.065 {
                witnesses[index] = nil
            }
        }
        guard witnesses.count == sites.count, let oldest = witnesses.values.min(by: { $0.first.time < $1.first.time })?.first else { return nil }
        let frames = Set(witnesses.values.flatMap { [$0.first.id, $0.pose.id] })
        return (oldest, frames.sorted { $0.frame < $1.frame })
    }
}

/// Current confidence-filtered rays, kept only in local recent observation history. These may monitor
/// the remainder of a spoken permit, never create a new one or extend its inspected footprint.
struct LiveStepView {
    private enum Samples { case depth(LidarDepthFrame), visual(VisualStepRays) }
    private let samples: Samples, capture: FrameID, level: Double
    fileprivate init(depth: LidarDepthFrame, level: Double) { samples = .depth(depth); capture = depth.capture; self.level = level }
    fileprivate init(_ pair: VisualStepRays) { samples = .visual(pair); capture = pair.pose.id; level = pair.ground.y }
    private func measuresFloor(_ q: V3, at p: FramePose) -> Bool {
        switch samples { case .depth(let d): return d.measuresFloor(q, at: p); case .visual(let v): return v.measuresFloor(q) }
    }
    private func seesThrough(_ q: V3, at p: FramePose) -> Bool {
        switch samples { case .depth(let d): return d.seesThrough(q, at: p); case .visual(let v): return v.seesThrough(q) }
    }
    func watches(_ permit: StepPermit, at p: FramePose) -> Bool {
        let check = permit.spokenCheck ?? permit.check, origin = permit.check.origin
        guard p.normal, capture == p.id, p.id.sameWorld(origin.id), let started = permit.spokenAt,
              p.time >= started, let oldestBody = check.coverage.compactMap(\.bodyTime).max(),
              abs(turnAngle(p.heading - origin.heading)) <= 16 else { return false }
        let axis = StripAxes(origin,0), progress = (p.position-origin.position).dot(axis.along)
        func visible(_ q: V3) -> Bool {
            guard let uv = p.project(q) else { return false }
            return (0.035...0.965).contains(uv.0) && (0.035...0.965).contains(uv.1)
        }
        for x in [-0.23, 0.0, 0.23] {
            var floors = 0, volume = 0, high = false
            for d in [0.30,0.46,0.62,0.78,0.96] where d > progress + 0.055 {
                let site = origin.position + axis.along*d + axis.across*x
                let foot = V3(site.x,level,site.z)
                if visible(foot) { guard measuresFloor(foot, at:p) else { return false }; floors += 1 }
            }
            for d in [0.56,0.90] where d > progress + 0.055 {
                let site = origin.position + axis.along*d + axis.across*x
                for h in check.footprint.bodyHeights {
                    let q = V3(site.x,level+h,site.z)
                    if visible(q) {
                        guard seesThrough(q, at:p) else { return false }
                        volume += 1; if h >= 1.05 { high = true }
                    } else if p.time - oldestBody > 1.50 { return false }
                }
            }
            guard floors > 0, volume >= 2, high else { return false }
        }
        return true
    }
}

private struct LidarPassage {
    private var newest: (id: FrameID, time: Double)?
    private var previous: (pose: FramePose, level: Double, clear: Set<Int>)?
    // A prior level may veto a sudden rebase at the same station. It cannot supply missing returns.
    private var station: (pose: FramePose, level: Double)?
    // At the same station a slightly raised view can observe torso height before the close floor is framed.
    private var bodySurvey = StepBodySurvey()

    /// A classified floor at the observer supplies a level, never clearance. An unclassified
    /// horizontal anchor might be furniture: require the same local support as for no anchor.
    private func approachLevel(_ p: FramePose, _ hits: [V3], _ planes: [FloorPatch]) -> Double? {
        let position = p.position
        let anchors = planes.filter { patch in
            let height = position.y - patch.y
            return patch.surface != .nonFloor && patch.contains(position) &&
                (patch.surface == .floor ? (0.55...2.15) : (1.10...1.95)).contains(height)
        }
        let levels = anchors.filter { $0.surface == .floor }.map(\.y)
        if let low = levels.min(), let high = levels.max() { return high - low < 0.07 ? (high + low) / 2 : nil }

        let labelled = planes.filter { $0.surface != .unclassified }
        var near: [(offset: V3, radius: Double)] = [], inner: [Double] = []
        for q in hits {
            let d = q - position, radius = hypot(d.x, d.z), height = -d.y
            guard radius < 0.92, (0.55...2.15).contains(height) else { continue }
            let onPatch: (FloorPatch) -> Bool = { abs($0.y - q.y) < 0.055 && $0.contains(q) }
            guard !labelled.contains(where: { $0.surface == .nonFloor && onPatch($0) }),
                  (1.10...1.95).contains(height) || labelled.contains(where: { $0.surface == .floor && onPatch($0) }) else { continue }
            near.append((d, radius))
            if radius < 0.67 { inner.append(q.y) }
        }
        guard inner.count >= 12 else { return nil }
        inner.sort()
        let level = inner[inner.count / 2]
        guard inner.filter({ abs($0 - level) <= 0.035 }).count * 4 >= inner.count * 3,
              anchors.allSatisfy({ abs($0.y - level) < 0.07 }) else { return nil }
        // Look for a connected 30 cm wide patch close to the observer, including on either
        // side of a central occlusion. A horizontal line on a wall cannot set the level.
        let inliers = near.filter { abs(position.y + $0.offset.y - level) <= 0.035 }
        for direction in [0, -40, 40] {
            let axes = StripAxes(p, direction)
            var masks = [UInt8](repeating: 0, count: 8)
            for hit in inliers {
                let ahead = hit.offset.dot(axes.along), across = hit.offset.dot(axes.across)
                guard (0.22..<0.84).contains(ahead), (-0.40..<0.40).contains(across) else { continue }
                let column = min(7, Int((across + 0.40) / 0.10))
                if ahead < 0.64 {
                    if hit.radius < 0.67 { masks[column] |= 1 }
                } else { masks[column] |= ahead < 0.74 ? 2 : 4 }
            }
            if (0..<6).contains(where: { masks[$0...($0+2)].allSatisfy { $0 == 7 } }) { return level }
        }
        return nil
    }

    mutating func inspect(_ p: FramePose, depth: LidarDepthFrame?, planes: [FloorPatch], observations: [Sighting],
                          personOK: Bool, exposed: Bool, bands: Bool, previousImageProof: (StripAxes, Double) -> Bool) -> NearField {
        var field = unassessed(p, observations)
        if let newest, newest.id.sameWorld(p.id), (newest.id.frame >= p.id.frame || newest.time >= p.time) {
            field.reason = "等待新的近场帧。"
            return field
        }
        newest = (p.id, p.time)
        let prior = previous
        previous = nil
        bodySurvey.expire(at: p)
        if !p.normal { bodySurvey = StepBodySurvey(); station = nil }
        guard exposed, p.hasDepthCalibration, p.normal else { field.reason = "画面或位置追踪不清。"; return field }
        field.canCoachFraming = personOK
        let hits = depth?.capture == p.id ? depth?.hits ?? [] : []
        field.visible = !hits.isEmpty || !field.hazards.isEmpty
        let level = approachLevel(p, hits, planes)
        if let old = station, !old.pose.id.sameWorld(p.id) || old.pose.position.groundDistance(p.position) > 0.40 { station = nil }
        if hits.isEmpty { field.reason = "近场深度或置信度不足。" }
        else if !personOK { field.reason = "人员检测暂不可用。" }
        else if !p.observesGround { field.reason = "前方地面未进入有效视野。" }
        else if level == nil { field.reason = "尚未确认脚边地面高度。" }
        if let level, let old = station, abs(old.level - level) > 0.10 { field.reason = "地面基准高度发生变化。" }
        var previousClear = Set<Int>()
        if let prior, let level, abs(prior.level - level) < 0.055, comparable(prior.pose, p, angle: 5, displacement: 0.12) {
            previousClear = prior.clear
        }
        let excluded = planes.filter { $0.surface == .nonFloor }
        if !personOK || !exposed || hits.isEmpty || level == nil { bodySurvey = StepBodySurvey() }
        let steps = observations.filter { $0.kind == .steps && $0.box.valid }
        var clear = Set<Int>()
        for i in field.sectors.indices {
            var sector = field.sectors[i]
            let axes = StripAxes(p, sector.angle)
            if bands && p.stripIntersects(.init(0.28, 0.53, 0.72, 0.93), at: sector.angle) { sector.stepEvidence = .horizontalBands }
            if steps.contains(where: { p.stripIntersects($0.box, at: sector.angle) }) { sector.stepEvidence = .systemClassification }
            let mobile = field.hazards.contains { $0.kind.mobile && p.stripIntersects($0.box, at: sector.angle) }
            let strip = LidarStrip(p, axes, hits, level: level, excluded: excluded)
            sector.nearest = strip.obstacle
            if let drop = strip.drop {
                sector.stepEvidence = .measuredDrop(drop)
                sector.nearest = min(sector.nearest ?? .infinity, (drop - p.position).dot(axes.along))
                if let uv = p.project(drop), !field.hazards.contains(where: { $0.kind == .steps }) {
                    let box = ImageBox(max(0,uv.0-0.025), max(0,uv.1-0.02), min(1,uv.0+0.025), min(1,uv.1+0.02))
                    if box.valid { field.hazards.append(.init(kind: .steps, box: box, confidence: 0.85)) }
                }
            }
            if sector.angle == 0 {
                if mobile || sector.nearest != nil || strip.hasConflict { bodySurvey = StepBodySurvey() }
                else if let depth, let level, personOK, !hits.isEmpty {
                    if field.reason == nil { field.liveStepView = LiveStepView(depth: depth, level: level) }
                    let sites = StepVolume.sites(p, axes.along, axes.across, level)
                    let witnesses = bodySurvey.observe(sites, at: p, level: level) { depth.seesThrough($0, at: p) }
                    sector.stepCoverage = .init(source: .lidar, nearGround: strip.floorCovered(rows: 1..<3),
                        landing: strip.floorCovered(rows: 3..<6), body: witnesses != nil, bodyFrame: witnesses?.oldest.id,
                        bodyTime: witnesses?.oldest.time, bodyFrames: witnesses?.frames, checkedBodySites: bodySurvey.checkedSites)
                }
            }
            if mobile || sector.nearest != nil { sector.state = .occupied }
            else if field.reason == nil, let level, let depth, strip.hasClearance(p, axes, level, depth) {
                clear.insert(sector.angle)
                if previousClear.contains(sector.angle) || previousImageProof(axes, level) { sector.state = .free }
            }
            field.sectors[i] = sector
        }
        if let level {
            previous = (p, level, clear)
            if station == nil, field.sectors.contains(where: { $0.state == .free || $0.hasMeasuredDrop }) { station = (p, level) }
        }
        return field
    }
}

private enum StepVolume {
    static func sites(_ p: FramePose, _ along: V3, _ across: V3, _ level: Double) -> [V3] {
        [0.56, 0.90].flatMap { d in [-0.22, 0.0, 0.22].flatMap { x in
            let site = p.position + along * d + across * x
            return StepFootprint().bodyHeights.map { V3(site.x, level + $0, site.z) }
        } }
    }
}

/// Gravity-aligned 60 cm wide strip. Each 16 × 12 cm cell votes in four quadrants. Near-to-far
/// coverage needs three quadrants per cell, so isolated missing rays are fine, missing lanes are not.
private struct LidarStrip {
    private struct Cell {
        var flat: UInt8 = 0, lower: UInt8 = 0
        var lowMin = Double.infinity, lowMax = -Double.infinity
        var lowerPoint: V3?, elevatedPoint: V3?
        var elevatedCount = 0, elevatedSpan = 0.0, nearest = Double.infinity
    }
    private static let rows = 12, columns = 5
    private var cells = [Cell](repeating: Cell(), count: rows * columns)
    private(set) var obstacle: Double?
    private var disputed = false

    init(_ pose: FramePose, _ axes: StripAxes, _ hits: [V3], level: Double?, excluded: [FloorPatch]) {
        let position = pose.position
        for point in hits {
            let delta = point - position, ahead = delta.dot(axes.along), side = delta.dot(axes.across)
            guard (0.08..<2.0).contains(ahead), (-0.30..<0.30).contains(side) else { continue }
            let r = (ahead - 0.08) / 0.16, c = (side + 0.30) / 0.12
            let row = min(Self.rows - 1, Int(r)), column = min(Self.columns - 1, Int(c))
            let index = row * Self.columns + column
            let quadrant: UInt8 = 1 << ((r - Double(row) < 0.5 ? 0 : 2) + (c - Double(column) < 0.5 ? 0 : 1))
            let height = level.map { point.y - $0 }
            if let height, abs(height) <= 0.045 {
                if excluded.contains(where: { abs($0.y - point.y) <= 0.055 && $0.contains(point) }) { disputed = true }
                else { cells[index].flat |= quadrant }
            } else if let height, height <= -0.11 {
                disputed = true
                cells[index].lower |= quadrant
                cells[index].lowMin = min(cells[index].lowMin, point.y)
                cells[index].lowMax = max(cells[index].lowMax, point.y)
                if cells[index].lowerPoint == nil { cells[index].lowerPoint = point }
            } else if height.map({ (0.075...1.95).contains($0) }) ?? (-0.50...0.45).contains(delta.y) {
                // Even without a floor reference a cluster at torso/camera height blocks this direction.
                disputed = true
                if let first = cells[index].elevatedPoint {
                    cells[index].elevatedSpan = max(cells[index].elevatedSpan, (point - first).length)
                } else { cells[index].elevatedPoint = point }
                cells[index].elevatedCount += 1
                cells[index].nearest = min(cells[index].nearest, ahead)
                if cells[index].elevatedCount >= 3 && cells[index].elevatedSpan >= 0.035 {
                    obstacle = min(obstacle ?? .infinity, cells[index].nearest)
                }
            }
        }
    }

    var hasConflict: Bool { disputed }
    func floorCovered(rows: Range<Int>) -> Bool {
        !disputed && rows.allSatisfy { r in
            (0..<Self.columns).allSatisfy { c in cells[r * Self.columns + c].flat.nonzeroBitCount >= 3 }
        }
    }

    func hasClearance(_ p: FramePose, _ axes: StripAxes, _ level: Double, _ depth: LidarDepthFrame) -> Bool {
        // Full width from 0.56 to 2.00 m. Also check any nearer cells the lens can actually
        // see: a blind patch at the toes must not be bridged by good returns farther away.
        guard !disputed, cells.dropFirst(3 * Self.columns).allSatisfy({ $0.flat.nonzeroBitCount >= 3 }) else { return false }
        for row in 0..<3 {
            for col in 0..<Self.columns where cells[row * Self.columns + col].flat.nonzeroBitCount < 2 {
                let site = p.position + axes.along * (0.16 + 0.16 * Double(row)) + axes.across * (0.12 * Double(col - 2))
                if let uv = p.project(V3(site.x, level, site.z)), (0.025...0.975).contains(uv.0), (0.025...0.975).contains(uv.1) {
                    return false
                }
            }
        }
        for d in [0.90, 1.55] {
            for side in [-0.23, 0, 0.23] {
                let site = p.position + axes.along * d + axes.across * side
                for height in [0.30, 0.55] where !depth.seesThrough(V3(site.x, level + height, site.z), at: p) { return false }
            }
        }
        let torso = p.position + axes.along * 0.95
        return depth.seesThrough(V3(torso.x, level + 0.85, torso.z), at: p)
    }

    var drop: V3? {
        guard disputed else { return nil }
        // Require an actual upper approach in the SAME pair of lanes immediately before a
        // two-row lower patch. One intervening bin allows for the lip's geometric occlusion.
        for r in 1..<(Self.rows-1) { for c in 0..<(Self.columns-1) {
            let i = r * Self.columns + c
            guard let witness = cells[i].lowerPoint else { continue }
            let area = [i, i+1, i+Self.columns, i+Self.columns+1]
            guard area.allSatisfy({ cells[$0].lower.nonzeroBitCount >= 2 && cells[$0].flat.nonzeroBitCount <= 1 &&
                cells[$0].lowMin >= witness.y - 0.045 && cells[$0].lowMax <= witness.y + 0.045 }) else { continue }
            for upper in max(0,r-2)..<r {
                let j = upper * Self.columns + c
                if cells[j].flat.nonzeroBitCount >= 2 && cells[j+1].flat.nonzeroBitCount >= 2 { return witness }
            }
        } }
        return nil
    }
}
