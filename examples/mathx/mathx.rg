# mathx.rg — example registry package: a small math utility module
# publish with rack: run `rack publish` in rack/examples/mathx

public def add(a: int, b: int) -> int {
    return a + b
}

public def mul(a: int, b: int) -> int {
    return a * b
}

# 0/1/1/2/3/5/8 ...
public def fib(n: int) -> int {
    if n <= 1 {
        return n
    }
    a = 0
    b = 1
    i = 2
    while i <= n {
        t = a + b
        a = b
        b = t
        i = i + 1
    }
    return b
}

public def square_sum(n: int) -> int {
    total = 0
    for i in range(n + 1) {
        total = total + mul(i, i)
    }
    return total
}
