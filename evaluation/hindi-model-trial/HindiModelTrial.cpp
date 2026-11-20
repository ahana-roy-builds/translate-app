// Test adapter for whisper.cpp. This translation unit is linked only into the device benchmark.
#include "whisper.h"
#include <mach/mach.h>
#include <cstring>
#include <string>

extern "C" void *duet_trial_load(const char *model) {
    auto options = whisper_context_default_params();
    return whisper_init_from_file_with_params(model, options);
}

extern "C" int duet_trial_decode(void *handle, const float *audio, int count, char *output, int capacity) {
    auto *context = static_cast<whisper_context *>(handle);
    auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.language = "hi";
    params.translate = false;
    params.no_context = true;
    params.no_timestamps = true;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.n_threads = 4;
    if (whisper_full(context, params, audio, count) != 0) return -1;
    std::string result;
    for (int i = 0; i < whisper_full_n_segments(context); ++i) {
        result += whisper_full_get_segment_text(context, i);
    }
    if (capacity <= 0 || result.size() >= static_cast<size_t>(capacity)) return -2;
    std::memcpy(output, result.c_str(), result.size() + 1);
    return 0;
}

extern "C" void duet_trial_free(void *handle) {
    whisper_free(static_cast<whisper_context *>(handle));
}

extern "C" uint64_t duet_trial_peak_bytes() {
    task_vm_info_data_t stats{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&stats), &count) != KERN_SUCCESS) return 0;
    return stats.ledger_phys_footprint_peak;
}

// Task CPU energy only. The GPU and Apple's out-of-process services are separate.
extern "C" uint64_t duet_trial_cpu_energy_nj() {
    task_power_info_v2_data_t stats{};
    mach_msg_type_number_t count = TASK_POWER_INFO_V2_COUNT;
    if (task_info(mach_task_self(), TASK_POWER_INFO_V2, reinterpret_cast<task_info_t>(&stats), &count) != KERN_SUCCESS) return 0;
    return stats.task_energy;
}
