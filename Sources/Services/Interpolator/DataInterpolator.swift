import Foundation
import CoreLocation

/// 负责将稀疏数据插值为平滑流的引擎
final class DataInterpolator: Sendable {
    private let points: [TrajectoryPoint]
    private let startTime: Double
    private let endTime: Double
    
    enum FrequencyMode {
        case sparse    // 1Hz 左右，需要强补帧
        case highFreq  // 10Hz 及以上，需要忠实还原
    }
    let mode: FrequencyMode
    
    init(points: [TrajectoryPoint]) {
        self.points = points.sorted { $0.ts < $1.ts }
        self.startTime = self.points.first?.ts ?? 0
        self.endTime = self.points.last?.ts ?? 0
        
        if points.count > 1 {
            let avgInterval = (endTime - startTime) / Double(points.count - 1)
            self.mode = avgInterval < 0.25 ? .highFreq : .sparse
        } else {
            self.mode = .sparse
        }
    }
    
    func state(at timestamp: Double) -> InterpolatedState? {
        guard timestamp >= startTime, timestamp <= endTime else { return nil }
        
        guard let index = points.firstIndex(where: { $0.ts >= timestamp }) else { return nil }
        if index == 0 { return makeState(from: points[0]) }
        
        let p1 = points[index - 1]
        let p2 = points[index]
        
        let t = (timestamp - p1.ts) / (p2.ts - p1.ts)
        
        // 1. 基础物理量插值 (使用平滑步进)
        let lat = p1.lat + (p2.lat - p1.lat) * t
        let lng = p1.lng + (p2.lng - p1.lng) * t
        let smoothT = t * t * (3 - 2 * t)
        let speed = p1.speed + (p2.speed - p1.speed) * smoothT
        
        // 2. 纵向 G 值插值 (增强型逻辑)
        var gX: Double = 0
        if let ax1 = p1.ax, let ax2 = p2.ax {
            gX = ax1 + (ax2 - ax1) * t
        } else if mode == .highFreq {
            // 高频模式下缺失点处理：寻找最近的有效值
            gX = (p1.ax ?? p2.ax ?? 0)
        } else {
            let dv = p2.speed - p1.speed
            let dt = p2.ts - p1.ts
            gX = dt > 0 ? (dv / dt) / 9.81 : 0
        }
        
        // 3. 横向 G 值插值
        var gY: Double = 0
        if let ay1 = p1.ay, let ay2 = p2.ay {
            gY = ay1 + (ay2 - ay1) * t
        } else if mode == .highFreq {
            gY = (p1.ay ?? p2.ay ?? 0)
        } else {
            let heading1 = calculateHeading(from: p1, to: p2)
            let p0 = index > 1 ? points[index - 2] : p1
            let heading0 = calculateHeading(from: p0, to: p1)
            var dHeading = heading1 - heading0
            if dHeading > 180 { dHeading -= 360 }
            if dHeading < -180 { dHeading += 360 }
            let dt = p2.ts - p1.ts
            let omega = dt > 0 ? (dHeading * Double.pi / 180.0) / dt : 0
            gY = (speed * omega) / 9.81
        }
        
        return InterpolatedState(
            timestamp: timestamp,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            speed: speed,
            gForceLongitudinal: gX,
            gForceLateral: gY
        )
    }
    
    private func calculateHeading(from: TrajectoryPoint, to: TrajectoryPoint) -> Double {
        let lat1 = from.lat * Double.pi / 180; let lon1 = from.lng * Double.pi / 180
        let lat2 = to.lat * Double.pi / 180; let lon2 = to.lng * Double.pi / 180
        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return atan2(y, x) * 180 / Double.pi
    }
    
    private func makeState(from point: TrajectoryPoint) -> InterpolatedState {
        return InterpolatedState(
            timestamp: point.ts,
            coordinate: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng),
            speed: point.speed,
            gForceLongitudinal: point.ax ?? 0,
            gForceLateral: point.ay ?? 0
        )
    }
    
    func calculateGForceRange() -> (min: Double, max: Double) {
        var minG = -0.5; var maxG = 0.5
        let step = max(1.0, (endTime - startTime) / 100.0)
        var t = startTime
        while t <= endTime {
            if let s = state(at: t) {
                minG = min(minG, s.gForceLongitudinal, s.gForceLateral)
                maxG = max(maxG, s.gForceLongitudinal, s.gForceLateral)
            }
            t += step
        }
        let padding = (maxG - minG) * 0.2
        return (minG - padding, maxG + padding)
    }
}

struct InterpolatedState: Sendable {
    let timestamp: Double; let coordinate: CLLocationCoordinate2D; let speed: Double 
    let gForceLongitudinal: Double; let gForceLateral: Double
    var speedKmh: Double { speed * 3.6 }
}
