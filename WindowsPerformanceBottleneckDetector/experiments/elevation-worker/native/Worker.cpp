#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <cstddef>
#include <cstdio>
#include <vector>
#include "Request.h"

namespace {
struct Token {
    HANDLE value = nullptr;
    ~Token() { if (value != nullptr) CloseHandle(value); }
    Token() = default;
    Token(const Token&) = delete;
    Token& operator=(const Token&) = delete;
};
struct TokenFacts {
    bool available = false;
    bool elevated = false;
    bool admin_enabled = false;
    DWORD integrity = 0;
};
bool query(HANDLE token, TOKEN_INFORMATION_CLASS kind, std::vector<std::byte>& buffer) {
    DWORD required = 0;
    if (GetTokenInformation(token, kind, nullptr, 0, &required) != FALSE || GetLastError() != ERROR_INSUFFICIENT_BUFFER ||
        required == 0 || required > 65536) return false;
    buffer.resize(required);
    return GetTokenInformation(token, kind, buffer.data(), static_cast<DWORD>(buffer.size()), &required) != FALSE && required <= buffer.size();
}
// Own primary token ONLY; no credentials, other-process memory, privilege adjustment or output destination.
TokenFacts own_token() {
    TokenFacts facts{};
    Token token;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token.value)) return facts;
    TOKEN_TYPE type{}; DWORD size = 0;
    if (!GetTokenInformation(token.value, TokenType, &type, static_cast<DWORD>(sizeof(type)), &size) || type != TokenPrimary) return facts;
    TOKEN_ELEVATION elevation{};
    if (!GetTokenInformation(token.value, TokenElevation, &elevation, static_cast<DWORD>(sizeof(elevation)), &size)) return facts;
    std::vector<std::byte> integrity;
    if (!query(token.value, TokenIntegrityLevel, integrity) || integrity.size() < sizeof(TOKEN_MANDATORY_LABEL)) return facts;
    const auto label = reinterpret_cast<const TOKEN_MANDATORY_LABEL*>(integrity.data());
    if (!IsValidSid(label->Label.Sid)) return facts;
    const auto count = *GetSidSubAuthorityCount(label->Label.Sid);
    if (count == 0) return facts;
    facts.integrity = *GetSidSubAuthority(label->Label.Sid, static_cast<DWORD>(count - 1));
    if (facts.integrity > static_cast<DWORD>((std::numeric_limits<std::int32_t>::max)())) return TokenFacts{};
    std::vector<std::byte> groups;
    if (!query(token.value, TokenGroups, groups) || groups.size() < offsetof(TOKEN_GROUPS, Groups)) return TokenFacts{};
    const auto all = reinterpret_cast<const TOKEN_GROUPS*>(groups.data());
    if (all->GroupCount > 2048 || all->GroupCount > (groups.size() - offsetof(TOKEN_GROUPS, Groups)) / sizeof(SID_AND_ATTRIBUTES)) return TokenFacts{};
    for (DWORD i = 0; i < all->GroupCount; ++i) {
        const auto& group = all->Groups[i];
        if (!IsValidSid(group.Sid)) return TokenFacts{};
        if (IsWellKnownSid(group.Sid, WinBuiltinAdministratorsSid) &&
            (group.Attributes & SE_GROUP_ENABLED) != 0 && (group.Attributes & SE_GROUP_USE_FOR_DENY_ONLY) == 0)
            facts.admin_enabled = true;
    }
    facts.elevated = elevation.TokenIsElevated != 0;
    facts.available = true;
    return facts;
}
// No define, argument, manifest or environment switch authorises deployment. The future
// reviewed native inventory/signature/ACL/identity implementation must replace this blocker.
constexpr bool protected_deployment_verified() noexcept { return false; }
}

int wmain(int argc, wchar_t* argv[]) {
    // Refusal-stage native SOURCE ONLY. Never elevate an unreviewed build.
    if (argc != 13) { std::fputs("Worker refused: exactly six fixed argument pairs required.\n", stderr); return 2; }
    std::array<std::wstring_view, 12> args{};
    for (std::size_t i = 0; i < args.size(); ++i) args[i] = argv[i + 1];
    if (!wpbd::parse(args)) { std::fputs("Worker refused: unsupported/noncanonical request.\n", stderr); return 2; }
    try {
        const auto facts = own_token();
        if (!facts.available || !facts.elevated || !facts.admin_enabled || facts.integrity < SECURITY_MANDATORY_HIGH_RID) {
            std::fputs("Worker refused: required primary token unavailable.\n", stderr); return 3;
        }
        if (!protected_deployment_verified()) {
            std::fputs("Worker refused: protected deployment and authenticated channel unavailable.\n", stderr); return 4;
        }
        // Intentionally no endpoint or success result. Native UAC, protected recipient
        // authentication, protocol sender and bounded lifetime are NOT implemented here.
        return 4;
    } catch (...) {
        std::fputs("Worker refused: bounded token inspection failed.\n", stderr); return 4;
    }
}
