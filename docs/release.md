---
id: release-policy
type: reference
title: release-and-compatibility
description: 發一版的流程、版本語意與對外相容性承諾
status: done
created: 2026-08-16
updated: 2026-08-16
related-adr: [adr-0016, adr-0011]
related-spec: [func-0019]
---

# 發布與相容性

本文是**流程本身**：發一版要做什麼、版本號怎麼跳、哪些平台算數、對外承諾到哪裡為止。決策的理由在 [ADR-0016](adr/adr-0016-release-compatibility-policy.md)，本文只講怎麼做。

本文的三張硬資訊（平台清單、tag 格式、檢查清單）由 `test/ReleaseDocSpec.hs` 與 `test/ReleaseMetaSpec.hs` 機械守護——它們與 `README.md`、`.github/workflows/ci.yml`、`particle-magic.cabal` 之間不得漂移。改這裡而不改那裡，`cabal test` 會紅。

---

## 1. 支援平台分級

| 級別 | 意義 | 成員 |
|---|---|---|
| **Tier 1** | 進 main 之前由 CI 驗證 build＋test＋validate（觸發時機見 §1.1）；回歸視為缺陷 | `windows-latest`（x86_64）、`ubuntu-latest`（x86_64） |
| **Tier 2** | 預期可用但無 CI；壞了修，但不擋發布 | macOS、其他 Linux 發行版 |
| **未支援** | 沒有人試過 | ARM、WASM、行動平台 |

Tier 1 的清單**就是** `.github/workflows/ci.yml` 的 `matrix.os`。一個平台想進 Tier 1，唯一的方式是把它加進矩陣——分級是承諾，不是願望。

兩個 Tier 1 平台走的不是同一條連結路徑：Windows 的 foreign-library 靠 `particle-magic-ffi.def` 明列匯出，Linux 的 `.so` 靠 GHC 預設匯出。這是矩陣的第二個價值（第一個見 §5）。

### 1.1 CI 什麼時候跑（以及為什麼不是每次 push）

| 觸發 | 時機 | 頻率 |
|---|---|---|
| `pull_request` → `main` | 開 PR、以及 PR 分支每次更新 | 每輪 spec 幾次 |
| `push` tag `v*` | 打版本 tag（＝ §4 第 3 步的機器保證） | 一年幾次 |
| `workflow_dispatch` | 你想跑就跑 | 隨意 |

**沒有分支 push 觸發。** 本 repo 是 private，Actions 分鐘數計費，且 **Windows runner 以 2× 計費**（Linux 1×）：熱快取一次矩陣約 15 計費分鐘，冷快取約 60。設在每次 push 會把月額度花在半成品 commit 上，而且與 `pull_request` 併用時同一份工作會跑兩遍。

**所以日常的驗證仍然是你自己的 `cabal test`**——CI 是併入 main 前的閘門，不是編輯器的即時回饋。完整理由與被否決的方案見 [ADR-0016](adr/adr-0016-release-compatibility-policy.md) D5。

## 2. 版本號

四段 PVP，寫在 `particle-magic.cabal` 的 `version:`。

| 變更 | 跳哪一位 |
|---|---|
| 破壞 `magic-core`／`magic-boundary` 的凍結介面（移除或改變匯出的型別、簽名、語意） | **major**（前兩段其一） |
| 純增補：新匯出、新符文、新 JSON 鍵、新 C 宣告 | **minor**（第三段） |
| 修正、效能、文件、測試 | **patch**（第四段） |

配套規則：

- **所有 `build-depends` 條目帶 `^>=` 上界。** 同套件內的子庫依賴（`particle-magic:magic-core`／`magic-boundary`）豁免——它們的版本恆等於本套件自身。
- **`tested-with:` 只寫實際建置並測試過的 GHC**，且必須等於 CI 安裝的版本。
- **`PM_ABI_VERSION` 與本版本號獨立遞增**（ADR-0016 D3）。header 是 add-only，加宣告不動世代；Haskell 面的破壞性變更也完全可能不碰 C 面。**major bump 不自動代表 ABI 世代 bump，反之亦然。** 世代只在 header 出現非加法變更時 +1。

## 3. CHANGELOG

`CHANGELOG.md` 每個版本一個 `## <version> — <YYYY-MM-DD>` 段落，段落內**一份 func-spec 一行**：

```
## 0.1.0.0 — 2026-08-13

- **00NN <題目>** — 這一輪交付了什麼，一段話。(delivered)
```

cabal 的 `version:` 必須在 CHANGELOG 找得到同名段落標題（`ReleaseMetaSpec` 守護）。版本號跳動與 CHANGELOG 段落是同一個動作的兩半，不是兩件事。

## 4. 發布流程

1. `CHANGELOG.md` 補本版段落（§3 的格式，一份 spec 一行）。
2. `particle-magic.cabal` 的 `version:` 依 §2 的規則 bump。
3. **CI 兩個 Tier 1 平台全綠**——三個步驟都要綠：

   ```
   cabal build all
   cabal test
   cabal run magic-validate -- assets/spells
   ```

   `magic-validate` 的 exit code ＝ 載入或施放失敗的檔數，所以第三步不需要任何額外判讀。

   併入 main 的那個 PR 已經跑過這三步（§1.1）；若距離上次 PR 有新的 commit，用 `workflow_dispatch` 手動跑一次。
4. `git tag v<version>`，例如本版是 `v0.1.0.0`——**`v` 加上 cabal 版本字串，一字不差、四段不省**。
5. `git push --tags`。**push tag 會再觸發一次 CI**（§1.1），所以第 3 步在打版當下由機器再確認一遍——這是這條 tag 觸發存在的唯一理由。

**tag 是目前唯一的發布動作。** 不上 Hackage、不做自動 release（ADR-0016 §被否決）。tag 的用途是讓 `source-repository-package` 的使用者有東西可以釘：

```cabal
source-repository-package
  type: git
  location: https://github.com/utomore/particle-magic-system.git
  tag: v0.1.0.0
```

## 5. 決定論的對外承諾（讀這一節再決定要不要在意）

**同一台機器上**：相同的 `(json, pos, facing, seed, dt 序列)` ⇒ 逐位元相同的輸出，兩條消費路徑（Haskell 與 C ABI）皆然。重播、回歸網、錄影都建立在這上面，這句話沒有例外。

**跨平台**：保證的是**結構**——相同的粒子、相同的順序、相同的每幀數量——位置欄相差至多兩個 ulp。

| 欄 | 跨平台 |
|---|---|
| `pbPosX`／`pbPosZ` | 可能相差最後 1–2 位元，實測絕對差 ≤ `1.79e-07` 世界單位 |
| `pbPosY`／`pbSize`／`pbLife`／`pbColor` | 實測逐位元相同 |

原因不在本專案的算術：IEEE-754 保證 `sqrt` 正確捨入，但**不保證** `sin`／`cos`，而 mingw 與 glibc 的 libm 對約 1.3% 的引數在最後一位不同（實測：4096 個 `Float` 角度中 sin 63 個、cos 46 個相異，最壞皆 1 ulp）。兩邊都合法。完整量測與裁決見 [ADR-0016](adr/adr-0016-release-compatibility-policy.md) D4。

**對宿主的一句話**：在同一台機器上重播錄影，用相等比較；跨機器比對，用容差比較。

**對本專案的一句話**：逐位元 golden 的摘要半場只在錄製它的平台（目前 windows/x86_64）斷言，每幀粒子數到處斷言——見 `test/GoldenPlatform.hs`。新增參考平台＝錄一份該平台的 golden ＋ 放寬 `referencePlatform`，其他 golden spec 的部分不動。**這條規則適用於每一份 golden**，包括 `examples/haskell/expected-output.txt`（enhance-0001 §8.3：它漏套過一次，代價是 CI 的 Linux 腳紅在一個 checksum 的最後一位小數）。

## 6. 發布產物（一包裡有什麼）

宿主拿到的不是原始碼，是一包檔案。**機器可讀的權威是 `packaging/artifacts.json`**；下面這張表是它的散文複述，`test/PackagingSpec.hs` 斷言兩者**雙向相等**——清單裡有的檔名這裡一定看得到，這裡提到的檔名清單裡一定有。少一個就紅。

| 平台 | 檔案 | 角色 | 狀態 |
|---|---|---|---|
| **windows-x86_64** | `particle-magic-ffi.dll` | runtime（standalone，內嵌 RTS） | 已驗證 |
| | `particle-magic-ffi.dll.a` | import-lib-mingw | 已驗證 |
| | `particle-magic-ffi.lib` | import-lib-msvc | 已驗證 |
| | `particle_magic.h` | header | 已驗證 |
| | `pm-version.json` | version | 已驗證 |
| **linux-x86_64** | `libparticle-magic-ffi.so` | runtime | 已驗證 |
| | `*.so*` | runtime-closure（與 `.so` 同層的共享物件閉包） | 已驗證 |
| | `particle_magic.h` | header | 已驗證 |
| | `pm-version.json` | version | 已驗證 |
| **macos-x86_64** | `libparticle-magic-ffi.dylib` | runtime | **未驗證** |
| | `particle_magic.h` | header | **未驗證** |
| | `pm-version.json` | version | **未驗證** |
| **macos-arm64** | `libparticle-magic-ffi.dylib` | runtime | **未驗證** |
| | `particle_magic.h` | header | **未驗證** |
| | `pm-version.json` | version | **未驗證** |

`role` 是**封閉詞彙**，只有六個值：`runtime`、`runtime-closure`、`import-lib-mingw`、`import-lib-msvc`、`header`、`version`。清單多出第七個角色，守門測試會紅。

### 6.1 三個平台各自的形狀

**Windows** 的 DLL 是 standalone 的——RTS 內嵌，宿主不需要裝 GHC。MinGW 宿主連 `particle-magic-ffi.dll.a`，MSVC 宿主連 `particle-magic-ffi.lib`（由 `lib.exe /def:` 從 repo 裡那份 `particle-magic-ffi.def` 產生，沒有 MSVC 時退回 ghcup 隨附的 `llvm-dlltool`）。接法見 [integration.md](integration.md) §4.8。

**Linux** 走的**不是**字面的 standalone。GHC 發行版的靜態封存檔不是 PIC，連結器直接拒絕把它們連進共享物件（2026-08-20 實測），所以字面 standalone 在這條工具鏈上做不到。改走的路是等價的：`.so` 連結時帶 `-Wl,-rpath,$ORIGIN`，打包時把它的整個共享物件閉包（`libHS*`、`libffi`、`libgmp`）複製到同一個資料夾。目標與 standalone 相同——**宿主不必安裝 GHC 執行期，也不相依發行版的 libgmp／libffi**。驗收是機械的：`packaging/pack.sh --verify` 在 `env -i` 的乾淨環境下斷言 `ldd` 零 `not found`，且沒有任何一條相依解析到產物資料夾之外（涵蓋整個閉包，不只 gmp 與 ffi），再 dlopen 一次確認 `pm_init` 真的活著。

**macOS** 本輪**只寫了建置設定與打包腳本分支，沒有機器驗過**。`install_name` 以 `@rpath` 為基準（cabal 的 `if os(darwin)` 條件下），雙架構由分別建置後 `lipo -create` 合併。清單裡兩列的 `verified` 欄因此是 `false`，這張表的狀態欄寫「未驗證」——等 macOS 進 CI 矩陣之後才改。

### 6.2 版本檔

每份產物資料夾根目錄放一份 `pm-version.json`，四個欄位、一個不多：

| 欄位 | 型別 | 來源 |
|---|---|---|
| `package-version` | string | `particle-magic.cabal` 的 `version:` |
| `abi-version` | number | `include/particle_magic.h` 的 `PM_ABI_VERSION` |
| `platform` | string | 清單的平台 id（`windows-x86_64` 等） |
| `commit` | string | `git rev-parse HEAD`；不在 git 工作樹裡（例如從 sdist 建）時寫 `unknown` |

套件版本與 ABI 世代**獨立遞增**（§2），版本檔同時記兩個就是為了讓宿主一眼看出自己拿到的是哪一組。

### 6.3 打包腳本

| 腳本 | 平台 | 做什麼 |
|---|---|---|
| `packaging/pack.ps1` | Windows | 蒐集 DLL 與 MinGW 匯入庫、產 MSVC 匯入庫、複製標頭、寫版本檔 |
| `packaging/pack.sh` | Linux／macOS | 蒐集共享函式庫與（Linux）共享物件閉包、複製標頭、寫版本檔；`--verify` 做乾淨環境的自足性檢查 |
| `packaging/smoke-msvc.ps1` | Windows | 以 `cl.exe` 編 C 最小宿主、連 MSVC 匯入庫、跑完一次完整生命週期 |

三支腳本的退出碼語意一致：**0 ＝ 產物齊全且（`--verify` 時）自足**，非 0 ＝ 指出缺哪一個檔或哪一條相依沒解析到。CI 直接消費退出碼，不解讀訊息。建置與上傳流程本身不在本文的範圍內（見 `.github/workflows/`）。
