#pragma once

#include <string>
#include <vector>

namespace mamba_ssm {

struct test_case {
    std::string id;
    std::vector<float> state_input;
    std::vector<float> x;
    std::vector<float> dt;
    std::vector<float> A;
    std::vector<float> B;
    std::vector<float> C;
};

const std::vector<test_case> & deterministic_test_cases();

} // namespace mamba_ssm
