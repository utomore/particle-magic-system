---
id: legacy-map
type: reference
title: legacy-map
description: 新舊設計文檔體系的對照表與界線
status: active
created: 2026-08-19
updated: 2026-08-20
parent: system
---

# 新舊體系對照表

本檔是 `.design/` 與舊 `docs/` 之間**唯一的橋**。它存在的理由只有一個：舊體系累積了 26 份交付紀錄、20 份架構決策與大量推論過程，那些內容仍然正確且經常需要回查，但它們的**編號體系與新的三層階梯不相容**。與其重寫（會切斷與 git history、CHANGELOG 及程式碼註解的對應），不如凍結它們並留一張表。

## 界線（三句話）

1. **`.design/` 是唯一的活體系。** 新的架構調整、功能、優化、缺陷一律走 `.design/`，依 dev-flow 三層階梯。
2. **`docs/` 的設計文檔是唯讀歷史。** 不再新增、不再改動、不重編號。它們記錄「這件事當初是怎麼想的、怎麼交付的」。
3. **`docs/` 的產品文件仍然是活的**，見下方「不在遷移範圍內」。

## 為什麼程式碼一個字都沒改

`src/`、`app/`、`tools/`、`test/`、`include/` 裡有約 938 處形如 `func-spec 0016`、`spec 0009 §2` 的註解與測試名稱，散在 196 個檔案。它們是**出處紀錄**——說的是「這行程式碼是哪一輪交付的」——而 git history 與 `CHANGELOG.md` 用的是同一套詞彙。

**這些引用全部仍然有效**：拿編號查下表即可定位到舊文檔，以及它在新體系裡屬於哪個子系統。改掉它們會換來一致的詞彙，但會永久切斷與提交歷史的對應，而且是 196 個檔案的零行為變更編輯。

## 交付紀錄對照（26 份）

舊文檔全部位於 `docs/spec/` 與 `docs/enhance/`，狀態皆為 `done`。「子系統」欄是它在新體系裡的歸屬——這份歸屬不是本次遷移新判的，而是既有的單一主場裁決（一份規格恰屬一個子系統）直接沿用。

### magic-semantics（7）

| 舊 id | feature | 舊文檔 |
|---|---|---|
| func-0002 | circle-interpreter | `docs/spec/func-0002-circle-interpreter.md` |
| func-0004 | expr-rune-wiring | `docs/spec/func-0004-expr-rune-wiring.md` |
| func-0006 | lifecycle-formation | `docs/spec/func-0006-lifecycle-formation.md` |
| func-0016 | sigil-geometry | `docs/spec/func-0016-sigil-geometry.md` |
| func-0017 | sigil-persistence | `docs/spec/func-0017-sigil-persistence.md` |
| func-0020 | sigil-motion | `docs/spec/func-0020-sigil-motion.md` |
| func-0021 | magic-vocabulary | `docs/spec/func-0021-magic-vocabulary.md` |

### expr-language（2）

| 舊 id | feature | 舊文檔 |
|---|---|---|
| func-0003 | expr-subsystem | `docs/spec/func-0003-expr-subsystem.md` |
| func-0022 | cse-and-bytecode | `docs/spec/func-0022-perf-second-tier.md` |

### particle-simulation（2）

| 舊 id | feature | 舊文檔 |
|---|---|---|
| func-0007 | force-field-layer | `docs/spec/func-0007-force-field-layer.md` |
| func-0010 | performance-budget | `docs/spec/func-0010-performance-budget.md` |

### boundary-host（5）

| 舊 id | feature | 舊文檔 |
|---|---|---|
| func-0001 | framework-skeleton | `docs/spec/func-0001-framework-skeleton.md` |
| func-0008 | ortho2d-projection | `docs/spec/func-0008-ortho2d-backend.md` |
| func-0012 | scene-layer | `docs/spec/func-0012-multi-circle-composition.md` |
| func-0025 | spatial-output-anchors | `docs/spec/func-0025-spatial-output-anchors.md` |
| enhance-0001 | haskell-host-onboarding | `docs/enhance/enhance-0001-haskell-2d-host-onboarding.md` |

### host-runtime（3）

2026-08-20 依 [ADR-025](adr/ADR-025-host-runtime-subsystem-split.md) D4 自 boundary-host 換主場——「一份規格恰屬一個子系統」的規則不變，只是三份換了歸屬。

| 舊 id | feature | 舊文檔 |
|---|---|---|
| func-0009 | ffi-foreign-library | `docs/spec/func-0009-ffi-foreign-library.md` |
| func-0011 | host-integration-surface | `docs/spec/func-0011-host-integration-surface.md` |
| func-0018 | scene-c-abi | `docs/spec/func-0018-scene-c-abi.md` |

### render-shell（4）

| 舊 id | feature | 舊文檔 |
|---|---|---|
| func-0005 | render-observability | `docs/spec/func-0005-render-observability.md` |
| func-0013 | visual-expressiveness | `docs/spec/func-0013-visual-expressiveness.md` |
| func-0015 | visual-vocabulary | `docs/spec/func-0015-visual-vocabulary.md` |
| func-0023 | production-visuals | `docs/spec/func-0023-production-visuals.md` |

### authoring-engineering（3）

| 舊 id | feature | 舊文檔 |
|---|---|---|
| func-0014 | authoring-tools | `docs/spec/func-0014-authoring-tools.md` |
| func-0019 | engineering-ci-release | `docs/spec/func-0019-engineering-ci-release.md` |
| func-0024 | authoring-tools-2 | `docs/spec/func-0024-authoring-tools-2.md` |

### 唯一被搬過來的一份

| 舊 id | 新 id | 原因 |
|---|---|---|
| func-0026 | `magic-semantics/F001` | 唯一**尚未實作**的規格。未來工作走新體系，所以它搬家；同時把它原本涵蓋的兩列功能規劃合併為一個 feature `sigil-time-axis`（0.7.0 是一份文檔一個 F 號） |

## 架構決策（ADR）

**20 份 ADR 全部留在 `docs/adr/`，檔名不變。** 它們被程式碼註解、規格與 header 到處引用（如「ADR-0014 D3」「ADR-0010 D9」），這些引用是本專案最有價值的資產之一。

**新的 ADR 寫進 `.design/adr/`，編號從 `ADR-021` 接續**，避免與舊的 `adr-0001..0020` 撞號。

| ADR | 決策 |
|---|---|
| adr-0001 | 混合粒子模型：解析為主，可選力場層 |
| adr-0002 | 分層式 DSL，不採深度 GADT DSL |
| adr-0003 | 槽位固定職責＋符文 |
| adr-0004 | 不用 ECS，採資料流架構 |
| adr-0005 | JSON ＋熱重載作為系統輸入介面 |
| adr-0006 | SoA ＋ unboxed vector 粒子緩衝 |
| adr-0007 | 效果邊界，核心零 IO |
| adr-0008 | 維度無關核心，3D 優先投影 |
| adr-0009 | 渲染路徑採動態 quad mesh，不採 instancing |
| adr-0010 | 力場層組合點語意：加法位移疊加、穩定槽位身分、熱重載歸零 |
| adr-0011 | C ABI 邊界：foreign-library、JSON 進、SoA copy-out、handle 生命週期 |
| adr-0012 | 多陣合成與場景層配額 |
| adr-0013 | 告示板詞彙：無參數列舉、程序生成貼圖 |
| adr-0014 | 符文陣由魔法陣資料導出：摘要即合約 |
| adr-0015 | 陣駐留到法術結束：取消陣形收束 |
| adr-0016 | 發布相容性政策：同平台逐位元、跨平台結構 ＋ 2 ulp |
| adr-0017 | 平行取樣的決定論：以純 Strategies 分片 |
| adr-0018 | 自訂 shader 進殼層、SoA 六欄鬆綁為九欄 |
| adr-0019 | 空間摘要是輸出不是模擬結構 |
| adr-0020 | 陣會自轉：逐位元邊界收窄至 t = 0 |

新體系的 ADR（`.design/adr/`），以及它們修訂了哪些舊條款：

| ADR | 決策 | 修訂 |
|---|---|---|
| ADR-021 | 平台策略：PC 三平台為出貨目標，Haskell 庫即出貨執行期 | adr-0016 D1 |
| ADR-022 | 執行期契約：RTS 由宿主設定、例外防火牆、執行緒模型、控制代碼世代 | adr-0011 D4、D5 |
| ADR-023 | 宿主緩衝契約與純值契約並存，取樣器直寫宿主記憶體 | adr-0011 D3；補充 adr-0006、adr-0007 |
| ADR-024 | 自製確定性三角函數，決定論升級為跨平台逐位元 | **取代** adr-0016 D4 |
| ADR-025 | 從 boundary-host 切出 host-runtime 子系統 | 本檔的主場歸屬 |

## 其他舊文檔的去向

| 舊文檔 | 內容去了哪裡 |
|---|---|
| `docs/arch/architecture.md`（v1.3） | → `.design/system.md`。舊檔保留為歷史，**但它不再是燈塔** |
| `docs/arch/subarch-0001..0006` | → 六份 `.design/subsystems/*/design.md`。內容重寫過：**簽名一律移除**，改為契約層敘述（見下節） |
| `docs/roadmap.md` | 各子系統的候選項與欠款記帳 → 各 `design.md` 的「功能規劃」與契約卡。舊檔保留為當初的排序推論 |
| `docs/analysis/report-*` | 原地保留。0.7.0 沒有 analysis 文檔類型，健檢改由 `/arch-audit` 產出 |

## 不在遷移範圍內（`docs/` 裡仍然活著的檔案）

這四份是**產品文件**，不是設計文檔——它們是給寫陣的人、接宿主的人、發版的人看的，而且被六條守門測試釘死路徑（含 `tools/Schema.hs` 的預設輸出路徑）。它們留在 `docs/`，繼續更新：

| 檔案 | 誰讀它 |
|---|---|
| `docs/spell-schema.md` | 寫魔法陣的人：鍵名、值域、公式語法、範例導覽 |
| `docs/spell.schema.json` | 編輯器與 CI：機器可讀的格式宣告 |
| `docs/integration.md` | 接宿主的人：Haskell／C／C++／Unity 各自怎麼接 |
| `docs/release.md` | 發版的人：平台分級、版本規則、承諾到哪裡為止 |

## 一條刻意的斷點：簽名不再進架構文檔

舊的 `subarch-*` 在架構層逐條抄了函式簽名。那是**體系設計上的錯誤**，不是撰寫疏失——架構文檔沒有守門測試，簽名卻會隨每次提交漂移，於是它成了第二份會過期的真相。實測結果：六份 subarch 共 53 條簽名，**15 條與原始碼不符**，其中 8 條是實質錯誤（參數個數、參數順序、回傳型別）。

dev-flow 0.7.0 把這件事寫成硬規則（**資訊抽象邊界規範**）：Level 1 與 Level 2 只定義邊界契約與資料流，簽名只出現在 Level 3。

因此六份新的 `design.md` **不含任何函式簽名**，改寫成契約敘述。例:

| 舊寫法（會過期） | 新寫法（不會） |
|---|---|
| `orthographic :: ViewPlane -> V3 -> V2` | 正交投影回傳平面座標**與深度**，深度供 painter 排序使用 |
| `occupancyOf :: ActiveSpell -> Int -> OccupancyGrid` | 宿主可查一個法術在 N³ 格網上的佔用計數；N 預設 3，27 格恰好壓進一個 32 位元遮罩 |

第一列的舊寫法連「它會回傳深度」都寫漏了——契約層的抽象度反而擋得住這種錯，因為它問的是「保證什麼」而不是「長什麼樣」。要查真正的簽名，唯一權威是原始碼。
