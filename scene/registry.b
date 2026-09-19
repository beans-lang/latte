package scene

/// A window-local owner of render objects. A recycled slot changes generation.
/// Namespace ids are explicit, supplied by the composition root, not globals.
pub class RenderRegistry {
    namespace_value: u64
    slots: Map<int, RenderObject> = {}
    generations: Map<int, int> = {}
    free_slots: List<int> = []
    next_slot: int = 1
    pub fn init(namespace: int) { self.namespace_value = namespace as u64 }
    pub fn namespace() -> u64 { return self.namespace_value }
    pub fn count() -> int { return self.slots.len() }
    pub fn add(object: RenderObject) -> Result<u64> {
        if self.namespace_value == 0 || self.namespace_value > 32767 {
            return err("render namespace must be 1..32767", "out_of_range")
        }
        if object.identity != 0 { return err("render object already registered", "bad_owner") }
        var slot: int = self.next_slot
        if self.free_slots.len() > 0 {
            slot = self.free_slots[self.free_slots.len() - 1]
            self.free_slots.remove(self.free_slots.len() - 1)
        } else {
            if slot >= 2147483647 { return err("render registry is full", "out_of_range") }
            self.next_slot += 1
        }
        let generation: int = self.generations.get(slot).or(1)
        let handle: u64 = (1 as u64 << 63) | (self.namespace_value << 48) |
                          (generation as u64 << 32) | slot as u64
        object.identity = handle
        self.slots[slot] = object
        return ok(handle)
    }
    pub fn get(handle: u64) -> Option<RenderObject> {
        let slot: int = (handle & 0xffffffff) as int
        match self.slots.get(slot) {
            some(object) => { if object.identity == handle && object.alive { return some(object) } }
            none => {}
        }
        return none
    }
    pub fn release(handle: u64) {
        match self.get(handle) {
            none => {}
            some(object) => {
                match self.get(object.parent_id) { some(parent) => { parent.remove(object) } none => {} }
                // Release the registry's ownership of the whole subtree too.
                for object.child_count() > 0 {
                    match object.child_at(object.child_count() - 1) {
                        some(child) => { self.release(child.handle()) }
                        none => {}
                    }
                }
                object.dispose()
                let slot: int = (handle & 0xffffffff) as int
                self.slots.remove(slot)
                let generation: int = self.generations.get(slot).or(1) + 1
                self.generations[slot] = generation
                // Retire rather than wrap a generation: stale handles never revive.
                if generation <= 65535 { self.free_slots.push(slot) }
            }
        }
    }
    pub fn close() {
        let keys: List<int> = self.slots.keys()
        for slot: int in keys {
            match self.slots.get(slot) { some(object) => { self.release(object.identity) } none => {} }
        }
    }
}
