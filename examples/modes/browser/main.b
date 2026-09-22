// The browser entry: what `client` regions of this application run in.
//
// It imports `modes.site` and NOTHING else of the application. `modes.server`
// — the note store and the action group — is not reachable from here, so it
// is not in the bundle, and `tools/client_check.mjs` asks the bundle what it
// can build and requires that to be true.
//
// The ten exports are the page's whole surface. They are declared here and
// not in `latte_client` because `--emit shared` exports the `pub extern "C"`
// names of the module being BUILT; `latte build --client` writes this file
// for an application that has none.
package main

import modes.site
import {action_cancel_raw, action_result_raw, actions_in_flight, boot_raw,
        catalogue_raw, event_raw, last_error_raw, mount_raw,
        install_action_transport, props_raw, take_raw,
        unmount_raw} from latte_client


// The page's half of a server action. Declared HERE, in a module that only
// ever builds for a browser, and installed into the region runtime at boot:
// a declaration inside `latte_client` would put these symbols in the SERVER
// binary too, because a client component that calls an action imports that
// module and the server renders the same component for the prerender.
pub extern "C" fn latte_js_action(call: i32, name: RawPtr<i8>, name_len: i32,
                                  body: RawPtr<i8>, body_len: i32) -> i32
pub extern "C" fn latte_js_action_cancel(call: i32) -> i32

fn send_action(call: int, name: RawPtr<i8>, name_len: int,
               body: RawPtr<i8>, body_len: int) -> int {
    unsafe {
        return latte_js_action(call as i32, name, name_len as i32,
                               body, body_len as i32) as int
    }
}

fn cancel_action(call: int) -> int {
    unsafe { return latte_js_action_cancel(call as i32) as int }
}

pub extern "C" fn latte_client_boot() -> i32 {
    install_action_transport(send_action, cancel_action)
    return boot_raw() as i32
}

pub extern "C" fn latte_client_mount(id: RawPtr<i8>, id_len: i32,
                                     name: RawPtr<i8>, name_len: i32,
                                     props: RawPtr<i8>, props_len: i32) -> i32 {
    return mount_raw(id, id_len as int, name, name_len as int,
                     props, props_len as int) as i32
}

pub extern "C" fn latte_client_props(handle: i32, props: RawPtr<i8>,
                                     props_len: i32) -> i32 {
    return props_raw(handle as int, props, props_len as int) as i32
}

pub extern "C" fn latte_client_event(handle: i32, message: RawPtr<i8>,
                                     message_len: i32) -> i32 {
    return event_raw(handle as int, message, message_len as int) as i32
}

pub extern "C" fn latte_client_take(handle: i32, out: RawPtr<i8>,
                                    cap: i32) -> i32 {
    return take_raw(handle as int, out, cap as int) as i32
}

pub extern "C" fn latte_client_unmount(handle: i32) -> i32 {
    return unmount_raw(handle as int) as i32
}

pub extern "C" fn latte_client_last_error(out: RawPtr<i8>, cap: i32) -> i32 {
    return last_error_raw(out, cap as int) as i32
}

pub extern "C" fn latte_client_catalogue(out: RawPtr<i8>, cap: i32) -> i32 {
    return catalogue_raw(out, cap as int) as i32
}

pub extern "C" fn latte_client_action_result(call: i32, ok: i32,
                                             payload: RawPtr<i8>,
                                             payload_len: i32) -> i32 {
    return action_result_raw(call as int, ok as int, payload,
                             payload_len as int) as i32
}

pub extern "C" fn latte_client_action_cancel(call: i32) -> i32 {
    return action_cancel_raw(call as int) as i32
}

pub extern "C" fn latte_client_in_flight() -> i32 {
    return actions_in_flight() as i32
}

/// Never called in a browser: `--emit shared` has no `_start`. It is here
/// because a module root declares an entry, and it does nothing.
fn main() {}
