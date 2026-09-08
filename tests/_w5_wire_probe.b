package main

import {WireLimits, ClientMessage, decode_client, write_json_string, encode_bye} from latte
import std.fmt
import std.io

fn show(text: string) {
    let limits: WireLimits = new WireLimits()
    let m: ClientMessage = decode_client(text, limits)
    io.println("{text}")
    io.println("  -> kind={m.kind} fault=[{m.fault}] h={m.handler} k={m.event} fam={m.family} x={m.x} v=[{m.text}] c={m.circuit} b={m.batch} fields={m.fields.len()}")
}

fn main() {
    show(r#"{"t":"attach","c":"abc","u":"/counter/3"}"#)
    show(r#"{"t":"ev","h":9,"k":"click","p":{"b":0,"x":12,"y":34}}"#)
    show(r#"{"t":"ev","h":9,"k":"input","p":{"v":"hi A😀","c":true}}"#)
    show(r#"{"t":"ack","b":42}"#)
    show(r#"{"t":"ev","h":9,"k":"submit","p":{"f":{"name":"bo","n":3}}}"#)
    show(r#"{"t":"ev","h":9,"k":"wat"}"#)
    show(r#"{"t":"ack","b":1e999}"#)
    show(r#"{"t":"ack","b":9223372036854775808}"#)
    show(r#"[1,2,3]"#)
    show(r#"{"t":"ack","b":1} trailing"#)
    show(r#"{"t":"attach","c":"a"} "#)
    show(r#"{"t":"ev","h":9,"k":"input","p":{"v":"\ud83d"}}"#)
    show(r#"{"t":"ack","b":01}"#)
    var deep: fmt.StringBuilder = new fmt.StringBuilder()
    for i: int in 0..40 { deep.push("[") }
    show(deep.to_string())

    var out: fmt.StringBuilder = new fmt.StringBuilder()
    write_json_string(out, "a\"b\\c<d\ne\u{2028}f\u{1f600}g\x01")
    io.println("escaped: {out.to_string()}")
    io.println(encode_bye("limit", "the inbox is full"))
}
