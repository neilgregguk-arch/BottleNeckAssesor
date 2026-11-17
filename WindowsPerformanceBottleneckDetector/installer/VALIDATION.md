# WPBD 0.4 installer validation

Verified on 17 November 2026 on the Windows 11 development workstation. Compilation used .NET SDK 10.0.303 and Inno Setup 6.7.4. The compiler was extracted to a temporary tools directory from the official, Authenticode-verified release. Generated installer files and test logs stay outside source control.

## Results

- Release WPF build succeeded with zero warnings and zero errors.
- All 49 engine Pester tests and 9 .NET regression checks passed.
- The installer build checked the self-contained runtime, WPF runtime files and all five bundled engine files. A missing-compiler invocation stopped with an actionable error.
- A fresh install to the default current-user directory completed. The Setup log recorded non-administrative installation and current-user registry registration.
- Start menu and optional desktop shortcuts resolved to the installed executable. Both shortcuts were used to launch WPBD. The installed process loaded coreclr.dll from the installed program folder.
- The installed app displayed version 0.4.0 and its application icon.
- A 60-second diagnostic started through the installed GUI and displayed live readings and graphs. It collected 30 of 30 samples, including 30 valid CPU samples, with zero missed samples and zero collection-error groups. The actual sampling duration was 60.18 seconds. A paired JSON and HTML report was generated under the existing user report directory.
- Cancellation through the installed UI stopped a second session after three samples. The report directory contents were unchanged.
- A silent 0.4.1 test upgrade was rejected while WPBD was running. The installed version and active process remained intact.
- After closing WPBD, the 0.4.1 test installer upgraded the existing app in place. Installed Apps contained one WPBD entry with the updated version. SHA-256 comparisons verified that all 17 recorded report, log and preference files were unchanged.
- The desktop shortcut launched version 0.4.1 with the previously selected 30-second duration. The upgraded GUI reopened a historical report from before installation.
- Uninstall removed the program directory, both shortcuts and the Installed Apps entry. All 17 recorded user-data files survived unchanged.
- Reinstalling release 0.4.0 succeeded and preserved user data. The default task selection omitted the optional desktop shortcut. WPBD was left installed at release 0.4.0.
- The original PowerShell CLI ran a short diagnostic and retained JSON schema 0.2.

## Deployment checks still required

Windows Sandbox is unavailable on this host. A clean workstation without developer tools, Windows 10, organisation-specific application-control policies, physical DPI settings, and production Authenticode signing require separate validation. Installation and diagnostics on this development workstation establish local functionality.

The release installer is unsigned. The test build override 0.4.1 is kept only in the temporary QA output. The authoritative release version remains 0.4.0.

## Process browsing update 0.4.2

The 0.4.2 WPF build passed with zero warnings and errors. All 55 Pester tests and 11 .NET checks passed, including process identity, Teams/WebView2 ownership, different hosts, termination, missing memory, timestamp-aligned aggregation and reconstruction from older report samples. Live Windows integration completed 15 of 15 scheduled samples and verified cancellation without partial export. A separate live report grouped two Teams processes with eight WebView2 descendants under Microsoft Teams.

The 0.4.2 installer compiled successfully with the new engine file bundled. This update's installer has not repeated the full install/upgrade/uninstall cycle above. Visual inspection of the updated process tabs was blocked by the computer-use helper returning a window ownership error. Windows 10 and Task Manager private resident working-set comparison remain unverified. The schema remains 0.2 with documented optional fields.
