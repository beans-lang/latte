// CanvasKit behind Latte's paint interface. It decides nothing: each command
// arrives and is issued. Two memories, handles, the surface: docs/notes.md.

const SHAPE = { RECTANGLE: 0, ELLIPSE: 1, PATH: 2, RESOURCE_IMAGE: 3 };

/// 0 butt, 1 round, 2 square — `paint.VisualStyle.stroke_cap`.
const CAPS = ["Butt", "Round", "Square"];
/// 0 miter, 1 round, 2 bevel.
const JOINS = ["Miter", "Round", "Bevel"];
/// 0 default, 1 light, 2 regular, 3 medium, 4 semibold, 5 bold, 6 heavy.
const WEIGHTS = [400, 300, 400, 500, 600, 700, 900];
/// 0 leading, 1 centre, 2 trailing.
const ALIGNS = ["Left", "Center", "Right"];

export class CanvasKitSurface {
    /// `canvasKit` is a loaded module and `element` the `<canvas>` to draw
    /// into. Both are the page's: a surface has nowhere to put its own canvas.
    constructor(canvasKit, element, options = {}) {
        this.ck = canvasKit;
        this.element = element;
        this.surface = null;
        this.canvas = null;
        this.revision = 0;
        this.isSoftware = false;
        this.wantSoftware = options.software === true;
        this.width = 0;
        this.height = 0;
        this.scale = 1;
        this.paragraphs = new Map();
        this.images = new Map();
        this.nextHandle = 1;
        this.fontState = 0;          // 0 none, 1 loading, 2 ready, -1 failed
        this.fontFaces = [];
        this.fontFamily = null;
        this.segmenter = typeof Intl !== "undefined" && Intl.Segmenter
            ? { grapheme: new Intl.Segmenter(undefined, { granularity: "grapheme" }),
                word: new Intl.Segmenter(undefined, { granularity: "word" }) }
            : null;
        this.lastError = "";
        this.commands = 0;
        this.frames = 0;
        // Frames copied back through the CPU, which should be zero for every
        // frame a reader sees. A number a gate reads, not a claim in a comment.
        this.readbacks = 0;
        // The paint objects. Two, reused: a Paint is a Skia object and one per
        // command would be an allocation and a delete per rectangle.
        this.fillPaint = new this.ck.Paint();
        this.fillPaint.setAntiAlias(true);
        this.strokePaint = new this.ck.Paint();
        this.strokePaint.setAntiAlias(true);
        this.strokePaint.setStyle(this.ck.PaintStyle.Stroke);
    }

    // ---- the surface -----------------------------------------------------

    /// A surface for the element at its current backing size. GPU first, CPU
    /// only if that fails, and `isSoftware` says which rather than nothing.
    ensureSurface() {
        const backingWidth = Math.max(1, Math.round(this.width * this.scale));
        const backingHeight = Math.max(1, Math.round(this.height * this.scale));
        if (this.surface &&
            this.element.width === backingWidth &&
            this.element.height === backingHeight &&
            !this.surface.isDeleted()) {
            return true;
        }
        this.dropSurface();
        this.element.width = backingWidth;
        this.element.height = backingHeight;
        this.element.style.width = `${this.width}px`;
        this.element.style.height = `${this.height}px`;

        if (!this.wantSoftware) {
            try {
                const surface = this.ck.MakeWebGLCanvasSurface(this.element);
                if (surface) {
                    this.surface = surface;
                    this.isSoftware = false;
                    this.revision++;
                    return true;
                }
            } catch (error) {
                this.lastError = String(error);
            }
        }
        try {
            const surface = this.ck.MakeSWCanvasSurface(this.element);
            if (surface) {
                this.surface = surface;
                this.isSoftware = true;
                this.revision++;
                return true;
            }
        } catch (error) {
            this.lastError = String(error);
        }
        return false;
    }

    dropSurface() {
        if (this.surface && !this.surface.isDeleted()) this.surface.delete();
        this.surface = null;
        this.canvas = null;
    }

    /// The page telling us the context went away. The revision it bumps makes
    /// Latte repaint everything: a new surface holds none of the old pixels.
    noteContextLost() {
        this.dropSurface();
        this.revision++;
    }

    /// Forces the CPU path from here on. What the page calls when WebGL has
    /// failed for good, and what a gate calls to compare the two.
    useSoftware(yes = true) {
        if (this.wantSoftware === yes) return;
        this.wantSoftware = yes;
        this.dropSurface();
        this.revision++;
    }

    // ---- fonts -----------------------------------------------------------

    /// Starts loading the fonts a page draws text with — CanvasKit ships none
    /// and cannot read the system's. See docs/notes.md; `fontState` reports.
    useFont(source) {
        if (!source) {
            this.fontFaces = [];
            this.fontFamily = null;
            this.fontState = 0;
            this.bumpFontCollection();
            return true;
        }
        const sources = source.split(/\s+/).filter(Boolean);
        this.fontState = 1;
        this.fontWanted = sources.length;
        this.fontFaces = [];
        Promise.all(sources.map((url) =>
            fetch(url).then((response) => {
                if (!response.ok) throw new Error(`${url}: ${response.status} ${response.statusText}`);
                return response.arrayBuffer();
            })))
            .then((buffers) => {
                const faces = buffers.map((buffer) => new Uint8Array(buffer));
                // One family name for every face, from the first file: under
                // its own name a weight would fall back rather than match.
                const manager = this.ck.FontMgr.FromData(faces[0]);
                if (!manager) throw new Error("CanvasKit could not read the first font file");
                this.fontFamily = manager.getFamilyName(0);
                manager.delete?.();
                this.fontFaces = faces;
                this.fontState = 2;
                this.bumpFontCollection();
            })
            .catch((error) => {
                this.lastError = `could not load a font: ${error}`;
                this.fontState = -1;
            });
        return true;
    }

    /// Throws away the cached font collection, so the next paragraph builds a
    /// new one against whatever is registered now.
    bumpFontCollection() {
        if (this.fontCollection) { this.fontCollection.delete(); this.fontCollection = null; }
        this.fontCollectionFor = null;
        // New faces means every shaped paragraph is measured wrong, so the
        // revision moves and the scene repaints, as a lost context does.
        this.revision++;
    }

    // ---- colours ---------------------------------------------------------

    /// Latte packs RGBA with red high; CanvasKit wants four floats. `>>> 0`
    /// first, because a colour with the top bit set arrives as a negative i32.
    color(packed) {
        const value = packed >>> 0;
        return this.ck.Color4f(
            ((value >>> 24) & 255) / 255,
            ((value >>> 16) & 255) / 255,
            ((value >>> 8) & 255) / 255,
            (value & 255) / 255);
    }

    /// Whether a packed colour would draw anything. A fully transparent one is
    /// skipped rather than issued: it costs a draw call and changes no pixel.
    visible(packed) { return ((packed >>> 0) & 255) !== 0; }

    // ---- the frame -------------------------------------------------------

    begin(width, height, scale, background) {
        this.width = width;
        this.height = height;
        this.scale = scale;
        if (!this.ensureSurface()) return -1;
        this.canvas = this.surface.getCanvas();
        this.canvas.save();
        // Latte draws in logical points and the surface is device pixels. One
        // scale here, not a multiply per command, keeps a round corner round.
        this.canvas.scale(scale, scale);
        if (this.visible(background)) {
            this.canvas.clear(this.color(background));
        } else {
            this.canvas.clear(this.ck.TRANSPARENT);
        }
        this.commands = 0;
        return 0;
    }

    end() {
        if (!this.canvas || !this.surface) return -1;
        this.canvas.restore();
        // flush() on the page's own surface. There is no readback and no
        // intermediate image: the browser composites what Skia just drew.
        this.surface.flush();
        this.canvas = null;
        this.frames++;
        return 0;
    }

    // ---- drawing ---------------------------------------------------------

    rrect(x, y, width, height, radius) {
        const box = this.ck.LTRBRect(x, y, x + width, y + height);
        if (!radius) return box;
        return this.ck.RRectXY(box, radius, radius);
    }

    fill(packed) {
        this.fillPaint.setColor(this.color(packed));
        this.fillPaint.setStyle(this.ck.PaintStyle.Fill);
        return this.fillPaint;
    }

    stroke(packed, width, cap = 0, join = 0) {
        this.strokePaint.setColor(this.color(packed));
        this.strokePaint.setStrokeWidth(width);
        this.strokePaint.setStrokeCap(this.ck.StrokeCap[CAPS[cap] || "Butt"]);
        this.strokePaint.setStrokeJoin(this.ck.StrokeJoin[JOINS[join] || "Miter"]);
        return this.strokePaint;
    }

    drawRect(x, y, width, height, radius, color, strokeWidth) {
        if (!this.canvas) return -1;
        this.commands++;
        const shape = this.rrect(x, y, width, height, radius);
        if (strokeWidth > 0) {
            if (radius) this.canvas.drawRRect(shape, this.stroke(color, strokeWidth));
            else this.canvas.drawRect(shape, this.stroke(color, strokeWidth));
            return 0;
        }
        if (!this.visible(color)) return 0;
        if (radius) this.canvas.drawRRect(shape, this.fill(color));
        else this.canvas.drawRect(shape, this.fill(color));
        return 0;
    }

    drawEllipse(x, y, width, height, fillColor, outlineColor, strokeWidth) {
        if (!this.canvas) return -1;
        this.commands++;
        const box = this.ck.LTRBRect(x, y, x + width, y + height);
        if (this.visible(fillColor)) this.canvas.drawOval(box, this.fill(fillColor));
        if (strokeWidth > 0 && this.visible(outlineColor)) {
            this.canvas.drawOval(box, this.stroke(outlineColor, strokeWidth));
        }
        return 0;
    }

    drawPath(data, fillColor, outlineColor, strokeWidth) {
        if (!this.canvas) return -1;
        this.commands++;
        const path = this.ck.Path.MakeFromSVGString(data);
        // A refusal rather than nothing. Bad path data is a typo in somebody's
        // markup, and a shape that quietly does not appear is a long afternoon.
        if (!path) { this.lastError = `not SVG path data: ${data}`; return -1; }
        try {
            if (this.visible(fillColor)) this.canvas.drawPath(path, this.fill(fillColor));
            if (strokeWidth > 0 && this.visible(outlineColor)) {
                this.canvas.drawPath(path, this.stroke(outlineColor, strokeWidth));
            }
        } finally {
            path.delete();
        }
        return 0;
    }

    /// One shape with a full style: gradient, shadow, stroke shape and a
    /// rounded clip. `style` is the thirteen numbers `paint.VisualStyle` packs.
    drawVisual(kind, x, y, width, height, data, style) {
        if (!this.canvas) return -1;
        this.commands++;
        const [fillColor, outlineColor, strokeWidth, gradientStart, gradientEnd,
               gradientOn, shadowColor, shadowBlur, shadowDx, shadowDy,
               clipRadius, cap, join] = style;

        const box = this.ck.LTRBRect(x, y, x + width, y + height);
        let path = null;
        if (kind === SHAPE.PATH) {
            path = this.ck.Path.MakeFromSVGString(data);
            if (!path) { this.lastError = `not SVG path data: ${data}`; return -1; }
        }

        const drawWith = (paint) => {
            if (kind === SHAPE.ELLIPSE) this.canvas.drawOval(box, paint);
            else if (kind === SHAPE.PATH) this.canvas.drawPath(path, paint);
            else if (clipRadius) this.canvas.drawRRect(this.rrect(x, y, width, height, clipRadius), paint);
            else this.canvas.drawRect(box, paint);
        };

        try {
            // The shadow first, as a blurred copy. A mask filter, not a
            // drop-shadow one: that forces a saveLayer per shadowed control.
            if (shadowBlur > 0 && this.visible(shadowColor)) {
                const shadow = new this.ck.Paint();
                shadow.setAntiAlias(true);
                shadow.setColor(this.color(shadowColor));
                shadow.setMaskFilter(this.ck.MaskFilter.MakeBlur(
                    this.ck.BlurStyle.Normal, shadowBlur / 2, false));
                this.canvas.save();
                this.canvas.translate(shadowDx, shadowDy);
                drawWith(shadow);
                this.canvas.restore();
                shadow.delete();
            }

            if (gradientOn) {
                const gradient = new this.ck.Paint();
                gradient.setAntiAlias(true);
                gradient.setShader(this.ck.Shader.MakeLinearGradient(
                    [x, y], [x, y + height],
                    [this.color(gradientStart), this.color(gradientEnd)],
                    [0, 1], this.ck.TileMode.Clamp));
                drawWith(gradient);
                gradient.delete();
            } else if (this.visible(fillColor)) {
                drawWith(this.fill(fillColor));
            }

            if (strokeWidth > 0 && this.visible(outlineColor)) {
                drawWith(this.stroke(outlineColor, strokeWidth, cap, join));
            }
        } finally {
            if (path) path.delete();
        }
        return 0;
    }

    // ---- paragraphs ------------------------------------------------------

    /// The font collection every paragraph is built against, remade only when
    /// the pinned font changes: one per paragraph is the expensive mistake.
    fonts() {
        if (this.fontCollection && this.fontCollectionFor === this.fontState) {
            return this.fontCollection;
        }
        if (this.fontCollection) this.fontCollection.delete();
        const provider = this.ck.TypefaceFontProvider.Make();
        for (const face of this.fontFaces) {
            provider.registerFont(face, this.fontFamily);
        }
        this.fontCollection = provider;
        this.fontCollectionFor = this.fontState;
        return provider;
    }

    makeParagraph(text, size, weight, tracking, align, width, color) {
        // Refused, not shaped to nothing: with no font CanvasKit lays out
        // zero glyphs and reports nothing, so every control comes up wordless.
        if (this.fontState !== 2 || !this.fontFamily) {
            this.lastError = this.fontState === 1
                ? "the font is still loading"
                : this.fontState === -1
                    ? `the font did not load: ${this.lastError}`
                    : "no font is registered — call useFont() before drawing text, because CanvasKit has none of its own and cannot read the system's";
            return -1;
        }
        const families = [this.fontFamily];
        const style = new this.ck.ParagraphStyle({
            textStyle: {
                color: this.color(color),
                fontFamilies: families,
                fontSize: size,
                letterSpacing: tracking,
                fontStyle: { weight: { value: WEIGHTS[weight] || 400 } },
            },
            textAlign: this.ck.TextAlign[ALIGNS[align] || "Left"],
        });
        let builder;
        try {
            builder = this.ck.ParagraphBuilder.MakeFromFontProvider(style, this.fonts());
        } catch (error) {
            this.lastError = String(error);
            style.delete?.();
            return -1;
        }
        builder.addText(text);
        const paragraph = builder.build();
        builder.delete();
        // A width of zero means do not wrap. Skia will not take Infinity, so
        // this is the largest finite layout width it does take.
        paragraph.layout(width > 0 ? width : 16777216);
        const handle = this.nextHandle++;
        this.paragraphs.set(handle, { paragraph, text, wrapped: width > 0 });
        return handle;
    }

    paragraphAt(handle) {
        const entry = this.paragraphs.get(handle);
        return entry ? entry.paragraph : null;
    }

    releaseParagraph(handle) {
        const entry = this.paragraphs.get(handle);
        if (!entry) return;
        entry.paragraph.delete();
        this.paragraphs.delete(handle);
    }

    // ---- images ----------------------------------------------------------

    loadImage(source) {
        const handle = this.nextHandle++;
        const entry = { image: null, state: 0, source };
        this.images.set(handle, entry);
        fetch(source)
            .then((response) => {
                if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
                return response.arrayBuffer();
            })
            .then((buffer) => {
                const image = this.ck.MakeImageFromEncoded(new Uint8Array(buffer));
                if (!image) throw new Error("CanvasKit could not decode it");
                // The handle may have been released mid-fetch. Deleting here
                // rather than storing is what keeps a cancelled load from leaking.
                if (!this.images.has(handle)) { image.delete(); return; }
                entry.image = image;
                entry.state = 1;
                if (this.onImageReady) this.onImageReady(handle);
            })
            .catch((error) => {
                entry.state = -1;
                this.lastError = `could not load ${source}: ${error}`;
            });
        return handle;
    }

    releaseImage(handle) {
        const entry = this.images.get(handle);
        if (!entry) return;
        if (entry.image) entry.image.delete();
        this.images.delete(handle);
    }

    // ---- reading back ----------------------------------------------------

    /// The pixels of the last finished frame. A full copy through the CPU,
    /// which is why nothing on the drawing path calls it.
    readPixels() {
        if (!this.surface || this.surface.isDeleted()) return null;
        this.readbacks++;
        const image = this.surface.makeImageSnapshot();
        if (!image) return null;
        try {
            const width = image.width();
            const height = image.height();
            const pixels = image.readPixels(0, 0, {
                width, height,
                colorType: this.ck.ColorType.RGBA_8888,
                alphaType: this.ck.AlphaType.Unpremul,
                colorSpace: this.ck.ColorSpace.SRGB,
            });
            return pixels ? { width, height, pixels } : null;
        } finally {
            image.delete();
        }
    }

    /// Paragraphs and images still held. A scene that closed and left one
    /// behind shows here as a number that did not come back to zero.
    resourceCount() { return this.paragraphs.size + this.images.size; }

    close() {
        for (const handle of [...this.paragraphs.keys()]) this.releaseParagraph(handle);
        for (const handle of [...this.images.keys()]) this.releaseImage(handle);
        if (this.fontCollection) { this.fontCollection.delete(); this.fontCollection = null; }
        this.fillPaint.delete();
        this.strokePaint.delete();
        this.dropSurface();
    }
}

/// The drawing imports, bound to one surface. `runtime` owns the memory every
/// pointer here is an offset into, and is the only thing decoded against.
export function canvasKitImports(runtime, surface) {
    const read = (pointer, length) => runtime.text(pointer, length);
    const writeReals = (pointer, values) => {
        const view = new Float64Array(runtime.memory.buffer, pointer, values.length);
        view.set(values);
    };
    const writeWholes = (pointer, values) => {
        const view = new Int32Array(runtime.memory.buffer, pointer, values.length);
        view.set(values);
    };

    return {
        latte_js_ck_ready: () => (surface.surface || surface.ensureSurface() ? 1 : 0),
        latte_js_ck_revision: () => surface.revision,
        latte_js_ck_software: () => (surface.isSoftware ? 1 : 0),

        latte_js_ck_use_font: (pointer, length) =>
            surface.useFont(read(pointer, length)) ? 0 : -1,
        latte_js_ck_font_state: () => surface.fontState,

        latte_js_ck_begin: (width, height, scale, background) =>
            surface.begin(width, height, scale, background),
        latte_js_ck_end: () => surface.end(),

        latte_js_ck_save: () => { if (!surface.canvas) return -1; surface.canvas.save(); return 0; },
        latte_js_ck_restore: () => { if (!surface.canvas) return -1; surface.canvas.restore(); return 0; },
        latte_js_ck_translate: (x, y) => { if (!surface.canvas) return -1; surface.canvas.translate(x, y); return 0; },
        latte_js_ck_rotate: (degrees) => { if (!surface.canvas) return -1; surface.canvas.rotate(degrees, 0, 0); return 0; },
        latte_js_ck_scale: (x, y) => { if (!surface.canvas) return -1; surface.canvas.scale(x, y); return 0; },

        latte_js_ck_clip: (x, y, width, height, radius) => {
            if (!surface.canvas) return -1;
            const shape = surface.rrect(x, y, width, height, radius);
            if (radius) surface.canvas.clipRRect(shape, surface.ck.ClipOp.Intersect, true);
            else surface.canvas.clipRect(shape, surface.ck.ClipOp.Intersect, true);
            return 0;
        },

        latte_js_ck_rect: (x, y, width, height, radius, color, stroke) =>
            surface.drawRect(x, y, width, height, radius, color, stroke),
        latte_js_ck_ellipse: (x, y, width, height, fill, outline, stroke) =>
            surface.drawEllipse(x, y, width, height, fill, outline, stroke),
        latte_js_ck_path: (pointer, length, fill, outline, stroke) =>
            surface.drawPath(read(pointer, length), fill, outline, stroke),

        latte_js_ck_visual: (kind, x, y, width, height, dataPtr, dataLen, stylePtr) => {
            const style = Array.from(new Float64Array(runtime.memory.buffer, stylePtr, 13));
            return surface.drawVisual(kind, x, y, width, height, read(dataPtr, dataLen), style);
        },

        latte_js_ck_draw_image: (handle, x, y, width, height) => {
            if (!surface.canvas) return -1;
            const entry = surface.images.get(handle);
            if (!entry || !entry.image) return -1;
            surface.canvas.drawImageRect(
                entry.image,
                surface.ck.LTRBRect(0, 0, entry.image.width(), entry.image.height()),
                surface.ck.LTRBRect(x, y, x + width, y + height),
                surface.fillPaint);
            surface.commands++;
            return 0;
        },

        latte_js_ck_draw_paragraph: (handle, x, y) => {
            if (!surface.canvas) return -1;
            const paragraph = surface.paragraphAt(handle);
            if (!paragraph) return -1;
            surface.canvas.drawParagraph(paragraph, x, y);
            surface.commands++;
            return 0;
        },

        latte_js_ck_paragraph: (pointer, length, size, weight, tracking, align, width, color) =>
            surface.makeParagraph(read(pointer, length), size, weight, tracking, align, width, color),

        latte_js_ck_paragraph_size: (handle, out) => {
            const paragraph = surface.paragraphAt(handle);
            if (!paragraph) return -1;
            // `getMaxIntrinsicWidth` is the unwrapped width; `getMaxWidth` is
            // the layout width, which for an unwrapped paragraph is 16777216.
            const entry = surface.paragraphs.get(handle);
            const width = entry.wrapped
                ? Math.min(paragraph.getMaxWidth(), paragraph.getMaxIntrinsicWidth())
                : paragraph.getMaxIntrinsicWidth();
            writeReals(out, [width, paragraph.getHeight()]);
            return 0;
        },

        latte_js_ck_paragraph_metrics: (handle, out) => {
            const paragraph = surface.paragraphAt(handle);
            if (!paragraph) return -1;
            const lines = paragraph.getLineMetrics();
            if (!lines.length) { writeReals(out, [0, 0, 0, 0]); return 0; }
            const first = lines[0];
            writeReals(out, [first.ascent, first.descent, first.height, first.baseline]);
            return 0;
        },

        latte_js_ck_paragraph_hit: (handle, x, y) => {
            const paragraph = surface.paragraphAt(handle);
            if (!paragraph) return -1;
            return paragraph.getGlyphPositionAtCoordinate(x, y).pos;
        },

        latte_js_ck_paragraph_caret: (handle, byteOffset, out) => {
            const paragraph = surface.paragraphAt(handle);
            if (!paragraph) return -1;
            const entry = surface.paragraphs.get(handle);
            const total = entry.text.length;
            // A caret at the end has no glyph after it, so the box is the one
            // before it moved to its right edge; a zero range answers nothing.
            const at = Math.max(0, Math.min(byteOffset, total));
            if (at >= total && total > 0) {
                const boxes = paragraph.getRectsForRange(total - 1, total,
                    surface.ck.RectHeightStyle.Tight, surface.ck.RectWidthStyle.Tight);
                if (boxes.length) {
                    const box = boxes[boxes.length - 1].rect ?? boxes[boxes.length - 1];
                    writeReals(out, [box[2], box[1], 1, box[3] - box[1]]);
                    return 0;
                }
            }
            const boxes = paragraph.getRectsForRange(at, Math.min(at + 1, total),
                surface.ck.RectHeightStyle.Tight, surface.ck.RectWidthStyle.Tight);
            if (!boxes.length) {
                writeReals(out, [0, 0, 1, paragraph.getHeight()]);
                return 0;
            }
            const box = boxes[0].rect ?? boxes[0];
            writeReals(out, [box[0], box[1], 1, box[3] - box[1]]);
            return 0;
        },

        latte_js_ck_paragraph_selection: (handle, first, last, out, cap) => {
            const paragraph = surface.paragraphAt(handle);
            if (!paragraph) return -1;
            let from = Math.min(first, last);
            let to = Math.max(first, last);
            const entry = surface.paragraphs.get(handle);
            if (from < 0 || to > entry.text.length) return -1;
            const boxes = paragraph.getRectsForRange(from, to,
                surface.ck.RectHeightStyle.Tight, surface.ck.RectWidthStyle.Tight);
            if (!out || cap <= 0) return boxes.length;
            const flat = [];
            for (const each of boxes) {
                const box = each.rect ?? each;
                flat.push(box[0], box[1], box[2] - box[0], box[3] - box[1]);
            }
            writeReals(out, flat);
            return boxes.length;
        },

        latte_js_ck_paragraph_release: (handle) => surface.releaseParagraph(handle),

        latte_js_ck_graphemes: (pointer, length, out, cap) =>
            boundaries(surface, read(pointer, length), "grapheme", out, cap, runtime),
        latte_js_ck_words: (pointer, length, out, cap) =>
            boundaries(surface, read(pointer, length), "word", out, cap, runtime),

        latte_js_ck_image_load: (pointer, length) => surface.loadImage(read(pointer, length)),
        latte_js_ck_image_state: (handle) => {
            const entry = surface.images.get(handle);
            return entry ? entry.state : -1;
        },
        latte_js_ck_image_size: (handle, out) => {
            const entry = surface.images.get(handle);
            if (!entry) return -1;
            if (!entry.image) { writeReals(out, [0, 0]); return 0; }
            writeReals(out, [entry.image.width(), entry.image.height()]);
            return 0;
        },
        latte_js_ck_image_release: (handle) => surface.releaseImage(handle),

        latte_js_ck_snapshot: (out, cap, sizeOut) => {
            const shot = surface.readPixels();
            if (!shot) return -1;
            writeWholes(sizeOut, [shot.width, shot.height]);
            if (!out || cap <= 0) return shot.pixels.length;
            if (cap < shot.pixels.length) return shot.pixels.length;
            new Uint8Array(runtime.memory.buffer, out, shot.pixels.length).set(shot.pixels);
            return shot.pixels.length;
        },
    };
}

/// Grapheme or word boundaries, as **byte** offsets into the UTF-8 text:
/// `Intl.Segmenter` answers UTF-16 indices and Beans counts bytes.
function boundaries(surface, text, granularity, out, cap, runtime) {
    if (!surface.segmenter) {
        // No Intl.Segmenter: every code point is its own grapheme, which is
        // wrong for emoji and combining marks. Reported rather than hidden.
        surface.lastError = "this browser has no Intl.Segmenter; boundaries are per code point";
    }
    const encoder = new TextEncoder();
    const offsets = [0];
    if (surface.segmenter) {
        let bytes = 0;
        for (const piece of surface.segmenter[granularity].segment(text)) {
            if (granularity === "word" && !piece.isWordLike && offsets.length > 1) {
                // A run of spaces or punctuation is its own piece, and its
                // start is a boundary: a double-click on a space selects it.
            }
            bytes += encoder.encode(piece.segment).length;
            offsets.push(bytes);
        }
    } else {
        let bytes = 0;
        for (const point of text) {
            bytes += encoder.encode(point).length;
            offsets.push(bytes);
        }
    }
    // The first offset is always 0 and the last is always the byte length, so
    // a text of one grapheme answers [0, n] — two boundaries, not one.
    if (!out || cap <= 0) return offsets.length;
    if (cap < offsets.length) return offsets.length;
    new Int32Array(runtime.memory.buffer, out, offsets.length).set(offsets);
    return offsets.length;
}

export { SHAPE };
