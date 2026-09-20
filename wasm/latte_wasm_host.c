/* The browser host for a Latte WebAssembly module.
 *
 * `--emit shared` on wasm32-unknown-unknown links with `-nostdlib`, so there is
 * no libc in the module and nothing owns linear memory. This file is what the
 * Beans runtime stands on: the five `beans_host_*` hooks it declares, the four
 * memory builtins Clang emits calls to, and an allocator over `__heap_base`.
 *
 * Why the allocator is here and not in JavaScript. JavaScript can see this
 * module's memory and could hand back offsets, but every allocation would then
 * be a call out of WebAssembly and back — and the Beans collector allocates on
 * the hot path of every frame. It also could not be reentered: a JS allocator
 * called from inside a JS callback that the module is already inside would be
 * a second allocator state on one heap. Keeping it here makes allocation a
 * plain function call and leaves JavaScript with two imports it genuinely owns:
 * writing bytes out, and ending the program.
 */

typedef unsigned char       u8;
typedef unsigned int        u32;
typedef unsigned long long  u64;
typedef long long           i64;

/* Where the linker put the end of static data. Everything above it is ours. */
extern u8 __heap_base;

/* The things only the page can do. Unresolved at link time, so they arrive as
 * WebAssembly imports and JavaScript supplies them. */
extern void latte_js_write(int stream, const char *bytes, u32 len);
extern void latte_js_exit(int code);

/* Floating-point text.
 *
 * The Beans runtime declares these two as host hooks because correct
 * double-to-decimal cannot be written in a few lines, and a freestanding
 * module has no libc to borrow one from. JavaScript's own conversions are
 * correctly rounded by specification, so the page is the right place to ask —
 * what is left here is spelling, and `tests/canvas/floats.b` holds it to what
 * the other two backends print, byte for byte.
 *
 * They are only reached by a program that puts a float into text. Nothing on
 * the drawing path calls them: a coordinate crosses as a double. */
/* `int` rather than `long long`, although the hook it feeds returns one: a
 * 64-bit return crosses to JavaScript as a BigInt, and a plain number thrown
 * back at it is a TypeError inside the import. The value is a byte count of a
 * buffer this file sized, so 32 bits is not a limit anything can reach — and
 * the runtime measures the text with strlen anyway. */
extern int latte_js_format_f64(char *out, u32 cap, double value,
                               int places, int mode);
extern int latte_js_parse_f64(const char *text, double *out, const char **end);

/* ---- the memory builtins -------------------------------------------------
 *
 * Clang lowers struct copies and array fills to these whatever the flags say,
 * so a freestanding module has to define them itself. Word-at-a-time while the
 * pointers allow it: a byte loop here costs real time on a string copy, and
 * strings are what a UI moves.
 */

void *memset(void *destination, int value, unsigned long count) {
    u8 *out = (u8 *)destination;
    u8 byte = (u8)value;
    unsigned long at = 0;
    if (count >= 8 && ((unsigned long)out & 7) == 0) {
        u64 wide = (u64)byte;
        wide |= wide << 8;  wide |= wide << 16;  wide |= wide << 32;
        for (; at + 8 <= count; at += 8) *(u64 *)(out + at) = wide;
    }
    for (; at < count; at++) out[at] = byte;
    return destination;
}

void *memcpy(void *destination, const void *source, unsigned long count) {
    u8 *out = (u8 *)destination;
    const u8 *in = (const u8 *)source;
    unsigned long at = 0;
    if (count >= 8 && ((unsigned long)out & 7) == 0 && ((unsigned long)in & 7) == 0) {
        for (; at + 8 <= count; at += 8) *(u64 *)(out + at) = *(const u64 *)(in + at);
    }
    for (; at < count; at++) out[at] = in[at];
    return destination;
}

void *memmove(void *destination, const void *source, unsigned long count) {
    u8 *out = (u8 *)destination;
    const u8 *in = (const u8 *)source;
    if (out == in || count == 0) return destination;
    if (out < in) return memcpy(destination, source, count);
    for (unsigned long at = count; at > 0; at--) out[at - 1] = in[at - 1];
    return destination;
}

int memcmp(const void *left, const void *right, unsigned long count) {
    const u8 *a = (const u8 *)left;
    const u8 *b = (const u8 *)right;
    for (unsigned long at = 0; at < count; at++) {
        if (a[at] != b[at]) return (int)a[at] - (int)b[at];
    }
    return 0;
}

void *memchr(const void *block, int value, unsigned long count) {
    const u8 *at = (const u8 *)block;
    u8 byte = (u8)value;
    for (unsigned long i = 0; i < count; i++) {
        if (at[i] == byte) return (void *)(at + i);
    }
    return 0;
}

unsigned long strlen(const char *text) {
    unsigned long at = 0;
    while (text[at]) at++;
    return at;
}

/* ---- the arithmetic libc would have supplied ------------------------------
 *
 * WebAssembly has instructions for square root, absolute value and the four
 * roundings, so Clang emits those inline. What it cannot lower to an
 * instruction becomes a call into libm, and a `-nostdlib` module has none.
 *
 * Each one here is exact rather than approximate, and each says why it is
 * allowed to be.
 */

/* Beans' `%` on a pair of doubles. Exact.
 *
 * The textbook scale-and-subtract: scale the divisor up by powers of two until
 * one more doubling would pass the dividend, then halve back down, subtracting
 * wherever it fits. Every step is exact in binary floating point — multiplying
 * and dividing by two move the exponent and leave the significand alone, and
 * subtracting two values within a factor of two of each other is exact by
 * Sterbenz's lemma. So this is not an approximation of fmod, it is fmod.
 *
 * The one case it does not cover is a subnormal divisor, where halving loses
 * bits. Nothing in a layout produces one — a coordinate that small is zero to
 * every renderer — and a result there would be wrong rather than imprecise, so
 * it is named here rather than left to be discovered. */
double fmod(double x, double y) {
    /* NaN in, NaN out — including 0/0 built here, since there is no NAN
     * macro without a header. */
    double nan = (x - x) / (x - x);
    if (x != x || y != y) return nan;
    if (y == 0.0) return nan;

    double ax = x < 0.0 ? -x : x;
    double ay = y < 0.0 ? -y : y;
    /* An infinity has no remainder; a finite dividend by an infinite divisor
     * is itself. */
    if (ax > 1.7976931348623157e308) return nan;
    if (ay > 1.7976931348623157e308) return x;
    if (ax < ay) return x;

    double scaled = ay;
    while (scaled * 2.0 <= ax) scaled *= 2.0;
    while (scaled >= ay) {
        if (ax >= scaled) ax -= scaled;
        scaled *= 0.5;
    }
    return x < 0.0 ? -ax : ax;
}

/* The same, for a single-precision `%`. Computed in double and rounded once,
 * which is exact: every float is a double, and the true remainder of two
 * floats is representable as a float. */
float fmodf(float x, float y) { return (float)fmod((double)x, (double)y); }

/* ---- the allocator -------------------------------------------------------
 *
 * Size-class free lists with coalescing, over one growing region.
 *
 * A bump pointer would be shorter and is what most WebAssembly shims ship. It
 * is also wrong for this program: Latte mounts and unmounts scenes, and a
 * runtime whose memory only ever goes up turns "the user opened a dialog
 * forty times" into a tab that has to be reloaded. `tests/wasm_lifecycle`
 * mounts and unmounts repeatedly and asserts the page count stops growing,
 * which is a claim only a reusing allocator can make.
 *
 * Every block carries a header with its size and whether it is in use, and the
 * word before a block holds the previous block's size so a free can look left.
 * Freed neighbours merge in both directions, so a long run of differently
 * sized allocations does not shred the heap into unusable gaps.
 *
 * This was a first-fit scan over every block, free or not, which is quadratic
 * for a page that allocates every frame: on the showcase's table one
 * `new Element` took 10.7 microseconds and building the visible cells took
 * 3.3 ms of a 16.7 ms frame, all of it here. Per-size lists of free blocks
 * make the common case a pop off a list head.
 */

#define LATTE_ALIGN      16u
#define LATTE_PAGE       65536u
#define LATTE_IN_USE     1u

/* 32 bytes, not the 16 the four fields need.
 *
 * The extra room buys two things. The payload starts 16-aligned without any
 * arithmetic, and `shift` sits in the word immediately below the returned
 * address — which is what lets one `free` handle both an ordinary block and an
 * over-aligned one, with no magic number and no second allocator. The cost is
 * 16 bytes a block, and the Beans runtime pools small objects above this hook,
 * so a block here is a chunk rather than an object. */
typedef struct Block {
    u32 size;            /* payload bytes, a multiple of LATTE_ALIGN */
    u32 flags;           /* LATTE_IN_USE, or 0 */
    struct Block *prev;  /* the block below this one, or 0 */
    struct Block *next;  /* the block above this one, or 0 */
    /* The two links that make this block findable when it is free. They are
     * meaningless while it is in use, which is why they cost nothing: the
     * header already had the room. */
    struct Block *free_prev;
    struct Block *free_next;
    u32 pad2;
    u32 shift;           /* payload[-1]: how far the caller's pointer was moved */
} Block;

#define LATTE_HEADER     ((u32)sizeof(Block))

/* One list per size, up to half a kilobyte, and one for everything above it.
 * Every block in an exact class is exactly that size, so the head of the first
 * non-empty class at or above what was asked for always fits — no search. */
#define LATTE_CLASSES    33

static Block *latte_first = 0;
static Block *latte_last = 0;
static Block *latte_free[LATTE_CLASSES];
static u8 *latte_top = 0;      /* one past the last byte we own */
static u64 latte_live = 0;     /* payload bytes currently handed out */

static u32 latte_class(u32 size) {
    u32 slot = size / LATTE_ALIGN;
    if (slot >= LATTE_CLASSES) slot = LATTE_CLASSES - 1;
    return slot;
}

/* A free block joins its class; one that is about to be used or merged leaves
 * it. Every block with LATTE_IN_USE clear is on exactly one of these lists. */
static void latte_free_push(Block *block) {
    u32 slot = latte_class(block->size);
    block->free_prev = 0;
    block->free_next = latte_free[slot];
    if (latte_free[slot]) latte_free[slot]->free_prev = block;
    latte_free[slot] = block;
}

static void latte_free_pull(Block *block) {
    u32 slot = latte_class(block->size);
    if (block->free_prev) block->free_prev->free_next = block->free_next;
    else latte_free[slot] = block->free_next;
    if (block->free_next) block->free_next->free_prev = block->free_prev;
    block->free_prev = 0;
    block->free_next = 0;
}

static u32 latte_round(u64 bytes) {
    u64 rounded = (bytes + (LATTE_ALIGN - 1)) & ~(u64)(LATTE_ALIGN - 1);
    if (rounded == 0) rounded = LATTE_ALIGN;
    return (u32)rounded;
}

static u8 *latte_payload(Block *block) { return (u8 *)block + LATTE_HEADER; }

/* Grows linear memory by enough pages to hold `bytes` more, and returns the
 * new block, or 0 when the engine refuses to grow. */
static Block *latte_extend(u32 bytes) {
    u32 want = bytes + LATTE_HEADER;
    if (latte_top == 0) {
        /* First call: the heap starts at the first aligned address above the
         * linker's static data. */
        latte_top = (u8 *)(((u64)&__heap_base + (LATTE_ALIGN - 1)) & ~(u64)(LATTE_ALIGN - 1));
    }
    u8 *limit = (u8 *)((u64)__builtin_wasm_memory_size(0) * LATTE_PAGE);
    if (latte_top + want > limit) {
        u64 short_by = (u64)(latte_top + want - limit);
        u64 pages = (short_by + LATTE_PAGE - 1) / LATTE_PAGE;
        /* A little more than needed, so a run of small allocations does not
         * call memory.grow once each. */
        if (pages < 16) pages = 16;
        if (__builtin_wasm_memory_grow(0, (int)pages) == -1) return 0;
    }
    Block *block = (Block *)latte_top;
    block->size = bytes;
    block->flags = 0;
    block->prev = latte_last;
    block->next = 0;
    block->free_prev = 0;
    block->free_next = 0;
    block->shift = 0;
    if (latte_last) latte_last->next = block;
    if (!latte_first) latte_first = block;
    latte_last = block;
    latte_top += want;
    return block;
}

/* Splits `block` when the tail is worth keeping, and puts the tail on a free
 * list. A split that left a header-sized scrap would cost more in bookkeeping
 * than it returns. `block` itself must already be off every free list. */
static void latte_split(Block *block, u32 wanted) {
    if (block->size < wanted + LATTE_HEADER + LATTE_ALIGN) return;
    Block *tail = (Block *)(latte_payload(block) + wanted);
    tail->size = block->size - wanted - LATTE_HEADER;
    tail->flags = 0;
    tail->shift = 0;
    tail->prev = block;
    tail->next = block->next;
    if (block->next) block->next->prev = tail;
    else latte_last = tail;
    block->next = tail;
    block->size = wanted;
    latte_free_push(tail);
}

static Block *latte_use(Block *block, u32 wanted) {
    latte_free_pull(block);
    latte_split(block, wanted);
    block->flags |= LATTE_IN_USE;
    latte_live += block->size;
    return block;
}

static Block *latte_take(u32 wanted) {
    u32 slot = latte_class(wanted);
    /* Every block in an exact class is that size, so the first head found is
     * the smallest block that fits. */
    for (u32 at = slot; at < LATTE_CLASSES - 1; at++) {
        if (latte_free[at]) return latte_use(latte_free[at], wanted);
    }
    /* The last class is every size above the exact ones, so it is searched —
     * over free blocks only, and there are few of them. */
    for (Block *at = latte_free[LATTE_CLASSES - 1]; at; at = at->free_next) {
        if (at->size >= wanted) return latte_use(at, wanted);
    }
    Block *fresh = latte_extend(wanted);
    if (!fresh) return 0;
    fresh->flags |= LATTE_IN_USE;
    latte_live += fresh->size;
    return fresh;
}

void *beans_host_alloc(u64 size, u64 align) {
    u32 wanted = latte_round(size);
    /* Room for the worst-case shift, so an over-aligned address is always
     * inside this block's own payload. */
    if (align > LATTE_ALIGN) wanted = latte_round((u64)wanted + align);

    Block *block = latte_take(wanted);
    if (!block) return 0;

    u8 *out = latte_payload(block);
    block->shift = 0;
    if (align > LATTE_ALIGN) {
        u64 aligned = ((u64)out + (align - 1)) & ~(align - 1);
        block->shift = (u32)(aligned - (u64)out);
        out = (u8 *)aligned;
        /* `shift` lives in the header's last word, which is the word below an
         * unshifted payload — so a shifted payload needs its own copy where
         * free() will look for it. */
        *((u32 *)out - 1) = block->shift;
    }
    /* The contract is zeroed memory: the runtime's own weak host calls calloc. */
    memset(out, 0, size);
    return out;
}

static Block *latte_block_of(void *block) {
    u8 *at = (u8 *)block;
    u32 shift = *((u32 *)at - 1);
    if (shift > 0) at -= shift;
    return (Block *)(at - LATTE_HEADER);
}

void beans_host_free(void *block) {
    if (!block) return;
    Block *header = latte_block_of(block);
    if ((header->flags & LATTE_IN_USE) == 0) return;   /* a double free is a no-op */
    header->flags &= ~LATTE_IN_USE;
    header->shift = 0;
    latte_live -= header->size;

    Block *above = header->next;
    if (above && (above->flags & LATTE_IN_USE) == 0) {
        latte_free_pull(above);
        header->size += above->size + LATTE_HEADER;
        header->next = above->next;
        if (above->next) above->next->prev = header;
        else latte_last = header;
    }
    Block *below = header->prev;
    if (below && (below->flags & LATTE_IN_USE) == 0) {
        latte_free_pull(below);
        below->size += header->size + LATTE_HEADER;
        below->next = header->next;
        if (header->next) header->next->prev = below;
        else latte_last = below;
        latte_free_push(below);
        return;
    }
    latte_free_push(header);
}

void *beans_host_realloc(void *block, u64 size) {
    if (!block) return beans_host_alloc(size, LATTE_ALIGN);
    Block *header = latte_block_of(block);
    u32 wanted = latte_round(size);
    /* An over-aligned block cannot be grown here without quietly giving up
     * the alignment it was asked for, and a caller that wanted 64 bytes of
     * alignment wanted it for a reason. The runtime never does this — an
     * over-aligned block comes from beans_raw_alloc and goes to
     * beans_raw_free — so this is a refusal rather than a case to handle. */
    if (header->shift != 0) return 0;
    if (header->shift == 0 && header->size >= wanted) {
        u32 was = header->size;
        latte_split(header, wanted);
        latte_live -= was - header->size;
        return block;
    }

    /* Grow in place when the block above is free and big enough: a List that
     * doubles is the common case, and copying it every time is the cost this
     * check removes. */
    Block *above = header->next;
    if (header->shift == 0 && above && (above->flags & LATTE_IN_USE) == 0 &&
        header->size + LATTE_HEADER + above->size >= wanted) {
        u32 was = header->size;
        latte_live -= was;
        latte_free_pull(above);
        header->size += above->size + LATTE_HEADER;
        header->next = above->next;
        if (above->next) above->next->prev = header;
        else latte_last = header;
        latte_split(header, wanted);
        latte_live += header->size;
        /* Grown memory is zeroed, like a fresh block: the runtime reads a
         * List's new tail before writing it. */
        memset((u8 *)block + was, 0, header->size - was);
        return block;
    }

    void *moved = beans_host_alloc(size, LATTE_ALIGN);
    if (!moved) return 0;
    /* The smaller of the two payloads. `header->size` is the block, which is
     * the old payload exactly, because an over-aligned block was refused
     * above. */
    u64 keep = header->size < wanted ? header->size : wanted;
    memcpy(moved, block, (unsigned long)keep);
    beans_host_free(block);
    return moved;
}

/* ---- what the page can see ----------------------------------------------- */

void beans_host_write(int stream, const char *bytes, u64 len) {
    latte_js_write(stream, bytes, (u32)len);
}

void beans_host_exit(int code) { latte_js_exit(code); }

long long beans_host_format_f64(char *out, u64 cap, double value,
                                int places, int mode) {
    return (long long)latte_js_format_f64(out, (u32)cap, value, places, mode);
}

int beans_host_parse_f64(const char *text, double *out, const char **end) {
    return latte_js_parse_f64(text, out, end);
}

/* How many bytes are handed out right now, and how big the heap has grown.
 * The lifecycle check reads both: a mount/unmount loop must leave the first
 * unchanged and must stop moving the second. */
__attribute__((export_name("latte_heap_live")))
u64 latte_heap_live(void) { return latte_live; }

__attribute__((export_name("latte_heap_pages")))
u64 latte_heap_pages(void) { return (u64)__builtin_wasm_memory_size(0); }

/* Bytes JavaScript can write into, to hand text and pixels to the module.
 *
 * One buffer, taken and given back around a single call, rather than a
 * long-lived arena: the page is single threaded and never has two calls in
 * flight, and a buffer that outlived its call would be a second place for
 * memory to leak from. */
__attribute__((export_name("latte_scratch_take")))
void *latte_scratch_take(u32 bytes) { return beans_host_alloc((u64)bytes, LATTE_ALIGN); }

__attribute__((export_name("latte_scratch_drop")))
void latte_scratch_drop(void *block) { beans_host_free(block); }
