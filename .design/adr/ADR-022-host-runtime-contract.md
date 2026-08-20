---
id: ADR-022
type: adr
title: host-runtime-contract
description: 執行期契約：RTS 由宿主設定、例外防火牆、執行緒模型
status: accepted
created: 2026-08-20
updated: 2026-08-20
---

# ADR-022: 執行期契約——RTS 由宿主設定、C ABI 是例外防火牆、執行緒模型明文化

## 狀態（Status）

accepted（2026-08-20）。修訂 [ADR-0011](../../docs/adr/adr-0011-ffi-c-abi-boundary.md) D4（handle 生命週期中「use-after-free 為未定義行為」一句）與 D5（RTS 政策）。ADR-0011 其餘條款不動，header add-only 約束（D7）由本 ADR 全程遵守。

## 背景（Context）

2026-08-20 的 production 審計在宿主面找到的缺口，全部屬於「宿主拿到共享函式庫之後會發生什麼」，而這一層在現行契約裡是空白的：

1. **沒有例外處理。** 29 個 `foreign export`（加上 `pm_init`／`pm_shutdown` 兩個 C 函式即標頭的 31 條凍結宣告） 沒有任何 `catch`；一個 Haskell 例外穿出 C 邊界等於宿主進程被 RTS 終止，訊息印在沒人看的 stderr。純核心目前是全函數（無 `error`、無不完整模式），但堆積耗盡、惡意 JSON 造成的深度遞迴、`deRefStablePtr` 打到已釋放的 handle，都不是核心能保證的事。
2. **宿主無法設定 RTS。** foreign-library 是整個 cabal 檔裡唯一沒有 `-with-rtsopts` 的 stanza，`hs_init` 拿到的是寫死的一元素 argv。結果是出貨給 C／Unity 宿主的庫**永遠只有一個 capability**——demo 執行檔享有的平行取樣，C 宿主拿不到，還要付 ≥8192 粒時分片與串接的代價換零加速。nursery 大小、nonmoving GC 同樣無從指定。
3. **執行緒模型只有一句話、零測試。** 「一 handle 一執行緒、無內部鎖」寫在註解裡；`pm_advance` 是非原子的 read-modify-write，同 handle 併發會靜默丟步。`pm_rts_running` 是裸 C static，兩個引擎執行緒同時 `pm_init` 是資料競爭。
4. **固定時步的正確實作只有 Haskell 面能用。** 累加器、單幀最大步數截斷（死亡螺旋防護）、浮點 epsilon 都在邊界層的時步規劃器裡，但 C ABI 沒有匯出它；出貨的 C 與 C# 範例 loop 都沒有截斷——一次關卡載入的 hitch 會讓宿主對 field spell 連呼叫數百次 `pm_advance`。
5. **`dt` 不檢查。** NaN 的 `dt` 讓法術時鐘永久中毒，`pm_is_finished` 永遠回 0，宿主的 `while (!pm_is_finished)` 卡死。
6. **沒有診斷面。** 宿主無法問「這幀取樣花了多久、配置了多少、GC 幾次」。
7. **關閉與重入無防護。** 「shutdown 之後不能再 init」只有文件說，程式碼不擋。（本條原本斷言 Windows standalone DLL 由 `DllMain` 先啟動 RTS、導致兩平台語意不同；2026-08-20 以真 DLL ＋ 純 C 宿主實測**推翻**：兩平台都是「未初始化就呼叫」與「關閉後呼叫」皆殺進程，語意一致。D1 的降級條款因此改為適用於「宿主自己啟動 RTS」的情況。）

這些都不是魔法語意、不是取樣，也不是 Haskell 面的合約——它們是**嵌入執行期**的契約，需要自己的一份 ADR。

## 決策（Decision）

### D1（RTS 由宿主設定）

新增 `pm_init_ex(const PmConfig*)`，`PmConfig` 以 `size` 欄開頭（add-only 結構，未來加欄不破壞舊宿主）。宿主可指定：capability 數（0 = 依硬體）、nursery 大小、是否啟用 nonmoving GC。**`pm_init()` 保留且行為不變**（單 capability、預設 GC）——既有宿主零改動；`docs/integration.md` 改為推薦 `pm_init_ex` 並給遊戲用的建議設定。

`pm_init_ex` 回傳錯誤碼（`pm_init` 的凍結簽名是 `void`，不動）。初始化**原子化**（C 側以原子旗標或一次性初始化原語實作）。**`pm_shutdown` 之後再初始化一律回 `PM_ERR_STATE`**（新錯誤碼 −7，涵蓋所有「宿主呼叫順序錯」：未初始化就呼叫、關閉後再初始化、重複帶設定初始化），兩個平台語意統一為「本進程不得再使用本庫」。若某平台的 RTS 在宿主呼叫前已由載入器啟動且無法關閉，capability 數仍以執行期 API 生效，其餘欄位回 `PM_ERR_STATE` 並逐平台文件化——不靜默忽略。

### D2（例外防火牆）

**每一個匯出符號**都包一層攔截所有 Haskell 例外的防火牆；攔到的例外映射為新錯誤碼 `PM_ERR_INTERNAL`（−6），若該呼叫帶訊息緩衝則寫入例外文字（沿用既有的 UTF-8 邊界安全截斷）。不帶訊息緩衝的查詢類符號回 `PM_ERR_INTERNAL` 或等價的哨兵值（回傳指標者回 NULL、回傳計數者回 −6）。**庫在任何情況下不終止宿主進程**——這是 production 定位的第一條驗收標準（P-1）。

防火牆是**最後一道**，不是控制流：核心「不失敗」（ADR-0007）與邊界「錯誤轉成值」的原則不變，防火牆存在的理由是堆積耗盡、手誤、未來的不完整模式這類核心無法以型別排除的事。每次防火牆真的攔到東西都視為缺陷。

### D3（控制代碼帶世代標籤）

`PmSpell*`／`PmScene*` 仍是不透明指標（header 不變），但表徵從裸 `StablePtr` 改為**帶世代標籤的控制代碼**：已釋放或偽造的 handle 被辨識出來並回 `PM_ERR_ARGS`，而不是 ADR-0011 D4 所說的未定義行為。double-free 亦同。這是 D4 那一句的修訂；「一 handle 由 `pm_cast` 配置、`pm_free` 釋放」的生命週期不變。

### D4（執行緒模型）

明文寫進 header 與整合指南，且每一條都有測試：

- **不同 handle 在不同執行緒**：可併發，無限制（純核心無全域狀態）。
- **同一 handle**：庫以原子的 read-modify-write 保證**不丟更新**（兩個 `pm_advance` 併發不會只推進一步），但**不保證順序**——推進與觀測的相對順序是宿主的責任。單執行緒宿主不付鎖的成本：每幀路徑無鎖，原子讀改寫的固定成本為個位數奈秒（2026-08-20 實測 +6.5 ns／次推進，對照非原子寫入 2.84 ns）。
- **初始化與關閉**：D1 已原子化；`pm_shutdown` 與任何其他呼叫併發是宿主錯誤，文件明列。
- 庫**不會**自行開 OS 執行緒去做宿主沒要求的事；capability 數完全由 D1 決定。

### D5（固定時步上 C ABI，`dt` 檢查）

新增 `pm_plan_steps(dt, max_steps, elapsed, acc_in, *steps, *acc_out)`，純函數，參數與累加器為**雙精度**（邊界層的規劃器是雙精度，單精度累加器會漂移且無法逐位元等價；既有推進符號的單精度步長不動），與邊界層既有的時步規劃器**同一份實作**（含單幀最大步數截斷與 epsilon）。宿主的主迴圈因此不必自己寫累加器。出貨的 C／C#／Unity 範例全部改用它。

`pm_advance`／`pm_scene_advance` 對**非有限或負的 `dt`** 回 `PM_ERR_ARGS` 且狀態不變。這只改變「原本就是未定義」的輸入的行為，合法輸入的輸出逐位元不變。

### D6（診斷）

新增 `pm_stats(handle, PmStats*)`（`PmStats` 同樣以 `size` 欄開頭）：上一次觀測的存活粒子數、批次數、壁鐘耗時、堆積配置量，以及進程層級的 GC 次數與暫停時間（取自 RTS 統計）。**只讀、不改變任何狀態、不在主路徑上**——不呼叫它的宿主零成本。 **GC 數字以初始化時要求了 RTS 統計為前提**——統計旗標無法在初始化後開啟(2026-08-20 實測),故 `PmConfig` 帶一個對應欄位(D1)。

## 考慮過的替代方案（Alternatives Considered）

- **在 foreign-library 直接加 `-with-rtsopts=-N`**：一行就能讓 C 宿主拿到平行取樣，但那是庫替宿主決定要開幾個 OS 執行緒——遊戲引擎有自己的 job system，未經同意開滿核心是不禮貌且會搶時間片的行為。D1 把決定權交給宿主，預設維持保守。
- **把例外轉成 C++／SEH 例外拋給宿主**：只對 C++ 宿主有意義，C#／Godot／C 拿不到；且 GHC 的 `foreign export` 不支援這種穿越。錯誤碼是唯一對所有宿主都成立的通道。
- **每 handle 一把互斥鎖，序列化所有操作**：同時解決丟更新與順序問題，但單執行緒宿主每次呼叫都要付鎖的成本，而且宿主想要的通常是「我自己排程、你別擋路」。D4 只保證不丟更新，順序留給宿主，是成本最低且誠實的承諾。
- **`pm_advance` 內建累加器（吃 `elapsed` 而非 `dt`）**：改變既有符號的語意，違反 add-only；而且把「累加器屬於誰」從宿主搬到庫，對有自己固定時步循環的引擎反而礙事。D5 的純規劃器把正確性交出去、不搶所有權。
- **靜默夾住 NaN／負 `dt` 為 0**：掩蓋宿主 bug。回錯誤碼讓問題在開發期浮現。
- **接受「use-after-free 是 UB」的 C 慣例**：一般 C 庫可以這樣說，但 P-1 要求庫永不讓宿主崩潰，而 use-after-free 是宿主最常犯的錯。世代標籤的成本是一次表查與比較，可忽略。

## 影響（Consequences）

- header 新增:`PM_ERR_INTERNAL`(−6)、`PM_ERR_STATE`(−7)、`PmConfig`、`pm_init_ex`、`pm_plan_steps`、`PmStats`、`pm_stats`,以及推進的兩個錯誤碼變體 `pm_advance_ex`／`pm_scene_advance_ex`(凍結標頭裡有七個符號沒有錯誤碼通道,每幀呼叫的推進是其中最需要回報的兩個;其餘五個以安全無操作兌現保證)。符號自 31 增至 **35**(`pm_init_ex` 一個、`pm_plan_steps` 與推進的兩個變體共三個;階段二的 `pm_stats` 會再加一個),全部是加法,`PM_ABI_VERSION` 不動。`test/FFIContractSpec.hs` 與 C# 綁定的雙向對帳測試自動涵蓋新符號。
- `cbits/pm_init.c` 重寫為原子初始化；匯出清單 `.def` 同步。
- 新增 out-of-process 測試：真的載入 `.dll`／`.so`，跑一遍 cast → advance → observe → free，並以一條刻意觸發內部失敗的路徑驗證 D2 的防火牆會回 `PM_ERR_INTERNAL` 而不是殺進程。這是 CI 第一次載入它自己產出的函式庫。
- 新增併發測試（D4 的每一條各一）。
- `docs/integration.md` 新增「執行期」一章：RTS 設定建議、執行緒模型、錯誤碼 −6 的意義、固定時步範例改用 `pm_plan_steps`。
- 本 ADR 的全部條款落在新子系統 host-runtime（[ADR-025](ADR-025-host-runtime-subsystem-split.md)）。
