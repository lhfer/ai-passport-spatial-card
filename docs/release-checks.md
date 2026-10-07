# Public preview validation

Checked on 2026-10-07 for the first public source release.

| Check | Result |
| --- | --- |
| Hub TypeScript typecheck | Passed |
| Hub unit / integration tests | 139 passed |
| Firmware host tests and generated asset checks | 4 groups passed |
| visionOS simulator build | Passed, signing disabled |
| visionOS unit tests | 543 passed |
| visionOS device target compile | Passed, signing disabled; no device installation |
| Offline Hub, 1440 × 1000 and 390 × 844 | Rendered and inspected; +5 and refresh worked; no horizontal overflow at mobile width |
| Public profile, covers and avatar layers | Regenerated and inspected in the running simulator |
| README animation assets | Two recordings from the public app, with anonymous local data |
| Extended artifact | Apple compiler accepted the public package; all 8 model payload files match the original, with checksum verification |
| Sensitive identity markers | No matches in the initial public files and recursively inspected archive members |
| Gitleaks staged changes and exported source files | No findings |

The publication tree uses a new Git history. Development workspaces, build outputs, login state, device backups, private notes and old media are excluded. No source or assets were deleted from the original development project.

This is build, logic, packaging and simulator evidence. The anonymized screen design and published model still require real hardware testing together. It does not establish headset frame rate, physical object tracking quality or end-to-end device acceptance. See [known issues](known-issues.md).
