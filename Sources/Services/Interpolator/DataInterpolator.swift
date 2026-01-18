import Foundation
import CoreLocation

/// 负责将稀疏数据插值为平滑流的引擎
final class DataInterpolator: Sendable {
    private let points: [TrajectoryPoint]
    private let startTime: Double
    private let endTime: Double
    
    init(points: [TrajectoryPoint]) {
        self.points = points.sorted { $0.ts < $1.ts }
        self.startTime = self.points.first?.ts ?? 0
        self.endTime = self.points.last?.ts ?? 0
    }
    
    func state(at timestamp: Double) -> InterpolatedState? {
        guard timestamp >= startTime, timestamp <= endTime else { return nil }
        
        guard let index = points.firstIndex(where: { $0.ts >= timestamp }) else { return nil }
        if index == 0 { return makeState(from: points[0]) }
        
        let p1 = points[index - 1]
        let p2 = points[index]
        
        let t = (timestamp - p1.ts) / (p2.ts - p1.ts)
        
        // 1. 基础物理量插值
        let lat = p1.lat + (p2.lat - p1.lat) * t
        let lng = p1.lng + (p2.lng - p1.lng) * t
        
        let smoothT = t * t * (3 - 2 * t)
        let speed = p1.speed + (p2.speed - p1.speed) * smoothT
        
        // 2. 纵向 G 值 (加速度)
        let dv = p2.speed - p1.speed
        let dt = p2.ts - p1.ts
        let accelMS2 = dt > 0 ? dv / dt : 0
        let gForceLongitudinal = accelMS2 / 9.81
        
        // 3. 横向 G 值 (基于航向角变化近似计算)
        // 计算两点之间的距离和航向变化
        let heading1 = calculateHeading(from: p1, to: p2)
        // 寻找更早的一个点来计算角速度
        let p0 = index > 1 ? points[index - 2] : p1
        let heading0 = calculateHeading(from: p0, to: p1)
        
        var dHeading = heading1 - heading0
        if dHeading > 180 { dHeading -= 360 }
        if dHeading < -180 { dHeading += 360 }
        
        // 横向加速度 a = v * omega (速度 * 角速度)
        let omega = dt > 0 ? (dHeading * Double.pi / 180.0) / dt : 0
        let gForceLateral = (speed * omega) / 9.81
        
        return InterpolatedState(
            timestamp: timestamp,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            speed: speed,
            gForceLongitudinal: gForceLongitudinal,
            gForceLateral: gForceLateral
        )
    }

    /// 计算整个行程的 G 值范围
    func calculateGForceRange() -> (min: Double, max: Double) {
        var minG = -0.5
        var maxG = 0.5
        
        // 采样整个行程来确定范围
        let step = max(1.0, (endTime - startTime) / 100.0)
        var t = startTime
        while t <= endTime {
            if let s = state(at: t) {
                minG = min(minG, s.gForceLongitudinal, s.gForceLateral)
                maxG = max(maxG, s.gForceLongitudinal, s.gForceLateral)
            }
            t += step
        }
        
        // 向上取整到 0.1，并留出 20% 的边距
        let padding = (maxG - minG) * 0.2
        minG -= padding
        maxG += padding
        
        // 确保至少有 0.2 的跨度
        if maxG - minG < 0.2 {
            maxG += 0.1
            minG -= 0.1
        }
        
        return (minG, maxG)
    }
    
    private func calculateHeading(from: TrajectoryPoint, to: TrajectoryPoint) -> Double {
        let lat1 = from.lat * Double.pi / 180
        let lon1 = from.lng * Double.pi / 180
        let lat2 = to.lat * Double.pi / 180
        let lon2 = to.lng * Double.pi / 180
        
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
            gForceLongitudinal: 0,
            gForceLateral: 0
        )
    }
}

struct InterpolatedState: Sendable {
    let timestamp: Double
    let coordinate: CLLocationCoordinate2D
    let speed: Double 
    let gForceLongitudinal: Double 
    let gForceLateral: Double // 新增横向 G 值
    
    var speedKmh: Double { speed * 3.6 }
}
