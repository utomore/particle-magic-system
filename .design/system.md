---
id: system
type: system
title: particle-magic
description: 以魔法陣為資料、由解釋器驅動的粒子魔法系統
status: active
created: 2026-08-19
updated: 2026-08-20
subsystems: [magic-semantics, expr-language, particle-simulation, boundary-host, host-runtime, render-shell, authoring-engineering]
---

# 粒子魔法系統 系統主架構

> **本檔是專案燈塔**，取代 `docs/arch/architecture.md`（v1.3）。舊的 `docs/` 體系自此為**唯讀歷史**：26 份 func-spec、20 份 ADR、roadmap 與分析報告全部原地保留、不再新增。新舊對照見 [legacy-map.md](legacy-map.md)。新的架構決策自 [ADR-021](adr/ADR-021-platform-strategy-pc-shipping.md) 起住 `.design/adr/`。
>
> 產品文件不在本體系內，仍住 `docs/`：`spell-schema.md`（作者手冊）、`spell.schema.json`、`integration.md`（宿主整合指南）、`release.md`（發布政策）。它們是給寫陣的人、接宿主的人、發版的人看的，而且被六條守門測試釘死路徑。

## 需求說明

一套**粒子魔法系統**：玩家用參數與符文組出魔法，魔法的一切表現皆由粒子系統建構。特效不是魔法結算後補上的視覺糖衣——魔法陣的每個槽位直接決定粒子的數學行為，**看到的粒子形態就是魔法的語意**。

五條設計理念決定了整個架構的形狀：

| 理念 | 對架構的約束 |
|---|---|
| **Circle as Data** | 魔法陣是純資料（可序列化），不是程式碼。表達力來自資料的組合空間，而非程式碼分支 |
| **特效即魔法** | 粒子行為由陣的語意導出，不容許「渲染層自己加好看的東西」 |
| **純函數核心** | 核心零 IO。粒子狀態主要是時間的純函數，帶來完全確定性、可重播、可純函數測試 |
| **由內而外設計** | 語意由核心→內圈→夾層→外圈展開；架構同樣由內而外：純核心 → 邊界 → 效果外殼 |
| **維度無關** | 核心在抽象 3D 空間運作，不知道最終投影到 2D 還是 3D。換遊戲、換引擎、換維度只需替換外殼 |

**量化目標**：1 萬～10 萬粒子。POC 階段已實測達成——10 萬粒取樣單執行緒 8.4 ms（-N16 2.5 ms）；護欄值 16384 粒單幀 1.5 ms（-N8 1.0 ms）。production 目標見下方驗收標準。

**永久非目標**（不是「還沒做」，是「這個模型從根本上不做」）：GPU compute／transform feedback、粒子間碰撞、空間分割結構。力場層只支援「場對粒子」，不支援「粒子對粒子」。另外，玩家在 JSON 裡寫 GLSL 也是永久非目標——那會把 GPU API 帶進輸入合約，破壞可攜性。

**定位**（2026-08-20 起）：**production library**——要能嵌進真實的遊戲專案出貨，而不只是示範。25 份既有功能規格與 1 份改善規格全數交付驗收，hspec 套件在 Windows 與 Linux 皆綠；純核心作為「魔法是什麼、這一幀長什麼樣」的實作已達 production 等級。尚未達標的是**嵌入執行期**——宿主拿到共享函式庫之後會發生什麼——這正是 P6–P8 三個階段與新子系統 host-runtime 的由來（[ADR-025](adr/ADR-025-host-runtime-subsystem-split.md)）。

### 產品等級驗收標準

每一條都是可機械檢查的出口條件；哪一條還紅，專案就還不是 production。

| # | 標準 | 量化出口 | 主責子系統 |
|---|---|---|---|
| **P-1** | 庫**永不**讓宿主進程崩潰；任何內部失敗都變成錯誤碼 | 每個匯出符號皆有例外防火牆；out-of-process 測試以刻意觸發的內部失敗驗證回 `PM_ERR_INTERNAL` 而非殺進程 | host-runtime |
| **P-2** | 幀成本可預測：穩態零堆積配置、無 GC 尖峰 | 無新施法、無重載的穩態幀，堆積配置以配置計數器斷言為 0；GC 暫停進 bench 記錄 | particle-simulation、host-runtime |
| **P-3** | 效能：C 宿主拿到與 demo 相同的平行取樣，且單緒更快 | 16384 粒 ≤ 0.5 ms 單緒；10 萬粒 ≤ 3 ms 單緒；宿主可選 capability 數 | particle-simulation、host-runtime |
| **P-4** | 執行緒模型明文化且有測試 | 不同 handle 可併發、同 handle 不丟更新，各有併發測試 | host-runtime |
| **P-5** | 可交付：二進位產物、CI 真的載入過共享函式庫、三平台矩陣 | tag 產出三平台可下載產物；三平台 CI 各跑一次 out-of-process 載入 | authoring-engineering、host-runtime |
| **P-6** | 宿主整合深度：固定時步上 ABI、跟隨施法者、事件查詢、批次歸屬 | 時步規劃器有 C 面；發動點可更新；相位與完成可輪詢；場景批次帶法術 id | boundary-host、magic-semantics、host-runtime |
| **P-7** | 不受信任輸入有完整限制清單 | 位元組上限、節點上限、預算上限、`dt` 有限性各有測試；未知鍵政策明文 | boundary-host、expr-language |
| **P-8** | 可觀測性 | 宿主可查上一幀耗時、配置量、GC 統計，不呼叫則零成本 | host-runtime |
| **P-9** | 決定論：跨平台逐位元 | 同一份輸入在三平台產出相同的九欄位元，golden 三平台皆斷言（[ADR-024](adr/ADR-024-cross-platform-bitexact-trig.md)） | particle-simulation、expr-language |

## 技術棧與環境

| 項目 | 選擇 |
|---|---|
| 語言／編譯器 | Haskell，GHC 9.14.1（`tested-with` 即 CI 安裝的版本） |
| 建置 | cabal 3.16，多 target：兩個公開 sublibrary、一個 foreign-library、四個執行檔、測試與 bench |
| 核心架構模式 | **資料流（Dataflow）**，明確不採 ECS |
| 渲染 | h-raylib（僅外殼層） |
| 序列化 | Aeson |
| 效果系統 | effectful（僅外殼層） |
| 熱路徑 | SoA ＋ unboxed vector；平行取樣以純 Strategies 實作 |
| 嵌入執行期 | GHC RTS 由宿主設定（capability 數、nursery、GC 模式），庫預設保守；C ABI 是例外防火牆（[ADR-022](adr/ADR-022-host-runtime-contract.md)） |
| 出貨平台 | Windows／Linux／macOS（x86_64 與 arm64）三平台 Tier 1；行動與主機不是本執行期的目標，核心保留為移植的 oracle（[ADR-021](adr/ADR-021-platform-strategy-pc-shipping.md)） |

**架構關鍵約束**：分層由**套件結構強制**，不靠紀律。核心 sublibrary 帶依賴白名單，執行檔／CLI／FFI 外殼只依賴邊界 sublibrary，因此**實體上構不到核心內部**。這條由測試機械守護。

## 系統對外介面（External I/O Contract）

### 輸入：魔法陣 JSON（schema v1）

一份帶 `version` 欄的 JSON 物件描述一張魔法陣：四類符文槽（外圈 2／夾層 1／內圈 2／核心）加上陣層級的選配屬性。**一切槽位可為 `null`，全 `null` 即「素放」**；陣層級鍵缺鍵等同「無」，因此舊檔逐位元照舊。

**權威來源**：`docs/spell.schema.json`（機器可讀）與 `docs/spell-schema.md`（作者手冊），兩者互為 golden 並由守門測試釘住。**本檔不複述鍵名與值域**——那會製造第二份會過期的真相。

### 輸出：RenderBatch 串流

每幀輸出一串 render batch：粒子位置為**抽象 3D 座標**的 SoA 緩衝，加上混合模式與 billboard 形狀。

**這個輸出不含任何渲染器型別**——這是渲染後端可替換性的保證，也是「維度無關」在介面上的兌現。宿主的責任只有兩件：把批次交給自己的投影後端，依混合模式設定管線狀態並整批繪製。

### 三種消費模式

| 模式 | 誰用 | 契約權威 |
|---|---|---|
| **Haskell library** | Haskell 宿主、demo 外殼、作者 CLI | 兩個 `visibility: public` sublibrary；宿主只准 import 入口模組與編解碼模組 |
| **C ABI** | Unity／Godot／C++ 等非 Haskell 宿主 | `include/particle_magic.h`——**只加不改**，31 個已凍結符號加 production 階段的加法；由 host-runtime 擁有 |
| **場景層** | 需要多法術共存與全域配額的宿主 | 上述兩者之上的純值組合層，Haskell 面與 C 面皆有 |

三者共用同一條**生命週期契約**：`施法 → 推進 → 觀測 → 結束`。推進與觀測分離，是可重播性的來源。

### 兩條觀測契約

觀測有兩種形式並存，輸出**逐位元相同**（[ADR-023](adr/ADR-023-host-buffer-contract.md) 等價律 3）：

| 契約 | 緩衝歸誰 | 適用 |
|---|---|---|
| **純值觀測**（凍結） | 庫配置，宿主可長期持有，每幀全新 | Haskell 宿主、測試、golden、一次性工具 |
| **宿主緩衝觀測** | 宿主提供記憶體與容量，取樣器直接寫入，下一次呼叫覆寫 | 每幀繪製的遊戲宿主；穩態零配置的來源 |

### 執行期契約

宿主拿到共享函式庫之後的一切，由 [ADR-022](adr/ADR-022-host-runtime-contract.md) 定義、host-runtime 實作：

- **RTS 由宿主設定**：capability 數、nursery、GC 模式；不設定則維持保守預設。初始化原子化；關閉後不得再初始化，兩平台語意一致。
- **例外防火牆**：每個匯出符號攔截一切 Haskell 例外並映射為 `PM_ERR_INTERNAL`；庫在任何情況下不終止宿主進程。
- **執行緒模型**：不同 handle 可併發；同一 handle 保證不丟更新、不保證順序。
- **控制代碼安全**：已釋放或偽造的 handle 回錯誤而非未定義行為。
- **固定時步上 C ABI**：時步規劃器（含單幀最大步數截斷）與邊界層同一份；非有限或負的 `dt` 拒收。
- **診斷**：上一幀耗時、配置量、GC 統計可查，不查則零成本。

### 決定論的範圍

同一份輸入永遠得到同一串畫面。POC 階段的邊界是「同平台逐位元、跨平台結構相同 ＋ 2 ulp」（根因是 libm 的三角函數不保證正確捨入）；production 階段以自製的確定性三角函數把它升級為**跨平台逐位元**——相同的 `(json, pos, facing, seed, dt 序列)` 在三個 Tier 1 平台產出相同的九欄位元（[ADR-024](adr/ADR-024-cross-platform-bitexact-trig.md)，取代 ADR-0016 D4）。這是多人 lockstep 與跨機器重播的前提。前提條件：單精度確定的 SIMD 單元、宿主不改動浮點控制字。

### 全域錯誤處理策略

錯誤在**邊界層**被轉成值，核心不拋例外、不做防禦性檢查（不合法的組合在型別層就無法表示）。C 面以負值錯誤碼加呼叫端提供的訊息緩衝回報，與 Haskell 面的錯誤型別一一對應。**C ABI 之外再無任何一層**：例外防火牆是最後一道，攔到東西一律視為缺陷，而不是錯誤處理的一部分。

## 子系統劃分（Subsystems & Bounded Contexts）

切分依據是 **cabal 的實際依賴邊界與模組歸屬**，不是概念分類——每一塊都指得到具體檔案。七個子系統，每個一份 Level 2 設計。

### magic-semantics — 魔法語意

**職責**：回答「**魔法是什麼**」。魔法陣的結構、四類符文的詞彙、由內而外的解釋器、生命週期時間表、以及由陣自身結構摘要導出的符文陣幾何。

**明確不做**：不求值數學式、不取樣粒子、不認識 JSON 或任何文字語法、不認識相機與繪圖 API。

**對外契約摘要**：吃一張魔法陣，吐一份**編譯後的法術**（發射器集合 ＋ 生命週期界標 ＋ 力場環境 ＋ 粒子預算），外加陣形的靜態查詢。編譯結果是**資料而非函數**，因此可序列化、可快取、可在編譯期做預算分析。

**設計**：[subsystems/magic-semantics/design.md](subsystems/magic-semantics/design.md)

### expr-language — 數學式

**職責**：玩家可寫的小型算式語言。AST 與語意、編譯期化簡與加速、文字文法的剖析與還原。系統中唯一**由玩家直接撰寫程式碼**的地方，因此同時是表達力來源與輸入攻擊面。

**明確不做**：不決定式子掛在哪個槽位、吃哪一條時間軸（那是 magic-semantics 的語意）；不是 λ 演算——封閉、一階、無遞迴綁定，保證求值必然終止、可序列化、可靜態分析。

**對外契約摘要**：文字 ↔ AST 的雙向轉換（剖析錯誤附位置）、AST 的參照求值語意、以及與參照語意**逐位元等價**的加速求值路徑。

**設計**：[subsystems/expr-language/design.md](subsystems/expr-language/design.md)

**邊界特例**：這是唯一橫跨純核心與邊界層的**縱切**子系統——AST 與求值器在核心，文字文法在邊界。理由是核心不認識文字。

### particle-simulation — 粒子模擬

**職責**：回答「**這一幀長什麼樣**」。拿編譯後的法術加上一個時間，算出一整塊粒子緩衝。實作混合粒子模型：解析為主（無狀態、可任意快轉倒帶），力場為輔（系統唯一的跨幀狀態）。

**明確不做**：不編譯魔法陣、不繪製、不投影、不做粒子對粒子互動、不自行跨幀重用緩衝（純值契約下會偷改上一幀；宿主緩衝契約下記憶體歸宿主管，庫不保留）。

**對外契約摘要**：`(編譯後的法術, 施法上下文, 時間, 寫入目標) → 填好的粒子欄位`——寫入目標可以是庫自己剛配置的欄位（純值觀測）或呼叫端提供的欄位（宿主緩衝觀測），同一條填寫路徑；力場層以編譯期固定的槽位身分為鍵，與解析層以**加法位移疊加**組合；固定時步規劃器供外殼與 C ABI 共用同一份；三角函數為自製確定性實作，跨平台逐位元。

**設計**：[subsystems/particle-simulation/design.md](subsystems/particle-simulation/design.md)

### boundary-host — 邊界與宿主整合

**職責**：系統對外的**唯一合約面的 Haskell 面**。把三個核心子系統包成一份契約。涵蓋編解碼、法術生命週期入口（含施法上下文更新與相位／完成的輪詢查詢）、場景層（含批次歸屬）、維度無關輸出的投影、空間摘要輸出、欄位回灌，以及 Haskell 宿主的接入範例。它是 host-runtime、render-shell、authoring-engineering 三者唯一准許依賴的東西。

**明確不做**：不含任何魔法語意、不選繪圖 API、不輸出任何渲染器型別、不做視錐剔除與碰撞判定（庫交保守包絡與佔用格網，判定是宿主的事）、不碰 C 呼叫慣例與 RTS（那是 host-runtime）。

**對外契約摘要**：本檔「系統對外介面」中的輸入、輸出、兩條觀測契約與生命週期——以 Haskell 型別表達的那一面。

**設計**：[subsystems/boundary-host/design.md](subsystems/boundary-host/design.md)

### host-runtime — 嵌入執行期

**職責**：把 boundary-host 的 Haskell 契約變成宿主進程裡**一個安全、可調、可診斷的共享函式庫**。涵蓋 C ABI 外殼與 `include/particle_magic.h`、RTS 生命週期與設定、例外防火牆、控制代碼註冊、執行緒模型、宿主緩衝觀測的 C 面與整塊複製、固定時步的 C 面、診斷統計、各語言綁定與非 Haskell 宿主範例、共享函式庫的封裝（standalone 連結、MSVC 匯入庫、產物內容）。

**明確不做**：不含任何魔法語意、不重新定義邊界層的 Haskell 契約（只消費它）、不選繪圖 API、不接 Haskell 宿主（那是 boundary-host）、不擁有 CI 流程（產物的建置與上傳屬 authoring-engineering，產物的內容屬本子系統）。

**對外契約摘要**：本檔「系統對外介面」中的 C ABI 消費模式與**執行期契約**全節。31 個已凍結符號只加不改；production 階段新增的符號與結構全部是加法，ABI 世代不動。

**設計**：[subsystems/host-runtime/design.md](subsystems/host-runtime/design.md)（[ADR-025](adr/ADR-025-host-runtime-subsystem-split.md)）

### render-shell — 渲染外殼

**職責**：**參考宿主**——demo 遊戲外殼與專案裡全部的 Haskell IO。主迴圈、熱重載、3D 與 2D 後端、批次繪製、深度排序、後處理、HUD 與參數面板。production 定位下它的角色是「一個按規矩接庫的宿主長什麼樣」，不是出貨的一部分。

**明確不做**：不定義任何對外合約、不含魔法語意、不把渲染概念推回庫裡。

**對外契約摘要**：**沒有對外契約**——它是終端消費者。它的「介面」是單向的：只消費邊界層，反過來沒有任何庫元件依賴它。這一塊整組刪掉，庫仍然完整。

**設計**：[subsystems/render-shell/design.md](subsystems/render-shell/design.md)

### authoring-engineering — 作者工具與工程化

**職責**：服務兩種人——**寫魔法陣的人**（格式手冊、驗證與檢視 CLI、機器可讀 schema）與**發布這個庫的人**（相容性政策、版本規則、三平台 CI 矩陣、**二進位發布產物**、**效能回歸門檻**）。另含本專案的特色機制：**把文件當成被測物**的守門測試。

**明確不做**：產物一行都不進出貨的庫，也不影響任何執行期行為；發布產物的**內容**（哪些檔、怎麼連結）由 host-runtime 定義，本子系統只負責把它建出來、驗過、放到可下載的地方。

**對外契約摘要**：三支 CLI 的旗標、退出碼與報告格式；schema 檔本身；發布產物的命名與平台矩陣。

**設計**：[subsystems/authoring-engineering/design.md](subsystems/authoring-engineering/design.md)

## 通訊拓撲與原則（Communication Topology）

**通訊方式一律是同進程的直接函數呼叫**（Direct In-Memory Call）——沒有 REST、沒有訊息佇列、沒有序列化跨界，唯一的例外是 C ABI 那道邊界（值以 C 呼叫慣例傳遞，緩衝以連續陣列整塊複製或由取樣器直接寫入宿主記憶體）。

**依賴方向嚴格由外向內，且不可逆**：

```text
render-shell ──┐
authoring-eng ─┼─→ boundary-host ─→ { magic-semantics, expr-language, particle-simulation }
host-runtime ──┘
```

六條全域原則：

1. **核心零 IO**。核心不執行效果、不依賴任何 IO 專屬 API，簽名中不出現 `IO` 或效果型別；對呼叫端提供的欄位填寫以 `ST` 進行、對執行單子多型，由外殼選擇在宿主記憶體上以 `IO` 執行（ADR-023 D4）。
2. **邊界是唯一依賴點**。宿主與外殼只准經邊界層的入口模組使用系統，構不到核心內部——由套件結構強制，測試守護。host-runtime 也不例外。
3. **上層不知道下層的存在**。核心不知道有外殼，也不知道有相機、螢幕、繪圖 API、RTS 或執行緒。
4. **固定時步是系統公理**。模擬永遠以固定步長推進，渲染幀率以累加器解耦。改成可變時步會同時破壞重播與所有測試基準。時步規劃器只有一份，Haskell 面與 C 面共用。
5. **RTS 是宿主的**。庫不替宿主決定開幾個執行緒、用多大的 nursery；不設定就保守。庫不自行開 OS 執行緒。
6. **C ABI 是例外防火牆**。沒有任何 Haskell 例外穿過它；攔到的一律是缺陷。

**錯誤處理**：核心不失敗（不合法組合在型別層不可表示）；邊界層把載入、編譯、配額三類失敗轉成值；C 面映射為錯誤碼，並以防火牆兜住其餘一切。**沒有任何一層拋例外當控制流**。

## 架構圖

```text
        魔法陣 JSON                                      RenderBatch 串流
        （schema v1）                                    （零渲染器型別）
             │                                                  ▲
             ▼                                                  │
  ┌──────────────────────────────────────────────────────────────────────┐
  │                          host-runtime                                │
  │   嵌入執行期：C ABI（include/particle_magic.h，只加不改）／RTS 設定    │
  │   例外防火牆／執行緒模型／宿主緩衝直寫／時步 C 面／診斷／綁定與封裝     │
  │   只依賴 boundary-host；非 Haskell 宿主唯一的入口                      │
  └──────────────────────────────────┬───────────────────────────────────┘
                                     │
                                     ▼
  ┌──────────────────────────────────────────────────────────────────────┐
  │                          boundary-host                               │
  │   合約面的 Haskell 面：編解碼 / 生命週期入口 / 場景層 / 投影 / 空間摘要 │
  │   ├─ Haskell library（public sublibrary）                            │
  │   ├─ 兩條觀測契約（純值 ／ 宿主緩衝），逐位元等價                       │
  │   └─ 場景層（多法術 ＋ 全域配額 ＋ 批次歸屬）                           │
  └───────┬───────────────────┬──────────────────────┬───────────────────┘
          │                   │                      │
          ▼                   ▼                      ▼
  ┌───────────────┐   ┌───────────────┐   ┌──────────────────────┐
  │ magic-        │   │ expr-language │   │ particle-simulation  │
  │ semantics     │◀──│               │──▶│                      │
  │               │   │  AST／求值    │   │  解析取樣 ＋ 力場      │
  │ 魔法是什麼     │──────────────────────▶│  這一幀長什麼樣        │
  │               │      編譯後的法術                              │
  └───────────────┘   └───────────────┘   └──────────────────────┘
       純核心（零 IO）      縱切：核心＋邊界         純核心（零 IO）

  ┌──────────────────────────────┐   ┌──────────────────────────────┐
  │ render-shell                 │   │ authoring-engineering        │
  │ 參考宿主：demo 外殼與全部 IO   │   │ 三支 CLI ／ schema ／ CI      │
  │ 只消費 boundary-host          │   │ 三平台矩陣 ／ 發布產物 ／ bench 門檻 │
  │ 無人依賴它 → 可整組替換        │   │ 產物不進出貨的庫              │
  └──────────────────────────────┘   └──────────────────────────────┘
```

## 開發階段

專案已走過概念驗證的三道分水嶺（效能、多陣合成與全域配額、視覺表現力），P1–P4 交付了一個**可出貨的 POC**。2026-08-20 起定位改為 production library，以「產品等級驗收標準」P-1～P-9 為出口，分三個階段推進；P5 原本的「各子系統候選項」併入各階段或留在各 `design.md` 的候選區。

| 階段 | 狀態 | 涵蓋 | 出口條件 |
|---|---|---|---|
| **P1 骨架與語意** | ✅ 已完成 | 套件邊界、魔法陣解釋器、數學式語言、生命週期與陣形幾何 | — |
| **P2 可用的庫** | ✅ 已完成 | 效能達標、C ABI 與各語言綁定、多陣合成與場景層、空間輸出 | — |
| **P3 可看的畫面** | ✅ 已完成 | 渲染、深度排序、展現詞彙、產品級特效 | — |
| **P4 可交付的流程** | ✅ 已完成 | 作者 CLI、JSON Schema、CI 兩平台矩陣、發布政策 | — |
| **P6 不會崩、可交付** | 進行中 | host-runtime：例外防火牆、RTS 設定、控制代碼世代、執行緒模型、時步 C 面、`dt` 檢查；authoring-engineering：三平台矩陣、CI 載入共享函式庫、發布產物；文件修正（`pm_max_particles` 的過期註解、C 範例的容量常數） | P-1、P-4、P-5 綠；任意錯誤輸入與 API 誤用都回錯誤碼 |
| **P7 快而穩** | 未開始 | particle-simulation：去中介向量、編譯期預窄化、分片直寫、力場步進只走存活槽位、確定性三角函數、上限重量；expr-language：迴圈不變式提升、內建函數改走確定性實作；boundary-host 與 host-runtime：宿主緩衝觀測、整塊複製；authoring-engineering：bench 回歸門檻；host-runtime：診斷 | P-2、P-3、P-8、P-9 綠；golden 一次性重錄後三平台皆斷言 |
| **P8 遊戲整合** | 未開始 | magic-semantics 與 boundary-host：發動點跟隨施法者、相位與完成的輪詢查詢、場景批次歸屬、多陣合成的 C 面、魔法代價閘門；boundary-host：輸入強化與未知鍵政策、schema v2 遷移行使一次；host-runtime：C# native array 路徑、`SafeHandle`、IL2CPP 驗證、C++ RAII 包裝 | P-6、P-7 綠；一個真實遊戲宿主（非 demo）跑完一個關卡的整合清單 |

階段之間有順序（P6 的防火牆與 out-of-process 測試是 P7 量測的前提；P7 的宿主緩衝是 P8 的 native array 路徑的前提），階段之內各子系統可平行。**每個項目的契約與驗收在各 `design.md` 的功能規劃與契約卡**；本檔只定階段與出口。

