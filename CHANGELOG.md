# [1.2.0](https://github.com/qtsone/actions/compare/v1.1.0...v1.2.0) (2026-01-20)


### Features

* allow specifying additional custom tags for Docker images ([5e12f8b](https://github.com/qtsone/actions/commit/5e12f8b8e394ce596d4b90ff3286834c441be6bc))

# [1.1.0](https://github.com/qtsone/actions/compare/v1.0.1...v1.1.0) (2026-01-14)


### Features

* **docker:** allow skipping checkout in build action ([921a80f](https://github.com/qtsone/actions/commit/921a80f52bb65bf32d29e981f8c5ee4a6ac4d3e7))

## [1.0.1](https://github.com/qtsone/actions/compare/v1.0.0...v1.0.1) (2026-01-13)


### Bug Fixes

* **docker:** refactor and minor fixes ([eb0e5d7](https://github.com/qtsone/actions/commit/eb0e5d71f9a77575f7458d3670d89b7931bff58c))

# 1.0.0 (2025-10-30)


### Bug Fixes

* **actions:** bump versions ([4736f6f](https://github.com/qtsone/actions/commit/4736f6ffa294f64c7170c45ad54483151de2f3df))
* add checkout step before local action reference ([261b69a](https://github.com/qtsone/actions/commit/261b69abfcf11853538e3de81a8a945c0244c916))
* add checkout step to Docker Tests action ([6fc7e8a](https://github.com/qtsone/actions/commit/6fc7e8a2e18d0929beb3803737ca1029c660d86b))
* add skip-checkout parameter to prevent config override in tests ([a57c56a](https://github.com/qtsone/actions/commit/a57c56aa7e0fc24e9b9b063acfb0c7c70203116a))
* ensure proper branch name in test workflow for semantic-release ([32dcf5f](https://github.com/qtsone/actions/commit/32dcf5f5ea3d46f21dbdf3f32acb77ad989086e6))
* explicitly set git symbolic-ref to force correct branch ([a3d2af2](https://github.com/qtsone/actions/commit/a3d2af292223203d3e9561b8ab176807a6acc0a4))
* export environment variables directly in bash script ([7a57451](https://github.com/qtsone/actions/commit/7a574510b9d6b7c304c71f6c24fc5f500015e8e1))
* override GITHUB_EVENT_NAME to prevent PR context detection ([aa70eb4](https://github.com/qtsone/actions/commit/aa70eb46262456d67b6a8020448d9eecb7952455))
* override GITHUB_REF for correct branch detection in PR tests ([68f3935](https://github.com/qtsone/actions/commit/68f393578f169ded01a1fc25f2834fb7251d965d))
* override PR detection in test workflow to enable version analysis ([a6d1cbe](https://github.com/qtsone/actions/commit/a6d1cbe5a8fbccd910f4e0a05a9435b31aa6f941))
* **release:** add back the output ([49e0973](https://github.com/qtsone/actions/commit/49e09734a955473ed193fe7c17cfc1b2c097f536))
* **release:** add branch-override input for PR testing ([4adcba2](https://github.com/qtsone/actions/commit/4adcba259ddddb18a44b20f61e408947f4cfe030))
* **release:** override GITHUB_REF inside composite action ([e2c1ba3](https://github.com/qtsone/actions/commit/e2c1ba3e2a1a7f75321ca409deb53848bf27cad6))
* **release:** update checkout version ([48fceed](https://github.com/qtsone/actions/commit/48fceedd65b7b974b93fadb77366a604d9434116))
* **release:** use correct ref branch ([550c558](https://github.com/qtsone/actions/commit/550c558c0f4ef089b77067407f27f822c628310f))
* **release:** use deploy key ([0359f1c](https://github.com/qtsone/actions/commit/0359f1ca2a990a68f7dea49567123cf3a550cece))
* remove checkout step from Docker Tests action ([8729048](https://github.com/qtsone/actions/commit/87290483319645618c821b15492050c2dec5c784))
* remove hardcoded extra_plugins from release action ([b8f3a07](https://github.com/qtsone/actions/commit/b8f3a0725ea0c2d4949b863f1fe1d2d6f144306b))
* resolve peer dependency conflicts in npm install ([4a6c140](https://github.com/qtsone/actions/commit/4a6c14034e880634bbc8e1b3f47cc90f4f44c225))
* **test-release:** add branch setup for semantic-release detection ([e8268fa](https://github.com/qtsone/actions/commit/e8268fae611929630f754582f1b27d584272ed1f))
* **test-release:** disable GitHub Actions detection for semantic-release ([ecfdc04](https://github.com/qtsone/actions/commit/ecfdc046f8a06cfc28e11cdbf7323cf3bd94cfdc))
* **test-release:** move GITHUB_REF override to job level ([5992a49](https://github.com/qtsone/actions/commit/5992a49f384f8c072784c8398cd54a30dfaeb594))
* **test-release:** override GITHUB_REF for PR context ([b9f25ff](https://github.com/qtsone/actions/commit/b9f25ffe1d282c1455dea356ea6420b2d086a01a))
* **test-release:** override GITHUB_REF for semantic-release branch detection ([97462df](https://github.com/qtsone/actions/commit/97462dfb0fb46d1d4c8cd3d7dc9db371281b2964))
* **test-release:** simplify branch configuration for PR testing ([6fd3321](https://github.com/qtsone/actions/commit/6fd332121744e7650153d1ace8340bd52d4b593b))
* **test:** allow test/* and wildcard branches in test .releaserc ([d67b67b](https://github.com/qtsone/actions/commit/d67b67ba03ff30eb3d713617e796d931f89fa076))
* **test:** checkout actual PR branch instead of merge commit ([1bff1b3](https://github.com/qtsone/actions/commit/1bff1b38a761355eff70f5de063154067cfdfefd))
* **trivy:** add check for Trivy results file before appending to output ([6559a73](https://github.com/qtsone/actions/commit/6559a7336d9f85d08c3ec8c669084e0d559cb1cb))
* **trivy:** non-blocking ([12578a2](https://github.com/qtsone/actions/commit/12578a22f52297f025db15c1738dc435cccdacaf))
* update releaserc ([ff52270](https://github.com/qtsone/actions/commit/ff522703be0e3028521f8aefed25b7b9bf389403))
* use --branches CLI flag for explicit branch specification ([aa876a1](https://github.com/qtsone/actions/commit/aa876a15f1309fcb1def8660f757614d8154c139))
* use correct org ([fa58b80](https://github.com/qtsone/actions/commit/fa58b80b46122bfc04800aa12f6e6ae3ea4c501f))
* use string prerelease identifiers instead of boolean ([cd84cd6](https://github.com/qtsone/actions/commit/cd84cd6c50b1e6d7e693b86783dfb8572d4cae0a))


### Features

* add automated release workflow for actions repository ([abb12aa](https://github.com/qtsone/actions/commit/abb12aa35343c007655a38bec09a54946186c3f8))
* add comprehensive CI test workflow for release action ([b6d2ed3](https://github.com/qtsone/actions/commit/b6d2ed35fb065dbba368a6e1f6ea8a75ce533551))
* add no-ci flag to enable version analysis in PR context ([25f6380](https://github.com/qtsone/actions/commit/25f63809126464591c21b45d7e1d578b6f8ddf5e))
* implement production-ready semantic-release action with output capture ([41945d3](https://github.com/qtsone/actions/commit/41945d3312af082a974c8910060950eda23e10f9))
* initial setup ([4052897](https://github.com/qtsone/actions/commit/4052897ae1aa45fb98ee54b6a63fcf61e93a0024))
* make extra-plugins configurable input with sensible defaults ([0b0dca6](https://github.com/qtsone/actions/commit/0b0dca68bec2ae7c67f78449ea8446b11cf6534e))
* **release:** add @semantic-release/exec plugin support ([eb9c4e1](https://github.com/qtsone/actions/commit/eb9c4e1c3f8a1c64dff5c963b803016a46185113))
