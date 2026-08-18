---
id: subarch-0001
type: subarch
title: magic-semantics
description: 魔法陣結構、符文詞彙、由內而外解釋器與符文陣幾何
status: active
created: 2026-08-18
updated: 2026-08-18
parent-arch: architecture
related-adr: [adr-0002, adr-0003, adr-0014, adr-0015, adr-0020]
---

# 魔法語意 子系統架構

## 定位與範圍

在[主架構 §2.1](architecture.md#21-子系統劃分)的六塊裡，這一塊住**純核心**，回答的問題是「**魔法是什麼**」——一張魔法陣作為資料，它的結構長怎樣、每個槽位放進去的符文代表什麼語意、這些語意如何被一個預先寫好的解釋器折成一組發射器。它是「Circle as Data」（主架構 §1.1）與「特效即魔法」（§1.2）這兩條理念的實際落點。

**做**：

- 魔法陣的結構 ADT 與其硬合約（外 2／夾 1／內 2／核心）
- 四類符文的詞彙定義（依槽位職責分類，ADR-0003）
- 由內而外的解釋器 fold：`Circle → CompiledSpell`
- 生命週期時間表（`PhasePlan`）與編譯期粒子預算（`ParticleBudget`）
- 符文陣：由魔法陣自身的結構摘要導出的陣形幾何與自轉（`Magic.Sigil`）

**明確不做**：

- **不求值數學式**。符文可以夾帶 `Expr`，但 AST 與求值器屬 [subarch-0002](subarch-0002-expr-language.md)；本子系統只負責決定式子掛在哪個槽位、吃哪一條時間軸。
- **不取樣粒子**。`CompiledSpell` 是**資料**，把它變成某一幀的 `ParticleBuffer` 是 [subarch-0003](subarch-0003-particle-simulation.md) 的事。
- **不認識 JSON 或任何文字語法**。核心只見 ADT（主架構 §2 關鍵約束）；文字↔ADT 在 [subarch-0004](subarch-0004-boundary-host.md)。
- **不認識相機、螢幕、繪圖 API**。連「視錐」這個詞都不在本子系統的詞彙裡——核心只交保守包絡，判定是宿主責任。

## 需求說明

來自 `Init.md` 的原始需求：玩家用參數與符文組出魔法，魔法陣可自由組合（所有槽位皆選配），沒有魔法陣就是單純的魔力放出。轉成本子系統的三條要求：

1. **不合法的組合要無法被表示**，而不是被檢查出來。槽位的職責由型別決定，「把行為符文放進外圈」在型別層就不存在，解釋器因此不需要防禦性分支。
2. **擴充要便宜**。加一種符文＝對應 sum type 加一個建構子＋解釋器加一個 case，GHC 的窮盡性檢查負責列出所有要補的位置（主架構 §10）。既有建構子的語意與 JSON tag 凍結，但 sum type 本身明文為開放擴充點。
3. **陣要是這個魔法自己的陣**。陣形幾何不能是寫死的裝飾圖案，必須由 `Circle` 的資料導出——同一份 JSON 永遠畫出同一個陣，不同的 JSON 畫出不同的陣（ADR-0014）。

## 架構規劃

| 元件 | 檔案 | 職責 |
|---|---|---|
| 共用空間詞彙 | `src/core/Magic/Types.hs` | `V3`／`V2`／`Time`／`Seconds`／`Seed`／`CastContext`、`basisFromNormal`、確定性隨機 `hashChan`。全核心共用的地基，三個核心子系統都依賴它，但它不依賴任何人 |
| 結構 ADT | `src/core/Magic/Circle.hs` | `Circle`／`TwoOf`／`Core`／`Nodes`／`PhaseConfig`／`emptyCircle`。**只有形狀，沒有語意**——這份型別不知道 `OuterRune` 是幹嘛的 |
| 符文詞彙 | `src/core/Magic/Rune.hs` | 四類符文 sum type（`OuterRune`／`BridgeRune`／`InnerRune`／`EssenceRune` 及 `NodeRune`）與其值域（`FaceShape`／`RadiationMode`／`Trajectory`／`Envelope`／`Element`／`BillboardShape`）。另含兩個**陣層級屬性**而非符文槽的型別：`ForceField`、`Anchor` |
| 解釋器 | `src/core/Magic/Compile.hs` | 由內而外 fold、`CompiledSpell`／`EmitterSpec`／`Motion`／`Appearance`／`PhasePlan`、`budgetCap` 護欄、`ParticleBudget`、`emitterBounds` 的區間算術、`elementAppearance` 查表。子系統中最大的一塊，也是最擁擠的檔案（roadmap §4.8 的串行鏈幾乎全因它而生） |
| 符文陣 | `src/core/Magic/Sigil.hs` | `hashCircle` 結構摘要（**交付即凍結**，ADR-0014 D3）、`SigilPlan`／`SigilStroke` 六種筆畫、`sigilBudget`、`SigilSpin`／`spinAngle` 自轉的分段閉式函數 |

依賴方向：`Types ← Circle ← Rune ← {Compile, Sigil}`，`Sigil ← Compile`（解釋器 fold 的第 5 步取用陣形計畫）。子系統內無循環。

## 對外介面

其他子系統只透過下列面使用本子系統。**簽名已凍結**，變更視同破壞性版本（主架構 §11）。

```haskell
-- 編譯（消費者：subarch-0004 的 Magic.Interface）
compile      :: Circle -> Either CompileError CompiledSpell
compileMany  :: [Circle] -> Either CompileError CompiledSpell   -- 逐界標 max，預算相加
budgetCap    :: Int                                              -- 16384（ADR-0012 D7 的量測規則）

-- 編譯產物（消費者：subarch-0003 的取樣器與力場層）
data CompiledSpell = CompiledSpell
  { spellLifetime   :: !Seconds
  , spellBudget     :: !Int
  , spellBudgetPlan :: !ParticleBudget
  , spellEmitters   :: !(Vector EmitterSpec)
  , spellPhases     :: !PhasePlan
  , spellFields     :: ![ForceField]
  }
phaseAt            :: PhasePlan -> Time -> Phase
spellNeedsVelocity :: CompiledSpell -> Bool      -- 拖尾 opt-in（subarch-0003 據此選建構子）

-- 靜態查詢（消費者：subarch-0004 的空間摘要與宿主）
emitterBounds :: CastContext -> EmitterSpec -> (V3, V3)   -- 保守 AABB，逐位元凍結
shapeRadius   :: FaceShape -> Double
evalInterval  :: IntervalEnv -> Expr -> Interval          -- 內部面：只開放給 Magic.Space

-- 符文陣（消費者：subarch-0003 的陣形取樣）
hashCircle :: Circle -> Word64        -- 凍結：改它＝靜默改變每一個法術的長相
sigilPlan  :: Circle -> SigilPlan
spinAngle  :: SigilSpin -> PhasePlan -> Time -> Double
```

**對外承諾的三條律**：

1. **空陣即素放**：`emptyCircle`（所有槽位 `Nothing`）走同一條 fold，產出跳過 Drawing／Converging 的預設放出發射器。無特例分支。
2. **開放擴充、凍結語意**：sum type 可加建構子；既有建構子的語意與 JSON tag 不動。
3. **摘要即合約**：`hashCircle` 的輸出決定陣的長相，浮點以位元進入摘要，因此同一份 JSON 在同平台永遠畫出同一個陣。

## 使用的技術

沿用主架構的技術棧（Haskell GHC 9.14.1、GHC2021、cabal）。子系統特有的只有一件事：**依賴白名單**。`magic-core` 的 `build-depends` 僅 `base`／`vector`／`deepseq`／`parallel`，由 `test/BoundarySpec.hs` 機械守護——本子系統一行 IO、一個 `Eff`、一個 `aeson` 型別都碰不到（ADR-0007）。

## 架構圖

```text
                 Circle（由 subarch-0004 的 Magic.Codec 解碼而來）
                                    |
        +---------------------------+---------------------------+
        |                                                       |
        v                                                       v
+--------------------------------------------+      +--------------------------+
| Magic.Compile - 由內而外 fold               |      | Magic.Sigil              |
|                                            |      |                          |
|  (1) Core      --> SpellSeed               |      |  hashCircle（凍結摘要）   |
|      本質：屬性、強度、節點偏置               |      |        |                 |
|         |                                  |      |        v                 |
|  (2) 內圈      --> BehaviorProto            |      |  SigilPlan               |
|      行為：軌跡、包絡、玩家式子               |      |   |- SigilStroke x 6 種  |
|         |                                  |      |   +- SigilSpin（自轉）    |
|  (3) 夾層      --> ModulatedProto           |      |        |                 |
|      調變：收束、增幅、時序位移               |      |        | (5) 陣形發射器   |
|         |                                  |<-----+--------+                 |
|  (4) 外圈      --> Vector EmitterSpec       |      +--------------------------+
|      展現：形狀取樣、範圍、輻射               |
+------------------+-------------------------+
                   |  查詢符文語意
                   v
        +---------------------+        +------------------------------+
        | Magic.Rune          |        | Magic.Circle                 |
        | Outer/Bridge/Inner/ |<-------| 結構 ADT（外2 夾1 內2 核心）  |
        | Essence/Node        |  型別  | 槽位皆 Optional              |
        | + ForceField/Anchor |  約束  +------------------------------+
        +----------+----------+
                   v
        +------------------------------------------------+
        | Magic.Types - V3 / Time / Seed / hashChan       |
        | 全核心共用詞彙（subarch-0002、0003 同樣依賴）    |
        +------------------------------------------------+

出口 --> CompiledSpell（給 subarch-0003 取樣）
     --> emitterBounds / budgetPlanOf / hashCircle（給 subarch-0004 查詢）
```

## 資料結構的框架格式

- **結構 ADT**：`Circle` 為固定欄位的 record，環用 `TwoOf a`（恰兩層）、節點用 `Nodes a`（恰四向），全部槽位包在 `Maybe` 裡。層數是型別層的硬合約，不是執行期的長度檢查。
- **符文**：一律 sum type，建構子攜帶各自的參數 record 或值域列舉。**不使用 GADT／type class 抽象**（ADR-0002）——符文是資料，不是行為。
- **編譯產物**：`CompiledSpell` 的每個欄位都是 strict 的資料；`Motion`／`Appearance` 是**資料而非函數**，因此整個 `CompiledSpell` 可序列化、可快取、可在編譯期做預算分析。`spellEmitters` 用 `Data.Vector`（boxed，發射器數量以十計）。
- **時間表**：`PhasePlan` 是四個絕對時間界標（Drawing／Converging／Casting／Dissipating 的起訖），階段切換由時間查表得出（`phaseAt`），**不是狀態機**——這是整條管線保持「`t` 的純函數」的關鍵。
- **符文陣計畫**：`SigilPlan` 是 `Vector SigilStroke`，每筆筆畫帶種類、半徑、角度區間與粒子配額；索引序即繪製序。

## 使用到的套件

| 套件 | 用途 |
|---|---|
| `base` | — |
| `vector` | `spellEmitters`、`SigilPlan` 的 boxed 向量 |
| `deepseq` | 編譯產物的嚴格求值 |

`parallel` 雖在同一份白名單，但只被 [subarch-0003](subarch-0003-particle-simulation.md) 使用。

## 開發階段

對應主架構的 **POC 實作階段**，是整個專案的第一條主線與最長的串行鏈（roadmap §4.8：`Compile.hs`／`Sigil.hs` 的檔案交集使 0012→0015→0016→0017→0020→0021 無法平行）。內部里程碑三個：**M1 結構與解釋器**（陣可以被折成發射器）、**M2 陣形自身**（陣變成看得見的線、活滿整場、會轉）、**M3 語彙廣度**（值域從 POC 的最小集擴到可玩）。三者皆已達成。

## 功能規劃

一份 spec 只掛在一個子系統（`/code-audit status` 以此判定歸屬與進度），所以下表只列**主場在本子系統**的 spec；橫跨到別處的那一半記在表後的參與清單。

### 階段一：語意骨架（M1，已交付）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 1 | circle-interpreter | `Circle`／`Rune` ADT 與由內而外的四步 fold，空陣即素放 | - | func-0002 |
| 2 | expr-rune-wiring | 四種夾帶 `Expr` 的符文接上魔法陣，分層時間軸凍結 | #1 | func-0004 |
| 3 | lifecycle-formation | `PhasePlan` 四階段，以及由陣形幾何導出的發射器 | #2 | func-0006 |

### 階段二：陣形自身（M2，已交付）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 4 | sigil-geometry | `hashCircle` 摘要導出六種筆畫，索引序＝繪製序 | #3 | func-0016 |
| 5 | sigil-persistence | 陣活到法術結束、取消收束，法術從仍存在的陣中射出 | #4 | func-0017 |
| 6 | sigil-motion | 整陣自轉、相鄰環反向、蓄力段加速後恆速 | #5 | func-0020 |

### 階段三：語彙廣度（M3，已交付）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 7 | magic-vocabulary | `Element` 4→9、`FaceShape` 4→8、`Trajectory` 4→8、`RadiationMode` 2→4 | #6 | func-0021 |

### 階段四：候選（未動工，逐條有記帳來源）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 8 | sigil-linger-phase | 陣的獨立時間軸：新增 `phases.linger`，讓陣比法術晚收或早收（記帳 0017 §8-3） | #5 | - |
| 9 | frozen-sigil | 畫完即凍結的靜止陣，取代現行以週期重畫造成的「呼吸」（0017 §8-1） | #5 | - |
| 10 | node-orbit | 節點群公轉；roadmap 指名應與多發動點合流後做（0020 §8-9） | #6 | - |
| 11 | time-varying-modulation | 第四種時間掛載點：`Expr` 驅動的時變場參數與非等速自轉（0007 §9、0020 §8-2） | #6 | - |
| 12 | glyph-semantics | 符文文字表義——現行 `GlyphBand` 只產生線段，不表義（0016 §8-1） | #4 | - |
| 13 | volumetric-sigil | 3D 立體陣：多層平面沿法線堆疊（0016 §8-4） | #4 | - |
| 14 | spell-cost-model | 魔法代價閘門，用遊戲層詞彙約束符文組合爆炸（主架構 §8.1） | #7 | - |

**本子系統參與但不擁有的 spec**

| spec | 主場 | 本子系統的那一半 |
|---|---|---|
| func-0012 | [subarch-0004](subarch-0004-boundary-host.md) | `compileMany` 的合成律：發射器與力場串接、預算相加、`PhasePlan` 逐界標取 max |

小結：共 **14 個 features、4 個階段**，前 7 個（階段一～三）已交付，子系統的核心語意已可交付；階段四七項皆為已記帳的欠款或明列的延後項，不是願望清單。
