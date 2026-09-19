package scene

/// One active numeric property; all timing and values live in Beans.
class ScalarTween {
    from_value: f64
    to_value: f64
    elapsed: f64 = 0.0
    duration: f64
    easing: int
    pub fn init(from_value: f64, to_value: f64, duration: f64, easing: int) {
        self.from_value = from_value
        self.to_value = to_value
        self.duration = duration
        self.easing = easing
    }
    pub fn destination() -> f64 { return self.to_value }
    pub fn done() -> bool { return self.elapsed >= self.duration }
    pub fn advance(seconds: f64) -> f64 {
        self.elapsed += seconds
        if self.elapsed > self.duration { self.elapsed = self.duration }
        let progress: f64 = self.elapsed / self.duration
        let curved: f64 = if self.easing == 1 {
            progress * progress * (3.0 - 2.0 * progress)
        } else { progress }
        return self.from_value + (self.to_value - self.from_value) * curved
    }
}

/// Packed RGBA channels interpolate independently, including alpha zero.
class ColorTween {
    from_value: int
    to_value: int
    elapsed: f64 = 0.0
    duration: f64
    easing: int
    pub fn init(from_value: int, to_value: int, duration: f64, easing: int) {
        self.from_value = from_value
        self.to_value = to_value
        self.duration = duration
        self.easing = easing
    }
    pub fn destination() -> int { return self.to_value }
    pub fn done() -> bool { return self.elapsed >= self.duration }
    pub fn advance(seconds: f64) -> int {
        self.elapsed += seconds
        if self.elapsed > self.duration { self.elapsed = self.duration }
        let progress: f64 = self.elapsed / self.duration
        let curved: f64 = if self.easing == 1 {
            progress * progress * (3.0 - 2.0 * progress)
        } else { progress }
        let red: int = self.channel(24, curved)
        let green: int = self.channel(16, curved)
        let blue: int = self.channel(8, curved)
        let alpha: int = self.channel(0, curved)
        return (red << 24) | (green << 16) | (blue << 8) | alpha
    }
    fn channel(shift: int, progress: f64) -> int {
        let start: f64 = ((self.from_value >> shift) & 255) as f64
        let end: f64 = ((self.to_value >> shift) & 255) as f64
        return (start + (end - start) * progress) as int
    }
}
