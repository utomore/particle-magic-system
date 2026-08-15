# SKILL.md — 本專案的文件體系與工作方法

本檔定義專案內各類文件的角色、寫作規範，與「文件 → 實作 → 測試」的工作循環。所有貢獻者（含 AI 協作者）依此運作。

## 文件體系

| 文件 | 角色 | 何時讀 / 何時寫 |
|---|---|---|
| `Init.md` | 原始願景筆記 | 只讀，不再更新；細節已由架構書取代 |
| `docs/architecture.md` | 系統架構設計書：模組結構、資料流、型別草圖、介面規格、風險分析 | 任何設計/實作前必讀；架構層變動時更新 |
| `docs/adr/NNNN-*.md` | 架構決策紀錄（ADR）：一份一決策，含背景/決策/後果/被否決方案 | 違反前必先修訂；新的架構級決策新增一份 |
| `docs/func-spec/NNNN-*.md` | **功能規格書（function spec）**：一份對應一個模組或一次程式設計迭代的實作細節 | 每輪實作**動工前**寫定；實作中回填驗收紀錄 |
| `docs/roadmap.md` | **路線圖與完整度盤點**：還差什麼、下一輪該蓋哪一個。內容由各 spec 的 §9 非目標與驗收紀錄盤點而來，不引入新決策 | 決定下一份 spec 主題時讀；每次 func-spec 驗收後更新 |
| `docs/integration.md` | **宿主整合指南**：Haskell／C／C++／Unity／自製前端各自怎麼接，資料合約速查、限制與相容性承諾 | 對外介面（`Magic.Interface`／`Magic.Codec`／`Magic.Projection`／C ABI header）變動時同步更新 |

## Func-Spec：功能規格書

架構書回答「系統長什麼樣、為什麼」；func-spec 回答「**這一輪具體怎麼蓋**」。每份 func-spec 必含以下章節：

1. **目標與完成定義** — 這輪做什麼、做到什麼程度算完成（可驗證的條件）。
2. **使用到的架構與技巧** — 本輪套用的模式/手法及選擇理由（如 accumulator 時步、bracket 效果、SoA）。
3. **ADT** — 本輪實際定義的型別，標明「永久型別」與「⚠ stub 佔位」；stub 的介面即最終介面。
4. **資料結構與儲存方式** — 資料放哪、什麼結構、生命週期。
5. **資料流（pipeline）** — 本輪範圍內的資料流動，標明純/IO 分界（mermaid 圖）。
6. **搭建方式** — 實作步驟順序與排序理由（風險優先）。
7. **Todo List 與 1-to-1 測試對應** — 見下方規則。
8. **非目標** — 明確不做、留給哪份後續 spec。
9. **驗收紀錄** — 實作時回填（日期、結果）。

### Todo ↔ 測試 1-to-1 規則

- 每個 Todo 項目（`Sx`）對應**恰好一個**測試模組（`test/XxxSpec.hs`），表格中並列。
- **一個 Todo 打勾的前提：對應測試存在且綠**。不積欠測試債。
- 無法自動測試的項目（如開視窗目視）明確標記「手動 smoke」，並在驗收紀錄章節留下結果。
- 測試框架：hspec（hspec-discover）＋ QuickCheck；純函數優先寫 property 測試。

### 編號與狀態

- 檔名 `NNNN-短英文名.md`，編號遞增不重用。
- 文件開頭標狀態：`設計中` → `設計定案，待實作` → `實作中` → `已完成`（附驗收紀錄）。
- 文件開頭同時標**性質**與**前置依賴**（見下節）。

## 多協作者開發模式（每份 spec 一位協作者）

開發方式：一位協作者（一個 Claude session）負責討論/撰寫設計文檔，其他協作者各自認領 func-spec 實作。**一位協作者同時最多負責一份 func-spec**。因此：

1. **Spec 之間盡量解耦**：一份 spec 只能依賴（a）架構書定義的永久介面，與（b）狀態為「已完成」的 spec。不得依賴其他「實作中」spec 的內部細節——需要別的 spec 的東西時，依賴的是它在架構書層級的介面簽名，不是它的實作。
2. **每份 spec 開頭必須宣告**：
   - `性質：一般` 或 `性質：**重大基建功能**`
   - `前置依賴：無` 或 `前置依賴：spec NNNN（需已完成）`
3. **重大基建功能**：若一份 spec 是多份後續 spec 的共同地基（如套件邊界、對外介面合約、核心資料結構），必須在文件開頭標示 `**重大基建功能**`。規則：
   - 重大基建 spec **完成驗收前，依賴它的 spec 不得動工**；
   - 其「永久介面」一旦完成即凍結——後續變更視同架構變更，需先修訂 ADR/架構書，並盤點所有下游 spec；
   - 認領重大基建 spec 的協作者，交付時必須在驗收紀錄註明「凍結的介面清單」，供下游 spec 引用。
4. 平行進行的 spec 不得修改同一個模組檔案；若無法避免，表示切分錯了，回到設計階段重切。

## 工作循環

```
架構書/ADR（不變的合約）
   └─> 寫 func-spec NNNN（本輪細節，含 Todo×測試表）
        └─> 依搭建順序實作，逐項「測試綠 → 打勾」
             └─> 回填驗收紀錄，狀態改「已完成」
                  └─> 下一份 func-spec
```

衝突處理：func-spec 不得與 ADR 矛盾；發現必須矛盾時，先修訂 ADR（或新增 ADR 取代舊決策），再改 func-spec。

## 現有 Func-Spec 索引

| 編號 | 主題 | 性質 | 前置依賴 | 狀態 |
|---|---|---|---|---|
| [0001](docs/func-spec/0001-framework-skeleton.md) | 框架搭建（walking skeleton）：套件邊界、IO/核心邊界、端到端資料流 | **重大基建功能** | 無 | 已完成 |
| [0002](docs/func-spec/0002-circle-interpreter.md) | 魔法陣結構與解釋器：Circle ADT、參數層符文、由內而外 fold、真實取樣、完整槽位 JSON schema | **重大基建功能** | spec 0001（已完成） | 已完成 |
| [0003](docs/func-spec/0003-expr-subsystem.md) | Expr 數學式子系統：封閉一階 AST、樸素求值器、文字語法剖析（megaparsec）、渲染器；不含符文接線 | **重大基建功能** | spec 0001（已完成）；不依賴 0002 | 已完成 |
| [0004](docs/func-spec/0004-expr-rune-wiring.md) | Expr 符文接線：`RangeRune`/`ConvergeRune`/`AmplifyRune`/`FormulaRune`、`ExprV3` 定型、分層時間框架（行為層 t＝粒子年齡、調變層 t＝施法秒數）、fold 加 case、Codec 加 tag | 一般 | spec 0002（已完成）＋0003（已完成） | 已完成 |
| [0005](docs/func-spec/0005-render-observability.md) | 渲染落實與觀測：動態 quad mesh 單 draw call、`rbBlend`/`rbShape` 生效、HUD＋載入錯誤上屏、鍵盤切換範例、`-O2`＋benchmark 基線；`advanceSpell`/`observeSpell` 分離 | 一般 | spec 0001/0002/0003（已完成）；**與 0004 平行**（檔案零交集，見其 §0.3） | 已完成 |
| [0006](docs/func-spec/0006-lifecycle-formation.md) | 生命週期四階段與陣形發射器：`Phase`/`PhasePlan`、opt-in `"phases"` JSON、陣形幾何→發射器（fold 步驟 5）、casting 包絡位移、合成收束 ramp；取樣器零變更、既有範例逐位元相容 | 一般 | spec 0002/0003/0004（已完成）；**與 0005 平行**（檔案零交集，見其 §0.2） | 已完成 |
| [0007](docs/func-spec/0007-force-field-layer.md) | 力場層：`ForceField`（gravity/attractor/vortex）、`FieldState` 穩定槽位身分、半隱式尤拉、零場逐位元相容律；ADR-0010 組合點語意；`app/*` 零觸碰 | 一般 | spec 0006（已完成）——修改檔案與 0006 交集（Circle/Compile/Codec），動工門檻＝0006 驗收 | 已完成 |
| [0008](docs/func-spec/0008-ortho2d-backend.md) | 2D 正交後端：`ViewPlane`/`orthographic`/`depthOrder` 入 `Magic.Project`、boundary 再匯出 `Magic.Projection`、真 2D 繪製路徑（painter 排序＋螢幕座標）、demo Tab/V 切換三視圖；兌現 ADR-0008 | 一般 | 無（0001/0002/0005 已完成）；**與 0007 平行**（檔案零交集，見其 §0.2） | 已完成 |
| [0009](docs/func-spec/0009-ffi-foreign-library.md) | FFI 外殼（C ABI）：cabal foreign-library 產 `.dll`/`.so`、`pm_cast`(JSON)→`pm_advance`→`pm_observe`(SoA copy-out) handle 生命週期、`particle_magic.h` 凍結合約、跨界決定論等價律；ADR-0011 | 一般 | 無（0001/0002/0005 已完成）；**與 0007／0008 三方平行**（新檔案為主，見其 §0.2） | 已完成（凍結：`include/particle_magic.h` 全文＋10 個 C 進入點，見其 §10） |
| [0010](docs/func-spec/0010-performance-budget.md) | 效能與粒子預算治理：熱路徑 unboxed 化（count-then-fill、`FieldState` SoA、in-place 穩定排序、Expr 常數摺疊）、結構化 `ParticleBudget`＋`maxSpellParticles` 匯出、發射器時間窗剔除、10k–100k 量測；golden 先行、逐位元相容律；**不改 4096 值**（上限提升在 0012） | 一般 | 無（0005 bench 基線已備）；**與 0011／0013 三方平行**（檔案零交集，見其 §0.2） | 已完成（取樣 3.4×、`depthOrder` 10×、100k 粒 6.5 ms；凍結：`ParticleBudget(..)`、`budgetPlanOf`、`maxSpellParticles`、`emittersOf`、`emitterBounds`、`foldConstants`，見其 §9.3） |
| [0011](docs/func-spec/0011-host-integration-surface.md) | 宿主整合面：`pm_max_particles`／`pm_project`／`pm_depth_order` 純增補匯出、契約測試的 4096 釘選改寫為查詢鏡射律、header 純註解補顏色位元組序與座標手性、新 boundary `Magic.Columns`、C# 參考綁定＋Unity 最小範例 | 一般 | 無（0008/0009 已完成）；**與 0010／0013 三方平行**（見其 §0.2） | 已完成（凍結：11 個 C 進入點、`PM_PLANE_*`／`PM_ERR_ARGS`、`Magic.Columns` 匯出面；查詢鏡射律解鎖 0012 的上限提升，見其 §9.4） |
| [0012](docs/func-spec/0012-multi-circle-composition.md) | 多陣合成與場景層：`Semigroup`/`Monoid CompiledSpell`（`PhasePlan` 逐界標 max）、`compileMany`、`Magic.Scene` 全域配額（先到先得）、上限 4096→依 0010 量測值正式提升（header 零觸碰）；同輪 ADR-0012 | 一般 | spec 0010＋0011（皆需已完成）；**與 0014 平行**（見其 §0.2） | 已完成（上限 **16384**，單幀純 CPU 1.45 ms；凍結：`Semigroup`/`Monoid` 律、`compileMany`、`castSpells`、`Magic.Scene` 匯出面，見其 §9.4） |
| [0013](docs/func-spec/0013-visual-expressiveness.md) | 視覺表現力（app/* 半場）：3D alpha batch 相機距離深度排序（staging 層）、3D 軌道/縮放相機、2D 平移/縮放＋resize 適配、俯視深度色調線索；零輸入零漣漪律 | 一般 | 無（0005/0008 已完成）；**與 0010／0011 三方平行**（`app/*` only，見其 §0.2） | 已完成（穩定面清單見其 §9.3；`app/Main.hs` 最終零修改） |
| [0014](docs/func-spec/0014-authoring-tools.md) | 作者工具：`magic-validate` 驗證 CLI（boundary 第三個消費者）、`docs/spell-schema.md` 作者面 schema 說明（鍵名機械守護）、spell 清單週期熱掃描（`ScanDir` op） | 一般 | spec 0010（需已完成）；**動工門檻另含 0013 驗收**（app 檔交集）；與 0012 平行 | 已完成（凍結：`magic-validate` 命令列與行格式、`ScanDir` op，見其 §9.3） |
| [0015](docs/func-spec/0015-visual-vocabulary.md) | 視覺表現力（核心半場）：`observeSpell` 依 `(blend, shape)` 分批（分割律逐位元）、`BillboardShape` 遷入核心並擴為 4 個無參數建構子、外圈 `StyleRune`＋`"style"` JSON tag、`PM_SHAPE_*` 純增補（stride 零觸碰）、shell 程序生成貼圖差異化繪製；opt-in 逐位元律；同輪 ADR-0013 | 一般 | spec 0012（需已完成——五檔交集）；**與 0014 平行**（見其 §0.2） | 已完成（凍結：`BillboardShape` 建構子宣告序＝`PM_SHAPE_*` 0–3、`StyleRune` 的 JSON 形狀與名稱表、`observeSpell` 分割律，見其 §9） |
| [0016](docs/func-spec/0016-sigil-geometry.md) | 符文陣（陣形幾何由魔法陣資料導出）：新核心模組 `Magic.Sigil`——`hashCircle` 結構摘要、結構定骨架／摘要定花紋的 `SigilPlan`、六種筆畫閉式取樣（弧環／星形多邊形／輻條／刻度／玫瑰線／位元遮罩符文帶）；「索引序＝繪製序」律讓陣被畫出來而非浮現；`SpawnOnStroke` 一個建構子接線；Codec 零觸碰、schema 不升版；逐位元豁免僅限 Drawing／Converging 兩相位；同輪 ADR-0014 | 一般 | spec 0015（需已完成——`Compile.hs` 交集，**已於 2026-08-15 解除**）；**與 0014 平行**（見其 §0.2） | 已完成（凍結：`hashCircle` 全函數＋其排除 `circleFields` 的邊界、`Magic.Sigil` 匯出面、`sampleStroke` 索引律與六種 kind、`SpawnOnStroke`、逐位元豁免只到 Drawing／Converging，見其 §9.3） |
