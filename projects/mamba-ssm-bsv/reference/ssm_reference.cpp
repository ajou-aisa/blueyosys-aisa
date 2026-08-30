#include "test_cases.hpp"

#include "ggml-alloc.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "ggml.h"

#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr int64_t D_STATE  = 2;
constexpr int64_t HEAD_DIM = 1;
constexpr int64_t N_HEAD   = 2;
constexpr int64_t N_GROUP  = 1;
constexpr int64_t N_TOKEN  = 1;
constexpr int64_t N_SEQ    = 1;
constexpr int64_t K        = 1;

struct tensor_dump {
    std::string          name;
    std::vector<int64_t> shape;
    std::vector<float>   values;
};

uint32_t float_bits(float value) {
    uint32_t bits;
    static_assert(sizeof(bits) == sizeof(value));
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

uint32_t q16_bits(float value) {
    const int32_t q16 = static_cast<int32_t>(std::lround(value * 65536.0f));
    uint32_t bits;
    static_assert(sizeof(bits) == sizeof(q16));
    std::memcpy(&bits, &q16, sizeof(bits));
    return bits;
}

void write_header(std::ostream & out) {
    out << "format mamba_ssm_reference_v1\n";
    out << "d_state " << D_STATE << '\n';
    out << "head_dim " << HEAD_DIM << '\n';
    out << "n_head " << N_HEAD << '\n';
    out << "n_group " << N_GROUP << '\n';
    out << "n_token " << N_TOKEN << '\n';
    out << "n_seq " << N_SEQ << '\n';
    out << "ids 0\n";
    out << "ggml_packed_output y,new_state\n\n";
}

void write_tensor(std::ostream & out, const tensor_dump & tensor) {
    out << "tensor " << tensor.name << '\n';
    out << "shape";
    for (const int64_t dim : tensor.shape) {
        out << ' ' << dim;
    }
    out << "\ndata\n";

    for (size_t i = 0; i < tensor.values.size(); ++i) {
        out << i << ' '
            << std::setprecision(std::numeric_limits<float>::max_digits10) << tensor.values[i]
            << " 0x" << std::hex << std::setw(8) << std::setfill('0') << float_bits(tensor.values[i])
            << std::dec << std::setfill(' ') << '\n';
    }
    out << "end\n\n";
}

void write_file(const std::filesystem::path & path, const std::vector<tensor_dump> & tensors) {
    std::ofstream out(path);
    if (!out) {
        throw std::runtime_error("failed to open " + path.string());
    }

    write_header(out);
    for (const tensor_dump & tensor : tensors) {
        write_tensor(out, tensor);
    }
}

void write_input_file(const std::filesystem::path & path, const std::vector<tensor_dump> & tensors) {
    std::ofstream out(path);
    if (!out) {
        throw std::runtime_error("failed to open " + path.string());
    }

    out << "// mamba_ssm_q16_v1\n";
    out << "// Q16.16 words in GGML tensor order\n";
    for (const tensor_dump & tensor : tensors) {
        out << "// " << tensor.name << '\n';
        for (const float value : tensor.values) {
            out << std::hex << std::setw(8) << std::setfill('0') << q16_bits(value)
                << std::dec << std::setfill(' ') << '\n';
        }
    }
}

void print_tensors(const std::vector<tensor_dump> & tensors) {
    write_header(std::cout);
    for (const tensor_dump & tensor : tensors) {
        write_tensor(std::cout, tensor);
    }
}

void generate_reference(
    const std::filesystem::path & vector_dir,
    const std::vector<float> & state_data,
    const std::vector<float> & x_data,
    const std::vector<float> & dt_data,
    const std::vector<float> & A_data,
    const std::vector<float> & B_data,
    const std::vector<float> & C_data,
    bool print_results) {
    std::filesystem::create_directories(vector_dir);

    const int32_t ids_data[] = { 0 };

    ggml_init_params init_params = {};
    init_params.mem_size   = 1U << 20;
    init_params.mem_buffer = nullptr;
    init_params.no_alloc   = true;

    ggml_context * ctx = ggml_init(init_params);
    if (ctx == nullptr) {
        throw std::runtime_error("ggml_init failed");
    }

    ggml_tensor * state = ggml_new_tensor_4d(ctx, GGML_TYPE_F32, D_STATE, HEAD_DIM, N_HEAD, N_SEQ);
    ggml_tensor * x     = ggml_new_tensor_4d(ctx, GGML_TYPE_F32, HEAD_DIM, N_HEAD, N_TOKEN, N_SEQ);
    ggml_tensor * dt    = ggml_new_tensor_3d(ctx, GGML_TYPE_F32, N_HEAD, N_TOKEN, N_SEQ);
    ggml_tensor * A     = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, D_STATE, N_HEAD);
    ggml_tensor * B     = ggml_new_tensor_4d(ctx, GGML_TYPE_F32, D_STATE, N_GROUP, N_TOKEN, N_SEQ);
    ggml_tensor * C     = ggml_new_tensor_4d(ctx, GGML_TYPE_F32, D_STATE, N_GROUP, N_TOKEN, N_SEQ);
    ggml_tensor * ids   = ggml_new_tensor_1d(ctx, GGML_TYPE_I32, N_SEQ);

    ggml_set_name(state, "state_input");
    ggml_set_name(x, "x");
    ggml_set_name(dt, "dt");
    ggml_set_name(A, "A");
    ggml_set_name(B, "B");
    ggml_set_name(C, "C");
    ggml_set_name(ids, "ids");

    ggml_tensor * output = ggml_ssm_scan(ctx, state, x, dt, A, B, C, ids, K);
    ggml_set_name(output, "ssm_scan_output");

    ggml_backend_t backend = ggml_backend_cpu_init();
    if (backend == nullptr) {
        ggml_free(ctx);
        throw std::runtime_error("ggml_backend_cpu_init failed");
    }
    ggml_backend_cpu_set_n_threads(backend, 1);

    ggml_backend_buffer_t buffer = ggml_backend_alloc_ctx_tensors(ctx, backend);
    if (buffer == nullptr) {
        ggml_backend_free(backend);
        ggml_free(ctx);
        throw std::runtime_error("ggml_backend_alloc_ctx_tensors failed");
    }

    ggml_backend_tensor_set(state, state_data.data(), 0, state_data.size() * sizeof(float));
    ggml_backend_tensor_set(x, x_data.data(), 0, x_data.size() * sizeof(float));
    ggml_backend_tensor_set(dt, dt_data.data(), 0, dt_data.size() * sizeof(float));
    ggml_backend_tensor_set(A, A_data.data(), 0, A_data.size() * sizeof(float));
    ggml_backend_tensor_set(B, B_data.data(), 0, B_data.size() * sizeof(float));
    ggml_backend_tensor_set(C, C_data.data(), 0, C_data.size() * sizeof(float));
    ggml_backend_tensor_set(ids, ids_data, 0, sizeof(ids_data));

    ggml_cgraph * graph = ggml_new_graph(ctx);
    ggml_build_forward_expand(graph, output);

    const ggml_status status = ggml_backend_graph_compute(backend, graph);
    if (status != GGML_STATUS_SUCCESS) {
        ggml_backend_buffer_free(buffer);
        ggml_backend_free(backend);
        ggml_free(ctx);
        throw std::runtime_error("ggml_backend_graph_compute failed");
    }

    const size_t y_count = static_cast<size_t>(HEAD_DIM * N_HEAD * N_TOKEN * N_SEQ);
    const size_t state_count = static_cast<size_t>(D_STATE * HEAD_DIM * N_HEAD * N_SEQ);
    std::vector<float> packed_output(y_count + state_count);
    ggml_backend_tensor_get(output, packed_output.data(), 0, packed_output.size() * sizeof(float));

    std::vector<float> y_data(
        packed_output.begin(),
        packed_output.begin() + static_cast<std::ptrdiff_t>(y_count));
    std::vector<float> new_state_data(
        packed_output.begin() + static_cast<std::ptrdiff_t>(y_count),
        packed_output.end());

    const std::vector<tensor_dump> inputs = {
        { "state_input", { D_STATE, HEAD_DIM, N_HEAD, N_SEQ }, state_data },
        { "x",           { HEAD_DIM, N_HEAD, N_TOKEN, N_SEQ }, x_data },
        { "dt",          { N_HEAD, N_TOKEN, N_SEQ }, dt_data },
        { "A",           { D_STATE, N_HEAD }, A_data },
        { "B",           { D_STATE, N_GROUP, N_TOKEN, N_SEQ }, B_data },
        { "C",           { D_STATE, N_GROUP, N_TOKEN, N_SEQ }, C_data },
    };
    const std::vector<tensor_dump> expected = {
        { "new_state", { D_STATE, HEAD_DIM, N_HEAD, N_SEQ }, new_state_data },
        { "y",         { HEAD_DIM, N_HEAD, N_TOKEN, N_SEQ }, y_data },
    };

    write_input_file(vector_dir / "input.txt", inputs);
    write_file(vector_dir / "expected.txt", expected);

    if (print_results) {
        std::cout << "INPUTS\n\n";
        print_tensors(inputs);
        std::cout << "EXPECTED OUTPUTS\n\n";
        print_tensors(expected);
    }

    ggml_backend_buffer_free(buffer);
    ggml_backend_free(backend);
    ggml_free(ctx);
}

void validate_case_catalog(const std::vector<mamba_ssm::test_case> & cases) {
    if (cases.size() != 9) {
        throw std::runtime_error("case catalog must contain exactly nine cases");
    }

    std::set<std::string> ids;
    for (const mamba_ssm::test_case & test : cases) {
        if (test.id.empty() || test.id.find_first_of("/\\") != std::string::npos || !ids.insert(test.id).second) {
            throw std::runtime_error("case catalog contains an unsafe or duplicate ID");
        }
        if (test.state_input.size() != 4 || test.x.size() != 2 || test.dt.size() != 2 ||
            test.A.size() != 4 || test.B.size() != 2 || test.C.size() != 2) {
            throw std::runtime_error("case catalog contains an invalid tensor shape");
        }
    }
}

void generate_cases(const std::filesystem::path & root) {
    if (std::filesystem::exists(root)) {
        if (!std::filesystem::is_directory(root)) {
            throw std::runtime_error("cases root is not a directory: " + root.string());
        }
        if (std::filesystem::directory_iterator(root) != std::filesystem::directory_iterator()) {
            throw std::runtime_error("cases root must be empty: " + root.string());
        }
    } else {
        std::filesystem::create_directories(root);
    }

    const std::vector<mamba_ssm::test_case> & cases = mamba_ssm::deterministic_test_cases();
    validate_case_catalog(cases);

    std::ofstream manifest(root / "manifest.txt");
    if (!manifest) {
        throw std::runtime_error("failed to open " + (root / "manifest.txt").string());
    }
    manifest << "format mamba_ssm_case_manifest_v1\n";
    for (const mamba_ssm::test_case & test : cases) {
        manifest << "case " << test.id << '\n';
    }
    manifest.close();
    if (!manifest) {
        throw std::runtime_error("failed to write " + (root / "manifest.txt").string());
    }

    for (const mamba_ssm::test_case & test : cases) {
        generate_reference(root / test.id, test.state_input, test.x, test.dt, test.A, test.B, test.C, false);
    }
}

void generate_legacy_reference(const std::filesystem::path & vector_dir) {
    const std::vector<float> state_data = {
         0.125f, -0.250f,
         0.375f,  0.500f,
    };
    const std::vector<float> x_data = {
         0.50f,
        -0.25f,
    };
    const std::vector<float> dt_data = {
         0.125f,
        -0.250f,
    };
    const std::vector<float> A_data = {
        -0.50f, -1.00f,
        -0.25f, -0.75f,
    };
    const std::vector<float> B_data = {
         0.25f, -0.50f,
    };
    const std::vector<float> C_data = {
         0.50f,  0.75f,
    };
    generate_reference(vector_dir, state_data, x_data, dt_data, A_data, B_data, C_data, true);
}

void print_usage() {
    std::cout << "usage: ssm_reference [vector-directory]\n"
              << "       ssm_reference --cases-root <directory>\n";
}

} // namespace

int main(int argc, char ** argv) {
    try {
        if (argc == 2 && (std::string(argv[1]) == "--help" || std::string(argv[1]) == "-h")) {
            print_usage();
            return 0;
        }
        if (argc == 2 && std::string(argv[1]) == "--cases-root") {
            throw std::runtime_error("usage: ssm_reference --cases-root <directory>");
        }
        if (argc == 3 && std::string(argv[1]) == "--cases-root") {
            generate_cases(argv[2]);
            return 0;
        }
        if (argc > 2 || (argc == 2 && (std::string(argv[1]).empty() || std::string(argv[1]).front() == '-'))) {
            throw std::runtime_error("usage: ssm_reference [vector-directory] | --cases-root <directory>");
        }

        generate_legacy_reference(argc == 2 ? argv[1] : "vectors");
        return 0;
    } catch (const std::exception & error) {
        std::cerr << "ssm_reference: " << error.what() << '\n';
        return 1;
    }
}
