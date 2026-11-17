# Process identity review for 0.5

The 0.4.2 analysis builds keys as PID/start time when start time is available. When start time is inaccessible it instead uses unknown/PID/sample-slot. Each sample therefore creates a separate identity for the same continuously observed restricted process. Application grouping uses these statistics rows as its member list, which inflates identity counts and unattributed membership. The same-sample memory totals do not sum those separate peaks, so the count inflation is distinct from memory aggregation.

The 0.4.2 desktop preserves Statistics.Processes.All exactly. Its raw-sample fallback for earlier reports repeats the same unknown/PID/slot rule. The broad Unattributed group also combines accessible processes with missing ownership evidence, restricted metadata and unknown identities. Windows service metadata was not collected.

Version 0.5 uses PID/start time for verified identities and a session-local provisional key for consecutive observations of the same PID and process name without a start time. Observed absence, name changes, counter regression, conflicting accessible paths and a transition between verified and provisional evidence start a new identity. A replacement with the same PID/name and no distinguishable evidence between consecutive captures remains undetectable and is labelled provisional.

Raw measurement values are retained. CPU deltas continue to require verified start times. Categories record process type independently from metadata access and identity status. Application memory remains a same-sample sum with unavailable values preserved. Historical reports keep their recorded identities and attribution, with explicit legacy quality labels where the older report did not record them.

## Reproducible comparison

The Pester fixture New-IdentitySamples captures two verified processes and two processes with inaccessible start times over 15 samples. Applying the former per-slot key rule yields 32 identity records. Version 0.5 yields four identities, with the same 60 observations and a combined 100 MiB private-memory total at each sample.

A replay of the retained 15-sample workstation report produced the following identity-only comparison. The original report file was read without modification and ownership categories were not inferred from missing historical metadata.

| Quantity | Recorded by 0.4.2 | 0.5 identity replay |
| --- | --- | --- |
| Process identity records | 2,558 | 304 |
| Records without verified start time | 2,415 | 161 provisional identities |
| Verified identities | 143 | 143 |
| Captured observations | 4,551 | 4,551 |

## Windows validation

The installed 0.5 engine completed a 30-second run with 15 of 15 samples and no missed slots. It reported 318 identities, comprising 151 verified and 167 provisional, across 4,716 observations. It identified 116 application processes and 34 Windows components, and recorded restricted metadata for 167 identities. Teams retained nine identities and 135 observations. One preferred CPU-provider timeout was recovered through the existing fallback.

The self-contained x64 installer upgraded the existing installation with its stable AppId. SHA-256 comparisons confirmed that all 21 recorded reports, logs and preference files survived unchanged. The installed app launched and its accessibility tree exposed version 0.5.0 and the existing process views. Interactive visual validation was limited by a black window capture and a computer-use activation failure.

All 64 Pester tests and 12 .NET regression checks passed. Windows integration checks passed for real streamed collection, report loading, unique identity and group membership counts, and cancellation without partial reports. The self-contained WPF publish succeeded and Inno Setup generated WPBD-Setup-0.5.0-x64.exe. Windows 10 and clean-machine validation remain outstanding.
