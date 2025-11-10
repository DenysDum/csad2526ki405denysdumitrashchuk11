#include "math_operations.h"
#include <cassert>
#include <iostream>

int main() {
    // Test add function
    assert(add(2, 3) == 5);
    assert(add(-1, 1) == 0);
    assert(add(0, 0) == 0);
    assert(add(-5, -7) == -12);

    std::cout << "All unit tests passed." << std::endl;
    return 0;
}
