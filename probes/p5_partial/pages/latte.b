// The bits of latte the partial-class probe needs, standing in for the real
// package: the builder, the base component, and the annotations a `<beans>`
// block carries. Runtime retention, because latte's page scan reads them
// back through reflection at startup.
package pages

@target(value: ["type"])
@retention(value: "runtime")
annotation page {
    route: string
}

@target(value: ["type"])
@retention(value: "runtime")
annotation layout {
    name: string = "Main"
}

@target(value: ["field"])
@retention(value: "runtime")
annotation param {
    required: bool = false
}
