#pragma once
#include <cstdint>

namespace omp_protocol {
// Caller serializes access. A delivered authorization is never replayable; timeout after claim
// is UNKNOWN, not permission to retry. A late result can resolve uncertainty, never persist.
enum class Phase { Queued, Claimed, Applied, Failed, Expired, Unknown };
struct State {
    Phase phase = Phase::Queued;
    uint64_t deadline = 0;
    bool persistAllowed = false;
    explicit State(uint64_t until) : deadline(until) {}
    bool active() const { return phase == Phase::Queued || phase == Phase::Claimed || phase == Phase::Unknown; }
    void expire(uint64_t now) {
        if (now < deadline) return;
        if (phase == Phase::Queued) phase = Phase::Expired;
        else if (phase == Phase::Claimed) phase = Phase::Unknown;
    }
    bool claim(uint64_t now, bool eligible) {
        expire(now);
        if (!eligible || phase != Phase::Queued) return false;
        phase = Phase::Claimed; return true;
    }
    bool result(uint64_t now, bool success, bool stillEligible) {
        if (phase != Phase::Claimed && phase != Phase::Unknown) return false;
        persistAllowed = success && stillEligible && now < deadline && phase == Phase::Claimed;
        phase = success ? Phase::Applied : Phase::Failed; return true;
    }
};
}
