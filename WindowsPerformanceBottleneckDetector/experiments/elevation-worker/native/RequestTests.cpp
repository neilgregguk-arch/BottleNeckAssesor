#include "Request.h"
#include <cstdio>

// These compile-time native checks have NOT been compiled on the current host.
constexpr std::array<std::wstring_view, 12> base{L"--session", L"1234567890abcdef1234567890abcdef", L"--relay-pid", L"42",
    L"--relay-start", L"133000000000000000", L"--duration", L"30", L"--interval", L"2", L"--operation", L"token-probe-v1"};
constexpr bool rejected(std::size_t index, std::wstring_view value) { auto args = base; args[index] = value; return !wpbd::parse(args).has_value(); }
static_assert(wpbd::parse(base).has_value());
static_assert(wpbd::parse(base)->relay_pid == 42);
static_assert(rejected(0, L"--command"));
static_assert(rejected(0, L"--script"));
static_assert(rejected(0, L"--output"));
static_assert(rejected(2, L"--session"));
static_assert(rejected(3, L"0"));
static_assert(rejected(3, L"042"));
static_assert(rejected(3, L"+42"));
static_assert(rejected(3, L"42;command"));
static_assert(rejected(3, L"4294967296"));
static_assert(rejected(5, L"9223372036854775808"));
static_assert(rejected(7, L"31"));
static_assert(rejected(9, L"3"));
static_assert(rejected(11, L"diagnose-v1"));
static_assert(rejected(1, L"00000000000000000000000000000000"));
static_assert(rejected(1, L"1234567890ABCDEF1234567890ABCDEF"));
int main() { std::puts("17 native request compile-time checks compiled successfully; no Windows security boundary tested."); }
