---
id: release-policy
type: reference
title: release-and-compatibility
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

**對本專案的一句話**：逐位元 golden 的摘要半場只在錄製它的平台（目前 windows/x86_64）斷言，每幀粒子數到處斷言——見 `test/GoldenPlatform.hs`。新增參考平台＝錄一份該平台的 golden ＋ 放寬 `referencePlatform`，三個 golden spec 的其他部分不動。
