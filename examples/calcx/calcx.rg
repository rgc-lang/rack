# calcx.rg — example package depending on mathx (shows transitive deps: calcx -> mathx@0.2.0)

import mathx

public def double_add(a: int, b: int) -> int {
    return mul(add(a, b), 2)
}

public def fib_sq(n: int) -> int {
    return mul(fib(n), fib(n))
}
