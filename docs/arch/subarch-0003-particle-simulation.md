---
id: subarch-0003
type: subarch
title: particle-simulation
description: 解析取樣、力場積分、SoA 緩衝與固定時步推進
status: active
created: 2026-08-18
updated: 2026-08-18
parent-arch: architecture
related-adr: [adr-0001, adr-0006, adr-0010, adr-0017, adr-0018]
---

# 粒子模擬 子系統架構

## 定位與範圍

[主架構 §2.1](architecture.md#21-子系統劃分) 六塊裡的第三塊，住**純核心**（唯一例外是固定時步規劃器 `Magic.Step`，見下），回答的問題是「**這一幀長什麼樣**」——拿 [subarch-0001](subarch-0001-magic-semantics.md) 編出來的 `CompiledSpell`，加上一個時間，算出一整塊粒子緩衝。

它是 ADR-0001「混合粒子模型」的實作：**解析為主，力場為輔**。多數魔法的粒子位置是時間的純函數（無狀態、可任意快轉倒帶）；需要粒子被外力拉扯時才啟用力場層，那是整個系統唯一的跨幀狀態。

**做**：

- SoA 粒子緩衝的表徵、不變量與建構（九欄，後三欄 opt-in）
- 解析層取樣：形狀取樣、軌跡、包絡排程、玩家式子求值的組裝
- 力場層：固定時步的純狀態轉移與位移疊加
- 效能治理：時間窗剔除、per-emitter 提升、平行分片、粒子預算
- 固定時步規劃（accumulator 與 spiral-of-death 護欄）

**明確不做**：

- **不編譯魔法陣**。`CompiledSpell` 是輸入，怎麼來的不關本子系統的事。
- **不繪製、不投影**。輸出是抽象 3D 座標的緩衝；投影與繪製分別在 [subarch-0004](subarch-0004-boundary-host.md) 與 [subarch-0005](subarch-0005-render-shell.md)。
- **不做粒子對粒子的互動**。力場層只支援「場對粒子」。碰撞、鄰居查詢、空間分割是主架構 §7／§11 的**永久非目標**——spec 0023 正面檢驗過，一字未鬆動。
- **不做跨幀的緩衝重用**。這是一個**改判**而非疏漏：`observeSpell` 回傳的緩衝是宿主可長期持有的純值，跨幀重寫同一塊會偷改上一幀，違反 ADR-0007 的引用透明。

## 需求說明

1. **同樣的輸入永遠得到同樣的畫面**。`(CompiledSpell, CastContext, dt 序列)` 決定一切，這是可重播性的來源，也是所有 golden 測試的前提。
2. **1 萬～10 萬粒子**（主架構 §7 的目標）。已實測達成：100k 粒取樣單執行緒 8.4 ms、16 緒 2.5 ms；護欄 `budgetCap` 現值 16384 下單幀 1.0 ms。
3. **零場的魔法要免費**。沒有力場的魔法必須在結構上跳過整層，成本與力場層不存在時完全相同（ADR-0010 D9）——實測 `advanceSpell` 約 1.1 ns／步。
4. **平行不能改變畫面**。多核加速的決定論不能靠「碰巧」，要由切分方式**結構性保證**（ADR-0017 D2）。

## 架構規劃

| 元件 | 檔案 | 層 | 職責 |
|---|---|---|---|
| SoA 緩衝 | `src/core/Magic/Particle/Buffer.hs` | 核心 | `ParticleBuffer` 九欄、`bufferInvariant`、`buildBuffer` 的 count-then-fill、`buildBufferWithVelocity`、`hasVelocity` |
| 解析層 | `src/core/Magic/Particle/Analytic.hs` | 核心 | `sample`／`sampleSequential`／`sampleParallel`、`particlePosition`／`aliveSlots`（**力場層對齊用的單一事實來源**）、`aliveRanges` 時間窗剔除、`sampleShape` 形狀取樣、`velocityStep` 有限差分 |
| 力場層 | `src/core/Magic/Particle/Field.hs` | 核心 | `fieldAccel`、`SlotState`／`stepSlot` 的參照語意、攤平為 unboxed 欄的 `FieldState`、`stepColumns`／`displacementColumns` 熱路徑 |
| 時步規劃 | `src/boundary/Magic/Step.hs` | 邊界 | `plan dt maxSteps elapsed acc → StepPlan`。**唯一不住核心的元件**：它是純函數，放邊界層是為了讓外殼主迴圈與測試套件消費**同一個**規劃器而非兩份拷貝 |

依賴方向：`Buffer ← Analytic ← Field`（力場層以解析層的 `particlePosition` 當基準位置），`Step` 誰都不依賴。

## 對外介面

```haskell
-- 主入口（消費者：subarch-0004 的 Magic.Interface）
sample :: CompiledSpell -> CastContext -> Time -> ParticleBuffer

-- 解析層外露的兩個半邊（力場層與邊界層據此對齊 row）
particlePosition :: CastContext -> Time -> EmitterSpec -> Int -> Double -> V3
aliveSlots       :: CompiledSpell -> Time -> [(Int, Int)]   -- 恰為 buffer 的 row 順序

-- 力場層（消費者：Magic.Interface 的推進迴圈）
fieldAccel           :: [ForceField] -> V3 -> V3
fieldInputsOf        :: CompiledSpell -> CastContext -> Time -> FieldInputs
stepColumns          :: [ForceField] -> DeltaTime -> FieldInputs -> FieldState -> FieldState
displacementColumns  :: FieldState -> ...                     -- 依 aliveSlots 的順序取出

-- 緩衝（消費者：邊界層、渲染外殼、C ABI）
data ParticleBuffer = ParticleBuffer
  { pbPosX, pbPosY, pbPosZ :: !(U.Vector Float)
  , pbSize, pbLife         :: !(U.Vector Float)
  , pbColor                :: !(U.Vector Word32)
  , pbVelX, pbVelY, pbVelZ :: !(U.Vector Float)   -- opt-in：空或滿，絕不半滿
  , pbCount                :: !Int
  }
hasVelocity :: ParticleBuffer -> Bool

-- 固定時步（消費者：subarch-0005 的主迴圈、C ABI 的 pm_advance）
plan :: Double -> Int -> Double -> Double -> StepPlan
```

**組合點的語意**（ADR-0010，本子系統對外最重要的一條約定）：

```text
renderedPos = analyticPos + fieldDisplacement
```

力場層**不吃 `ParticleBuffer`**——緩衝的 row 每幀變動，不能當身分（ADR-0010 D2）。它以編譯期固定的槽位 `(emitterIndex, particleIndex)` 為鍵，疊加時用 `aliveSlots` 這一份列舉對齊 row。

**四條不變量**：

| 不變量 | 內容 |
|---|---|
| 欄位長度 | 前六欄長度皆為 `pbCount`；三個速度欄要嘛全 0、要嘛全 `pbCount`（`bufferInvariant`） |
| 前六欄凍結 | 名稱、型別、順序、語意自 func-0001 起**逐位元未變**，第三方宿主與 C ABI 都依賴這件事 |
| 零場免費 | `spellFields` 為空時整層被結構性跳過，逐位元等同力場層存在之前 |
| 平行等同 | `sampleParallel ≡ sampleSequential`，逐位元，與核心數無關（ADR-0017 律 2） |

## 使用的技術

沿用核心的依賴白名單，子系統特有的三項選型：

| 選型 | 理由 |
|---|---|
| **SoA ＋ `Data.Vector.Unboxed`** | 無指標追蹤、快取友善，GC 只見少數大型區塊而非十萬個小物件；且連續記憶體可直接餵給渲染後端與 C ABI（ADR-0006） |
| **count-then-fill（`ST` 單趟寫入）** | 先數出 exact size 再一次填滿，零 boxed 中介。取代了原本先建 list 再轉 vector 的寫法 |
| **`Control.Parallel.Strategies`** | 平行取樣的唯一可接受手段：`using` 只選擇求值順序、永不改變值，因此不破壞 ADR-0007 的「核心零 IO、簽名中無 `Eff`」。`forkIO`／`unsafePerformIO` 做不到這一點（ADR-0017） |

## 架構圖

```text
   CompiledSpell（來自 subarch-0001）   CastContext      dt（來自外殼時鐘）
            |                              |                  |
            +--------------+---------------+                  |
                           |                                  v
                           |                        +---------------------+
                           |                        | Magic.Step          |
                           |                        |   plan -> StepPlan  |
                           |                        |   accumulator 與     |
                           |                        |   spiral-of-death 護欄|
                           |                        +----------+----------+
                           |                                   | n 個固定步
                           v                                   v
  +--------------------------------------+       +-----------------------------+
  | Magic.Particle.Analytic              |       | Magic.Particle.Field        |
  |                                      |       |                             |
  |  aliveRanges  時間窗剔除（O(log n)）  |       |  fieldInputsOf              |
  |  per-emitter 提升（座標系算一次）      |------>|   每步取解析基準位置          |
  |  sampleShape / trajectory / Expr     | 基準  |  stepColumns                |
  |  shardsOf -> 平行分片（>= 8192 粒）   |  位置 |   半隱式尤拉，僅 Casting 槽位 |
  |                                      |       |  FieldState（唯一跨幀狀態）  |
  +------------------+-------------------+       +--------------+--------------+
                     |                                          |
                     | count-then-fill                          | displacementColumns
                     v                                          |
  +--------------------------------------+                      |
  | Magic.Particle.Buffer                |                      |
  |   九欄 SoA（後三欄 opt-in 速度）       |                      |
  |   bufferInvariant                    |                      |
  +------------------+-------------------+                      |
                     |                                          |
                     +--------------------+---------------------+
                                          |
                            renderedPos = analyticPos + disp
                          （疊加在 subarch-0004 的 Interface 內，
                            以 aliveSlots 的順序對齊 row）
                                          v
                                    ParticleBuffer
                                 --> subarch-0004 組成 RenderBatch
```

## 資料結構的框架格式

- **粒子緩衝**：九個平行的 unboxed 向量 ＋ 一個計數。位置與尺寸為 `Float`、顏色為 packed `Word32`（`0xRRGGBBAA`）。**不是** array-of-structs，也沒有 `Maybe`／`Either` 包在裡面——每一欄都是密實的數值。
- **力場狀態**：`FieldState` 以攤平的 unboxed 欄表示每個槽位的 `(lastAge, 速度, 累積位移)`。**表徵明文不凍結**（spec 0007 §4.7），這是它敢在 0010 從 boxed 改成 SoA 的理由。
- **分片**：`Shard` 是「發射器索引 ＋ 粒子索引區間」，切分只依 `CompiledSpell` 與時間決定，與執行緒數無關——這正是平行決定論的結構性保證。
- **時步計畫**：`StepPlan { stepsToRun, accAfter }`，backlog 超過 `maxSteps` 時 clamp 並丟棄餘額（模擬變慢而不是凍結）。

## 使用到的套件

| 套件 | 用途 |
|---|---|
| `base` | — |
| `vector` | unboxed 緩衝與 `ST` 建構 |
| `deepseq` | 分片結果的求值控制 |
| `parallel` | `Control.Parallel.Strategies` 的逐發射器平行取樣（核心白名單自 func-0001 以來的唯一一次放寬） |

## 開發階段

對應主架構的 POC 實作階段，並承擔 §7 的全部效能目標。內部里程碑三個：**M1 兩層模型成立**（解析層 ＋ 力場層各自可用且組合語意釘死）、**M2 達到吞吐目標**（10k–100k）、**M3 多核與新欄**（平行取樣、速度欄的 opt-in 加欄範式）。三者皆已達成，`budgetCap` 也自 4096 抬到 16384。注意 M3 在下方「功能規劃」裡看不到對應階段——承載它的兩份 spec（func-0022 平行取樣、func-0023 速度欄）主場記在別的子系統，列於表後的參與清單。

## 功能規劃

一份 spec 只掛在一個子系統（`/code-audit status` 以此判定歸屬與進度），所以下表只列**主場在本子系統**的 spec；橫跨到別處的那一半記在表後的參與清單。

### 階段一：兩層模型（M1，已交付）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 1 | force-field-layer | 力場層落地：三種場、穩定槽位身分、加法位移疊加、零場結構性跳過 | - | func-0007 |

### 階段二：吞吐目標（M2，已交付）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 2 | performance-budget | count-then-fill、per-emitter 提升、時間窗剔除、`FieldState` SoA 化、結構化 `ParticleBudget` | #1 | func-0010 |

### 階段三：候選（未動工，逐條有記帳來源）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 3 | drop-intermediate-v3 | 去掉取樣器每粒子約 460 B 的中介 `V3` 配置——目前已知的下一個瓶頸（0022 §9 記帳） | #2 | - |
| 4 | budget-cap-raise | 依 ADR-0012 D7 的同一條規則重新量測並提高 `budgetCap`，同步 `pmMaxParticles`（ADR-0017 D5：前提已到位，屬另一輪） | #3 | - |
| 5 | velocity-aware-fields | 阻尼／磁力等速度相依的場——需 `fieldAccel` 看到速度，等於改熱路徑簽名並重寫每槽讀取（0021 §後記建議入主架構 §11） | #1 | - |
| 6 | caster-relative-fields | 施法者相對座標系的力場（0007 §9 記帳） | #1 | - |
| 7 | leased-buffer-api | 租借式緩衝／arena 的**新 API 合約**——純介面下的跨幀重用做不到，要做得換合約（0010 §9.4-10） | #2 | - |

**本子系統參與但不擁有的 spec**

本子系統是全專案最常見的「參與者」：`Buffer`／`Analytic` 幾乎每一輪都被動到，但那些輪次的主題多半在別的子系統。**擁有兩份、參與四份**，下表是後者：

| spec | 主場 | 本子系統的那一半 |
|---|---|---|
| func-0001 | [subarch-0004](subarch-0004-boundary-host.md) | `ParticleBuffer` 的 SoA 表徵與 `Magic.Step` 固定時步規劃器首次落地 |
| func-0002 | [subarch-0001](subarch-0001-magic-semantics.md) | 解析層 `sample`：形狀取樣、軌跡、包絡排程 |
| func-0022 | [subarch-0002](subarch-0002-expr-language.md) | 平行取樣 S4：逐發射器分片的純 Strategies，決定論由切分方式結構性保證（ADR-0017） |
| func-0023 | [subarch-0005](subarch-0005-render-shell.md) | 速度欄 S1／S2：六欄 → 九欄的 opt-in 加欄範式與固定步長有限差分 |

小結：共 **7 個 features、3 個階段**，前 2 個已交付。**進度數字會低估這個子系統的成熟度**——吞吐目標（100k 粒 6.5 ms 單執行緒、2.5 ms 十六緒）與多核加速都已實測達成，只是承載它們的 spec 主場記在別處；階段三五項中 #3／#4 是同一條線（先去配置再抬上限），#5／#6 是力場層的語意擴充，#7 明列為「需要不同的 API 合約」而非優化。
