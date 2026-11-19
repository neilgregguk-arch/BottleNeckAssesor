#pragma once
#include <array>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <string_view>

namespace wpbd {
// Source-only native port of the existing canonical grammar. No OS/IPC/launch operations.
struct Request {
    std::wstring_view session;
    std::uint32_t relay_pid;
    std::int64_t relay_start;
    std::uint32_t duration;
    std::uint32_t interval;
};
constexpr std::optional<std::uint64_t> positive(std::wstring_view text, std::uint64_t maximum) {
    if (text.empty() || text.front() == L'0') return {};
    std::uint64_t value = 0;
    for (wchar_t ch : text) {
        if (ch < L'0' || ch > L'9') return {};
        const auto digit = static_cast<std::uint64_t>(ch - L'0');
        if (digit > maximum || value > (maximum - digit) / 10) return {};
        value = value * 10 + digit;
    }
    return value == 0 ? std::nullopt : std::optional{value};
}
constexpr std::optional<Request> parse(std::span<const std::wstring_view> args) {
    constexpr std::array names{L"--session", L"--relay-pid", L"--relay-start", L"--duration", L"--interval", L"--operation"};
    if (args.size() != 12) return {};
    std::array<std::wstring_view, 6> fields{};
    std::array<bool, 6> seen{};
    for (std::size_t n = 0; n < args.size(); n += 2) {
        std::size_t index = 0;
        while (index < names.size() && args[n] != names[index]) ++index;
        if (index == names.size() || seen[index]) return {};
        fields[index] = args[n + 1]; seen[index] = true;
    }
    if (fields[0].size() != 32 || fields[5] != L"token-probe-v1") return {};
    bool nonzero = false;
    for (wchar_t ch : fields[0]) {
        if (!((ch >= L'0' && ch <= L'9') || (ch >= L'a' && ch <= L'f'))) return {};
        if (ch != L'0') nonzero = true;
    }
    if (!nonzero) return {};
    const auto pid = positive(fields[1], (std::numeric_limits<std::uint32_t>::max)());
    const auto start = positive(fields[2], static_cast<std::uint64_t>((std::numeric_limits<std::int64_t>::max)()));
    const auto duration = positive(fields[3], 300);
    const auto interval = positive(fields[4], 10);
    if (!pid || !start || !duration || !interval ||
        (*duration != 30 && *duration != 60 && *duration != 120 && *duration != 300) ||
        (*interval != 1 && *interval != 2 && *interval != 5 && *interval != 10) || *interval > *duration) return {};
    return Request{fields[0], static_cast<std::uint32_t>(*pid), static_cast<std::int64_t>(*start),
        static_cast<std::uint32_t>(*duration), static_cast<std::uint32_t>(*interval)};
}
} // namespace wpbd
