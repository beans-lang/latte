package compose

import latte.scene

pub abstract class RangeControlTemplate extends ControlTemplate {
    pub fraction: f64 = 0.0
    pub percent: f64 = 0.0
    pub number: string = "0"
    pub thumb_leading: f64 = 0.0
    pub indeterminate: bool = false
    /// The stepper half the pointer is holding: -1 none, 0 lower, 1 upper.
    pub held_half: int = -1

    pub fn init() { super.init() }

    pub override fn update(control: scene.RenderObject, theme: scene.Theme) {
        super.update(control, theme)
        match control as? scene.RangeRender {
            some(range) => {
                let fraction: f64 = range.fraction()
                let percent: f64 = fraction * 100.0
                let number: string = "{range.value()}"
                let width: f64 = control.frame().width - theme.slider_knob_width()
                let thumb_leading: f64 = range.shown_fraction() * (if width > 0.0 { width } else { 0.0 })
                var indeterminate: bool = false
                match range as? scene.ProgressBarRender { some(progress) => { indeterminate = progress.indeterminate() } none => {} }
                var held: int = -1
                match range as? scene.StepperRender { some(stepper) => { held = stepper.held_half() } none => {} }
                if self.fraction == fraction && self.percent == percent && self.number == number &&
                   self.thumb_leading == thumb_leading && self.indeterminate == indeterminate &&
                   self.held_half == held { return }
                self.fraction = fraction; self.percent = percent; self.number = number
                self.thumb_leading = thumb_leading; self.indeterminate = indeterminate
                self.held_half = held
                self.request_render()
            }
            none => {}
        }
    }
}
