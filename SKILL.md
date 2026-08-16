# SKILL.md — 本專案的文件體系與工作方法

本檔定義專案內各類文件的角色、寫作規範，與「文件 → 實作 → 測試」的工作循環。所有貢獻者（含 AI 協作者）依此運作。

## 文件體系

| 文件 | 角色 | 何時讀 / 何時寫 |
|---|---|---|
| `Init.md` | 原始願景筆記 | 只讀，不再更新；細節已由架構書取代 |
| `docs/architecture.md` | 系統架構設計書：模組結構、資料流、型別草圖、介面規格、風險分析 | 任何設計/實作前必讀；架構層變動時更新 |
| `docs/adr/adr-NNNN-*.md` | 架構決策紀錄（ADR）：一份一決策，含背景/決策/後果/被否決方案 | 違反前必先修訂；新的架構級決策新增一份 |
| `docs/spec/func-NNNN-*.md` | **功能規格書（function spec）**：一份對應一個模組或一次程式設計迭代的實作細節 | 每輪實作**動工前**寫定；實作中回填驗收紀錄 |
| `docs/bugfix/bug-NNNN-*.md` | 缺陷紀錄：一份一缺陷，含重現、根因、修法、回歸測試 | 發現缺陷時新增；修好且回歸測試綠後結案 |
| `docs/enhance/enhance-YYYY-MM-DD-*.md` | 改善提案：非新功能的體質改善（重構、效能、可讀性、依賴升級） | 提出時新增；落地後結案 |
| `docs/analysis/report-YYYY-MM-DD-*.md` | 分析報告：文檔對照程式碼的健檢結果（穩健性、解耦、資安、效能、過時套件） | 做專案健檢時產出，只讀不改 |
| `docs/roadmap.md` | **路線圖與完整度盤點**：還差什麼、下一輪該蓋哪一個。內容由各 spec 的 §9 非目標與驗收紀錄盤點而來，不引入新決策 | 決定下一份 spec 主題時讀；每次 func-spec 驗收後更新 |
| `docs/integration.md` | **宿主整合指南**：Haskell／C／C++／Unity／自製前端各自怎麼接，資料合約速查、限制與相容性承諾 | 對外介面（`Magic.Interface`／`Magic.Codec`／`Magic.Projection`／C ABI header）變動時同步更新 |

## 文檔 metadata 標準（YAML frontmatter）

spec／bugfix／enhance／adr／report 五類文件的**第一行必須**是 YAML frontmatter，狀態掃描腳本（`dev-flow` skill 的 `scan-status.mjs`，只讀每檔開頭 2KB）只解析這一段：

```yaml
---
id: func-0003            # func-NNNN | bug-NNNN | enhance-<date>-<slug> | adr-NNNN | report-<date>-<slug>
type: spec               # spec | bug | enhance | adr | report
title: expr-subsystem    # 檔名去掉編號前綴與副檔名的 slug
status: open             # open | in-progress | done | closed；ADR 改用 proposed | accepted | superseded
created: 2026-08-12
updated: 2026-08-13
depends-on: [func-0001]  # spec 用：前置依賴的 spec id，判斷任務可否平行開發
related-adr: [adr-0002]  # 相關 ADR id
related-spec: []         # bug/enhance/adr 回鏈到 spec id
---
```

規則：

- **檔名一律英文 kebab-case，內文一律繁體中文**；編號四位數遞增不重用（建檔前先掃該資料夾取最大編號 +1）；日期一律 `YYYY-MM-DD`。
- 修改任何文檔內容時，同步更新 frontmatter 的 `updated`。
- frontmatter 的 `status` 是**機器讀的真相**，文件開頭的中文狀態句（`設計中`／`設計定案，待實作`／`實作中`／`已完成`）是人讀的說明；兩者必須同時更新。對應關係：`設計中`／`設計定案，待實作` → `open`，`實作中` → `in-progress`，`已完成` → `done`，廢棄 → `closed`。
- 狀態總覽：`node <dev-flow>/skills/code-audit/scripts/scan-status.mjs ./docs`（exit 0 = 全部 done/closed；exit 1 = 有未完成或缺 metadata）。

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

- 檔名 `func-NNNN-短英文名.md`，放在 `docs/spec/`，編號遞增不重用。
- frontmatter 標 `status`（機器讀）；緊接的引文區塊標中文狀態：`設計中` → `設計定案，待實作` → `實作中` → `已完成`（附驗收紀錄）。兩者同步，對應表見「文檔 metadata 標準」。
- frontmatter 的 `depends-on` 是**前置依賴的機器版本**，與引文區塊的 `前置依賴：` 一句同步；引文區塊另標**性質**（見下節）。

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
| [0001](docs/spec/func-0001-framework-skeleton.md) | 框架搭建（walking skeleton）：套件邊界、IO/核心邊界、端到端資料流 | **重大基建功能** | 無 | 已完成 |
| [0002](docs/spec/func-0002-circle-interpreter.md) | 魔法陣結構與解釋器：Circle ADT、參數層符文、由內而外 fold、真實取樣、完整槽位 JSON schema | **重大基建功能** | spec 0001（已完成） | 已完成 |
| [0003](docs/spec/func-0003-expr-subsystem.md) | Expr 數學式子系統：封閉一階 AST、樸素求值器、文字語法剖析（megaparsec）、渲染器；不含符文接線 | **重大基建功能** | spec 0001（已完成）；不依賴 0002 | 已完成 |
| [0004](docs/spec/func-0004-expr-rune-wiring.md) | Expr 符文接線：`RangeRune`/`ConvergeRune`/`AmplifyRune`/`FormulaRune`、`ExprV3` 定型、分層時間框架（行為層 t＝粒子年齡、調變層 t＝施法秒數）、fold 加 case、Codec 加 tag | 一般 | spec 0002（已完成）＋0003（已完成） | 已完成 |
| [0005](docs/spec/func-0005-render-observability.md) | 渲染落實與觀測：動態 quad mesh 單 draw call、`rbBlend`/`rbShape` 生效、HUD＋載入錯誤上屏、鍵盤切換範例、`-O2`＋benchmark 基線；`advanceSpell`/`observeSpell` 分離 | 一般 | spec 0001/0002/0003（已完成）；**與 0004 平行**（檔案零交集，見其 §0.3） | 已完成 |
| [0006](docs/spec/func-0006-lifecycle-formation.md) | 生命週期四階段與陣形發射器：`Phase`/`PhasePlan`、opt-in `"phases"` JSON、陣形幾何→發射器（fold 步驟 5）、casting 包絡位移、合成收束 ramp；取樣器零變更、既有範例逐位元相容 | 一般 | spec 0002/0003/0004（已完成）；**與 0005 平行**（檔案零交集，見其 §0.2） | 已完成 |
| [0007](docs/spec/func-0007-force-field-layer.md) | 力場層：`ForceField`（gravity/attractor/vortex）、`FieldState` 穩定槽位身分、半隱式尤拉、零場逐位元相容律；ADR-0010 組合點語意；`app/*` 零觸碰 | 一般 | spec 0006（已完成）——修改檔案與 0006 交集（Circle/Compile/Codec），動工門檻＝0006 驗收 | 已完成 |
| [0008](docs/spec/func-0008-ortho2d-backend.md) | 2D 正交後端：`ViewPlane`/`orthographic`/`depthOrder` 入 `Magic.Project`、boundary 再匯出 `Magic.Projection`、真 2D 繪製路徑（painter 排序＋螢幕座標）、demo Tab/V 切換三視圖；兌現 ADR-0008 | 一般 | 無（0001/0002/0005 已完成）；**與 0007 平行**（檔案零交集，見其 §0.2） | 已完成 |
| [0009](docs/spec/func-0009-ffi-foreign-library.md) | FFI 外殼（C ABI）：cabal foreign-library 產 `.dll`/`.so`、`pm_cast`(JSON)→`pm_advance`→`pm_observe`(SoA copy-out) handle 生命週期、`particle_magic.h` 凍結合約、跨界決定論等價律；ADR-0011 | 一般 | 無（0001/0002/0005 已完成）；**與 0007／0008 三方平行**（新檔案為主，見其 §0.2） | 已完成（凍結：`include/particle_magic.h` 全文＋10 個 C 進入點，見其 §10） |
| [0010](docs/spec/func-0010-performance-budget.md) | 效能與粒子預算治理：熱路徑 unboxed 化（count-then-fill、`FieldState` SoA、in-place 穩定排序、Expr 常數摺疊）、結構化 `ParticleBudget`＋`maxSpellParticles` 匯出、發射器時間窗剔除、10k–100k 量測；golden 先行、逐位元相容律；**不改 4096 值**（上限提升在 0012） | 一般 | 無（0005 bench 基線已備）；**與 0011／0013 三方平行**（檔案零交集，見其 §0.2） | 已完成（取樣 3.4×、`depthOrder` 10×、100k 粒 6.5 ms；凍結：`ParticleBudget(..)`、`budgetPlanOf`、`maxSpellParticles`、`emittersOf`、`emitterBounds`、`foldConstants`，見其 §9.3） |
| [0011](docs/spec/func-0011-host-integration-surface.md) | 宿主整合面：`pm_max_particles`／`pm_project`／`pm_depth_order` 純增補匯出、契約測試的 4096 釘選改寫為查詢鏡射律、header 純註解補顏色位元組序與座標手性、新 boundary `Magic.Columns`、C# 參考綁定＋Unity 最小範例 | 一般 | 無（0008/0009 已完成）；**與 0010／0013 三方平行**（見其 §0.2） | 已完成（凍結：11 個 C 進入點、`PM_PLANE_*`／`PM_ERR_ARGS`、`Magic.Columns` 匯出面；查詢鏡射律解鎖 0012 的上限提升，見其 §9.4） |
| [0012](docs/spec/func-0012-multi-circle-composition.md) | 多陣合成與場景層：`Semigroup`/`Monoid CompiledSpell`（`PhasePlan` 逐界標 max）、`compileMany`、`Magic.Scene` 全域配額（先到先得）、上限 4096→依 0010 量測值正式提升（header 零觸碰）；同輪 ADR-0012 | 一般 | spec 0010＋0011（皆需已完成）；**與 0014 平行**（見其 §0.2） | 已完成（上限 **16384**，單幀純 CPU 1.45 ms；凍結：`Semigroup`/`Monoid` 律、`compileMany`、`castSpells`、`Magic.Scene` 匯出面，見其 §9.4） |
| [0013](docs/spec/func-0013-visual-expressiveness.md) | 視覺表現力（app/* 半場）：3D alpha batch 相機距離深度排序（staging 層）、3D 軌道/縮放相機、2D 平移/縮放＋resize 適配、俯視深度色調線索；零輸入零漣漪律 | 一般 | 無（0005/0008 已完成）；**與 0010／0011 三方平行**（`app/*` only，見其 §0.2） | 已完成（穩定面清單見其 §9.3；`app/Main.hs` 最終零修改） |
| [0014](docs/spec/func-0014-authoring-tools.md) | 作者工具：`magic-validate` 驗證 CLI（boundary 第三個消費者）、`docs/spell-schema.md` 作者面 schema 說明（鍵名機械守護）、spell 清單週期熱掃描（`ScanDir` op） | 一般 | spec 0010（需已完成）；**動工門檻另含 0013 驗收**（app 檔交集）；與 0012 平行 | 已完成（凍結：`magic-validate` 命令列與行格式、`ScanDir` op，見其 §9.3） |
| [0015](docs/spec/func-0015-visual-vocabulary.md) | 視覺表現力（核心半場）：`observeSpell` 依 `(blend, shape)` 分批（分割律逐位元）、`BillboardShape` 遷入核心並擴為 4 個無參數建構子、外圈 `StyleRune`＋`"style"` JSON tag、`PM_SHAPE_*` 純增補（stride 零觸碰）、shell 程序生成貼圖差異化繪製；opt-in 逐位元律；同輪 ADR-0013 | 一般 | spec 0012（需已完成——五檔交集）；**與 0014 平行**（見其 §0.2） | 已完成（凍結：`BillboardShape` 建構子宣告序＝`PM_SHAPE_*` 0–3、`StyleRune` 的 JSON 形狀與名稱表、`observeSpell` 分割律，見其 §9） |
| [0016](docs/spec/func-0016-sigil-geometry.md) | 符文陣（陣形幾何由魔法陣資料導出）：新核心模組 `Magic.Sigil`——`hashCircle` 結構摘要、結構定骨架／摘要定花紋的 `SigilPlan`、六種筆畫閉式取樣（弧環／星形多邊形／輻條／刻度／玫瑰線／位元遮罩符文帶）；「索引序＝繪製序」律讓陣被畫出來而非浮現；`SpawnOnStroke` 一個建構子接線；Codec 零觸碰、schema 不升版；逐位元豁免僅限 Drawing／Converging 兩相位；同輪 ADR-0014 | 一般 | spec 0015（需已完成——`Compile.hs` 交集，**已於 2026-08-15 解除**）；**與 0014 平行**（見其 §0.2） | 已完成（凍結：`hashCircle` 全函數＋其排除 `circleFields` 的邊界、`Magic.Sigil` 匯出面、`sampleStroke` 索引律與六種 kind、`SpawnOnStroke`，見其 §9.3；其「逐位元豁免只到 Drawing／Converging」一條已由 0017／ADR-0015 取代） |
| [0017](docs/spec/func-0017-sigil-persistence.md) | 陣的駐留：陣形發射器生存窗由 `castStart` 延長至 `ppEnd`、取消陣形收束曲線（`motConverge = Nothing`）——法術從仍然存在的陣中射出而不是把陣燒掉；取樣器零變更、預算零變更、schema 零觸碰；逐位元邊界收窄為 `t < min(phDraw, castStart − formLife)`；同輪 ADR-0015（取代 ADR-0014 D5） | 一般 | spec 0016（需已完成——`Compile.hs`／三份測試／兩個 golden 交集） | 已完成（凍結：`formEnvFor` 兩參數形狀與「陣形死於 `ppEnd`」時間軸律、陣形 `motConverge = Nothing`、`emPhase = Drawing`（力場判準）、逐位元邊界，見其 §9.5） |
| [0018](docs/spec/func-0018-scene-c-abi.md) | 場景層上 C ABI：`PmScene*` handle＋10 個純增補匯出（`pm_scene_new`/`cast`/`cast_many`/`dismiss`/`advance`/`observe`/`budget`/`count`/`spells`/`free`）、`PM_ERR_QUOTA`；C 面 ≡ `Magic.Scene` 匯出面的逐項穿越；解除 ADR-0012 D8 的延後；批次歸屬不提供（維持零新語意） | 一般 | 無（0009/0011/0012 已完成）；**與 0019／0020 三方平行**（見其 §0.2） | 設計定案，待實作 |
| [0019](docs/spec/func-0019-engineering-ci-release.md) | 工程化：GitHub Actions（build→test→`magic-validate`，win64＋Linux 矩陣）、發布與相容性政策（平台分級、PVP、tag 格式）、**Linux 首次實測**——同時是 ADR-0011 D8「跨平台逐位元決定論」宣稱的第一次真實檢驗；同輪 ADR-0016 | 一般 | **無**——與所有進行中的 spec 零交集，隨時可插隊（見其 §0.2） | 已完成（凍結：平台分級 ≡ CI 矩陣、`v<version>` tag 格式、PVP 上界規則、`PM_ABI_VERSION` 與套件版本獨立遞增。**S2 走 §2.1 第二條路**：Linux 1156 examples／23 golden 紅，根因量到是 libm `sin`/`cos` 的 1 ulp 差（絕對差 ≤ 1.79e-07，僅 posX／posZ），決定論範圍正式收窄為「同平台逐位元、跨平台結構＋2 ulp」——ADR-0016 D4、header 檔頭同步修正，見其 §8） |
| [0020](docs/spec/func-0020-sigil-motion.md) | 陣形的時間維度：`SigilSpin`＋分段 `spinAngle`（蓄力段二次、施放後恆速，角速度有界）、整陣繞面心自轉、層與層反向；**等距同構律**使 0016 三條律與 `emitterBounds` 全部零變更；`Compile.hs` 零觸碰、schema 不升版。撤銷 0016 §1-5 的 Casting 零影響律（其前提已由 ADR-0015 D4 撤銷），改立主效果零影響律；同輪 ADR-0020（逐位元邊界第三次收窄，取代 ADR-0015 D4） | 一般 | spec 0017（需已完成——`Sigil.hs`／`Analytic.hs` 交集，且其時間軸為本輪前提）；**與 0018／0019／0025 平行**（見其 §0.2） | 設計定案，待實作 |
| [0021](docs/spec/func-0021-magic-vocabulary.md) | 魔法語彙擴張：`Element` 4→9（**五行＋陰陽**）、`FaceShape` 4→8、`Trajectory` 4→8、`ForceField` 3→6、`RadiationMode` 2→4，＋俯視進階可讀性（壓平比例、輪廓強調）；全部加法 ⇒ **既有範例陣逐位元不變**；結清 0015 §8-5 的複數 blend 批次記帳；不加 `BlendMode`（避開 C 合約） | 一般 | spec 0020（需已完成——`Analytic.hs` 交集）；**與 0018／0019 平行**（見其 §0.2） | 設計定案，待實作 |
| [0022](docs/spec/func-0022-perf-second-tier.md) | 效能第二階梯：`Magic.Expr.Code` bytecode 求值器＋共同子式消去（`Expr.hs` 零觸碰，`evalExpr` 降為參照實作）、`Control.Parallel.Strategies` 平行取樣（核心白名單 +`parallel`）；**兩條逐位元等價律**是全部價值；備齊 ADR-0012 §後果指名的抬高上限前提；同輪 ADR-0017 | 一般 | spec 0021（需已完成——`Compile`／`Analytic` 交集）；**與 0018／0019／0024 平行**（見其 §0.2） | 設計定案，待實作 |
| [0023](docs/spec/func-0023-production-visuals.md) | 產品級視覺：`ParticleBuffer` 六欄→九欄（速度，opt-in）、`BillboardTrail`＋`pm_observe_ex`（六欄簽名一字不動）、自訂 shader 管線＋bloom＋軟粒子（含測試場景幾何）、跨 batch alpha 深度交錯；**取代 ADR-0009 的「不自訂 shader」前提、鬆綁 ADR-0006 六欄硬點**；同輪 ADR-0018 | **重大基建功能** | spec 0022＋0018（皆需已完成）；**與 0019 平行**（見其 §0.2） | 設計定案，待實作 |
| [0024](docs/spec/func-0024-authoring-tools-2.md) | 作者工具第二輪：`magic-schema`（draft-07 JSON Schema 入 repo，三向一致守護）、`magic-inspect` 結構報告、`magic-validate --json`、demo 內即時參數面板與寫回往返律；**可水平分割**——`tools/` 半場無依賴 | 一般 | `tools/` 半場：**無**（可提前認領）；`app/` 半場：spec 0023（需已完成——`app/*` 五檔交集）。見其 §0.3 | 設計定案，待實作 |
| [0025](docs/spec/func-0025-spatial-output-anchors.md) | 空間資訊輸出與多發動點：`Magic.Space`——貼合的有向盒 `emitterBox`（`emitterBounds` 逐位元不變）、spell 級聯集、面座標系對齊的 N³ 佔用格網（N=3 ⇒ 27 格塞進一個 `Word32` 遮罩）；`Circle` 加陣層級 `"anchors"`，主效果第一次可有多個發動點（**能量等分、預算守恆**）；7 個 C 匯出。空間摘要是**輸出**不是模擬結構——不為「粒子對粒子」開門；同輪 ADR-0019 | **重大基建功能** | spec 0018（需已完成）；0016／0017 已交付。**與 0019／0020 平行**（見其 §0.2） | 設計定案，待實作 |
