# Native refusal-stage source — uncompiled, not deployable

0.6.5 adds a minimal C++20 own-primary-token collector and canonical TokenProbeV1 request parser. **No native toolchain exists in the inspected host locations; no native compilation or execution is claimed.** CMake/MSVC/Windows SDK availability, static assertions, PE imports, loader flags, mitigations and actual token behaviour must be verified in an approved lab. Do not elevate this source's build outputs.

Only exactly six existing protocol argument pairs are supported. Parsing occurs before token queries. The worker queries only its own primary token, requires real elevation/enabled administrator/High integrity and then unconditionally refuses the unverified protected deployment. No endpoint/result-success path, file destination, command/script/executable launch, PowerShell, privilege adjustment, credentials or service control exists. Exceptions produce fixed refusal messages. Account/SID values are never output. The relay remains the blocked managed prototype; a native relay/UAC path is not implemented.

The proposed build uses static CRT, asInvoker manifest, x64/MSVC C++20, warnings as errors and loader/security linker options including System32-only static-import resolution. These are **source settings**, not inspected binary facts. System Windows DLLs/CRT-linked code remain dependencies, and actual PE/import/load traces plus environment/CWD/PATH substitution tests are required. [Microsoft's dependent-load flag guidance](https://learn.microsoft.com/en-us/cpp/build/reference/dependentloadflag?view=msvc-170) describes this mitigation; it is not a replacement for protected code and runtime validation.

After the lab owner explicitly provisions approved tools, ordinary-user compilation could use (run from `experiments/elevation-worker`):

```powershell
cmake -S native -B artifacts/native-065 -A x64
cmake --build artifacts/native-065 --config Release
ctest --test-dir artifacts/native-065 -C Release --output-on-failure
```

These commands were **not run** here and do not install/elevate anything. There is no install/package target. The 17 compile-time request checks are pending compilation, not passing tests. Generated files go only under ignored experimental artifacts; no binaries/keys/identifying test data belong in Git. Before even an isolated high test, independently review the native code/complete executable inventory and implement the protected-deployment and authenticated one-way transport gates. Do not merely delete the refusal or treat a user-writable hash list as authorisation.
