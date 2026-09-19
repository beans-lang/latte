// The header's `#define`s, restated.
//
// `beansc bindgen` reads declarations, not the preprocessor, so every constant
// in cortado_host.h is invisible to the generated binding and has to live
// here. Hand-copied values go stale silently, so `tools/check_constants.sh`
// reads both files and fails the build when a number here stops matching the
// header.
//
// These are the raw ABI numbers. Nothing outside this package should name
// them: the widget kinds surface as `controls.WidgetKind`, the statuses as
// `HostStatus`, and the capabilities as `Capability`.
package platform

pub const ABI_VERSION: int = 34

// ---- statuses ----

pub const OK: int = 0
pub const ERR_STALE: int = -1
pub const ERR_KIND: int = -2
pub const ERR_PLATFORM: int = -3
pub const ERR_THREAD: int = -4
pub const ERR_UNSUPPORTED: int = -5
pub const ERR_RANGE: int = -6
pub const ERR_ABI: int = -7
pub const ERR_STATE: int = -8

// ---- event kinds ----

pub const EV_ACTIVATE: int = 1
pub const EV_VALUE_CHANGED: int = 2
pub const EV_TEXT_COMMIT: int = 3
pub const EV_SELECTION: int = 4
pub const EV_POINTER_DOWN: int = 5
pub const EV_POINTER_UP: int = 6
pub const EV_POINTER_MOVE: int = 7
pub const EV_KEY_DOWN: int = 8
pub const EV_KEY_UP: int = 9
pub const EV_FOCUS: int = 10
pub const EV_BLUR: int = 11
pub const EV_SURFACE_RESIZED: int = 12
pub const EV_SURFACE_CLOSE: int = 13
pub const EV_APPEARANCE: int = 14
pub const EV_SCALE_CHANGED: int = 15
pub const EV_POST: int = 16
pub const EV_APP_LAUNCHED: int = 17
pub const EV_APP_FOREGROUND: int = 18
pub const EV_APP_BACKGROUND: int = 19
pub const EV_APP_WILL_QUIT: int = 20
pub const EV_LOW_MEMORY: int = 21
pub const EV_COMMAND: int = 22
pub const EV_FRAME: int = 23
pub const EV_ANIM_DONE: int = 24

/// One past the last kind, so a table with a row per kind can be sized.
pub const EV_NET_CHANGED: int = 32
pub const EV_POWER_CHANGED: int = 33
pub const EV_LOCATION: int = 34
pub const EV_BLE_FOUND: int = 35
pub const EV_BLE_LINK: int = 36
pub const EV_CAPTURE_DEVICES: int = 37
pub const EV_SCREEN_FRAME: int = 38
pub const EV_POINTER_SCROLL: int = 39
pub const EV_TEXT_INPUT: int = 40
pub const EV_COMPOSITION_UPDATE: int = 41
pub const EV_COMPOSITION_CANCEL: int = 42
pub const EV_SEMANTICS_ACTION: int = 43
pub const EV_COUNT: int = 44

// ---- modifier bits ----

pub const MOD_SHIFT: int = 1
pub const MOD_CONTROL: int = 2
pub const MOD_ALT: int = 4
pub const MOD_COMMAND: int = 8

// ---- application roles ----

pub const ROLE_GUI: int = 0
pub const ROLE_ACCESSORY: int = 1
pub const ROLE_HEADLESS: int = 2

// ---- capabilities ----

pub const CAP_MENU_BAR: int = 1
pub const CAP_WINDOW_MENU: int = 2
pub const CAP_MULTI_SURFACE: int = 3
pub const CAP_RESIZABLE: int = 4
pub const CAP_FILE_DIALOG: int = 5
pub const CAP_SNAPSHOT: int = 6
pub const CAP_GPU: int = 7
pub const CAP_TOOLBAR: int = 8
pub const CAP_POPOVER: int = 9
pub const CAP_WEB: int = 10
pub const CAP_ICONS: int = 11
pub const CAP_NETWORK: int = 12
pub const CAP_POWER: int = 13
pub const CAP_LOCATION: int = 14
pub const CAP_BLUETOOTH: int = 15
pub const CAP_CAPTURE: int = 16
pub const CAP_SCREEN: int = 17

// ---- widget kinds ----

pub const W_CONTAINER: int = 0
pub const W_LABEL: int = 1
pub const W_BUTTON: int = 2
pub const W_TEXT_FIELD: int = 3
pub const W_CHECK_BOX: int = 4
pub const W_IMAGE_VIEW: int = 5
pub const W_SLIDER: int = 6
pub const W_PROGRESS_BAR: int = 7
pub const W_SEPARATOR: int = 8
pub const W_TEXT_AREA: int = 9
pub const W_COMBO_BOX: int = 10
pub const W_SCROLL_VIEW: int = 11
pub const W_RADIO_BUTTON: int = 12
pub const W_CANVAS: int = 13
pub const W_SWITCH: int = 14
pub const W_SECURE_FIELD: int = 15
pub const W_STEPPER: int = 16
pub const W_LEVEL_INDICATOR: int = 17
pub const W_TABLE: int = 18
pub const W_SEARCH_FIELD: int = 19
pub const W_SPINNER: int = 20
pub const W_LINK: int = 21
pub const W_SEGMENTED: int = 22
pub const W_GROUP_BOX: int = 23
pub const W_DATE_PICKER: int = 24
pub const W_COLOR_WELL: int = 25
pub const W_DISCLOSURE: int = 26
pub const W_TAB_VIEW: int = 27
pub const W_SPLIT_VIEW: int = 28
pub const W_WEB_VIEW: int = 29
pub const W_OUTLINE_VIEW: int = 30
pub const PERM_BLUETOOTH: int = 1
pub const PERM_LOCATION: int = 2
pub const PERM_CAMERA: int = 3
pub const PERM_MICROPHONE: int = 4
pub const PERM_SCREEN_CAPTURE: int = 5
pub const PERM_PHOTOS: int = 6
pub const PERM_MOTION: int = 7
pub const ALLOW_UNAVAILABLE: int = 0
pub const ALLOW_GRANTED: int = 1
pub const ALLOW_DENIED: int = 2
pub const ALLOW_UNDECIDED: int = 3
pub const EV_PERMISSION: int = 25
pub const EV_DISMISS: int = 26
pub const EV_WEB_STARTED: int = 27
pub const EV_WEB_FINISHED: int = 28
pub const EV_WEB_FAILED: int = 29
pub const EV_WEB_MESSAGE: int = 30
pub const EV_WEB_RESULT: int = 31

// ---- property keys ----

pub const P_CHECKED: int = 1
pub const P_ENABLED: int = 2
pub const P_HIDDEN: int = 3
pub const P_MIN: int = 4
pub const P_MAX: int = 5
pub const P_VALUE: int = 6
pub const P_EDITABLE: int = 7
pub const P_ALIGNMENT: int = 8
pub const P_FONT_SIZE: int = 9
pub const P_STEP: int = 10
pub const P_SELECTED: int = 11
pub const P_INDETERMINATE: int = 12
pub const P_OPACITY: int = 13
pub const P_ANIMATING: int = 14
pub const P_DATE: int = 15
pub const P_COLOR: int = 16
pub const P_EXPANDED: int = 17
pub const P_AXIS: int = 18
pub const P_DIVIDER: int = 19
pub const P_ICON: int = 20
pub const CAP_LAYER_STYLE: int = 18
pub const P_BG_COLOR: int = 21
pub const P_CORNER_RADIUS: int = 22
pub const P_BORDER_WIDTH: int = 23
pub const P_BORDER_COLOR: int = 24
pub const P_FOCUSABLE: int = 25
pub const P_A11Y_ROLE: int = 26
pub const P_FG_COLOR: int = 27
pub const P_LINES: int = 28
pub const P_CODE_MODE: int = 29
pub const P_BORDERLESS: int = 30
pub const P_COMPACT: int = 31
pub const P_FONT_WEIGHT: int = 32
pub const P_BASELINE: int = 33
pub const P_OVERHANG: int = 34
pub const P_PROMINENT: int = 35
pub const A11Y_AUTO: int = 0
pub const A11Y_BUTTON: int = 1
pub const A11Y_IMAGE: int = 2
pub const A11Y_GROUP: int = 3

// What an outline's source is being asked. See "outlines" in
// src/cortado_host.h.
pub const OUTLINE_ROOT: int = 0
pub const OUTLINE_CHILDREN: int = 0
pub const OUTLINE_CHILD: int = 1
pub const OUTLINE_EXPANDS: int = 2
pub const OUTLINE_ICON: int = 3

// The system icon roles. See "icons" in src/cortado_host.h.
pub const ICON_NONE: int = 0
pub const ICON_REFRESH: int = 1
pub const ICON_ADD: int = 2
pub const ICON_REMOVE: int = 3
pub const ICON_DELETE: int = 4
pub const ICON_OPEN: int = 5
pub const ICON_SAVE: int = 6
pub const ICON_SEARCH: int = 7
pub const ICON_RUN: int = 8
pub const ICON_STOP: int = 9
pub const ICON_BACK: int = 10
pub const ICON_FORWARD: int = 11
pub const ICON_CUT: int = 12
pub const ICON_COPY: int = 13
pub const ICON_PASTE: int = 14
pub const ICON_UNDO: int = 15
pub const ICON_REDO: int = 16
pub const ICON_PRINT: int = 17
pub const ICON_SETTINGS: int = 18
pub const ICON_INFO: int = 19
pub const ICON_WARNING: int = 20
pub const ICON_ERROR: int = 21
pub const ICON_HELP: int = 22
pub const ICON_DOCUMENT: int = 23
pub const ICON_FOLDER: int = 24
pub const ICON_DATABASE: int = 25
pub const ICON_TABLE: int = 26
pub const ICON_COUNT: int = 27
pub const S_HINT: int = 1
pub const S_URL: int = 2
pub const S_A11Y_LABEL: int = 3

// ---- which key space a number is in ----
// The two overlap: P_CHECKED and S_HINT are both 1, each indexing its own
// switch, so anything asking about a key without the call must say which.
pub const KEY_PROPERTY: int = 0
pub const KEY_TEXT: int = 1

// ---- animation curves ----

pub const CURVE_LINEAR: int = 0
pub const CURVE_EASE_IN: int = 1
pub const CURVE_EASE_OUT: int = 2
pub const CURVE_EASE_IN_OUT: int = 3

// Menu command roles. The platform places, names and keys a command that has
// one; a command with no role goes where the application puts it.
pub const CMD_NONE: int = 0
pub const CMD_ABOUT: int = 1
pub const CMD_PREFERENCES: int = 2
pub const CMD_QUIT: int = 3
pub const CMD_HIDE: int = 4
pub const CMD_UNDO: int = 5
pub const CMD_REDO: int = 6
pub const CMD_CUT: int = 7
pub const CMD_COPY: int = 8
pub const CMD_PASTE: int = 9
pub const CMD_SELECT_ALL: int = 10
pub const CMD_CLOSE: int = 11
pub const CMD_MINIMIZE: int = 12
pub const CMD_FULLSCREEN: int = 13

// Dialog kinds. Every one is asynchronous: the answer arrives as an event
// carrying the token the request was made with.
pub const DLG_MESSAGE: int = 0
pub const DLG_CONFIRM: int = 1
pub const DLG_OPEN: int = 2
pub const DLG_SAVE: int = 3

// The system's own fonts, by role, so a program never hard-codes a family that
// is wrong on three platforms out of four.
pub const FONT_BODY: int = 0
pub const FONT_HEADING: int = 1
pub const FONT_CAPTION: int = 2
pub const FONT_MONO: int = 3

// ---- the GPU ----
//
// Which shading languages this host accepts, as bits. Three languages and no
// translation between them: see "the GPU" in the header for why that is the
// honest answer rather than a portability failure.
pub const SHADER_MSL: int = 1
pub const SHADER_HLSL: int = 2
pub const SHADER_SPIRV: int = 4
pub const SHADER_GLSL: int = 8

// What a device can be asked about itself.
pub const GPU_UNIFIED_MEMORY: int = 1
pub const GPU_MAX_BUFFER_BYTES: int = 2
pub const GPU_MEMORY_BYTES: int = 3

// How a drawn pixel is mixed with the one already there. Three named modes
// rather than a pair of blend factors: every backend has these three and means
// the same by them, and a factor pair is eight enums to get right in a
// combination nothing checks.
pub const BLEND_REPLACE: int = 0
pub const BLEND_ALPHA: int = 1
pub const BLEND_ADD: int = 2

// What a draw call makes out of its vertices.
pub const SHAPE_TRIANGLES: int = 0
pub const SHAPE_TRIANGLE_STRIP: int = 1
pub const SHAPE_LINES: int = 2
pub const SHAPE_LINE_STRIP: int = 3
pub const SHAPE_POINTS: int = 4

// Which pixels a pipeline writes: an off-screen target's 8-bit RGBA, or
// whatever this platform's compositor shows a canvas in.
pub const PIXELS_RGBA8: int = 0
pub const PIXELS_SCREEN: int = 1
pub const EDGE_MIN_X: int = 0
pub const EDGE_MIN_Y: int = 1
pub const EDGE_MAX_X: int = 2
pub const EDGE_MAX_Y: int = 3

// ---- input ----

// Which pointer button, in an event's `index`. A trackpad's tap is left and
// its two-finger tap is right on every platform here, because that is what
// each platform already calls them.
pub const BTN_LEFT: int = 1
pub const BTN_RIGHT: int = 2
pub const BTN_MIDDLE: int = 3

// Which key, in an event's `index`.
//
// There is no code for a letter, a digit or a punctuation mark, and that is
// the design: a code per character is a keyboard layout written into an ABI —
// the key that types "z" on one keyboard types "y" on another — so every key
// that types something is `CHARACTER` and what it typed is the event's text,
// already composed and already through the input method. What is enumerated
// is the keys that type nothing and mean the same thing everywhere.
pub const KEY_UNKNOWN: int = 0
pub const KEY_CHARACTER: int = 1
pub const KEY_ESCAPE: int = 2
pub const KEY_TAB: int = 3
pub const KEY_RETURN: int = 4
pub const KEY_SPACE: int = 5
pub const KEY_BACKSPACE: int = 6
pub const KEY_DELETE: int = 7
pub const KEY_LEFT: int = 8
pub const KEY_RIGHT: int = 9
pub const KEY_UP: int = 10
pub const KEY_DOWN: int = 11
pub const KEY_HOME: int = 12
pub const KEY_END: int = 13
pub const KEY_PAGE_UP: int = 14
pub const KEY_PAGE_DOWN: int = 15
pub const KEY_F1: int = 16
pub const KEY_F2: int = 17
pub const KEY_F3: int = 18
pub const KEY_F4: int = 19
pub const KEY_F5: int = 20
pub const KEY_F6: int = 21
pub const KEY_F7: int = 22
pub const KEY_F8: int = 23
pub const KEY_F9: int = 24
pub const KEY_F10: int = 25
pub const KEY_F11: int = 26
pub const KEY_F12: int = 27
pub const KEY_COUNT: int = 28

// ---- the machine ----

// Whether anything is reachable, and over what. `UNKNOWN` is "nothing has
// answered yet", which is a real state and not a failure: one platform's
// answer is a push and arrives a turn of the loop later.
pub const NET_UNKNOWN: int = 0
pub const NET_NONE: int = 1
pub const NET_WIFI: int = 2
pub const NET_WIRED: int = 3
pub const NET_CELLULAR: int = 4
pub const NET_OTHER: int = 5

// A path is several things at once, so these are bits.
pub const NET_F_EXPENSIVE: int = 1
pub const NET_F_CONSTRAINED: int = 2

// What is running the machine.
pub const POWER_UNKNOWN: int = 0
pub const POWER_MAINS: int = 1
pub const POWER_BATTERY: int = 2

// How hot it is. Only Apple's platforms have a scale for this; everywhere else
// the honest answer is `UNKNOWN`, because a temperature in a sysfs file is a
// reading and this is a judgement.
pub const THERMAL_UNKNOWN: int = 0
pub const THERMAL_NOMINAL: int = 1
pub const THERMAL_FAIR: int = 2
pub const THERMAL_SERIOUS: int = 3
pub const THERMAL_CRITICAL: int = 4

// ---- the gated four ----

// Which kind of thing a machine listens or looks through.
pub const CAPTURE_CAMERA: int = 0
pub const CAPTURE_MICROPHONE: int = 1
