---
id: subarch-0004
type: subarch
title: boundary-host
description: 系統對外的唯一合約面：Haskell 入口、場景層與 C ABI
status: active
created: 2026-08-18
updated: 2026-08-18
parent-arch: architecture
related-adr: [adr-0005, adr-0008, adr-0011, adr-0012, adr-0016, adr-0019]
---

# 邊界與宿主整合 子系統架構

## 定位與範圍

[主架構 §2.1](architecture.md#21-子系統劃分) 六塊裡唯一**面向外界**的一塊，也是 `Init.md`「完美的介面化」這條目標的落點。它把三個核心子系統包成一份合約，並用**三種呼叫慣例**送出去：Haskell 直呼、C ABI、以及兩者之上的場景層。

這塊涵蓋 `magic-boundary` 整個 sublibrary，加上外殼位階的 `src/ffi`。把 FFI 收進來的理由是：它與邊界層共用**同一份合約**，只是換一種呼叫慣例——C 面不得比 Haskell 面多知道一件事（func-0009 §2 的零新語意紀律）。

**做**：

- JSON ↔ ADT 的編解碼、schema 版本策略、載入錯誤的可讀化
- 法術生命週期的唯一入口（`castSpell` → `advanceSpell` → `observeSpell`）
- 場景層：多法術共存與全域粒子配額
- 維度無關輸出的投影（3D 恆等、2D 正交 ＋ painter 排序）
- 空間摘要輸出：貼合有向盒、spell 級聯集、N³ 佔用格網
- C ABI：`foreign-library`、handle 生命週期、SoA copy-out、31 個匯出符號
- 各語言的參考綁定與最小宿主範例（C、C#／Unity、Haskell）

**明確不做**：

- **不含任何魔法語意**。這裡沒有一行程式碼知道「外圈是展現」。
- **不選繪圖 API、不輸出任何 raylib 型別**。這條保證在 spec 0023 被正面檢驗過並且維持：自訂 shader、bloom、軟粒子全部進場，但全住在 [subarch-0005](subarch-0005-render-shell.md)，`FrameOutput`／`RenderBatch`／`ParticleBuffer` 一個 raylib 型別都沒多。
- **不做視錐剔除、不做碰撞判定**。核心沒有相機概念（ADR-0008），庫交出保守包絡與佔用格網，判定是宿主的事（ADR-0019）。
- **不管執行緒安全**。目前無內部鎖，多執行緒宿主需自行序列化 handle 存取（記帳 0009 §9-2）。

## 需求說明

1. **唯一依賴點**：外殼或任何宿主遊戲只准 import `Magic.Interface` 與 `Magic.Codec`，這件事要由**套件結構機械強制**，不是靠紀律。
2. **兩種消費模式**：Haskell 宿主與非 Haskell 宿主（Unity／Godot／C++）都要能驅動同一套模擬，且**決定論跨邊界成立**——FFI 路徑 ≡ Haskell 路徑必須是可測的等價律。
3. **只加不改**：C header 是別人編譯進去的東西。新能力一律加新函數、不動舊簽名（`pm_observe_ex` 而非改 `pm_observe`）。
4. **輸出要維度無關**：同一份 `FrameOutput` 換投影即換維度，核心零變更。

## 架構規劃

| 元件 | 檔案 | 位階 | 職責 |
|---|---|---|---|
| 系統入口 | `src/boundary/Magic/Interface.hs` | 邊界 | `ActiveSpell` 生命週期、`FrameOutput`／`RenderBatch` 組裝（含依 `(blend, shape)` 分批）、力場位移疊加、預算與空間查詢的再匯出。**對外唯一入口** |
| 編解碼 | `src/boundary/Magic/Codec.hs` | 邊界 | Aeson 編解碼、`LoadError`／`renderLoadError`、schema `version` 欄與（未來的）`migrate` |
| 場景層 | `src/boundary/Magic/Scene.hs` | 邊界 | `Scene`／`SpellId`／`SceneConfig`、`castInto` 的先到先得配額、`CastRefusal`、`advanceScene`／`observeScene` |
| 投影 | `src/core/Magic/Project.hs` ＋ `src/boundary/Magic/Projection.hs` | 核心／邊界 | `project`（3D 恆等）、`ViewPlane`／`orthographic`（2D 丟一軸）、`depthOrder`（painter 穩定置換）。`Magic.Projection` 是外殼取用投影的唯一通道 |
| 空間摘要 | `src/core/Magic/Space.hs` | 核心 | `OrientedBox`／`emitterBox`／`spellBox`／`boxToAABB`、`OccupancyGrid`／`occupancyOf`／`occupancyMask`。**住核心但語意屬輸出**（ADR-0019：空間摘要是 `RenderBatch` 的兄弟，不是 `FieldState` 的兄弟） |
| 欄位回灌 | `src/boundary/Magic/Columns.hs` | 邊界 | `fromColumns`／`fromColumnsWithVelocity`：宿主把九欄交回來重建緩衝 |
| 時步規劃 | `src/boundary/Magic/Step.hs` | 邊界 | 共用自 [subarch-0003](subarch-0003-particle-simulation.md)，`pm_advance` 與外殼主迴圈用同一份 |
| C ABI 外殼 | `src/ffi/Magic/FFI.hs`、`cbits/pm_init.c`、`particle-magic-ffi.def` | 外殼 | `foreign export` 的 31 個符號、handle 生命週期、錯誤碼分類、marshalling |
| 凍結的 C 合約 | `include/particle_magic.h` | 契約 | `PM_ABI_VERSION`、`PM_MAX_PARTICLES`、錯誤碼、blend／shape／plane 列舉、手性與位元組序的哨兵註記 |
| 參考綁定與範例 | `bindings/csharp/`、`examples/{c,unity,haskell}/` | 契約 | 三條消費路徑各一份可跑的最小宿主 |

**依賴紀律**（由 `test/BoundarySpec.hs`／`FFIContractSpec.hs` 機械守護）：`magic-boundary` 依賴 `magic-core` ＋ 白名單（`aeson`／`bytestring`／`text`／`megaparsec`／`vector`）；`src/ffi` 只依賴 `magic-boundary` ＋ 兩個 marshalling 套件，**構不到 `magic-core`**。

## 對外介面

### Haskell 面（`magic-boundary`，`visibility: public`）

```haskell
-- Magic.Codec
loadCircle      :: ByteString -> Either LoadError Circle
saveCircle      :: Circle -> ByteString
renderLoadError :: LoadError -> String

-- Magic.Interface：法術生命週期
castSpell    :: CastRequest -> Either CompileError ActiveSpell
castSpells   :: [Circle] -> CastContext -> Either CompileError ActiveSpell
advanceSpell :: FrameInput -> ActiveSpell -> ActiveSpell
observeSpell :: ActiveSpell -> FrameOutput
stepSpell    :: FrameInput -> ActiveSpell -> (ActiveSpell, FrameOutput)  -- ≡ advance 後 observe
isFinished   :: ActiveSpell -> Bool
spellAge     :: ActiveSpell -> Time

-- Magic.Interface：查詢
budgetPlanOf      :: ActiveSpell -> ParticleBudget
maxSpellParticles :: Int                       -- 取代寫死的 4096
emittersOf        :: ActiveSpell -> Vector EmitterSpec
spellBoxOf        :: ActiveSpell -> OrientedBox
occupancyOf       :: ActiveSpell -> Int -> OccupancyGrid
occupancyMask     :: ActiveSpell -> Word32     -- N=3 時 27 格恰好塞進一個 Word32

-- Magic.Scene：多法術與全域配額
castInto     :: SceneConfig -> Circle -> CastContext -> Scene -> Either CastRefusal (SpellId, Scene)
advanceScene :: DeltaTime -> Scene -> Scene
observeScene :: Scene -> FrameOutput

-- Magic.Project：維度無關輸出的投影
project      :: V3 -> V3          -- 3D：恆等
orthographic :: ViewPlane -> V3 -> V2
depthOrder   :: ViewPlane -> ParticleBuffer -> Vector Int   -- painter 穩定置換
```

### C 面（`include/particle_magic.h`，**只加不改**）

31 個匯出符號，分四組：**生命週期**（`pm_init`／`pm_cast`／`pm_cast_ex`／`pm_advance`／`pm_observe`／`pm_observe_ex`／`pm_free` …）、**投影**（`pm_project`／`pm_depth_order`）、**場景**（10 個 `pm_scene_*`）、**空間摘要**（7 個 `pm_spell_box`／`pm_occupancy` …）。`PM_ABI_VERSION` 仍為 1——header 只加不改，所以世代不動。

三個寫進 header 的**哨兵註記**（不寫不會壞，寫了才不咬人）：座標系手性 `right-handed`、顏色位元組序 `0xRRGGBBAA`、以及決定論的範圍（同平台逐位元、跨平台結構 ＋ 2 ulp，ADR-0016 D4）。

`PM_MAX_PARTICLES` 永釘 4096，實際上限改用 `pm_max_particles()` 查詢——這是「值可以動、合約不動」的做法，`budgetCap` 從 4096 抬到 16384 那一輪 header **零字元變更**、既有宿主零重編譯。

## 使用的技術

| 選型 | 理由 |
|---|---|
| **Aeson** | JSON 是跨語言的建構語言：C 宿主不需要懂 Haskell ADT，丟字串進來就好（ADR-0005、ADR-0011） |
| **cabal `foreign-library` ＋ `native-shared`** | 不引入額外的 FFI 產生器；Windows 端需 `standalone` ＋ `.def` 匯出清單，否則 DLL 連得起來但宿主解不到符號 |
| **JSON 進、SoA copy-out** | 輸入用字串換取跨語言可攜，輸出用連續陣列換取零轉換——宿主拿到的就是可以直接餵頂點緩衝的東西 |
| **不透明 handle** | `PmSpell*`／`PmScene*` 對宿主是黑盒，內部表徵可自由演進 |
| **公開 sublibrary** | `magic-core`／`magic-boundary` 皆為 `visibility: public`，外部 cabal 專案可經 `source-repository-package` 直接 `build-depends` |

## 架構圖

```text
      Haskell 宿主            C / C++ / C# / Unity 宿主        demo 外殼
   （examples/haskell）      （examples/c, examples/unity）  （subarch-0005）
            |                            |                        |
            |                            v                        |
            |                +------------------------+           |
            |                | include/particle_magic.h|          |
            |                |  31 個符號，只加不改      |          |
            |                +-----------+------------+           |
            |                            |                        |
            |                            v                        |
            |                +------------------------+           |
            |                | Magic.FFI（src/ffi）    |          |
            |                |  handle 生命週期         |          |
            |                |  JSON 進 / SoA copy-out |          |
            |                |  錯誤碼分類              |          |
            |                +-----------+------------+           |
            |                            |                        |
            +----------------------------+------------------------+
                                         |
========================================= 邊界層（magic-boundary）=========
                                         v
   +-------------------+   +--------------------------+   +------------------+
   | Magic.Codec       |   | Magic.Interface          |   | Magic.Scene      |
   |  loadCircle       |-->|  castSpell / advance     |<--|  castInto        |
   |  saveCircle       |   |  observe -> FrameOutput  |   |  全域配額（先到先得）|
   |  LoadError        |   |  依 (blend, shape) 分批   |   |  CastRefusal     |
   +-------------------+   +----+--------------+------+   +------------------+
                                |              |
                 +--------------+              +--------------+
                 v                                            v
   +---------------------------+                +---------------------------+
   | Magic.Project /Projection |                | Magic.Space               |
   |  project（3D 恆等）        |                |  emitterBox / spellBox    |
   |  orthographic（2D 丟一軸） |                |  occupancyOf（N^3 格網）   |
   |  depthOrder（painter）     |                |  住核心，語意屬輸出        |
   +---------------------------+                +---------------------------+
                 |                                            |
========================================= 純核心 =========================
                 v                                            v
        subarch-0001（compile）          subarch-0003（sample / field）
```

## 資料結構的框架格式

- **輸入**：`CastRequest { circleOf, ctxOf }`、`FrameInput { frameDt }`。JSON 側是帶 `version` 欄的物件，所有槽位可為 `null`，`phases`／`fields`／`anchors` 三個陣層級鍵皆 opt-in（缺鍵等同「無」，因此舊魔法檔逐位元照舊）。
- **輸出**：`FrameOutput { batches :: [RenderBatch] }`；`RenderBatch { rbParticles, rbBlend, rbShape }`，粒子座標為抽象 3D。C 面以九條平行陣列 ＋ 一條 `batch_info`（stride 4）表達同一件事。
- **場景**：`Scene` 是純值，內含 `SpellId → ActiveSpell` 的對應與 `SceneConfig`；已用量由現存法術即時求和，法術結束即釋放。
- **空間摘要**：`OrientedBox` 為中心 ＋ 三軸 ＋ 半長；`OccupancyGrid` 為 N³ 計數陣列，N=3 時另有 `Word32` 位元遮罩。**格網框的可比較性律**由 ADR-0019 定義。
- **錯誤**：Haskell 面是 `Either LoadError`／`Either CompileError`／`Either CastRefusal`；C 面是負值錯誤碼 ＋ 呼叫端提供的 `err_buf`，兩者一一對應。

## 使用到的套件

| 套件 | 元件 | 用途 |
|---|---|---|
| `aeson` | boundary | JSON 編解碼 |
| `bytestring` | boundary、ffi | `loadCircle` 的輸入與 marshalling |
| `text` | boundary | 式子文字與錯誤訊息 |
| `megaparsec`／`parser-combinators` | boundary | 由 [subarch-0002](subarch-0002-expr-language.md) 使用 |
| `vector` | boundary、ffi | 緩衝欄位的傳遞與 copy-out |

## 開發階段

對應主架構的 POC 實作階段，並承擔「可用的庫」這個維度。內部里程碑四個：**M1 唯一入口成立**（骨架與依賴紀律）、**M2 第二種消費模式**（C ABI ＋ 參考綁定）、**M3 多法術**（合成、場景層、場景上 C ABI）、**M4 空間輸出**（碰撞偵測與 AoE 判定的前提）。四者皆已達成，凍結的 C 符號自 11 個成長到 31 個且 `PM_ABI_VERSION` 未動。

## 功能規劃

### 階段一：唯一入口（M1，已交付）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 1 | framework-skeleton | 套件邊界、IO 與核心邊界、`Magic.Interface`／`Magic.Codec` 骨架與端到端資料流 | - | func-0001 |
| 2 | ortho2d-projection | `ViewPlane`／`orthographic`／`depthOrder`：同一份輸出換投影即換維度 | #1 | func-0008 |

### 階段二：第二種消費模式（M2，已交付）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 3 | ffi-foreign-library | `foreign-library` C ABI 外殼、handle 生命週期、決定論跨邊界的等價律 | #1 | func-0009 |
| 4 | host-integration-surface | 投影查詢上 C ABI、C# 參考綁定、手性與位元組序寫進 header | #2, #3 | func-0011 |
| 5 | haskell-host-onboarding | 母語路線的可跑最小宿主 ＋ 2D／像素風接法食譜 | #4 | enhance-0001 |

### 階段三：多法術（M3，已交付）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 6 | scene-layer | `Magic.Scene` 全域配額（先到先得）與 `castSpells` 合成（解釋器半場見 subarch-0001） | #1 | func-0012 |
| 7 | scene-c-abi | `PmScene*` ＋ 10 個純增補匯出 ＋ `PM_ERR_QUOTA`，`PM_ABI_VERSION` 不動 | #3, #6 | func-0018 |

### 階段四：空間輸出（M4，已交付）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 8 | spatial-output-anchors | 貼合有向盒、spell 級聯集、N³ 佔用格網、陣層級 `"anchors"` 多發動點；7 個新 C 匯出 | #7 | func-0025 |

### 階段五：候選（未動工，逐條有記帳來源）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 9 | scene-batch-attribution | 讓宿主知道哪個 batch 屬哪個 `SpellId`：boundary 先加 `observeSceneBy`，C 面再加平行 out 陣列（0018 §8-1，形狀已知且皆為加法） | #7 | - |
| 10 | cast-many-c-abi | 不進場景的多陣合成上 C ABI（`pm_cast_many` → `PmSpell*`）（0018 §8-3） | #7 | - |
| 11 | time-varying-anchors | 跟隨施法者的時變 anchor，以及「此刻」而非「至此刻為止」的時間參數化界（0025 §7-7／§7-8） | #8 | - |
| 12 | schema-v2-migrate | `version` 遞增時的舊版解碼器與 `migrate`——策略已定但從未行使（主架構 §5.1） | #1 | - |
| 13 | more-language-bindings | GDScript／C++ 包裝層（0009 §9-6、0011 §8-3：等真實宿主需求） | #4 | - |
| 14 | ffi-thread-safety | 內部鎖或明文的執行緒模型（0009 §9-2、0011 §8-4：等真實宿主需求） | #3 | - |

**明文不做**（已裁決，不進候選）：熱重載 FFI API（政策為「重載＝重施法」，宿主自行 `pm_cast`）；隔離合成的 per-emitter 場路由（ADR-0012 D4，v1 裁決為完全融合）；按 power 加權與優先權搶佔的配額策略（ADR-0012 D6，需要「重要性」這個遊戲層詞彙）；螢幕映射提升到 `magic-boundary`（enhance-0001 E3：先讓需求出現，再凍結介面）。

小結：共 **14 個 features、5 個階段**，前 8 個已交付，三種消費模式與空間輸出皆已上線；階段五六項全部是加法（新函數／新綁定），沒有一項需要動既有簽名。
