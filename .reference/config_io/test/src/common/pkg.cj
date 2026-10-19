package config_test.common

public func assertEq(name: String, actual: String, expected: String): Bool {
    if (actual == expected) {
        println("  [PASS] ${name} = ${actual}")
        return true
    } else {
        println("  [FAIL] ${name} = ${actual} (期望: ${expected})")
        return false
    }
}

public func assertEq(name: String, actual: Bool, expected: Bool): Bool {
    if (actual == expected) {
        println("  [PASS] ${name} = ${actual}")
        return true
    } else {
        println("  [FAIL] ${name} = ${actual} (期望: ${expected})")
        return false
    }
}

public func assertEq(name: String, actual: Int64, expected: Int64): Bool {
    if (actual == expected) {
        println("  [PASS] ${name} = ${actual}")
        return true
    } else {
        println("  [FAIL] ${name} = ${actual} (期望: ${expected})")
        return false
    }
}

public func assertTrue(name: String, cond: Bool): Bool {
    if (cond) {
        println("  [PASS] ${name}")
        return true
    } else {
        println("  [FAIL] ${name}")
        return false
    }
}

public func assertFalse(name: String, cond: Bool): Bool {
    assertTrue(name, !cond)
}

public func section(title: String): Unit {
    println("\n--- ${title} ---")
}

public func report(pass: Int64, fail: Int64): Unit {
    println("  小计: ${pass} PASS, ${fail} FAIL")
}
