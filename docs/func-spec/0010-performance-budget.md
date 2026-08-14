# Func-Spec 0010：效能與粒子預算治理

> 狀態：**設計定案，待實作**
> 性質：一般 —— 交付後凍結 `ParticleBudget` 型別與 `Magic.Interface` 的加法匯出（spec 0012 動工門檻＝本 spec 驗收，先例：0006→0007）。
> 前置依賴：**無**（動工前提「spec 0005 的 bench 基線」已於 0005 §10 交付：4096 粒 `buildQuads` ≈71µs、每幀純 CPU ≈0.73ms）。**與 spec 0011、0013 三方平行**：本 spec 鎖 core／`Interface.hs`／bench，0011 鎖 `src/ffi`＋`include`＋新目錄，0013 鎖 `app/*`——檔案零交集（§0.2 附證明），三 spec 可同時認領實作。
> 依據：architecture §7（效能設計整章——本 spec 是它的落地輪）、§8.2（Expr 加速階梯，只做第一階）；ADR-0006（SoA＋unboxed）、ADR-0007（核心零 IO——`ST` 內部可變、對外仍純）；[roadmap.md](../roadmap.md) §3.1（被 0002/0004/0005/0006/0007/0008 六份 spec §9 指名的欠款總表）。
> 範圍：把核心熱路徑從「處處 boxed list 往返」改成「端到端 unboxed」，量測 10k–100k 吞吐。**本輪不改 `budgetCap` 的值**（維持 4096）：`test/FFIContractSpec.hs` 把 `PM_MAX_PARTICLES == pmMaxParticles == budgetCap == 4096` 釘成三方相等，改值必觸 0011 的檔案、平行即破功——上限值的實際提升由 spec 0012 S1 落地（新值依本 spec 的量測選定，契約鬆綁由 0011 交付）。

---

## 0. 起點：引用的凍結介面、檔案盤點

### 0.1 引用的凍結介面（簽名零變更；內部實作可換）

| 凍結物 | 本 spec 的義務 |
|---|---|
| `Magic.Interface` 全匯出面（0005 凍結；0007/0008 未動簽名） | 只做**加法**匯出（`ParticleBudget`、`budgetPlanOf`、`maxSpellParticles`、`emitterBounds`）；既有簽名一個都不改 |
| `sample :: CompiledSpell -> CastContext -> Time -> ParticleBuffer`（0002） | 簽名不變，內部重寫（S2） |
| `ParticleBuffer` 六欄 fields＋`bufferInvariant`＋`fromParticles`（0005 對外開放 fields） | 型別與 fields 不變；`fromParticles` 保留且語意不變（相容入口），熱路徑改走新的內部 count-then-fill |
| `depthOrder :: ViewPlane -> ParticleBuffer -> U.Vector Int` 的**穩定 painter 律**（0008 凍結：遠到近、等深保 buffer 序） | 簽名與輸出**逐位元**不變，實作換成 in-place unboxed 排序（S5） |
| `FieldState` 表徵（0007 §4.7 **明文不凍結**）；`step`／`stepSlot`／`fieldAccel` 語意（半隱式尤拉、rebirth 偵測、零場跳過） | 表徵可換（SoA 化正是本 spec 工作）；語意逐位元保持（S4） |
| `compile :: Circle -> Either CompileError CompiledSpell`（0002）；`CompiledSpell` 記錄**可加欄位**（先例：0006 加 `spellPhases`、0007 加 `spellFields`） | 加 `spellBudgetPlan` 欄位；既有欄位（含 `spellBudget :: !Int`）保留不動 |
| 決定論合約（0002/0005：同輸入 ⇒ 逐位元同輸出）＋ 0009 的跨界等價律 | 本 spec 的**中心律**：全部 10 個範例 spell 的輸出逐位元不變（S1 golden 先行鎖定） |
| `budgetCap = 4096` 與 `FFIContractSpec` 的三方相等釘選（0009） | **值不動、檔案不碰**；本 spec 全文不得出現對 `PM_MAX_PARTICLES`／`pmMaxParticles`／`budgetCap` 值的修改 |

### 0.2 檔案盤點（與 0011／0013 的三方零交集證明）

**修改（7 原始碼＋bench）**：

| 檔案 | 變更 |
|---|---|
| `src/core/Magic/Particle/Buffer.hs` | 內部新增 count-then-fill 建構（`ST` mutable 六欄）；`fromParticles` 改為薄包裝，匯出面不變 |
| `src/core/Magic/Particle/Analytic.hs` | `sample` 熱路徑重寫（S2）＋發射器時間窗剔除（S3）＋per-emitter 基底提升 |
| `src/core/Magic/Particle/Field.hs` | `FieldState` SoA 化（S4）；`step`/`stepSlot`/`fieldAccel` 匯出簽名視 SoA 表徵調整（0007 明文允許），語意逐位元保持 |
| `src/core/Magic/Compile.hs` | `ParticleBudget` 型別＋`CompiledSpell` 加欄位 `spellBudgetPlan`＋`emitterBounds`（S6/S7） |
| `src/core/Magic/Project.hs` | `depthOrder` 換 in-place unboxed 排序（S5） |
| `src/core/Magic/Expr.hs` | `foldConstants`＋SPECIALIZE/INLINE 註記（S6） |
| `src/boundary/Magic/Interface.hs` | 加法匯出：`ParticleBudget(..)`、`budgetPlanOf`、`maxSpellParticles`、`emitterBounds` 轉匯出（S7）；內部 `fieldInputs`/`displaceBuffer` 的 list 往返消除（S4） |
| `bench/Bench.hs` | 新 bench 組：`advanceSpell`（帶場/零場）、`depthOrder`、10k/100k 合成吞吐（S8） |

**新增（8 測試）**：`test/PerfGoldenSpec.hs`、`SampleFillSpec.hs`、`CullSpec.hs`、`FieldSoASpec.hs`、`DepthSortSpec.hs`、`ExprFoldSpec.hs`、`BudgetPlanSpec.hs`、`Acceptance10Spec.hs`（§7 對應）＋golden 資料檔 `test/golden/perf-0010/*.txt`（S1 產出）。

**共用（行級聯集合併，同 0007/0008/0009 慣例）**：`particle-magic.cabal`（test-suite `other-modules` +8 行——0011 加 FFI 測試行、0013 加 app 測試行，同檔異行）；`SKILL.md`（索引 +0010 列）。

**明文不碰**：`app/*` 全部（cap 值不變 ⇒ `gpuCapacity` 不動）、`src/ffi/*`、`include/*`、`cbits/*`、`examples/*`、`bindings/*`（0011 的新目錄）、`test/FFIContractSpec.hs`、`src/boundary/{Codec,Projection,Step,Expr/Parse}.hs`。

**三方交集**：0011 觸 `src/ffi/Magic/FFI.hs`＋`include/particle_magic.h`＋`particle-magic-ffi.def`＋`test/FFIContractSpec.hs`＋新 `src/boundary/Magic/Columns.hs`＋新目錄；0013 觸 `app/*`＋新 app 模組。與本 spec 清單逐檔比對：**交集 = ∅**（cabal/SKILL.md 同檔異行除外）。

## 1. 目標與完成定義

**目標**：核心熱路徑（取樣、場積分、排序、Expr 求值）端到端 unboxed 化，結構化粒子預算落地，量測並記錄 10k–100k 吞吐——同時**不改變任何一個位元的輸出**。

**完成定義**（全部可驗證）：

1. 全部 10 個範例 spell（`assets/spells/*.json`）在 240 幀內每幀的六欄輸出，與重構前 golden **逐位元相同**（S1 鎖定、S9 端到端複驗）。
2. `sample` 不再產生 boxed 中介 list：count-then-fill 單趟建構，與舊路徑逐位元等價（S2）。
3. 發射器時間窗剔除：剔除路徑與全掃描逐位元等價（property，任意 Envelope×任意年齡）；死窗發射器零逐粒成本（S3）。
4. `FieldState` SoA 表徵：`step` 語意（rebirth、quiescent、零場恆等）與 0007 的參考語意逐位元等價（S4）。
5. `depthOrder` 新實作 ≡ 舊 `sortOn` 參考實作（property：任意 buffer 逐位元同置換），且為 in-place unboxed（S5）。
6. `eval (foldConstants e) env ≡ eval e env`（ExprGen property）；`ExprGoldenSpec` 既有 golden 不變（S6）。
7. `ParticleBudget` 不變量：`budgetTotal == U.sum budgetPerEmitter`、向量長度 == 發射器數、`spellBudget == budgetTotal`；`Magic.Interface` 加法匯出可用（S7）。
8. bench 新組跑出數字並回填 §9：`advanceSpell`（零場 vs 帶場）、`depthOrder`@4096、合成 10k／50k／100k `sample+observe` 吞吐（S8，量測性質、手動回填）。

## 2. 使用到的架構與技巧

- **Golden 先行（S1 最先做）**：任何重構動工前，先把現行輸出鎖成 golden 檔（10 spell × 取樣幀 × 六欄的逐位元摘要）。之後每一步重構都在這張網上進行——「逐位元相容」從口號變成每次 `cabal test` 都會撞到的牆。摘要格式：每幀 `pbCount`＋六欄的 FNV-1a 雜湊（純函數、test 內實作，避免引依賴）。
- **count-then-fill（`ST` 內部、對外仍純）**：現況 `sample` = `concatMap` boxed 4-tuple list → `fromParticles` 七趟遍歷。改為：第一趟算每發射器存活數（S3 的窗口分析直接給出），`runST` 配置六條 exact-size mutable 欄，第二趟按**與現行完全相同的發射器序×索引序**逐槽寫入，`unsafeFreeze` 出場。浮點運算的順序與個數一字不動——這是逐位元律成立的前提。**明確不做跨幀緩衝重用**：`observeSpell` 回傳的 `ParticleBuffer` 是宿主可長期持有的純值，跨幀重寫同一塊緩衝會讓上一幀的值被偷改（違反 ADR-0007 的引用透明）。architecture §7「緩衝重用」在純介面下的正解就是「每幀恰好六次 exact-size 配置、零中介」，真正的跨幀 mutable 重用需要不同的 API 合約，記帳 §8。
- **時間窗剔除（解析模型的紅利）**：`firstBirth` 對索引單調 ⇒ 每發射器在年齡 `t` 的存活索引是**連續區間**，可由 Envelope 閉式解出 `[lo, hi)`，不必逐索引問 `particleAge`。窗口為空 ⇒ 整發射器跳過。`aliveSlots` 與取樣共用同一份窗口計算（現況兩邊各掃一遍）。等價律：區間解 ≡ 全掃描（property）。
- **`FieldState` SoA**：`V.Vector (V.Vector (Maybe (Double, SlotState)))` → 攤平 unboxed 欄（見 §3）。`Maybe` 以 birth 欄的 NaN 哨兵或分離 mask 欄表達（實作擇一，測試只看語意）。`fieldInputs` 的巢狀 boxed 重建與 `displaceBuffer` 的三趟 list 往返一併消除：位移直接以三條 unboxed 欄與 buffer zip。
- **排序但保穩定**：`depthOrder` 的凍結律要求穩定。做法：對 `(depth, index)` 成對 unboxed 向量做 in-place introsort，比較器 =（depth 降冪，同深 index 升冪）——tie-break 使比較成全序，**任何**正確排序演算法的輸出都唯一且等於穩定排序，穩定性不再依賴演算法本身。手寫 introsort（quicksort＋深度超限轉 heapsort＋小段 insertion），不引入 `vector-algorithms`——核心依賴白名單 {base, vector, deepseq}（0001 紀律）一字不動。
- **Expr 第一階加速**：`foldConstants :: Expr -> Expr` 在 `compile` 時對無變數子樹預求值（用**同一個** `eval`，故逐位元一致）；熱路徑求值函數加 `INLINE`/`SPECIALIZE`。AST 與剖析器零變更（architecture §8.2：只換求值器側，介面不動）。bytecode 留待下一階，記帳 §8。
- **`emitterBounds` 保守包絡**：對 Expr 做區間算術求值（`evalInterval`，閉式 AST 逐建構子），t ∈ [0, lifetime]、索引域已知 ⇒ 每發射器保守 AABB。**視錐剔除本體屬宿主**（核心無相機概念，renderer-agnostic 不破）；核心只交包絡。包含律：任意取樣位置 ∈ 包絡（property）。

## 3. ADT

```haskell
-- Magic.Compile（新，永久型別；交付後凍結）
data ParticleBudget = ParticleBudget
  { budgetPerEmitter :: !(U.Vector Int)   -- 與 spellEmitters 索引對齊
  , budgetTotal      :: !Int              -- 不變量：== U.sum budgetPerEmitter
  } deriving (Eq, Show)

-- CompiledSpell：加欄位（既有欄位全數保留，含 spellBudget :: !Int）
--   spellBudgetPlan :: !ParticleBudget    -- 不變量：spellBudget == budgetTotal spellBudgetPlan

emitterBounds :: CastContext -> Seconds -> EmitterSpec -> (V3, V3)  -- 保守 AABB（min, max）

-- Magic.Expr（新）
foldConstants :: Expr -> Expr             -- 律：eval . foldConstants ≡ eval（逐位元）

-- Magic.Particle.Field（表徵重寫；0007 §4.7 明文不凍結）
data FieldState = FieldState
  { fsOffsets :: !(U.Vector Int)     -- 每發射器槽位起點（前綴和；末元素 = 總槽數）
  , fsBirth   :: !(U.Vector Double)  -- 攤平；未生槽以哨兵表達（實作擇一：NaN 或分離 mask）
  , fsVelX, fsVelY, fsVelZ    :: !(U.Vector Float)
  , fsDispX, fsDispY, fsDispZ :: !(U.Vector Float)
  }
-- step / stepSlot / fieldAccel / emptyFieldState / displacementsInOrder：
-- 語意逐位元同 0007；簽名視 SoA 表徵調整（displacementsInOrder 改回 unboxed 三欄）

-- Magic.Interface（加法匯出，交付後凍結）
--   ParticleBudget(..)、budgetPlanOf :: ActiveSpell -> ParticleBudget
--   maxSpellParticles :: Int          -- = budgetCap（首次經公開面匯出；0012 將把
--                                     --   pm_max_particles 改接到這裡，值本輪仍為 4096）
--   emitterBounds（轉匯出）
```

## 4. 資料結構與儲存方式

| 資料 | 現況 | 本輪之後 |
|---|---|---|
| 取樣中介 | boxed `[(V3,Float,Float,Word32)]`＋7 趟 `fromParticles` | 無中介：`ST` 六欄 exact-size 單趟寫入 |
| 存活判定 | 逐索引 `particleAge`（取樣、`aliveSlots` 各掃一遍） | 每發射器閉式 `[lo,hi)` 區間，算一次共用 |
| `FieldState` | 巢狀 boxed `V.Vector (V.Vector (Maybe (Double, SlotState)))` | 攤平 unboxed 欄＋前綴和索引（§3） |
| 場輸入/位移 | `fieldInputs` 每步重建巢狀 boxed；`displaceBuffer` 3 趟 list 往返 | unboxed 三欄直接 zip |
| 排序 | `sortOn` boxed pair list | in-place unboxed introsort（tie-break 全序） |
| 預算 | 裸 `spellBudget :: Int` | `ParticleBudget`（per-emitter＋total），舊欄位保留 |

## 5. 資料流（pipeline）

```mermaid
flowchart LR
  subgraph pure [magic-core（純）]
    C[compile<br/>+foldConstants +BudgetPlan] --> S[sample<br/>窗口區間 → ST count-then-fill]
    S --> B[ParticleBuffer]
    F[FieldState SoA<br/>step 半隱式尤拉] --> D[displace（unboxed zip）]
    B --> D
    D --> O[depthOrder<br/>in-place introsort]
  end
  subgraph boundary [magic-boundary（純）]
    I[Interface：advanceSpell / observeSpell<br/>＋budgetPlanOf / maxSpellParticles]
  end
  D --> I
  O --> I
```

IO 邊界不變：本 spec 全程在純環內，`ST` 只出現在 `runST` 封閉區域。

## 6. 搭建方式（順序即風險排序）

1. **S1 golden 鎖定**——一切之前：10 spell × 240 幀摘要落檔。沒有這張網，後面每一步的「逐位元」都無法宣稱。
2. **S2 count-then-fill**——最大的結構改動，最早暴露逐位元風險（浮點順序）。
3. **S3 時間窗剔除**——依賴 S2 的新結構（窗口即 fill 的邊界）。
4. **S4 FieldState SoA**——第二大改動；與 S2/S3 正交，golden 含帶場範例（`gravity-well`）可即時驗證。
5. **S5 depthOrder**——獨立，隨時可插入。
6. **S6 Expr foldConstants＋SPECIALIZE**——獨立；golden 直接守護。
7. **S7 ParticleBudget＋Interface 匯出**——純加法，風險最低，放後面避免擋住熱路徑工作。
8. **S8 bench 擴充與量測**——全部綠了才量，數字才有意義。
9. **S9 端到端驗收**。

## 7. Todo List 與 1-to-1 測試對應

| # | Todo | 測試 |
|---|---|---|
| S1 | golden 鎖定：10 範例 × 240 幀六欄摘要落 `test/golden/perf-0010/`，重構前產出並 commit | `test/PerfGoldenSpec.hs`（讀 golden 逐幀比對；此後每步重構的回歸網） |
| S2 | `sample` count-then-fill 重寫（`ST` 六欄、零 boxed 中介；`fromParticles` 降為相容薄包裝） | `test/SampleFillSpec.hs`（新舊路徑逐位元等價 property、`bufferInvariant`、空 spell／滿 4096 邊界） |
| S3 | 發射器時間窗剔除＋`aliveSlots` 共用窗口 | `test/CullSpec.hs`（區間解 ≡ 全掃描 property：任意 Envelope×年齡；死窗零產出；`aliveSlots` 等價） |
| S4 | `FieldState` SoA＋`fieldInputs`/`displaceBuffer` unboxed 化 | `test/FieldSoASpec.hs`（對 0007 語意逐位元：rebirth、quiescent、零場恆等、`gravity-well` 幀序列） |
| S5 | `depthOrder` in-place introsort（tie-break 全序） | `test/DepthSortSpec.hs`（≡ `sortOn` 參考實作 property、置換有效性、穩定律、空/等深/滿載） |
| S6 | `foldConstants`＋SPECIALIZE；`compile` 接入 | `test/ExprFoldSpec.hs`（`eval . foldConstants ≡ eval` ExprGen property、摺疊冪等、節點數不增） |
| S7 | `ParticleBudget`＋`CompiledSpell.spellBudgetPlan`＋`emitterBounds`＋Interface 加法匯出 | `test/BudgetPlanSpec.hs`（不變量三條、`spellBudget == budgetTotal`、包含律：取樣位置 ∈ `emitterBounds`、匯出可見性） |
| S8 | bench 新組＋10k/50k/100k 合成吞吐量測（直接建構 `CompiledSpell` 繞過 compile cap 檢查——`sample` 本身不查 cap） | **手動量測**（`cabal bench`；數字回填 §9；含帶場/零場 `advanceSpell` 與 `depthOrder`） |
| S9 | 端到端驗收 | `test/Acceptance10Spec.hs`（10 範例 cast→240 幀 advance/observe ≡ golden；100k 合成 spell 取樣不變量成立；`maxSpellParticles == 4096` 哨兵——0012 改值時此行隨 S1 一併更新） |

## 8. 非目標

1. **改 `budgetCap`／`PM_MAX_PARTICLES`／`pmMaxParticles` 的值**——spec 0012 S1（契約鬆綁由 0011 交付；新值依本 spec §9 量測選定）。
2. 跨幀 mutable 緩衝重用（需要不同的 API 合約——租借式緩衝或 arena；等 10k–100k 量測證明每幀配置真的是瓶頸再議）。
3. 視錐剔除本體（宿主責任；核心只交 `emitterBounds`）。
4. Expr bytecode／共同子式消去（architecture §8.2 第二、三階）。
5. 多陣合成與全域配額（spec 0012）；`gpuCapacity`／demo 分塊繪製（spec 0012 S1 隨 cap 一併處理）。
6. 多執行緒取樣（`-threaded` 平行 sample）——先把單執行緒的常數因子吃完。
7. GPU compute／粒子間碰撞／空間分割（architecture §7 明文不做）。

## 9. 驗收紀錄

（實作時回填：日期、`cabal test` 結果、S8 量測表——零場/帶場 advance、depthOrder、10k/50k/100k 吞吐與記憶體、對 0005 基線的倍率；凍結介面清單：`ParticleBudget(..)`、`budgetPlanOf`、`maxSpellParticles`、`emitterBounds`。）
