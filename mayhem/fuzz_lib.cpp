#include <cstdlib>
#include <fstream>
#include <string>
#include <unistd.h>

#include "pointmatcher/PointMatcher.h"

#include "FuzzedDataProvider.h"

typedef PointMatcher<float> PM;
typedef PM::DataPoints DP;

std::string create_file(FuzzedDataProvider& fdp, bool all_bytes = false) {
    std::string chosen_extension = fdp.PickValueInArray({".csv", ".vtk"});
    std::size_t file_len = fdp.ConsumeIntegralInRange<int>(0, 10000);
    // Use /dev/shm (a kernel tmpfs) — /tmp and the image root are read-only under
    // Mayhem's coverage-collection mode (docker run --read-only).
    std::string fuzz_file_name = "/dev/shm/lpm-fuzz-" +
        std::to_string(static_cast<long>(getpid())) + chosen_extension;

    // Write fuzzer data to temporary file
    std::ofstream fuzz_file{};
    fuzz_file.open(fuzz_file_name, std::ios::binary | std::ios::out);
    if (all_bytes) {
        fuzz_file << fdp.ConsumeRemainingBytesAsString();
    } else {
        fuzz_file << fdp.ConsumeBytesAsString(file_len);
    }
    fuzz_file.close();

    return fuzz_file_name;
}

extern "C" __attribute__((unused)) int LLVMFuzzerTestOneInput(const uint8_t *fuzz_data, size_t size) {
    FuzzedDataProvider fdp(fuzz_data, size);

    try {
        std::string ref_file_name = create_file(fdp, true);

        const DP ref = DP::load(ref_file_name);

        // Delete temporary file
        std::remove(ref_file_name.c_str());
    } catch (const PM::ConvergenceError& e) {
        return -1;
    } catch (boost::exception &e) {
        return -1;
    } catch (std::runtime_error &e) {
            return -1;
    }
    return 0;
}
