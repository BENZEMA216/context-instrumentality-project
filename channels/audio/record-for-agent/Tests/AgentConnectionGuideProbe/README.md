# Cloud connection guide probe

Uses synthetic URLs and folder names only. Compile the production formatter:

```sh
xcrun swiftc Phone/AgentOnboardingStatement.swift Tests/AgentConnectionGuideProbe/main.swift -o /tmp/rfa-agent-guide-probe
/tmp/rfa-agent-guide-probe
```

Covers both providers, each provider separately, no location, blank folder names,
exact Google folder links, iCloud name limitations, duplicate handling and removal
of developer-machine installation instructions. The separate UI probe compiles
this same formatter and tests the empty and connected copy-entry flows.
