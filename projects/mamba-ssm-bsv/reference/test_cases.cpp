#include "test_cases.hpp"

#include <cstdint>
namespace mamba_ssm {
namespace {

std::vector<float> fixed(std::initializer_list<float> values) {
    return { values };
}

std::vector<float> random_values(uint32_t & state, int lo, int hi, size_t count) {
    std::vector<float> values;
    values.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        state = state * 1664525u + 1013904223u;
        const int q = lo + static_cast<int>((state >> 16) % static_cast<uint32_t>(hi - lo + 1));
        values.push_back(static_cast<float>(q) / 256.0f);
    }
    return values;
}

test_case random_case(const char * id, uint32_t seed) {
    uint32_t state = seed;
    return {
        id,
        random_values(state, -64, 64, 4),
        random_values(state, -64, 64, 2),
        random_values(state, -32, 32, 2),
        random_values(state, -256, -64, 4),
        random_values(state, -64, 64, 2),
        random_values(state, -64, 64, 2),
    };
}

} // namespace

const std::vector<test_case> & deterministic_test_cases() {
    static const std::vector<test_case> cases = {
        {
            "hand_small",
            fixed({ 0.25f, -0.5f, 0.75f, 1.0f }),
            fixed({ 1.0f, -1.0f }),
            fixed({ 0.0f, 0.0f }),
            fixed({ -1.0f, -1.0f, -1.0f, -1.0f }),
            fixed({ 0.0f, 0.0f }),
            fixed({ 1.0f, 0.0f }),
        },
        {
            "zero",
            fixed({ 0.0f, 0.0f, 0.0f, 0.0f }),
            fixed({ 0.0f, 0.0f }),
            fixed({ 0.0f, 0.0f }),
            fixed({ 0.0f, 0.0f, 0.0f, 0.0f }),
            fixed({ 0.0f, 0.0f }),
            fixed({ 0.0f, 0.0f }),
        },
        {
            "positive_x",
            fixed({ 0.0625f, 0.125f, 0.1875f, 0.25f }),
            fixed({ 0.125f, 0.25f }),
            fixed({ 0.0625f, 0.125f }),
            fixed({ -0.25f, -0.5f, -0.75f, -1.0f }),
            fixed({ 0.125f, 0.25f }),
            fixed({ 0.25f, 0.5f }),
        },
        {
            "negative_x",
            fixed({ 0.0625f, 0.125f, 0.1875f, 0.25f }),
            fixed({ -0.125f, -0.25f }),
            fixed({ 0.0625f, 0.125f }),
            fixed({ -0.25f, -0.5f, -0.75f, -1.0f }),
            fixed({ 0.125f, 0.25f }),
            fixed({ 0.25f, 0.5f }),
        },
        random_case("random_1a2b3c4d", 0x1A2B3C4Du),
        random_case("random_31415926", 0x31415926u),
        random_case("random_5eed1234", 0x5EED1234u),
        random_case("random_c0ffee01", 0xC0FFEE01u),
        random_case("random_deadbeef", 0xDEADBEEFu),
    };
    return cases;
}

} // namespace mamba_ssm
