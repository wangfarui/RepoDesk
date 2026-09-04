# RepoDesk Agent Instructions

## 运行产物同步

- `swiftc -typecheck`、测试可执行文件和 `build/libRepoDesk.dylib` 只用于验证，不会更新独立运行的 `build/RepoDesk.app`。
- 默认情况下，每次完成源码改动后都必须运行 `./scripts/verify-local.sh`。该脚本完成验证后会重新构建、临时签名并校验 `build/RepoDesk.app`，保证用户重启应用时运行的是最新代码。
- 交付前必须确认 `build/RepoDesk.app/Contents/MacOS/RepoDesk` 的修改时间已更新，并执行 `codesign --verify --deep --strict build/RepoDesk.app`。未完成这些步骤时，不得声称可通过重启应用验收。
- 若改动非常小，并且当前开发运行方式确实支持只重建测试动态库后在已打开的应用中即时看到变化，可以先明确提示用户直接验收，再询问是否需要重新构建并签名 `build/RepoDesk.app`。
- 独立的 `build/RepoDesk.app` 当前不链接 `build/libRepoDesk.dylib`，不能将“测试动态库已重建”视为“应用已更新”。用户要求重启应用验收，或即时加载条件不明确时，必须执行完整应用构建和签名。

## 本地应用构建

- 完整验证、构建和签名使用 `./scripts/verify-local.sh`。
- 仅需刷新应用包且相关验证已经通过时，可使用 `./scripts/build-local.sh`；该脚本仍必须成功完成 `codesign --force --deep --sign -`。
