# Func-Spec 0012：多陣合成與場景層

> 狀態：**已完成**（2026-08-15 驗收，見 §9）
> 性質：一般 —— 交付後凍結 `Semigroup`/`Monoid CompiledSpell` 律、`Magic.Scene` 匯出面、提升後的上限值。
> 前置依賴：**spec 0010（需已完成）＋ spec 0011（需已完成）**——全域配額以 0010 的 `ParticleBudget` 表達且與其同碰 `Compile.hs`/`Interface.hs`；上限提升（S1）需要 0011 改寫後的契約測試（查詢鏡射律取代 4096 三方釘選）。**與 spec 0014 平行**（本 spec 觸 core/boundary/ffi 常數＋demo 上限行，0014 觸新 exe／`app/*` 熱掃描／docs——檔案零交集，§0.2 附證明；0014 另有 0013 動工門檻，見其頭部）。
> 依據：architecture §6 對照表「多個效果疊」列（**唯一未落地列**——完整度維度 A 剩下的 15%）、§8.1（預算閘門）、§8.4（多法術並行的緩衝管理）；ADR-0004（dataflow——場景層仍是純 fold）；[roadmap.md](../roadmap.md) §3.2／§4.5。合併律與配額政策屬架構級語意 → **本輪同步交付 ADR-0012**（先例：0007↔ADR-0010、0009↔ADR-0011）。
> 範圍：`CompiledSpell` 成為合法的 `Semigroup`/`Monoid`（發射器串接、預算相加、`PhasePlan` 逐界標取 max）、預算超額沿用 `BudgetExceeded`、新 boundary 模組 `Magic.Scene`（多 `ActiveSpell`＋全域配額，預設先到先得）、上限值 4096 → 依 0010 量測選定的新值正式落地。

---

## 0. 起點：引用的凍結介面、檔案盤點

### 0.1 引用的凍結介面

| 凍結物 | 本 spec 的用法 |
|---|---|
| `ParticleBudget(..)`／`budgetPlanOf`／`maxSpellParticles`（0010 交付凍結） | 全域配額的記帳單位；合成時 per-emitter 向量串接、total 相加 |
| 0011 改寫後的契約律：`PM_MAX_PARTICLES` 永釘 4096＋查詢鏡射律 `pm_max_particles ≡ budgetCap` | S1 改 `budgetCap` 值時，鏡射律要求 `pmMaxParticles` 同步（FFI 端一行）；header 一字不動——0011 §2 的設計目的在此兌現 |
| `Magic.Interface` 全匯出面（0005 凍結＋0010 加法） | 唯讀消費（`castSpell`/`advanceSpell`/`observeSpell`/`isFinished`）；`Magic.Scene` 是其上的**組合層**，不改任何既有簽名 |
| `compile :: Circle -> Either CompileError CompiledSpell`＋`CompileError = BudgetExceeded !Int !Int`（0002） | 合成超額沿用同一錯誤型別（`compileMany` 的 `Left`）；不加新建構子 |
| `PhasePlan` 不變量 `0 ≤ ppDrawEnd ≤ ppConvergeEnd ≤ ppCastingEnd ≤ ppEnd`（0006） | 合併律必須保不變量——逐界標 max 是保單調的（§2 論證） |
| `FrameInput`/`FrameOutput`/`RenderBatch`（0005 凍結） | `observeScene` 輸出仍是 `FrameOutput`（batch 串接）——宿主繪製路徑零改動 |
| `FieldState` 起步全靜止（ADR-0010 D8） | 合成 spell 的 `castSpell` 沿用；場清單串接（§2 風險節） |
| demo `gpuCapacity`（0005；0013 交付後 `app/*` 解鎖） | S1 隨上限提升同步：分塊繪製或 clamp（§2） |

### 0.2 檔案盤點（與 0014 的零交集證明）

**修改**：

| 檔案 | 變更 |
|---|---|
| `src/core/Magic/Compile.hs` | `Semigroup`/`Monoid CompiledSpell` 實體＋`compileMany`＋`budgetCap` 改值（S1/S2） |
| `src/boundary/Magic/Interface.hs` | 轉匯出 `compileMany`（或等價的多陣 `castSpell` 便利入口，設計見 §3） |
| `src/ffi/Magic/FFI.hs` | `pmMaxParticles` 跟改為新值（鏡射律；僅此一行） |
| `app/App/Render/Raylib3D.hs` | `gpuCapacity` 跟改＋超過單 mesh 容量時分塊繪製（S1） |
| `test/FFIContractSpec.hs` | 鏡射律兩側實值更新（若測試以 `budgetCap` 直接比對則零修改——實作時依 0011 交付形態） |

**新增**：`src/boundary/Magic/Scene.hs`、`test/ComposeSpec.hs`、`test/ComposeBudgetSpec.hs`、`test/SceneSpec.hs`、`test/CapacitySpec.hs`、`test/Acceptance12Spec.hs`、`docs/adr/0012-multi-circle-scene.md`。

**共用（行級聯集合併）**：`particle-magic.cabal`（magic-boundary exposed-modules +1、test other-modules +5——0014 加 executable stanza 與各自測試行，同檔異行）；`SKILL.md`（索引列）。

**明文不碰**：`app/App/{Loop,Effects,Hud,TestInterp,HotReload}.hs`、`app/Main.hs`、`app/App/Render/{Quads,Flat}.hs`（0013 交付後屬穩定面，本 spec 只碰 `Raylib3D.hs` 的容量行）、`src/boundary/{Codec,Projection,Step,Columns,Expr/Parse}.hs`、`include/particle_magic.h`（**零觸碰**——這正是 0011 鋪管道的意義）、`bindings/*`、`examples/*`、`tools/*`（0014 的新目錄）、`docs/spell-schema.md`（0014）。

**與 0014 交集**：0014 觸 `tools/`（新）、`app/Main.hs`／`Loop`／`Effects`／`HotReload`（熱掃描）、`docs/spell-schema.md`、`test/BoundarySpec.hs`。與本清單逐檔比對：**交集 = ∅**（cabal/SKILL.md 同檔異行除外）。

## 1. 目標與完成定義

**目標**：把 Init.md 對照表最後一個未落地列變成測試守護的事實——多張魔法陣可合成一個 spell、多個 spell 可在全域配額下共存；同時把粒子上限從骨架護欄提升為量測支持的值。

**完成定義**：

1. `budgetCap` 提升為依 0010 §9 量測選定的新值（選值規則：合成 100k 吞吐量測中「單幀純 CPU ≤ 2ms @ 上限粒子數」的最大 2 的冪）；`pmMaxParticles` 同步；`FFIContractSpec` 鏡射律全綠；`PM_MAX_PARTICLES` 與 header **零改動**；demo 以分塊繪製正常顯示超過 4096 粒的 spell（S1）。
2. `Semigroup`/`Monoid CompiledSpell` 合法：結合律（QuickCheck，逐位元）、`mempty` 左右恆等、合成後 `PhasePlan` 不變量保持、`spellBudgetPlan` 串接律成立（S2）。
3. `compileMany :: [Circle] -> Either CompileError CompiledSpell`：全部編譯 → fold 合成 → 總預算對 `budgetCap` 檢查，超額回 `BudgetExceeded 總需求 上限`（S3）。
4. `Magic.Scene`：全域配額下 `castInto` 先到先得（超額拒收、場景不變）、`advanceScene` 推進全部並移除已完成、`observeScene` batch 串接且決定論（同場景操作序列 ⇒ 逐位元同輸出）（S4）。
5. 合成 spell 的行為＝各成分行為的疊加：雙陣合成的 `observeSpell` 輸出 ≡ 兩個單陣分別 observe 後的粒子多重集（相同 `CastContext` 下，逐位元、順序依串接序）（S5 驗收律）。
6. ADR-0012 交付：合併律（逐界標 max）、配額政策（先到先得 v1）、場作用域（各自的場只作用於各自的發射器——見 §2 風險）的決策與被否決方案。

## 2. 使用到的架構與技巧

- **合併律＝逐界標 max**：`PhasePlan` 四界標分別取 max。單調性保持的論證：`a₁≤a₂≤a₃≤a₄`、`b₁≤b₂≤b₃≤b₄` ⇒ `max a₁ b₁ ≤ max a₂ b₂ ≤ …`（max 對每個分量單調）。語意直覺：合成陣的每個階段持續到「最慢的成分陣」結束——快的成分在自己的 envelope 內自然消退，不需要截斷任何一方。被否決方案（寫進 ADR-0012）：取 min（截斷慢方，破壞成分語意）、相加（無物理意義）、保留雙 plan（`PhasePlan` 型別要改，漣漪到 0006 全部凍結面）。
- **`spellEmitters` 串接與 index-0 慣例**：現況「index 0 = casting 發射器」是**建構慣例**而非讀取假設——場輸入以 `emPhase == Casting` 過濾、非以索引（0007 `fieldInputs`）。實作前置動作：grep 全 repo 確認無任何 `V.head`/`! 0` 讀取假設（S2 測試附一條「雙 casting 發射器合成後場語意正確」的見證）。
- **場的作用域**：`spellFields` 串接後，A 陣的場會作用到 B 陣的 Casting 粒子——這是**語意選擇**。v1 裁決：**合成 = 完全融合**（場作用於整個合成 spell 的 Casting 相位粒子），理由：玩家把兩張陣疊在一起，本來就是要它們互相作用；「隔離合成」（各場管各陣）需要 per-emitter 場路由，留待需求出現（ADR-0012 記錄兩案）。
- **`Monoid` 單位元**：`mempty` = 零發射器、零場、全零 `PhasePlan`、空 `ParticleBudget`。`compile emptyCircle` 是否恰為 `mempty` 不強求（emptyCircle 可能仍有 casting 發射器）；單位律只對 `mempty` 本身斷言。
- **場景層＝purely functional fold（ADR-0004 延續）**：`Scene` 是 `[(SpellId, ActiveSpell)]`＋配額帳＋下一個 id 的純值；`advanceScene` = map `advanceSpell` ＋ filter `isFinished`；`observeScene` = concatMap batches。無 IO、無鎖——多 spell 的**執行緒策略仍屬宿主**（0009 §9-2 立場不變）。
- **先到先得配額**：`castInto` 檢查 `usedBudget + budgetTotal (spellBudgetPlan s) ≤ scGlobalCap`；拒收回 `Left QuotaExceeded`（新型別，Scene 層自己的錯誤——不污染 `CompileError`）。已完成 spell 移除時配額自動釋放（帳跟著 spell 集合算，不另記簿）。
- **demo 分塊繪製**：單一動態 mesh 容量 `gpuCapacity` 不變大（GPU 上傳粒度維持小塊），改為每 batch 依 `gpuCapacity` 切塊多次 `uploadAndDraw`——draw call 數 = ⌈粒子數/塊⌉，仍與粒子數次線性。ADR-0009 的動態 mesh 路徑不變。

## 3. ADT

```haskell
-- Magic.Compile（加法）
instance Semigroup CompiledSpell   -- 發射器/場/預算串接；lifetime = max；PhasePlan 逐界標 max
instance Monoid    CompiledSpell   -- mempty = 空 spell（§2）
compileMany :: [Circle] -> Either CompileError CompiledSpell
  -- traverse compile → sconcat → 總預算 vs budgetCap（空清單 = Right mempty）

budgetCap :: Int   -- 4096 → 新值（S1；選值規則見 §1-1）

-- src/boundary/Magic/Scene.hs（新；交付後凍結）
newtype SpellId = SpellId Int              deriving (Eq, Ord, Show)
data SceneConfig = SceneConfig { scGlobalCap :: !Int }
data Scene                                  -- 不透明：spell 集合＋配額帳＋next id
data CastRefusal = QuotaExceeded !Int !Int  -- 需求、剩餘
  deriving (Eq, Show)

newScene     :: SceneConfig -> Scene
castInto     :: CastRequest -> Scene -> Either CastRefusal (SpellId, Scene)
dismiss      :: SpellId -> Scene -> Scene          -- 主動移除（宿主打斷施法）
advanceScene :: FrameInput -> Scene -> Scene       -- 推進全部；完成者移除、配額釋放
observeScene :: Scene -> FrameOutput               -- batch 串接（SpellId 升冪，決定論）
sceneBudget  :: Scene -> (Int, Int)                -- (已用, 上限)
```

## 4. 資料結構與儲存方式

`Scene` 內部：`Map SpellId ActiveSpell`（`containers` 已在 boundary 依賴內？——**否**，boundary 白名單無 containers；改用升冪 `[(SpellId, ActiveSpell)]` 關聯清單，場景規模＝同時存在的法術數（個位數～十位數），列表足矣且免新依賴）。配額帳＝即時求和（spell 數小，O(n) 可忽略）。

## 5. 資料流（pipeline）

```mermaid
flowchart LR
  subgraph pure [純環]
    J1[Circle A] --> CM[compileMany<br/>sconcat + 預算檢查]
    J2[Circle B] --> CM
    CM --> CS[CompiledSpell 合成體] --> AS[castSpell → ActiveSpell]
    AS --> SC[Scene：castInto（配額）]
    SC --> AD[advanceScene] --> OB[observeScene → FrameOutput]
  end
  OB --> HOST[宿主／demo（IO：分塊繪製）]
```

## 6. 搭建方式（風險優先）

1. **S1 上限提升**——最小改動、最大解鎖；先做，讓後續合成測試能用大預算場景。
2. **S2 `Semigroup`/`Monoid`**——核心語意，含 index-0 慣例查證。
3. **S3 `compileMany`＋超額**。
4. **S4 `Magic.Scene`**。
5. **S5 端到端**（含疊加律）。
6. ADR-0012 與 S2 同步起草、S5 定稿。

## 7. Todo List 與 1-to-1 測試對應

| # | Todo | 測試 |
|---|---|---|
| S1 | `budgetCap` 改值＋`pmMaxParticles` 跟改＋`gpuCapacity` 分塊繪製＋0010 `Acceptance10Spec` 哨兵行更新 | `test/CapacitySpec.hs`（新值哨兵、`compile` 接受 >4096 的陣、鏡射律見證；分塊：`buildQuads` 分塊聯集 ≡ 整塊——純函數層可測，GPU 路徑靠既有手動 smoke） |
| S2 | `Semigroup`/`Monoid CompiledSpell`＋index-0 慣例查證 | `test/ComposeSpec.hs`（結合律/單位律 QuickCheck 逐位元、`PhasePlan` 不變量保持、界標 max 見證、雙 casting 發射器場語意見證） |
| S3 | `compileMany`＋超額 `BudgetExceeded` | `test/ComposeBudgetSpec.hs`（預算串接律、超額值正確、空清單 = `Right mempty`、單元素 ≡ `compile`） |
| S4 | `Magic.Scene` 全 API | `test/SceneSpec.hs`（配額拒收且場景不變、完成移除釋放配額、`dismiss`、決定論：同操作序列逐位元同輸出、`observeScene` 序穩定） |
| S5 | 端到端驗收＋ADR-0012 定稿 | `test/Acceptance12Spec.hs`（疊加律：雙陣合成 observe ≡ 成分粒子多重集逐位元；場景三 spell 240 幀決定論；golden 單陣行為零回歸） |

## 8. 非目標

1. 多 spell 聚合 **FFI** API（`pm_scene_*`）——等場景層在 Haskell 面穩定一輪後再上 C ABI（記帳 roadmap §3.3）。
2. 玩家面 JSON 多陣文件格式（`"circles": [...]`）——合成是 API 級操作（宿主/遊戲層動態組合）；JSON schema 仍是單陣（v1 不動）。
3. 配額政策的進階策略（按 power 加權、優先權搶佔）——ADR-0012 記錄選項，v1 只做先到先得。
4. 合成陣的視覺專屬表現（合成特效、橋接光效）——視覺語彙屬 0013 之後的視覺輪。
5. 隔離合成（per-emitter 場路由）——見 §2 場作用域裁決。
6. demo 的場景層展示 UI（多 spell 同屏鍵位）——demo 仍單 spell；場景層由 headless 測試證明（保住與 0014 的檔案零交集）。

## 9. 驗收紀錄

> 驗收日：2026-08-15。環境：GHC 9.14.1／cabal 3.16.1.0／Windows 11 x86_64，全套件 `-O2`。
> `cabal build all` 綠（含 exe、bench、foreign-library），零新增警告（既有兩則 `-Wunused-imports` 為 0013 遺留，未觸碰）；`cabal test` **969 examples, 0 failures**（動工前 903 → 本輪 +66）。
> 決策文件：[ADR-0012](../adr/0012-multi-circle-scene.md)（合併律、配額政策、場作用域、上限選值）。

### 9.1 Todo 逐項

| # | 結果 | 測試 |
|---|---|---|
| S1 | ✅ `budgetCap` 4096 → **16384**、`pmMaxParticles` 跟改（FFI 端一行）、`gpuCapacity` 與上限脫鉤＋分塊繪製（新 `App.Render.Chunk`）、`Acceptance10Spec` 哨兵行更新 | `CapacitySpec`（12 examples） |
| S2 | ✅ `Semigroup`/`Monoid CompiledSpell`；index-0 慣例查證見下 | `ComposeSpec`（10 examples） |
| S3 | ✅ `compileMany`＋合成總量對同一 cap 檢查、沿用 `BudgetExceeded` | `ComposeBudgetSpec`（7 examples） |
| S4 | ✅ `Magic.Scene` 全 API（含合成入口 `castManyInto`） | `SceneSpec`（12 examples） |
| S5 | ✅ 端到端驗收＋ADR-0012 定稿 | `Acceptance12Spec`（25 examples） |

**S2 的 index-0 查證結果**：全 repo 對 `spellEmitters` 的讀取只有四處（`Magic.Interface` 的 `emptyFieldState`／`fieldInputs`／`emittersOf`、`Magic.Compile.spellBlend`、`Magic.Particle.Analytic` 的四個走訪）。唯一以索引 0 取值的是 `spellBlend`（取第一個發射器的混合模式），而它是 architecture §10「一個法術一種混合模式」的實作、不是「索引 0 是 casting」的假設；力場層如設計所述以 `emPhase == Casting` **過濾**。合成後第二張陣的 casting 發射器落在向量中間，`ComposeSpec` 以「兩個 Casting 發射器、第二個索引 > 0」＋「重力井的場確實位移了火環的粒子」兩條見證釘住。`spellBlend` 的可觀察後果寫入 ADR-0012 D5 並記帳。

### 9.2 S1 選值量測（本輪新增 bench 組 `frame CPU (sample + buildQuads)`）

`cabal bench`，全套 `-O2`，同機、與 0010 §9.2 同一組 fixture（合成單發射器法術，t = 2.5s 全數存活）。選值規則：**單幀純 CPU ≤ 2 ms 的最大 2 的冪**。

| 粒子數 | 取樣＋quad 展開（單幀純 CPU） | 佔 60 fps 預算 | 規則 |
|---|---|---|---|
| 4096（舊上限） | 0.328 ms ± 21 µs | 2.0% | 通過 |
| 8192 | 0.720 ms ± 69 µs | 4.3% | 通過 |
| **16384** | **1.45 ms ± 111 µs** | **8.7%** | **通過——選定值** |
| 32768 | 2.87 ms ± 168 µs | 17.2% | 超出 |

0010 §9.2 建議的 32768–65536 是**只算取樣**的推估；把 quad 展開一起量進來後，32768 就跨過了 2 ms 的自制線。差異的來源與量級都合理（quad 展開約 18 ns/粒，取樣約 65 ns/粒），故本輪取直接量測值而非推估區間，理由寫進 ADR-0012 D7 的被否決方案。

### 9.3 S1 手動 smoke（分塊繪製的 GPU 側）

分塊的純函數律由 `CapacitySpec` 守護（切塊聯集 ≡ 整塊，逐位元，含 property）；GPU 路徑照 spec 走手動 smoke。做法：臨時投入一份 `power = 24.0`（6144 粒）的 spell 檔到 `assets/spells/`，以 `Start-Process`＋`SetForegroundWindow`＋`SendKeys` 驅動真實視窗、截圖客戶區，驗畢刪檔（不入版控）。結果：

- **3D 透視**：HUD `particles: 6144`、`fps: 60.0`，粒子柱完整（若仍為 0012 前的夾擠行為，最後 2048 顆——即最晚出生、位於噴泉根部的那批——會整片消失；截圖中根部是全圖最亮最密處）；
- **2D 側視（Tab 後）**：同一份 6144 粒 batch 走 `drawFlatIO` 的分塊路徑，HUD 同樣 `particles: 6144`、`fps: 60.0`，畫面完整；
- 兩條路徑皆為 ⌈6144/4096⌉ = 2 次 `uploadAndDraw`，`CloseMainWindow` 後 exit code 0。

### 9.4 凍結清單（下游 spec 可直接引用）

`Magic.Compile`：

```haskell
instance Semigroup CompiledSpell   -- 發射器/場/預算串接；PhasePlan 逐界標 max
instance Monoid    CompiledSpell   -- mempty = 零發射器、零場、全零 PhasePlan
compileMany :: [Circle] -> Either CompileError CompiledSpell
budgetCap   :: Int                 -- == 16384
```

律（`ComposeSpec`／`ComposeBudgetSpec` 守護）：結合律逐位元；`mempty` 左右恆等（對所有滿足 `PhasePlan` 不變量者，即 `compile` 能產出的全部值）；`compileMany [] == Right mempty`；`compileMany [c] == compile c`；合成保持 `PhasePlan` 不變量、`spellLifetime == ppEnd`、`ParticleBudget` 的對齊與求和不變量。

`Magic.Interface` 加法匯出（既有簽名一個都沒改）：

```haskell
castSpells        :: [Circle] -> CastContext -> Either CompileError ActiveSpell
maxSpellParticles :: Int      -- 值 4096 → 16384（常數本身即匯出面，未新增第二個）
```

`Magic.Scene`（新 boundary 模組，交付後凍結）：

```haskell
newtype SpellId    = SpellId Int              deriving (Eq, Ord, Show)
newtype SceneConfig = SceneConfig { scGlobalCap :: Int } deriving (Eq, Show)
data    Scene                                  -- 不透明
data    CastRefusal = QuotaExceeded !Int !Int  -- 需求、剩餘
                    | CompileFailed !CompileError
  deriving (Eq, Show)

newScene     :: SceneConfig -> Scene
sceneSpells  :: Scene -> [SpellId]
sceneBudget  :: Scene -> (Int, Int)            -- (已用, 上限)
castInto     :: CastRequest -> Scene -> Either CastRefusal (SpellId, Scene)
castManyInto :: [Circle] -> CastContext -> Scene -> Either CastRefusal (SpellId, Scene)
dismiss      :: SpellId -> Scene -> Scene
advanceScene :: FrameInput -> Scene -> Scene
observeScene :: Scene -> FrameOutput
```

C ABI：**零變更**。`include/particle_magic.h` 一字未動，`PM_MAX_PARTICLES` 仍為 4096（永釘），`pm_max_particles()` 現答 16384。11 個 C 進入點、`.def`、C# 綁定全部原樣。

`App.Render.Chunk`（殼層，非對外面）：`chunkBatch :: Int -> QuadBatch -> [QuadBatch]`。

### 9.5 與設計書的偏差（逐條說明）

1. **`CastRefusal` 多一個建構子 `CompileFailed !CompileError`**（§3 只列了 `QuotaExceeded`）。`castInto` 吃的是 `CastRequest`，而編譯是它必經的一步——一張編不過的陣必須有地方回報。包起來而非合併，仍然守住 §2「不污染 `CompileError`」的意圖：Scene 有自己的錯誤型別，編譯器的錯誤是它的一個 case。
2. **`Magic.Interface` 轉匯出的是 `castSpells` 而非 `compileMany`**（§0.2 已預留「或等價的多陣 `castSpell` 便利入口」）。理由：`Magic.Interface` 刻意不匯出 `CompiledSpell`，轉匯出 `compileMany` 會逼它變成抽象型別再補一個「編譯產物 → `ActiveSpell`」的函數，等於為了轉匯出而擴張詞彙。`castSpells :: [Circle] -> CastContext -> Either CompileError ActiveSpell` 一個函數就夠，且與 `castSpell` 同形。`compileMany` 本身仍在 `Magic.Compile` 匯出（core 消費者與測試用）。
3. **`Magic.Scene` 多一個 `castManyInto` 與一個 `sceneSpells`**（§3 未列）。前者是場景層與合成層的交會點——少了它，兩個本輪交付的東西無法一起用；後者是觀察面（宿主要知道自己手上有哪些 handle 還活著，測試要能斷言「完成者已移除」），無它則 `Scene` 只能經 `sceneBudget` 的數字間接觀察。
4. **分塊繪製放進新模組 `app/App/Render/Chunk.hs`，而非改 `Quads.hs`**。§0.2 明文不碰 `Quads.hs`／`Flat.hs`（0013 的穩定面），而 `Raylib3D.hs` 不在測試套件內（h-raylib-free 規則），純函數律無處可測。新模組同時解決兩件事：律可測，且 3D 與 2D 兩條繪製路徑共用同一份切塊邏輯。與 0014 仍零交集。
5. **另外五個測試檔更新了寫死的 4096**（§0.2 只列了 `FFIContractSpec`，而它因 0011 改寫成鏡射律後**實際零修改**）：`BudgetPlanSpec`（「at the cap」fixture 改為由 `budgetCap` 導出的 `atCapCircle`，斷言改述為 `maxSpellParticles == budgetCap` 的律）、`CompileFoldSpec`（power 20 → 80）、`FormationSpec`（power 15 → 63，維持「casting 單獨不超、加上陣形才超」的案例意圖）、`FFIErrorSpec`（over-budget fixture power 40 → 80，訊息比對改用 `show budgetCap`）、`Acceptance10Spec`（哨兵值）。五個檔案與 0014 的清單皆無交集。改法一律往「述律而非釘值」靠，值的哨兵集中在 `CapacitySpec` 一處。
6. **`bench/Bench.hs` 新增一個量測組**（§0.2 未列 bench）。§1 的完成定義要求上限值「依量測選定」，而既有 bench 只量到取樣、量不到整幀。新增組 `frame CPU (sample + buildQuads)` 於四個候選值直接量（§9.2）。bench stanza 本就在 `BoundarySpec` 白名單之外，且 0014 不觸 bench。
7. **`compile emptyCircle ≠ mempty`，如 §2 所預期**——空陣仍施放素放（architecture §3.3），單位律只對 `mempty` 自身斷言。實作上 `mconcat` 走 base 的預設 `foldr (<>) mempty`，故 `mconcat [x] = x <> mempty`；對所有滿足 `PhasePlan` 不變量的值這與 `x` 相等（`max 0 x = x`），`ComposeSpec` 的單位律與 `ComposeBudgetSpec` 的 `compileMany [c] == compile c` 兩條合起來守護這件事。
8. **未新增任何 golden，也未重新產生任何 golden**。0010 §9.5 預期「提升 cap 時範例陣輸出理應不變，故預期不需要重新產生」——事實如此：`test/golden/perf-0010/*.txt` 十檔一位元未動，`PerfGoldenSpec` 與 `Acceptance10Spec` 全綠。
