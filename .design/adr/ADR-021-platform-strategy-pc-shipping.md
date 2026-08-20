---
id: ADR-021
type: adr
title: platform-strategy-pc-shipping
description: PC 三平台為出貨目標，Haskell 庫即出貨執行期
status: accepted
created: 2026-08-20
updated: 2026-08-20
---

# ADR-021: 平台策略——PC 為出貨目標，Haskell 庫就是出貨的執行期

## 狀態（Status）

accepted（2026-08-20）。修訂 [ADR-0016](../../docs/adr/adr-0016-release-compatibility-policy.md) D1 的平台分級：macOS 自 Tier 2 升為 Tier 1（附觸發條件）；「未支援」一列改寫為本 ADR 的 D3。

## 背景（Context）

專案自 2026-08-20 起從「可出貨的 POC」改定位為 **production library**：要能嵌進真實的遊戲專案出貨，而不只是示範。定位一改，第一個要回答的問題就是**出貨到哪裡**——因為這個庫是 Haskell 寫的，而 GHC 的目標平台覆蓋面與遊戲業的平台清單並不重合：

| 平台 | GHC 9.14 的現實 |
|---|---|
| Windows／Linux／macOS x86_64 | 原生支援，本專案 Tier 1／Tier 2 已實測 |
| macOS／Linux arm64 | 原生支援（NCG），本專案尚未實測 |
| WebAssembly（wasm32-wasi） | 後端存在，但**無執行緒**、foreign-library 形式受限 |
| iOS | **無支援目標**（跨編譯鏈自 8.x 後無人維護） |
| Android | 非官方、無 CI 上游，實務上不可靠 |
| 家用主機（Switch／PS／Xbox） | **不可能**：無 GHC 工具鏈，且 SDK 受 NDA，上游永遠不會有 |

如果不在動工前把這件事定下來，接下來的加速與執行期工作可能投在錯的那一邊——例如把力氣花在 GHC RTS 調校上，結果出貨目標根本沒有 GHC。

## 決策（Decision）

### D1（出貨目標：PC 三平台）

本執行期的出貨目標是 **Windows x86_64、Linux x86_64、macOS（x86_64 與 arm64）**。在這三個平台上，**Haskell 庫本身就是出貨的執行期**——宿主載入 `.dll`／`.so`／`.dylib`，沒有中間層、沒有移植。

### D2（Tier 1 擴充為三平台，macOS 帶觸發條件）

ADR-0016 D1「Tier 1 清單就是 CI 矩陣」的原則不變，macOS 進矩陣才算 Tier 1。但 GitHub 的 macOS runner 計費是 Linux 的 **10 倍**（Windows 是 2 倍），依 ADR-0016 D5「降低跑的次數、不降低每次的強度」的既定哲學：

- Windows／Linux：維持 `pull_request` → `main` 觸發。
- macOS：**只在 `push` tag `v*` 與 `workflow_dispatch` 時跑**。也就是說 macOS 的回歸在發版當下被機器確認，而不是每個 PR。

三個平台跑同一組步驟（`build all`、`test`、`magic-validate`），外加 [ADR-022](ADR-022-host-runtime-contract.md) 新增的「載入共享函式庫」out-of-process 煙霧測試。

### D3（行動與主機：不是本執行期的目標，核心是 oracle）

iOS、Android、家用主機**不是本執行期的出貨目標**，而且這不是「還沒做」，是 D1 的工具鏈現實決定的。若日後產品路線圖需要這些平台，路徑已在本 ADR 預留：

- **Haskell 核心是參照實作（oracle）**，出貨執行期由另一個專案以 C／C++（或 Rust）移植。
- 移植的規格就是現有的合約面：`include/particle_magic.h` 是 API 規格，`docs/spell.schema.json` 是輸入規格，`test/` 裡的逐位元 golden（FNV 摘要、每幀粒子數）與 [ADR-024](ADR-024-cross-platform-bitexact-trig.md) 之後的跨平台逐位元承諾是驗收標準。
- 本專案的設計讓這條路可行：純函數核心沒有隱藏狀態、編譯後的法術是資料不是函數、C ABI 凍結。**本 ADR 不啟動移植**，只保證日後要移植時不必回頭改架構。

### D4（WebAssembly：觀察，不承諾）

wasm32 後端可行但無執行緒，與本庫的平行取樣與 RTS 設定契約不相容。列為「觀察中」，不進任何 Tier，也不在 Level 2 路線圖立帳。

## 考慮過的替代方案（Alternatives Considered）

- **現在就把核心定位為 oracle、另寫 C++ 出貨執行期**：對「PC 遊戲」這個最可能的第一個宿主是過度投資——GHC 在 PC 三平台完全夠用，而移植會讓兩份實作的同步成本立刻出現。D3 把這條路留著，但不現在走。
- **macOS 與 Windows／Linux 一樣每個 PR 都跑**：10 倍計費，私有倉庫月額度撐不住。發版時跑的安全網與「每個 PR 都跑」的差異，在這個專案的變更頻率下可接受。
- **維持「PC 之外沒人試過」的 POC 措辭**：production 定位下，宿主會問「能不能上 Switch」，答案必須是明確的「不能，理由如下」，而不是「沒試過」。
- **等真實宿主出現再決定平台**：加速路線（[ADR-023](ADR-023-host-buffer-contract.md)）與執行期契約（ADR-022）都假設 GHC RTS 在出貨路徑上；不先定這一條，那兩份 ADR 沒有立足點。

## 影響（Consequences）

- `docs/release.md` §1 的平台分級表重寫：Tier 1 三平台（含 macOS 的觸發條件）、「行動／主機」改為「非本執行期目標，見 ADR-021 D3」。`test/ReleaseDocSpec.hs` 守護的三處平台清單同步。
- `.github/workflows/ci.yml` 的矩陣加入 `macos-latest`，帶 `if:` 條件限制觸發。
- macOS arm64 成為第二個「非參考平台」——在 ADR-024 落地前，逐位元 golden 只在參考平台斷言的規則照舊適用。
- authoring-engineering 子系統新增「平台矩陣擴充」與「發布產物」兩個 feature（Level 2 回填）。
- 日後若啟動 D3 的移植，需要一份新的 ADR 決定移植語言與同步政策；本 ADR 只預留路徑。
