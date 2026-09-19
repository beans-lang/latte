package paint

import latte.geometry

/// Commands retain the resources they use until this list is discarded.
/// Recording never enters the renderer. Replay is the one submission boundary.
pub abstract class PaintCommand {
    pub abstract fn replay(canvas: Canvas) -> Result<bool>
}

class SaveCommand extends PaintCommand {
    pub fn init() {}
    pub override fn replay(canvas: Canvas) -> Result<bool> { return canvas.save() }
}

class RestoreCommand extends PaintCommand {
    pub fn init() {}
    pub override fn replay(canvas: Canvas) -> Result<bool> { return canvas.restore() }
}

class TranslateCommand extends PaintCommand {
    x: f64
    y: f64
    pub fn init(x: f64, y: f64) { self.x = x; self.y = y }
    pub override fn replay(canvas: Canvas) -> Result<bool> { return canvas.translate(self.x, self.y) }
}

class RotateCommand extends PaintCommand {
    degrees: f64
    pub fn init(degrees: f64) { self.degrees = degrees }
    pub override fn replay(canvas: Canvas) -> Result<bool> { return canvas.rotate(self.degrees) }
}

class ScaleCommand extends PaintCommand {
    x: f64
    y: f64
    pub fn init(x: f64, y: f64) { self.x = x; self.y = y }
    pub override fn replay(canvas: Canvas) -> Result<bool> { return canvas.scale(self.x, self.y) }
}

class RectangleCommand extends PaintCommand {
    rect: geometry.Rect
    radius: f64
    color: int
    stroke: f64
    pub fn init(rect: geometry.Rect, radius: f64, color: int, stroke: f64) {
        self.rect = rect
        self.radius = radius
        self.color = color
        self.stroke = stroke
    }
    pub override fn replay(canvas: Canvas) -> Result<bool> {
        return canvas.rectangle(self.rect, self.radius, self.color, self.stroke)
    }
}

class EllipseCommand extends PaintCommand {
    rect: geometry.Rect
    fill: int
    outline: int
    stroke: f64
    pub fn init(rect: geometry.Rect, fill: int, outline: int, stroke: f64) {
        self.rect = rect; self.fill = fill; self.outline = outline; self.stroke = stroke
    }
    pub override fn replay(canvas: Canvas) -> Result<bool> {
        return canvas.ellipse(self.rect, self.fill, self.outline, self.stroke)
    }
}

class PathCommand extends PaintCommand {
    data: string
    fill: int
    outline: int
    stroke: f64
    pub fn init(data: string, fill: int, outline: int, stroke: f64) {
        self.data = data; self.fill = fill; self.outline = outline; self.stroke = stroke
    }
    pub override fn replay(canvas: Canvas) -> Result<bool> {
        return canvas.path(self.data, self.fill, self.outline, self.stroke)
    }
}

class VisualCommand extends PaintCommand {
    kind: int
    rect: geometry.Rect
    data: string
    style: VisualStyle
    pub fn init(kind: int, rect: geometry.Rect, data: string, style: VisualStyle) {
        self.kind = kind; self.rect = rect; self.data = data; self.style = style
    }
    pub override fn replay(canvas: Canvas) -> Result<bool> {
        return canvas.visual(self.kind, self.rect, self.data, self.style)
    }
}

class ImageCommand extends PaintCommand {
    value: ImageResource
    rect: geometry.Rect
    pub fn init(value: ImageResource, rect: geometry.Rect) { self.value = value; self.rect = rect }
    pub override fn replay(canvas: Canvas) -> Result<bool> { return canvas.image(self.value, self.rect) }
}

class ClipCommand extends PaintCommand {
    rect: geometry.Rect
    radius: f64
    pub fn init(rect: geometry.Rect, radius: f64) { self.rect = rect; self.radius = radius }
    pub override fn replay(canvas: Canvas) -> Result<bool> { return canvas.clip(self.rect, self.radius) }
}

class ParagraphCommand extends PaintCommand {
    value: Paragraph
    x: f64
    y: f64
    pub fn init(value: Paragraph, x: f64, y: f64) { self.value = value; self.x = x; self.y = y }
    pub override fn replay(canvas: Canvas) -> Result<bool> { return canvas.paragraph(self.value, self.x, self.y) }
}

pub class DisplayList implements Canvas {
    commands: List<PaintCommand> = []
    depth: int = 0
    pub fn init() {}
    pub fn count() -> int { return self.commands.len() }
    pub fn save() -> Result<bool> {
        self.commands.push(new SaveCommand())
        self.depth += 1
        return ok(true)
    }
    pub fn restore() -> Result<bool> {
        if self.depth == 0 { return err("paint restore without save", "paint_stack") }
        self.commands.push(new RestoreCommand())
        self.depth -= 1
        return ok(true)
    }
    pub fn translate(x: f64, y: f64) -> Result<bool> {
        self.commands.push(new TranslateCommand(x, y))
        return ok(true)
    }
    pub fn rotate(degrees: f64) -> Result<bool> {
        self.commands.push(new RotateCommand(degrees))
        return ok(true)
    }
    pub fn scale(x: f64, y: f64) -> Result<bool> {
        self.commands.push(new ScaleCommand(x, y))
        return ok(true)
    }
    pub fn clip(rect: geometry.Rect, radius: f64) -> Result<bool> {
        self.commands.push(new ClipCommand(rect, radius))
        return ok(true)
    }
    pub fn rectangle(rect: geometry.Rect, radius: f64, color: int, stroke: f64) -> Result<bool> {
        self.commands.push(new RectangleCommand(rect, radius, color, stroke))
        return ok(true)
    }
    pub fn ellipse(rect: geometry.Rect, fill: int, outline: int, stroke: f64) -> Result<bool> {
        self.commands.push(new EllipseCommand(rect, fill, outline, stroke))
        return ok(true)
    }
    pub fn path(data: string, fill: int, outline: int, stroke: f64) -> Result<bool> {
        self.commands.push(new PathCommand(data, fill, outline, stroke))
        return ok(true)
    }
    pub fn visual(kind: int, rect: geometry.Rect, data: string, style: VisualStyle) -> Result<bool> {
        self.commands.push(new VisualCommand(kind, rect, data, style))
        return ok(true)
    }
    pub fn image(value: ImageResource, rect: geometry.Rect) -> Result<bool> {
        self.commands.push(new ImageCommand(value, rect))
        return ok(true)
    }
    pub fn paragraph(value: Paragraph, x: f64, y: f64) -> Result<bool> {
        self.commands.push(new ParagraphCommand(value, x, y))
        return ok(true)
    }
    pub fn replay(canvas: Canvas) -> Result<bool> {
        if self.depth != 0 { return err("unclosed paint save", "paint_stack") }
        for command: PaintCommand in self.commands { command.replay(canvas)? }
        return ok(true)
    }
}
